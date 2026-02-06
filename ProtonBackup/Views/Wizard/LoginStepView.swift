import SwiftUI

/// Login step: Connect to Proton Drive via rclone or detect local sync folder.
/// Supports two modes:
/// 1. Local folder detection (if Proton Drive app is installed)
/// 2. Rclone authentication (for cloud-first approach)
struct LoginStepView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var wizardState: WizardState

    enum ConnectionMode: String, CaseIterable {
        case local = "Local Folder"
        case rclone = "Cloud Login"
    }

    @State private var connectionMode: ConnectionMode = .local
    @State private var isSearching = false
    @State private var detectedPath: String?
    @State private var errorMessage: String?

    // Rclone authentication fields
    @State private var username = ""
    @State private var password = ""
    @State private var twoFactorSecret = ""
    @State private var showPassword = false
    @State private var isTesting = false
    @State private var testResult: TestResult?

    enum TestResult {
        case success
        case failure(String)
    }

    private let rcloneService = RcloneService.shared

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Image(systemName: connectionMode == .local ? "folder.badge.gearshape" : "cloud.fill")
                .font(.system(size: 40))
                .foregroundColor(.protonPurple)

            Text("Connect to Proton Drive")
                .font(.title2)
                .fontWeight(.semibold)

            // Mode picker
            Picker("Connection Mode", selection: $connectionMode) {
                ForEach(ConnectionMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            .onChange(of: connectionMode) { _ in
                // Reset state when switching modes
                errorMessage = nil
                testResult = nil
            }

            // Mode description
            Text(connectionMode == .local
                 ? "Use the local Proton Drive app folder for faster backups."
                 : "Sign in to access Proton Drive cloud directly via rclone.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Divider()
                .padding(.vertical, 8)

            // Content based on mode
            if connectionMode == .local {
                localFolderContent
            } else {
                rcloneLoginContent
            }

            Spacer()

            // Help text
            if connectionMode == .rclone && !rcloneService.isRcloneInstalled() {
                rcloneNotInstalledWarning
            }
        }
        .onAppear {
            // Check if rclone is already configured
            if rcloneService.isConfigured() {
                connectionMode = .rclone
                wizardState.useRclone = true
            } else if !wizardState.isAuthenticated {
                detectProtonDriveFolder()
            }
        }
    }

    // MARK: - Local Folder Content

    @ViewBuilder
    private var localFolderContent: some View {
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

    // MARK: - Rclone Login Content

    @ViewBuilder
    private var rcloneLoginContent: some View {
        VStack(spacing: 16) {
            // Username field
            VStack(alignment: .leading, spacing: 4) {
                Text("Proton Email")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("user@proton.me", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            .frame(maxWidth: 350)

            // Password field
            VStack(alignment: .leading, spacing: 4) {
                Text("Password")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    if showPassword {
                        TextField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 350)

            // 2FA field (optional)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("2FA Code")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("(leave empty if no 2FA)")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                TextField("6-digit code from authenticator", text: $twoFactorSecret)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Text("Enter the 6-digit code from your authenticator app (e.g. 123456)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 350, alignment: .leading)
            }
            .frame(maxWidth: 350)

            // Test result
            if let result = testResult {
                switch result {
                case .success:
                    Label("Connected successfully!", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.statusGreen)
                case .failure(let error):
                    Label(error, systemImage: "xmark.circle.fill")
                        .foregroundColor(.statusRed)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 350)
                }
            }

            // Test connection button
            Button(action: testConnection) {
                if isTesting {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 120)
                } else {
                    Text("Test Connection")
                        .frame(width: 120)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.protonPurple)
            .disabled(username.isEmpty || password.isEmpty || isTesting)
        }
    }

    // MARK: - Rclone Not Installed Warning

    private var rcloneNotInstalledWarning: some View {
        VStack(spacing: 8) {
            Label("rclone not found", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.statusYellow)
                .font(.caption)

            Text("Cloud login requires rclone. Install it via Homebrew:")
                .font(.caption2)
                .foregroundColor(.secondary)

            Text("brew install rclone")
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)

            Link("Or download from rclone.org", destination: URL(string: "https://rclone.org/downloads/")!)
                .font(.caption2)
        }
        .padding()
        .background(Color.statusYellow.opacity(0.1))
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

                        // Extract username from folder name
                        let detectedUsername = String(protonFolder.dropFirst("ProtonDrive-".count))
                        wizardState.username = detectedUsername

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
            wizardState.useRclone = false
            wizardState.username = url.lastPathComponent
            errorMessage = nil

            appState.logService.log(.info, category: .config,
                message: "Manually selected source folder: \(url.path)")
        }
    }

    private func testConnection() {
        guard !username.isEmpty, !password.isEmpty else { return }

        isTesting = true
        testResult = nil

        // Check if 2FA input is a 6-digit code
        let is2FACode = twoFactorSecret.count == 6 && twoFactorSecret.allSatisfy { $0.isNumber }

        Task {
            do {
                if is2FACode {
                    // Use interactive auth with 2FA code
                    let success = try await rcloneService.authenticateWithCode(
                        username: username,
                        password: password,
                        twoFactorCode: twoFactorSecret
                    )

                    await MainActor.run {
                        if success {
                            handleAuthSuccess()
                        } else {
                            testResult = .failure("Authentication failed. Please check your credentials and 2FA code.")
                        }
                        isTesting = false
                    }
                } else {
                    // Configure with credentials (and optional TOTP secret)
                    try rcloneService.configure(
                        username: username,
                        password: password,
                        twoFactor: twoFactorSecret.isEmpty ? nil : twoFactorSecret
                    )

                    // Test the connection
                    let success = try await rcloneService.testConnection()

                    await MainActor.run {
                        if success {
                            handleAuthSuccess()
                        } else {
                            testResult = .failure("Connection test failed. Please check your credentials.")
                        }
                        isTesting = false
                    }
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false

                    appState.logService.log(.error, category: .config,
                        message: "Rclone authentication failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleAuthSuccess() {
        testResult = .success
        wizardState.isAuthenticated = true
        wizardState.useRclone = true
        wizardState.username = username
        wizardState.rcloneConfigured = true
        // For rclone mode, source path is the remote
        wizardState.sourcePath = "protondrive:"

        appState.logService.log(.info, category: .config,
            message: "Rclone authentication successful for \(username)")
    }
}
