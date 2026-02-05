import SwiftUI

@main
struct ProtonBackupApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        // Menu bar extra (the primary interface)
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.backupState.menuBarIconName)
        }

        // Setup wizard window
        Window("Proton Backup Setup", id: "setup-wizard") {
            SetupWizardView()
                .environmentObject(appState)
                .frame(width: 600, height: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 500, height: 600)
        }

        // Log viewer window
        Window("Backup Log", id: "log-viewer") {
            LogViewerView()
                .environmentObject(appState)
                .frame(minWidth: 600, minHeight: 400)
        }

        // Restore help window
        Window("Restore Help", id: "restore-help") {
            RestoreHelpView()
                .environmentObject(appState)
                .frame(width: 500, height: 450)
        }
        .windowResizability(.contentSize)
    }
}
