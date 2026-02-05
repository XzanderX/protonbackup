import AppKit

/// App delegate that handles lifecycle events for the menu bar app.
/// Primary responsibility: open the setup wizard on first launch.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        let log = LogService.shared

        // Ensure the app can receive keyboard/mouse input even when running via `swift run`
        // (LSUIElement apps need this to properly activate windows)
        NSApp.setActivationPolicy(.accessory)

        log.log(.info, category: .app, message: "applicationDidFinishLaunching")
        log.log(.info, category: .app, message: "WindowManager.appState is \(WindowManager.shared.appState == nil ? "nil" : "set")")

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar app should keep running when windows close
        false
    }
}
