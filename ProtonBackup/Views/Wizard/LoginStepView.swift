import SwiftUI

/// Login step: detect or select the Proton Drive sync folder.
/// The official Proton Drive app syncs files to ~/Library/CloudStorage/ProtonDrive-{username}/
struct LoginStepView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var wizardState: WizardState

    @State private var isSearching = false
    @State private var detectedPath: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 40))
                .foregroundColor(.protonPurple)

            Text("Locate Proton Drive Folder")
                .font(.title2)
                .fontWeight(.semibold)

            Text("This app backs up your Proton Drive files from the local sync folder created by the official Proton Drive app.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

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
                        Text("Make sure the Proton Drive app is installed and has synced at least once.")
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

            Spacer()

            // Help text
            VStack(spacing: 4) {
                Text("Don't have Proton Drive?")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Link("Download from proton.me", destination: URL(string: "https://proton.me/drive/download")!)
                    .font(.caption)
            }
        }
        .onAppear {
            if !wizardState.isAuthenticated {
                detectProtonDriveFolder()
            }
        }
    }

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

                        // Extract username from folder name
                        let username = String(protonFolder.dropFirst("ProtonDrive-".count))
                        wizardState.username = username

                        appState.logService.log(.info, category: .config,
                            message: "Detected Proton Drive folder: \(fullPath)")
                    }
                } else {
                    errorMessage = "Proton Drive folder not found. Please install the Proton Drive app and sync your files, or select the folder manually."
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
            wizardState.username = url.lastPathComponent
            errorMessage = nil

            appState.logService.log(.info, category: .config,
                message: "Manually selected source folder: \(url.path)")
        }
    }
}
