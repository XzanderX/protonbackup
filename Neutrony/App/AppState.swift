import Foundation
import SwiftUI
import Combine

/// Central application state that coordinates all services and drives the UI.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    @Published var config: BackupConfiguration
    @Published var backupState: BackupState = .notConfigured
    @Published var lastSummary: BackupSummary?
    @Published var isDestinationConnected: Bool = false
    @Published var destinationPath: String?

    // MARK: - Services

    let logService = LogService.shared
    let notificationService = NotificationService.shared
    let authService = ProtonAuthService.shared
    let driveClient = ProtonDriveClient.shared
    let loginItemService = LoginItemService.shared

    private(set) var syncEngine: SyncEngine!
    private(set) var backupEngine: BackupEngine!
    private(set) var driveMonitor: DriveMonitor!
    private(set) var fileWatcher: FileWatcher!
    private(set) var versionManager: VersionManager!
    private(set) var snapshotManager: SnapshotManager!

    /// Timer for periodic remote change polling.
    private var pollingTimer: Timer?

    /// Single-run lock.
    private var syncState = SyncState()

    // MARK: - Initialization

    init() {
        self.config = BackupConfiguration.load()

        let versionMgr = VersionManager(logService: LogService.shared)
        self.versionManager = versionMgr
        self.syncEngine = SyncEngine(logService: LogService.shared)
        self.backupEngine = BackupEngine(logService: LogService.shared, versionManager: versionMgr)
        self.driveMonitor = DriveMonitor(logService: LogService.shared)
        self.fileWatcher = FileWatcher(logService: LogService.shared)
        self.snapshotManager = SnapshotManager(logService: LogService.shared)

        setupDriveMonitor()
        setupFileWatcher()

        // Wire self to WindowManager so it can create windows with appState
        WindowManager.shared.appState = self

        logService.log(.info, category: .app, message: "AppState initialized, setupCompleted=\(config.setupCompleted)")

        if config.setupCompleted {
            startOperations()
        }
        // If not configured, AppDelegate will open the setup wizard
    }

    // MARK: - Setup

    /// Called when the setup wizard completes.
    func completeSetup(config: BackupConfiguration) {
        self.config = config
        self.config.setupCompleted = true
        saveConfig()

        WindowManager.shared.closeWindow(id: "setup-wizard")
        startOperations()

        // Automatically start the first backup
        logService.log(.info, category: .app, message: "Setup complete, starting initial backup...")
        runNow()
    }

    /// Save current configuration to disk.
    func saveConfig() {
        do {
            try config.save()
            loginItemService.syncWithConfig(config)
        } catch {
            logService.log(.error, category: .config,
                           message: "Failed to save configuration: \(error.localizedDescription)")
        }
    }

    // MARK: - Operations

    /// Start all background operations after setup is complete.
    private func startOperations() {
        // Don't reset state if backup is already in progress
        if !syncState.isLocked {
            backupState = .idle
        } else {
            logService.log(.debug, category: .app, message: "startOperations: backup in progress, preserving state")
        }

        // Check destination availability
        checkDestinationAvailability()

        // Start drive monitoring
        driveMonitor.startMonitoring()

        // Start file watching
        fileWatcher.startWatching(path: config.localMirrorPath)

        // Start polling timer
        startPollingTimer()

        // Request notification permission
        Task {
            _ = await notificationService.requestPermission()
        }

        // Initialize sync engine only for rclone mode (which uses Proton API)
        // Cloud-verified and local-only modes use the Proton Drive app's local folder
        if config.useRclone && config.rcloneConfigured {
            Task {
                do {
                    try await syncEngine.initialize()
                    logService.log(.info, category: .app, message: "App ready (rclone mode)")
                } catch {
                    logService.log(.error, category: .app,
                                   message: "Failed to initialize sync engine: \(error.localizedDescription)")
                    backupState = .error(message: error.localizedDescription)
                }
            }
        } else {
            // For cloud-verified or local-only modes, we're ready immediately
            logService.log(.info, category: .app, message: "App ready (local folder mode)")
        }
    }

    // MARK: - Manual triggers

    /// Run a complete backup cycle now.
    func runNow() {
        guard !syncState.isLocked else {
            logService.log(.warning, category: .app, message: "Backup already in progress, ignoring runNow request")
            return
        }

        logService.log(.info, category: .app, message: "Starting backup cycle...")

        Task {
            await performFullBackupCycle()
        }
    }

    /// Perform a sync-only operation (Proton → local mirror).
    /// Only available in rclone mode; local folder modes use Proton Drive app for syncing.
    func syncOnly() {
        // Sync only needed for rclone mode
        guard config.useRclone && config.rcloneConfigured else {
            logService.log(.info, category: .sync,
                           message: "Sync not needed - Proton Drive app handles syncing")
            return
        }

        guard !syncState.isSyncing else { return }

        Task {
            await performSync()
        }
    }

    // MARK: - Backup cycle

    /// Full backup cycle: sync from Proton (if needed), then copy to destination.
    private func performFullBackupCycle() async {
        logService.log(.info, category: .app,
                       message: "performFullBackupCycle: useRclone=\(config.useRclone), isDestConnected=\(isDestinationConnected), destPath=\(destinationPath ?? "nil")")

        // Phase 1: Sync from Proton to local mirror (only for rclone mode)
        // For local folder modes, Proton Drive app handles syncing
        if config.useRclone && config.rcloneConfigured {
            let syncSummary = await performSync()

            // Phase 2: Backup from mirror to destination (if connected)
            guard isDestinationConnected, let destPath = destinationPath else {
                if syncSummary != nil {
                    syncState.pendingBackup = true
                    logService.log(.info, category: .app,
                                   message: "Sync complete. Backup queued until destination connects.")
                }
                return
            }

            await performBackup(to: destPath)
        } else {
            // For local folder modes, go directly to backup
            guard isDestinationConnected, let destPath = destinationPath else {
                syncState.pendingBackup = true
                logService.log(.warning, category: .app,
                               message: "Backup skipped: isDestConnected=\(isDestinationConnected), destPath=\(destinationPath ?? "nil")")
                return
            }

            logService.log(.info, category: .app, message: "Calling performBackup to: \(destPath)")
            await performBackup(to: destPath)
        }
    }

    /// Sync from Proton Drive to local mirror.
    @discardableResult
    private func performSync() async -> BackupSummary? {
        guard !syncState.isSyncing else { return nil }
        syncState.isSyncing = true

        backupState = .syncing(progress: BackupProgress(
            totalFiles: 0, completedFiles: 0, currentFileName: "Starting sync…"
        ))

        do {
            let summary = try await syncEngine.performFullSync(
                mirrorPath: config.localMirrorPath,
                deletionPolicy: config.deletionPolicy
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.backupState = .syncing(progress: progress)
                }
            }

            config.lastSuccessfulSync = Date()
            saveConfig()

            syncState.isSyncing = false
            return summary
        } catch {
            syncState.isSyncing = false
            backupState = .error(message: "Sync failed: \(error.localizedDescription)")
            logService.log(.error, category: .sync,
                           message: "Sync failed: \(error.localizedDescription)")

            if config.notificationsEnabled {
                notificationService.notifyBackupFailed(errorMessage: error.localizedDescription)
            }
            return nil
        }
    }

    /// Pause the current backup.
    func pauseBackup() {
        guard backupState.isRunning else { return }

        if case .backing(let progress) = backupState {
            syncState.pause(progress: progress)
            backupState = .paused(progress: progress)
            logService.log(.info, category: .backup, message: "Backup paused")
        }
    }

    /// Resume a paused backup.
    func resumeBackup() {
        guard backupState.isPaused else { return }

        if let progress = syncState.pausedProgress {
            syncState.resume()
            backupState = .backing(progress: progress)
            logService.log(.info, category: .backup, message: "Backup resumed")
        }
    }

    /// Cancel the current backup (e.g., when drive is ejected).
    func cancelBackup() {
        guard syncState.isLocked else { return }

        syncState.cancel()
        logService.log(.info, category: .backup, message: "Backup cancelled (drive ejected)")

        // Clear badges
        BadgeService.shared.clearAllBadges()
    }

    /// Backup from Proton Drive folder to external destination.
    /// Uses hybrid approach (rclone + local optimization) when rclone is configured.
    private func performBackup(to destPath: String) async {
        guard !syncState.isBacking else {
            logService.log(.warning, category: .backup, message: "Backup already in progress, skipping")
            return
        }
        syncState.isBacking = true
        logService.log(.info, category: .backup, message: "Backup lock acquired, onDemandDownload=\(config.onDemandDownload)")

        backupState = .backing(progress: BackupProgress(
            totalFiles: 0, completedFiles: 0, currentFileName: "Starting backup…"
        ))

        do {
            let summary: BackupSummary

            if config.useRclone && config.rcloneConfigured {
                // Hybrid mode: use rclone as source of truth, copy from local when available
                let localFolderPath = detectLocalProtonDriveFolder()

                summary = try await backupEngine.performHybridBackup(
                    localFolderPath: localFolderPath,
                    destinationPath: destPath,
                    deletionPolicy: config.deletionPolicy,
                    keepVersions: config.keepVersions,
                    pauseChecker: { [weak self] in
                        (self?.syncState.isPaused ?? false) || (self?.syncState.shouldCancel ?? false)
                    }
                ) { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        if self.syncState.isPaused {
                            self.backupState = .paused(progress: progress)
                        } else {
                            self.backupState = .backing(progress: progress)
                        }
                    }
                }
            } else {
                // Local folder mode: copy from Proton Drive app folder
                guard let sourcePath = config.sourcePath else {
                    logService.log(.error, category: .backup, message: "No source path configured")
                    syncState.isBacking = false
                    backupState = .error(message: "No source path configured")
                    return
                }

                if config.onDemandDownload {
                    // On-demand mode: download cloud-only files as needed, optionally offload after
                    // This respects user's Proton Drive sync settings
                    summary = try await backupEngine.performOnDemandBackup(
                        sourcePath: sourcePath,
                        destinationPath: destPath,
                        deletionPolicy: config.deletionPolicy,
                        keepVersions: config.keepVersions,
                        offloadAfterBackup: config.offloadAfterBackup,
                        pauseChecker: { [weak self] in
                            (self?.syncState.isPaused ?? false) || (self?.syncState.shouldCancel ?? false)
                        }
                    ) { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            if self.syncState.isPaused {
                                self.backupState = .paused(progress: progress)
                            } else {
                                self.backupState = .backing(progress: progress)
                            }
                        }
                    }
                } else if config.requireCloudSync {
                    // Cloud-verified mode: only backup files confirmed synced with cloud
                    summary = try await backupEngine.performCloudVerifiedBackup(
                        sourcePath: sourcePath,
                        destinationPath: destPath,
                        deletionPolicy: config.deletionPolicy,
                        keepVersions: config.keepVersions,
                        requireSync: true,
                        pauseChecker: { [weak self] in
                            (self?.syncState.isPaused ?? false) || (self?.syncState.shouldCancel ?? false)
                        }
                    ) { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            if self.syncState.isPaused {
                                self.backupState = .paused(progress: progress)
                            } else {
                                self.backupState = .backing(progress: progress)
                            }
                        }
                    }
                } else {
                    // Simple local backup: copy all local files without sync verification
                    summary = try await backupEngine.performBackup(
                        sourcePath: sourcePath,
                        destinationPath: destPath,
                        deletionPolicy: config.deletionPolicy,
                        keepVersions: config.keepVersions,
                        pauseChecker: { [weak self] in
                            (self?.syncState.isPaused ?? false) || (self?.syncState.shouldCancel ?? false)
                        }
                    ) { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            if self.syncState.isPaused {
                                self.backupState = .paused(progress: progress)
                            } else {
                                self.backupState = .backing(progress: progress)
                            }
                        }
                    }
                }
            }

            config.lastSuccessfulBackup = Date()
            saveConfig()

            // Create point-in-time capture if configured
            if config.snapshotMode != .disabled {
                do {
                    let captureName = try snapshotManager.createSnapshot(
                        backupRoot: destPath, mode: config.snapshotMode)
                    if let name = captureName {
                        logService.log(.info, category: .history,
                                       message: "Point-in-time capture created: \(name)")
                    }

                    // Purge old captures if retention is configured
                    if config.snapshotRetentionDays > 0 && config.snapshotMode == .apfsClone {
                        let purged = try snapshotManager.purgeOldClones(
                            backupRoot: destPath,
                            olderThanDays: config.snapshotRetentionDays)
                        if purged > 0 {
                            logService.log(.info, category: .history,
                                           message: "Purged \(purged) old capture(s)")
                        }
                    }
                } catch {
                    logService.log(.warning, category: .history,
                                   message: "Point-in-time capture failed: \(error.localizedDescription)")
                }
            }

            lastSummary = summary

            // Check if backup was cancelled (drive ejected)
            let wasCancelled = syncState.shouldCancel
            syncState.resetAfterBackup()

            if wasCancelled {
                backupState = .destinationDisconnected
                logService.log(.info, category: .app, message: "Backup cancelled due to drive ejection")
            } else {
                backupState = .upToDate
                logService.log(.info, category: .app, message: "Backup complete: \(summary.displayText)")
            }

            if config.notificationsEnabled && !wasCancelled {
                if summary.succeeded {
                    notificationService.notifyBackupComplete(summary: summary)
                } else {
                    notificationService.notifyBackupFailed(
                        errorMessage: "\(summary.errors.count) errors during backup"
                    )
                }
            }
        } catch {
            syncState.isBacking = false
            backupState = .error(message: "Backup failed: \(error.localizedDescription)")
            logService.log(.error, category: .backup,
                           message: "Backup failed: \(error.localizedDescription)")

            if config.notificationsEnabled {
                notificationService.notifyBackupFailed(errorMessage: error.localizedDescription)
            }
        }
    }

    /// Detect the local Proton Drive app folder if available.
    private func detectLocalProtonDriveFolder() -> String? {
        let cloudStoragePath = NSHomeDirectory() + "/Library/CloudStorage"
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: cloudStoragePath) else {
            return nil
        }

        if let protonFolder = contents.first(where: { $0.hasPrefix("ProtonDrive-") }) {
            let fullPath = cloudStoragePath + "/" + protonFolder
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                return fullPath
            }
        }

        return nil
    }

    // MARK: - Drive monitoring

    private func setupDriveMonitor() {
        driveMonitor.onDestinationConnected = { [weak self] volumeInfo in
            Task { @MainActor in
                guard let self else { return }
                self.checkDestinationAvailability()

                if self.isDestinationConnected {
                    self.logService.log(.info, category: .driveMonitor,
                                        message: "Backup destination connected: \(volumeInfo.name)")

                    if self.config.notificationsEnabled {
                        self.notificationService.notifyDestinationConnected(volumeName: volumeInfo.name)
                    }

                    // Auto-start backup when drive connects (if setup is complete and not already running)
                    if self.config.setupCompleted && !self.syncState.isLocked {
                        self.logService.log(.info, category: .driveMonitor,
                                            message: "Auto-starting backup on drive connect...")
                        self.runNow()
                    }
                }
            }
        }

        driveMonitor.onDestinationDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                // Cancel any running backup when drive is ejected
                if self.syncState.isLocked {
                    self.logService.log(.info, category: .driveMonitor,
                                        message: "Backup destination ejected, cancelling backup...")
                    self.cancelBackup()
                }

                self.checkDestinationAvailability()
            }
        }
    }

    private func checkDestinationAvailability() {
        let (available, path) = driveMonitor.isDestinationAvailable(bookmark: config.destinationBookmark)
        isDestinationConnected = available
        destinationPath = path

        if !available && config.setupCompleted && !syncState.isLocked {
            backupState = .destinationDisconnected
        }
    }

    // MARK: - File watching

    private func setupFileWatcher() {
        fileWatcher.onChangesDetected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.config.setupCompleted else { return }
                guard self.isDestinationConnected else {
                    self.syncState.pendingBackup = true
                    return
                }
                guard !self.syncState.isLocked else { return }

                self.logService.log(.info, category: .fileWatcher,
                                    message: "Local changes detected, starting backup…")

                if let destPath = self.destinationPath {
                    await self.performBackup(to: destPath)
                }
            }
        }
    }

    // MARK: - Polling

    private func startPollingTimer() {
        pollingTimer?.invalidate()

        // Remote polling only needed for rclone mode which uses Proton API
        // For local folder modes, FileWatcher detects changes when Proton Drive app syncs
        guard config.useRclone && config.rcloneConfigured else {
            logService.log(.debug, category: .app, message: "Polling disabled (local folder mode)")
            return
        }

        let interval = TimeInterval(config.pollingIntervalMinutes * 60)
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.syncState.isLocked else { return }

                self.logService.log(.debug, category: .app, message: "Polling for remote changes…")

                do {
                    let result = try await self.syncEngine.checkForRemoteChanges()
                    if result.hasChanges {
                        self.logService.log(.info, category: .sync,
                                            message: "\(result.changes.count) remote changes detected")
                        await self.performFullBackupCycle()
                    } else {
                        self.logService.log(.debug, category: .sync, message: "No remote changes")
                    }
                } catch {
                    self.logService.log(.warning, category: .sync,
                                        message: "Failed to check remote changes: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Update the polling interval and restart the timer.
    func updatePollingInterval(_ minutes: Int) {
        config.pollingIntervalMinutes = minutes
        saveConfig()
        startPollingTimer()
    }

    // MARK: - Account management

    /// Sign out and reset.
    func signOut() async {
        pollingTimer?.invalidate()
        fileWatcher.stopWatching()
        driveMonitor.stopMonitoring()

        await authService.logout()

        config = .default
        saveConfig()

        backupState = .notConfigured
        WindowManager.shared.showSetupWizard()
    }
}
