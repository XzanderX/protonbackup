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
    @Published var recentFileActivities: [FileActivity] = []

    /// Maximum number of recent file activities to display
    private let maxRecentActivities = 10

    /// Track active file operations for concurrent worker safety
    private var activeFileOperations: [String: FileActivityStatus] = [:]

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

    /// Timer for periodic destination availability checks.
    private var destinationCheckTimer: Timer?

    /// Single-run lock.
    private var syncState = SyncState()

    /// Observers for sleep/wake notifications.
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    /// Observers for volume mount/unmount notifications.
    private var volumeMountObserver: NSObjectProtocol?
    private var volumeUnmountObserver: NSObjectProtocol?

    /// Grace period work item for drive disconnection events.
    /// External HDDs can briefly disappear due to USB hiccups or power management
    /// without actually being disconnected. We wait before reacting.
    private var disconnectGraceWork: DispatchWorkItem?
    private let disconnectGraceSeconds: Double = 5.0

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
        setupSleepWakeObservers()

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

        // Configure FinderSync badges for the backup destination
        if let dest = destinationPath {
            BadgeService.shared.configure(sourcePath: config.sourcePath, destinationPath: dest)
        }

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

        // Clear stale cancel/pause flags from a previous cycle
        syncState.shouldCancel = false
        syncState.isPaused = false
        syncState.pausedProgress = nil

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

        syncState.resume()
        logService.log(.info, category: .backup, message: "Backup resumed")

        if syncState.isBacking {
            // Engine is still running in its pause loop — just update UI state
            if let progress = syncState.pausedProgress {
                backupState = .backing(progress: progress)
            }
        } else {
            // Engine has exited (e.g., drive was ejected while paused) — start fresh
            syncState.pausedProgress = nil
            runNow()
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

        // Clear previous file activities when starting a new backup
        clearFileActivities()

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
                        self?.handleBackupProgress(progress, sourcePath: localFolderPath)
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

                logService.log(.info, category: .backup,
                               message: "Config: onDemandDownload=\(config.onDemandDownload), offloadAfterBackup=\(config.offloadAfterBackup)")

                if config.onDemandDownload {
                    // On-demand mode: download cloud-only files as needed, optionally offload after
                    // This respects user's Proton Drive sync settings
                    logService.log(.info, category: .backup, message: "Using on-demand backup mode with offload=\(config.offloadAfterBackup)")
                    summary = try await backupEngine.performOnDemandBackup(
                        sourcePath: sourcePath,
                        destinationPath: destPath,
                        deletionPolicy: config.deletionPolicy,
                        keepVersions: config.keepVersions,
                        offloadAfterBackup: config.offloadAfterBackup,
                        pauseChecker: { [weak self] in
                            (self?.syncState.isPaused ?? false) || (self?.syncState.shouldCancel ?? false)
                        },
                        cancelChecker: { [weak self] in
                            self?.syncState.shouldCancel ?? false
                        }
                    ) { [weak self, sourcePath] progress in
                        Task { @MainActor in
                            self?.handleBackupProgress(progress, sourcePath: sourcePath)
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
                    ) { [weak self, sourcePath] progress in
                        Task { @MainActor in
                            self?.handleBackupProgress(progress, sourcePath: sourcePath)
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
                    ) { [weak self, sourcePath] progress in
                        Task { @MainActor in
                            self?.handleBackupProgress(progress, sourcePath: sourcePath)
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

            // Mark all copying activities as completed
            finalizeFileActivities()

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
    /// Re-uses config.sourcePath when it already points to CloudStorage,
    /// avoiding an extra directory scan that triggers a TCC prompt.
    private func detectLocalProtonDriveFolder() -> String? {
        // If the user already configured a CloudStorage source path, use it directly
        if let src = config.sourcePath, src.contains("/Library/CloudStorage/ProtonDrive-") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue {
                return src
            }
        }
        return nil
    }

    // MARK: - Drive monitoring

    private func setupDriveMonitor() {
        driveMonitor.onDestinationConnected = { [weak self] volumeInfo in
            Task { @MainActor in
                guard let self else { return }
                self.cancelDisconnectGrace()
                let wasDisconnected = !self.isDestinationConnected
                self.checkDestinationAvailability()

                if self.isDestinationConnected && wasDisconnected {
                    self.logService.log(.info, category: .driveMonitor,
                                        message: "Backup destination connected: \(volumeInfo.name)")

                    if self.config.notificationsEnabled {
                        self.notificationService.notifyDestinationConnected(volumeName: volumeInfo.name)
                    }

                    // Auto-start backup when drive connects
                    if self.config.setupCompleted {
                        if self.syncState.isLocked {
                            // Engine stuck from before disconnect — reset and restart
                            self.logService.log(.info, category: .driveMonitor,
                                                message: "Resetting stale backup state on reconnect")
                            self.syncState.resetAfterBackup()
                        }
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
                self.scheduleDisconnectGrace(source: "DiskArbitration")
            }
        }
    }

    private func checkDestinationAvailability() {
        let (available, path) = driveMonitor.isDestinationAvailable(bookmark: config.destinationBookmark)

        // If backup is actively running and producing progress, the drive must be connected
        // This fixes stale status after wake from sleep
        let wasDisconnected = !isDestinationConnected
        isDestinationConnected = available
        destinationPath = path

        if !available && config.setupCompleted && !syncState.isLocked {
            backupState = .destinationDisconnected
        } else if available && wasDisconnected {
            // Drive became available - log it
            logService.log(.info, category: .driveMonitor,
                           message: "Destination now available at: \(path ?? "unknown")")
        }
    }

    // MARK: - Sleep/Wake handling

    /// Set up observers for system sleep/wake and volume mount/unmount events.
    private func setupSleepWakeObservers() {
        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter

        // Handle wake from sleep
        wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWakeFromSleep()
        }

        // Handle going to sleep (optional - cancel any running operations)
        sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleGoingToSleep()
        }

        // Handle volume mount - this is more reliable than DiskArbitration for some drives
        volumeMountObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleVolumeMounted(notification)
        }

        // Handle volume unmount
        volumeUnmountObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleVolumeUnmounted(notification)
        }

        // Also start a periodic check timer for destination availability
        // This catches cases where callbacks are missed
        startDestinationCheckTimer()
    }

    /// Handle system wake from sleep.
    private func handleWakeFromSleep() {
        logService.log(.info, category: .app, message: "System woke from sleep, checking destination...")

        // Brief delay to let drives remount
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            self.checkDestinationAvailability()

            guard self.isDestinationConnected && self.config.setupCompleted else { return }

            if self.syncState.isLocked {
                // Backup was running when we went to sleep — it's likely stalled.
                // Reset the lock and restart.
                self.logService.log(.info, category: .app, message: "Backup was active before sleep, restarting...")
                self.syncState.resetAfterBackup()
                self.runNow()
            } else if self.syncState.pendingBackup {
                self.logService.log(.info, category: .app, message: "Resuming pending backup after wake...")
                self.runNow()
            }
        }
    }

    /// Handle system going to sleep.
    private func handleGoingToSleep() {
        logService.log(.info, category: .app, message: "System going to sleep...")

        // Cancel the running backup so it can be cleanly restarted on wake.
        // Network connections and disk I/O will be interrupted by sleep anyway.
        if syncState.isLocked {
            logService.log(.info, category: .app, message: "Cancelling active backup before sleep")
            syncState.cancel()
        }
    }

    /// Handle volume mounted event.
    private func handleVolumeMounted(_ notification: Notification) {
        guard let volumePath = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
            return
        }

        logService.log(.info, category: .driveMonitor,
                       message: "Volume mounted (NSWorkspace): \(volumePath.lastPathComponent)")

        // Brief delay to ensure volume is fully ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            self.cancelDisconnectGrace()
            let wasDisconnected = !self.isDestinationConnected
            self.checkDestinationAvailability()

            // Auto-start backup when destination connects
            if self.isDestinationConnected && wasDisconnected {
                self.logService.log(.info, category: .driveMonitor,
                                    message: "Backup destination connected, starting backup...")

                if self.config.notificationsEnabled {
                    self.notificationService.notifyDestinationConnected(volumeName: volumePath.lastPathComponent)
                }

                // Auto-start backup if setup is complete
                if self.config.setupCompleted {
                    if self.syncState.isLocked {
                        // Engine stuck from before disconnect — reset and restart
                        self.logService.log(.info, category: .driveMonitor,
                                            message: "Resetting stale backup state on reconnect")
                        self.syncState.resetAfterBackup()
                    }
                    self.runNow()
                }
            }
        }
    }

    /// Handle volume unmounted event.
    private func handleVolumeUnmounted(_ notification: Notification) {
        guard let volumePath = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
            return
        }

        logService.log(.info, category: .driveMonitor,
                       message: "Volume unmounted (NSWorkspace): \(volumePath.lastPathComponent)")

        scheduleDisconnectGrace(source: "NSWorkspace:\(volumePath.lastPathComponent)")
    }

    /// Schedule a delayed check after a disconnection event.
    /// External HDDs can momentarily disappear due to USB bus resets, power management,
    /// or cable issues without actually being removed. This grace period avoids
    /// prematurely cancelling a backup for transient glitches.
    private func scheduleDisconnectGrace(source: String) {
        // Cancel any existing grace timer (coalesce rapid events)
        disconnectGraceWork?.cancel()

        logService.log(.info, category: .driveMonitor,
                       message: "Drive disconnect event from \(source), waiting \(Int(disconnectGraceSeconds))s before reacting...")

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                // Re-check: is the destination actually gone?
                let (available, _) = self.driveMonitor.isDestinationAvailable(bookmark: self.config.destinationBookmark)

                if available {
                    self.logService.log(.info, category: .driveMonitor,
                                        message: "Destination still available after grace period — ignoring transient disconnect")
                    return
                }

                // Drive is truly gone — react now
                self.logService.log(.warning, category: .driveMonitor,
                                    message: "Destination confirmed unavailable after grace period")

                if self.syncState.isLocked {
                    self.logService.log(.info, category: .driveMonitor,
                                        message: "Cancelling backup due to drive disconnection")
                    self.cancelBackup()
                }

                self.checkDestinationAvailability()
            }
        }

        disconnectGraceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + disconnectGraceSeconds, execute: work)
    }

    /// Cancel any pending disconnect grace timer (e.g., drive reconnected).
    private func cancelDisconnectGrace() {
        guard disconnectGraceWork != nil else { return }
        disconnectGraceWork?.cancel()
        disconnectGraceWork = nil
        logService.log(.info, category: .driveMonitor,
                       message: "Disconnect grace period cancelled — drive reconnected")
    }

    /// Start periodic timer to check destination availability.
    private func startDestinationCheckTimer() {
        destinationCheckTimer?.invalidate()

        // Check every 30 seconds for destination availability
        destinationCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkDestinationAvailability()
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

    // MARK: - File Activity Tracking

    /// Add a file activity to the recent list.
    func addFileActivity(_ activity: FileActivity) {
        recentFileActivities.insert(activity, at: 0)
        if recentFileActivities.count > maxRecentActivities {
            recentFileActivities.removeLast()
        }
    }

    /// Update the status of an existing file activity (e.g., copying → copied).
    func updateFileActivity(fileName: String, destinationFolder: String, status: FileActivityStatus) {
        if let index = recentFileActivities.firstIndex(where: {
            $0.fileName == fileName && $0.destinationFolder == destinationFolder
        }) {
            let old = recentFileActivities[index]
            recentFileActivities[index] = FileActivity(
                fileName: old.fileName,
                destinationFolder: old.destinationFolder,
                fileSize: old.fileSize,
                status: status
            )
        }
    }

    /// Clear all recent file activities.
    func clearFileActivities() {
        recentFileActivities.removeAll()
        activeFileOperations.removeAll()
    }

    /// Handle progress update and track file activities.
    /// Call this from backup progress handlers to automatically track file operations.
    func handleBackupProgress(_ progress: BackupProgress, sourcePath: String?) {
        // Update backup state
        if syncState.isPaused {
            backupState = .paused(progress: progress)
        } else {
            backupState = .backing(progress: progress)
        }

        // If backup is actively running, the drive must be connected
        // This fixes stale "Drive not connected" status after wake from sleep
        if !isDestinationConnected && destinationPath != nil {
            checkDestinationAvailability()
        }

        // Track file activity using destination path
        guard let currentFile = progress.currentFileName,
              let destPath = destinationPath else { return }

        // Determine status based on filename prefix (set by BackupEngine)
        let status = determineFileStatus(from: currentFile, progress: progress)

        // Skip status messages (scanning, checking, etc.) — not real file operations
        if case .indexing = status { return }

        let cleanFileName = cleanFileNameForDisplay(currentFile)
        let (fileName, destFolder) = splitFilePathForDestination(cleanFileName, destRoot: destPath)
        let fileKey = cleanFileName

        // Check if this is a terminal status
        let isTerminal: Bool
        switch status {
        case .offloaded, .copied, .deleted, .skipped, .error:
            isTerminal = true
        default:
            isTerminal = false
        }

        if activeFileOperations[fileKey] != nil {
            // File already tracked — update its status
            updateFileActivity(fileName: fileName, destinationFolder: destFolder, status: status)
            if isTerminal {
                activeFileOperations.removeValue(forKey: fileKey)
            } else {
                activeFileOperations[fileKey] = status
            }
        } else {
            // New file — add activity
            // Use file size from BackupEngine progress (avoids stat() syscall on main thread)
            let fileSize = progress.currentFileSize

            addFileActivity(FileActivity(
                fileName: fileName,
                destinationFolder: destFolder,
                fileSize: fileSize,
                status: status
            ))
            if !isTerminal {
                activeFileOperations[fileKey] = status
            }
        }
    }

    /// Determine file activity status based on progress info.
    private func determineFileStatus(from fileName: String, progress: BackupProgress) -> FileActivityStatus {
        // BackupEngine prefixes with ⏳ for waiting to download
        if fileName.hasPrefix("⏳") {
            return .waitingToDownload
        }

        // BackupEngine prefixes with ⬇ for active downloads
        if fileName.hasPrefix("⬇") {
            // Use per-file download progress from st_blocks/st_size when available
            return .downloading(progress: progress.currentFileProgress ?? 0.0)
        }

        // BackupEngine prefixes with ⬆ for offloading (evicting to cloud)
        if fileName.hasPrefix("⬆") {
            return .offloading
        }

        // BackupEngine prefixes with ☁ for offloaded (evicted to cloud)
        if fileName.hasPrefix("☁") {
            return .offloaded
        }

        // BackupEngine prefixes with 🗑 for deletions
        if fileName.hasPrefix("🗑") {
            return .deleted
        }

        // Status messages (not real files) — treat as indexing
        let lower = fileName.lowercased()
        if lower.contains("scanning") || lower.contains("indexing") || lower.contains("checking") {
            return .indexing
        }

        // Default to copying with indeterminate progress
        return .copying(progress: nil)
    }

    /// Remove status prefixes from file name for display.
    private func cleanFileNameForDisplay(_ fileName: String) -> String {
        var clean = fileName
        // Remove waiting prefix
        if clean.hasPrefix("⏳ ") {
            clean = String(clean.dropFirst(2))
        } else if clean.hasPrefix("⏳") {
            clean = String(clean.dropFirst(1))
        }
        // Remove download prefix
        if clean.hasPrefix("⬇ ") {
            clean = String(clean.dropFirst(2))
        } else if clean.hasPrefix("⬇") {
            clean = String(clean.dropFirst(1))
        }
        // Remove offloading prefix
        if clean.hasPrefix("⬆ ") {
            clean = String(clean.dropFirst(2))
        } else if clean.hasPrefix("⬆") {
            clean = String(clean.dropFirst(1))
        }
        // Remove offloaded prefix
        if clean.hasPrefix("☁ ") {
            clean = String(clean.dropFirst(2))
        } else if clean.hasPrefix("☁") {
            clean = String(clean.dropFirst(1))
        }
        // Remove deletion prefix
        if clean.hasPrefix("🗑 ") {
            clean = String(clean.dropFirst(2))
        } else if clean.hasPrefix("🗑") {
            clean = String(clean.dropFirst(1))
        }
        return clean
    }

    /// Split a relative file path into file name and destination folder path.
    private func splitFilePathForDestination(_ relPath: String, destRoot: String) -> (fileName: String, destFolder: String) {
        let nsPath = relPath as NSString
        let fileName = nsPath.lastPathComponent
        let relFolder = nsPath.deletingLastPathComponent

        let destFolder = relFolder.isEmpty ? destRoot : (destRoot as NSString).appendingPathComponent(relFolder)
        return (fileName, destFolder)
    }

    /// Mark all active activities as "copied" when backup completes.
    func finalizeFileActivities() {
        for (index, activity) in recentFileActivities.enumerated() {
            if activity.status.isActive {
                recentFileActivities[index] = FileActivity(
                    fileName: activity.fileName,
                    destinationFolder: activity.destinationFolder,
                    fileSize: activity.fileSize,
                    status: .copied
                )
            }
        }
        activeFileOperations.removeAll()
    }

    // MARK: - Account management

    /// Sign out and reset.
    func signOut() async {
        pollingTimer?.invalidate()
        destinationCheckTimer?.invalidate()
        fileWatcher.stopWatching()
        driveMonitor.stopMonitoring()

        // Remove sleep/wake and volume observers
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if let observer = wakeObserver {
            notificationCenter.removeObserver(observer)
        }
        if let observer = sleepObserver {
            notificationCenter.removeObserver(observer)
        }
        if let observer = volumeMountObserver {
            notificationCenter.removeObserver(observer)
        }
        if let observer = volumeUnmountObserver {
            notificationCenter.removeObserver(observer)
        }

        await authService.logout()

        config = .default
        saveConfig()

        backupState = .notConfigured
        WindowManager.shared.showSetupWizard()
    }
}
