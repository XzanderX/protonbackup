import SwiftUI

/// The app settings view, shown in the macOS Settings window.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            BackupSettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("Backup", systemImage: "externaldrive")
                }
                .tag(SettingsTab.backup)

            AccountSettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("Account", systemImage: "person")
                }
                .tag(SettingsTab.account)

            AdvancedSettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                .tag(SettingsTab.advanced)
        }
        .padding(20)
    }
}

enum SettingsTab {
    case general, backup, account, advanced
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Start at login", isOn: Binding(
                    get: { appState.config.startAtLogin },
                    set: { newValue in
                        appState.config.startAtLogin = newValue
                        appState.saveConfig()
                    }
                ))

                Toggle("Show notifications", isOn: Binding(
                    get: { appState.config.notificationsEnabled },
                    set: { newValue in
                        appState.config.notificationsEnabled = newValue
                        appState.saveConfig()
                    }
                ))
            } header: {
                Text("App Behavior")
            }

            Section {
                Picker("Check for remote changes every", selection: Binding(
                    get: { appState.config.pollingIntervalMinutes },
                    set: { appState.updatePollingInterval($0) }
                )) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("60 minutes").tag(60)
                    Text("120 minutes").tag(120)
                }
            } header: {
                Text("Sync Schedule")
            }

            Section {
                if let lastSync = appState.config.lastSuccessfulSync {
                    LabeledContent("Last sync") {
                        Text(lastSync.shortString)
                    }
                }
                if let lastBackup = appState.config.lastSuccessfulBackup {
                    LabeledContent("Last backup") {
                        Text(lastBackup.shortString)
                    }
                }
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Backup Settings

struct BackupSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                LabeledContent("Destination") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(appState.config.destinationDisplayName ?? "Not set")
                        HStack {
                            Circle()
                                .fill(appState.isDestinationConnected ? Color.statusGreen : Color.statusRed)
                                .frame(width: 8, height: 8)
                            Text(appState.isDestinationConnected ? "Connected" : "Disconnected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Button("Change Destination…") {
                    changeDestination()
                }
            } header: {
                Text("Backup Destination")
            }

            Section {
                LabeledContent("Mirror path") {
                    Text(appState.config.localMirrorPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Change Mirror Location…") {
                    changeMirrorLocation()
                }

                Button("Open Mirror Folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: appState.config.localMirrorPath))
                }
            } header: {
                Text("Local Mirror")
            }

            Section {
                Picker("Deletion policy", selection: Binding(
                    get: { appState.config.deletionPolicy },
                    set: { newValue in
                        appState.config.deletionPolicy = newValue
                        appState.saveConfig()
                    }
                )) {
                    ForEach(DeletionPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }

                Toggle("Keep file versions", isOn: Binding(
                    get: { appState.config.keepVersions },
                    set: { newValue in
                        appState.config.keepVersions = newValue
                        appState.saveConfig()
                    }
                ))

                Text(appState.config.deletionPolicy.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Deletion & Versioning")
            }
        }
        .formStyle(.grouped)
    }

    private func changeDestination() {
        guard let url = BookmarkManager.selectFolder(
            title: "Choose Backup Destination",
            message: "Select the folder where backups will be stored."
        ) else { return }

        do {
            let bookmark = try BookmarkManager.createReadWriteBookmark(for: url)
            appState.config.destinationBookmark = bookmark
            appState.config.destinationDisplayName = url.lastPathComponent
            appState.saveConfig()
        } catch {
            appState.logService.log(.error, category: .config,
                                     message: "Failed to update destination: \(error.localizedDescription)")
        }
    }

    private func changeMirrorLocation() {
        guard let url = BookmarkManager.selectFolder(
            title: "Choose Mirror Location",
            message: "Select where the local mirror will be stored."
        ) else { return }

        appState.config.localMirrorPath = url.path
        appState.saveConfig()
        appState.fileWatcher.stopWatching()
        appState.fileWatcher.startWatching(path: url.path)
    }
}

// MARK: - Account Settings

struct AccountSettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var showingSignOutConfirmation = false

    var body: some View {
        Form {
            Section {
                if let username = KeychainService.shared.getUsername() {
                    LabeledContent("Signed in as") {
                        Text(username)
                    }
                } else {
                    Text("Not signed in")
                        .foregroundColor(.secondary)
                }

                LabeledContent("Session") {
                    Text(ProtonAuthService.shared.hasSession ? "Active" : "None")
                        .foregroundColor(ProtonAuthService.shared.hasSession ? .statusGreen : .secondary)
                }

                Button("Test Connection") {
                    Task {
                        let success = try? await ProtonAuthService.shared.testConnection()
                        if success == true {
                            appState.logService.log(.info, category: .auth, message: "Connection test passed")
                        } else {
                            appState.logService.log(.warning, category: .auth, message: "Connection test failed")
                        }
                    }
                }
            } header: {
                Text("Proton Account")
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    showingSignOutConfirmation = true
                }
                .confirmationDialog(
                    "Sign Out",
                    isPresented: $showingSignOutConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Sign Out", role: .destructive) {
                        Task {
                            await appState.signOut()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will stop all backups and remove stored credentials. Your backup files will not be deleted.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var isExportingDiagnostics = false
    @State private var exportResult: String?

    var body: some View {
        Form {
            Section {
                Button("Open Log Viewer") {
                    openWindow(id: "log-viewer")
                }

                Button("Open Log File in Finder") {
                    let url = URL(fileURLWithPath: appState.logService.logFilePath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } header: {
                Text("Logging")
            }

            Section {
                Button("Export Diagnostics…") {
                    exportDiagnostics()
                }
                .disabled(isExportingDiagnostics)

                if let result = exportResult {
                    Text(result)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("Creates a zip file with logs and settings (no passwords or tokens).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Diagnostics")
            }

            Section {
                Button("Reset All Settings", role: .destructive) {
                    // TODO: confirmation dialog
                }

                Text("This will remove all configuration and require a new setup.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Reset")
            }
        }
        .formStyle(.grouped)
    }

    private func exportDiagnostics() {
        isExportingDiagnostics = true
        exportResult = nil

        Task {
            do {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "ProtonBackup-diagnostics.zip"
                panel.allowedContentTypes = [.zip]

                let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow())
                if response == .OK, let url = panel.url {
                    let exportURL = try DiagnosticsExporter.export(to: url.deletingLastPathComponent())
                    exportResult = "Exported to \(exportURL.lastPathComponent)"
                }
            } catch {
                exportResult = "Export failed: \(error.localizedDescription)"
            }
            isExportingDiagnostics = false
        }
    }
}
