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

    private let finderSyncHelper = FinderSyncHelper.shared
    @State private var extensionEnabled = false

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

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Finder badges")
                            .font(.body)
                        Text("Show sync progress on files in Finder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if !finderSyncHelper.isExtensionAvailable() {
                        Text("Not available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if extensionEnabled {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.statusGreen)
                                .frame(width: 8, height: 8)
                            Text("Enabled")
                                .font(.caption)
                                .foregroundColor(.statusGreen)
                        }
                    } else {
                        Button("Enable") {
                            _ = finderSyncHelper.requestEnableExtension()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if !extensionEnabled && finderSyncHelper.isExtensionAvailable() {
                    Button("Check Extension Status") {
                        Task {
                            await checkExtensionStatus()
                        }
                    }
                    .font(.caption)
                }
            } header: {
                Text("Finder Integration")
            } footer: {
                if !finderSyncHelper.isExtensionAvailable() {
                    Text("Build with `make package` to include the Finder extension.")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await checkExtensionStatus()
        }
    }

    private func checkExtensionStatus() async {
        extensionEnabled = await finderSyncHelper.isExtensionEnabledAsync()
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

                // Versioning disabled for now
                // Toggle("Keep file versions", isOn: Binding(
                //     get: { appState.config.keepVersions },
                //     set: { newValue in
                //         appState.config.keepVersions = newValue
                //         appState.saveConfig()
                //     }
                // ))

                Text(appState.config.deletionPolicy.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Deletion Policy")
            }

            Section {
                Toggle("Smart on-demand backup", isOn: Binding(
                    get: { appState.config.onDemandDownload },
                    set: { newValue in
                        appState.config.onDemandDownload = newValue
                        appState.saveConfig()
                    }
                ))

                Text("Downloads cloud-only files as needed for backup. Only downloads files that have changed since last backup.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if appState.config.onDemandDownload {
                    Toggle("Offload after backup", isOn: Binding(
                        get: { appState.config.offloadAfterBackup },
                        set: { newValue in
                            appState.config.offloadAfterBackup = newValue
                            appState.saveConfig()
                        }
                    ))

                    Text("Removes downloaded files after backup to free up local space. Respects your Proton Drive sync settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Smart Backup")
            } footer: {
                Text("Ideal for users who keep only some folders downloaded locally in Proton Drive.")
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

}

// MARK: - Account Settings

struct AccountSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                if let sourcePath = appState.config.sourcePath {
                    LabeledContent("Proton Drive folder") {
                        Text(sourcePath)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    LabeledContent("Status") {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(folderExists(sourcePath) ? Color.statusGreen : Color.statusRed)
                                .frame(width: 8, height: 8)
                            Text(folderExists(sourcePath) ? "Accessible" : "Not found")
                                .foregroundColor(folderExists(sourcePath) ? .statusGreen : .statusRed)
                        }
                    }

                    Button("Open in Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: sourcePath))
                    }

                    Button("Change Source Folder…") {
                        changeSourceFolder()
                    }
                } else {
                    Text("No Proton Drive folder configured")
                        .foregroundColor(.secondary)

                    Button("Select Proton Drive Folder…") {
                        changeSourceFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.protonPurple)
                }
            } header: {
                Text("Proton Drive Source")
            }

            Section {
                Text("This app backs up files from the Proton Drive sync folder (created by the official Proton Drive macOS app) to your external backup drive.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Link("Download Proton Drive app", destination: URL(string: "https://proton.me/drive/download")!)
                    .font(.caption)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
    }

    private func folderExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func changeSourceFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Proton Drive Folder"
        panel.message = "Choose the folder where Proton Drive syncs your files"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        let cloudStoragePath = NSHomeDirectory() + "/Library/CloudStorage"
        if FileManager.default.fileExists(atPath: cloudStoragePath) {
            panel.directoryURL = URL(fileURLWithPath: cloudStoragePath)
        }

        if panel.runModal() == .OK, let url = panel.url {
            appState.config.sourcePath = url.path
            appState.saveConfig()
            appState.logService.log(.info, category: .config,
                message: "Changed source folder to: \(url.path)")
        }
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var isExportingDiagnostics = false
    @State private var exportResult: String?

    var body: some View {
        Form {
            Section {
                Button("Open Log Viewer") {
                    WindowManager.shared.showLogViewer()
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
                panel.nameFieldStringValue = "Neutrony-diagnostics.zip"
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
