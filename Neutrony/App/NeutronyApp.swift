import SwiftUI

@main
struct NeutronyApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Menu bar extra (the primary interface)
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.backupState.menuBarIconName)
        }
        .menuBarExtraStyle(.window)

        // Settings window (uses macOS native Settings scene)
        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 500, height: 600)
        }
    }
}
