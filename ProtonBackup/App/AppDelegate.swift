import AppKit

/// App delegate that handles lifecycle events for the menu bar app.
/// Primary responsibility: open the setup wizard on first launch.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Give SwiftUI a moment to set up, then check if we need the wizard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let config = BackupConfiguration.load()
            if !config.setupCompleted {
                WindowManager.shared.showSetupWizard()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar app should keep running when windows close
        false
    }
}
