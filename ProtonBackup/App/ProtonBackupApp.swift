import SwiftUI

@main
struct ProtonBackupApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    init() {
        // Wire up the shared WindowManager so it can create windows with appState
        // (actual assignment happens in body via .onAppear since appState is
        //  not yet available at init time)
    }

    var body: some Scene {
        // Menu bar extra (the primary interface)
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .onAppear {
                    // Ensure WindowManager has access to appState
                    WindowManager.shared.appState = appState
                }
        } label: {
            Image(systemName: appState.backupState.menuBarIconName)
        }

        // Settings window (uses macOS native Settings scene)
        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 500, height: 600)
        }
    }
}
