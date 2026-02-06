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
        backupState = .idle

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

        // Initialize sync engine
        Task {
            do {
                try await syncEngine.initialize()
                logService.log(.info, category: .app, message: "App ready")
            } catch {
                logService.log(.error, category: .app,
                               message: "Failed to initialize sync engine: \(error.localizedDescription)")
                backupState = .error(message: error.localizedDescription)
            }
        }
    }

    // MARK: - Manual triggers

    /// Run a complete backup cycle now.
    func runNow() {
        guard !syncState.isLocked else {
            logService.log(.warning, category: .app, message: "Backup already in progress")
            return
        }

        Task {
            await performFullBackupCycle()
        }
    }

    /// Perform a sync-only operation (Proton → local mirror).
    func syncOnly() {
        guard !syncState.isSyncing else { return }

        Task {
            await performSync()
        }
    }

    // MARK: - Backup cycle

    /// Full backup cycle: sync from Proton, then copy to destination.
    private func performFullBackupCycle() async {
        // Phase 1: Sync from Proton to local mirror
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

    /// Backup from Proton Drive folder to external destination.
    private func performBackup(to destPath: String) async {
        guard !syncState.isBacking else { return }
        guard let sourcePath = config.sourcePath else {
            logService.log(.error, category: .backup, message: "No source path configured")
            return
        }
        syncState.isBacking = true

        backupState = .backing(progress: BackupProgress(
            totalFiles: 0, completedFiles: 0, currentFileName: "Starting backup…"
        ))

        do {
            let summary = try await backupEngine.performBackup(
                sourcePath: sourcePath,
                destinationPath: destPath,
                deletionPolicy: config.deletionPolicy,
                keepVersions: config.keepVersions
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.backupState = .backing(progress: progress)
                }
            }

            config.lastSuccessfulBackup = Date()
            saveConfig()

            lastSummary = summary
            syncState.resetAfterBackup()

            backupState = .upToDate
            logService.log(.info, category: .app, message: "Backup complete: \(summary.displayText)")

            if config.notificationsEnabled {
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

                    // If there's a pending backup, run it
                    if self.syncState.pendingBackup || self.backupState == .idle {
                        self.runNow()
                    }
                }
            }
        }

        driveMonitor.onDestinationDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
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
