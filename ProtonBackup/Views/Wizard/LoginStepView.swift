import SwiftUI

/// Login step: Select how to connect to Proton Drive.
/// Supports two modes:
/// 1. Local Folder - Simple backup from Proton Drive app's local folder
/// 2. Cloud-Verified - Backup from local folder with cloud sync verification
struct LoginStepView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var wizardState: WizardState

    enum ConnectionMode: String, CaseIterable {
        case cloudVerified = "Cloud-Verified"
        case localOnly = "Local Only"
    }

    @State private var connectionMode: ConnectionMode = .cloudVerified
    @State private var isSearching = false
    @State private var detectedPath: String?
    @State private var errorMessage: String?
    @State private var syncSummary: SyncSummary?
    @State private var isCheckingSync = false

    private let syncVerifier = CloudSyncVerifier.shared

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Image(systemName: connectionMode == .cloudVerified ? "checkmark.icloud" : "folder.fill")
                .font(.system(size: 40))
                .foregroundColor(.protonPurple)

            Text("Connect to Proton Drive")
                .font(.title2)
                .fontWeight(.semibold)

            // Mode picker
            Picker("Backup Mode", selection: $connectionMode) {
                ForEach(ConnectionMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .onChange(of: connectionMode) { newMode in
                wizardState.requireCloudSync = (newMode == .cloudVerified)
                errorMessage = nil
            }

            // Mode description
            modeDescription

            Divider()
                .padding(.vertical, 8)

            // Folder detection content
            folderContent

            Spacer()

            // Info box
            infoBox
        }
        .onAppear {
            wizardState.requireCloudSync = (connectionMode == .cloudVerified)
            if !wizardState.isAuthenticated {
                detectProtonDriveFolder()
            }
        }
    }

    // MARK: - Mode Description

    @ViewBuilder
    private var modeDescription: some View {
        VStack(spacing: 4) {
            if connectionMode == .cloudVerified {
                Text("Recommended: Verifies files are synced with cloud before backup.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Works with passkeys, 2FA, and all auth methods.")
                    .font(.caption2)
                    .foregroundColor(.protonPurple)
            } else {
                Text("Backs up all local files without cloud verification.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Faster, but may include files not yet synced to cloud.")
                    .font(.caption2)
                    .foregroundColor(.statusYellow)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 400)
    }

    // MARK: - Folder Content

    @ViewBuilder
    private var folderContent: some View {
        if wizardState.isAuthenticated, let path = wizardState.sourcePath {
            // Folder found/selected
            VStack(spacing: 12) {
                Label("Proton Drive folder found", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.statusGreen)

                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.protonPurple)
                    Text(path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

                // Sync status (for cloud-verified mode)
                if connectionMode == .cloudVerified {
                    syncStatusView
                }

                Button("Choose Different Folder…") {
                    selectFolderManually()
                }
                .font(.caption)
            }
        } else {
            // Not found yet
            VStack(spacing: 16) {
                if isSearching {
                    ProgressView("Searching for Proton Drive folder…")
                } else if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.statusYellow)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 350)

                    Button("Select Folder Manually…") {
                        selectFolderManually()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.protonPurple)
                } else {
                    Text("Make sure the Proton Drive app is installed and signed in.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 350)

                    HStack(spacing: 16) {
                        Button("Detect Automatically") {
                            detectProtonDriveFolder()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.protonPurple)

                        Button("Select Manually…") {
                            selectFolderManually()
                        }
                    }
                }
            }
        }

        // Help link
        VStack(spacing: 4) {
            Text("Don't have Proton Drive app?")
                .font(.caption)
                .foregroundColor(.secondary)
            Link("Download from proton.me", destination: URL(string: "https://proton.me/drive/download")!)
                .font(.caption)
        }
        .padding(.top, 8)
    }

    // MARK: - Sync Status View

    @ViewBuilder
    private var syncStatusView: some View {
        if isCheckingSync {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Checking sync status…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else if let summary = syncSummary {
            VStack(spacing: 6) {
                HStack {
                    if summary.allSynced {
                        Label("All files synced with cloud", systemImage: "checkmark.icloud.fill")
                            .foregroundColor(.statusGreen)
                    } else {
                        Label("\(summary.syncedFiles)/\(summary.totalFiles) files synced", systemImage: "icloud")
                            .foregroundColor(.statusYellow)
                    }
                }
                .font(.caption)

                if summary.cloudOnlyFiles > 0 {
                    Text("\(summary.cloudOnlyFiles) files not downloaded locally")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if summary.downloadingFiles > 0 || summary.uploadingFiles > 0 {
                    Text("Syncing in progress…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Button("Refresh") {
                    checkSyncStatus()
                }
                .font(.caption2)
            }
            .padding(10)
            .background(summary.allSynced ? Color.statusGreen.opacity(0.1) : Color.statusYellow.opacity(0.1))
            .cornerRadius(8)
        } else {
            Button("Check Sync Status") {
                checkSyncStatus()
            }
            .font(.caption)
        }
    }

    // MARK: - Info Box

    @ViewBuilder
    private var infoBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("How it works", systemImage: "info.circle")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.protonPurple)

            if connectionMode == .cloudVerified {
                Text("The Proton Drive app handles authentication (including passkeys). We verify each file is synced with the cloud before backing up, ensuring your backup matches what's stored online.")
            } else {
                Text("We copy files from the Proton Drive app's local folder without verifying cloud sync status. This is faster but may include files that haven't been uploaded yet.")
            }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Actions

    private func detectProtonDriveFolder() {
        isSearching = true
        errorMessage = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let cloudStoragePath = NSHomeDirectory() + "/Library/CloudStorage"
            let fileManager = FileManager.default

            do {
                let contents = try fileManager.contentsOfDirectory(atPath: cloudStoragePath)

                // Look for ProtonDrive-* folder
                if let protonFolder = contents.first(where: { $0.hasPrefix("ProtonDrive-") }) {
                    let fullPath = cloudStoragePath + "/" + protonFolder

                    // Verify it's a directory
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                        wizardState.sourcePath = fullPath
                        wizardState.isAuthenticated = true
                        wizardState.useRclone = false
                        wizardState.requireCloudSync = (connectionMode == .cloudVerified)

                        // Extract username from folder name
                        let detectedUsername = String(protonFolder.dropFirst("ProtonDrive-".count))
                        wizardState.username = detectedUsername

                        appState.logService.log(.info, category: .config,
                            message: "Detected Proton Drive folder: \(fullPath)")

                        // Check sync status if cloud-verified mode
                        if connectionMode == .cloudVerified {
                            checkSyncStatus()
                        }
                    }
                } else {
                    errorMessage = "Proton Drive folder not found. Please install the Proton Drive app and sign in, or select the folder manually."
                }
            } catch {
                errorMessage = "Could not search for Proton Drive folder. Please select it manually."
                appState.logService.log(.warning, category: .config,
                    message: "Failed to search CloudStorage: \(error.localizedDescription)")
            }

            isSearching = false
        }
    }

    private func selectFolderManually() {
        let panel = NSOpenPanel()
        panel.title = "Select Proton Drive Folder"
        panel.message = "Choose the folder where Proton Drive syncs your files"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        // Start in CloudStorage if it exists
        let cloudStoragePath = NSHomeDirectory() + "/Library/CloudStorage"
        if FileManager.default.fileExists(atPath: cloudStoragePath) {
            panel.directoryURL = URL(fileURLWithPath: cloudStoragePath)
        }

        if panel.runModal() == .OK, let url = panel.url {
            wizardState.sourcePath = url.path
            wizardState.isAuthenticated = true
            wizardState.useRclone = false
            wizardState.requireCloudSync = (connectionMode == .cloudVerified)
            wizardState.username = url.lastPathComponent
            errorMessage = nil

            appState.logService.log(.info, category: .config,
                message: "Manually selected source folder: \(url.path)")

            // Check sync status if cloud-verified mode
            if connectionMode == .cloudVerified {
                checkSyncStatus()
            }
        }
    }

    private func checkSyncStatus() {
        guard let path = wizardState.sourcePath else { return }

        isCheckingSync = true

        DispatchQueue.global(qos: .userInitiated).async {
            let summary = syncVerifier.getSyncSummary(forDirectory: path)

            DispatchQueue.main.async {
                self.syncSummary = summary
                self.isCheckingSync = false
            }
        }
    }
}
