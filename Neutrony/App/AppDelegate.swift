import AppKit

/// App delegate that handles lifecycle events for the menu bar app.
/// Primary responsibility: open the setup wizard on first launch.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set when the system is shutting down or restarting, so termination
    /// never blocks on a dialog or a running backup.
    private var isPoweringOff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let log = LogService.shared

        log.log(.info, category: .app, message: "applicationDidFinishLaunching")
        log.log(.info, category: .app, message: "WindowManager.appState is \(WindowManager.shared.appState == nil ? "nil" : "set")")

        // Posted before the quit event on shutdown/restart: lets us cancel
        // any running backup and terminate immediately without blocking.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isPoweringOff = true
            if let appState = WindowManager.shared.appState {
                Task { @MainActor in appState.cancelBackup() }
            }
            log.log(.info, category: .app, message: "System is powering off — preparing to terminate")
        }

        // Give SwiftUI a moment to finish creating the @StateObject,
        // then open the wizard if setup hasn't been completed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            log.log(.info, category: .app, message: "Checking setup status (delayed)…")
            log.log(.info, category: .app, message: "WindowManager.appState is \(WindowManager.shared.appState == nil ? "nil" : "set")")

            let config = BackupConfiguration.load()
            if !config.setupCompleted {
                log.log(.info, category: .app, message: "Setup not completed — opening wizard")
                WindowManager.shared.showSetupWizard()
            } else {
                log.log(.info, category: .app, message: "Setup already completed — running in background")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never block shutdown/restart: cancel any running backup and quit now.
        // Copies are atomic (temp file + rename), so quitting mid-backup is safe.
        if let appState = WindowManager.shared.appState {
            Task { @MainActor in appState.cancelBackup() }
        }
        if isPoweringOff {
            LogService.shared.log(.info, category: .app, message: "System powering off — terminating immediately")
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar app should keep running when windows close
        false
    }
}
