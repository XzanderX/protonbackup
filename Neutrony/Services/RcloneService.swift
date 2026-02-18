import Foundation

/// Service for managing rclone operations with Proton Drive.
/// Handles configuration, file listing, and downloads.
final class RcloneService: @unchecked Sendable {

    static let shared = RcloneService()

    private let logService = LogService.shared
    private let fileManager = FileManager.default

    /// Name of the rclone remote for Proton Drive
    private let remoteName = "protondrive"

    private init() {}

    // MARK: - Paths

    /// Path to the bundled or installed rclone binary
    var rclonePath: String {
        // First check if bundled in app
        if let bundledPath = Bundle.main.path(forResource: "rclone", ofType: nil) {
            return bundledPath
        }
        // Fall back to common install locations
        let commonPaths = [
            "/usr/local/bin/rclone",
            "/opt/homebrew/bin/rclone",
            "/usr/bin/rclone",
            NSHomeDirectory() + "/.local/bin/rclone"
        ]
        for path in commonPaths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return "rclone" // Hope it's in PATH
    }

    /// Directory for rclone configuration
    private var configDir: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Neutrony/rclone", isDirectory: true)
    }

    /// Path to rclone config file
    var configPath: String {
        configDir.appendingPathComponent("rclone.conf").path
    }

    // MARK: - Setup

    /// Check if rclone is available
    func isRcloneInstalled() -> Bool {
        let path = rclonePath
        if path == "rclone" {
            // Check if in PATH
            let result = runCommand([rclonePath, "version"])
            return result.exitCode == 0
        }
        return fileManager.fileExists(atPath: path)
    }

    /// Check if Proton Drive remote is configured
    func isConfigured() -> Bool {
        guard fileManager.fileExists(atPath: configPath) else { return false }
        let result = runCommand([rclonePath, "--config", configPath, "listremotes"])
        return result.exitCode == 0 && result.output.contains(remoteName)
    }

    /// Configure rclone with Proton Drive credentials
    /// - Parameters:
    ///   - username: Proton email
    ///   - password: Proton password
    ///   - twoFactor: Either a 6-digit TOTP code or the base32 TOTP secret (optional)
    func configure(
        username: String,
        password: String,
        twoFactor: String? = nil
    ) throws {
        // Ensure config directory exists
        try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Obscure the password (rclone requirement)
        let obscuredPassword = try obscurePassword(password)

        // Determine if twoFactor is a 6-digit code or a secret
        let is2FACode = twoFactor.map { $0.count == 6 && $0.allSatisfy { $0.isNumber } } ?? false

        // Build config content
        var configContent = """
        [\(remoteName)]
        type = protondrive
        username = \(username)
        password = \(obscuredPassword)
        """

        // If it's a secret (not a 6-digit code), add it to config
        if let secret = twoFactor, !secret.isEmpty, !is2FACode {
            let obscuredSecret = try obscurePassword(secret)
            configContent += "\n2fa = \(obscuredSecret)"
        }

        // Write config file
        try configContent.write(toFile: configPath, atomically: true, encoding: .utf8)

        // Set restrictive permissions (config contains credentials)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)

        logService.log(.info, category: .config, message: "Rclone configured for Proton Drive")
    }

    /// Authenticate with Proton Drive using rclone config
    /// This handles the interactive 2FA flow by piping the code to rclone
    func authenticateWithCode(
        username: String,
        password: String,
        twoFactorCode: String
    ) async throws -> Bool {
        // First remove any existing config
        try? removeConfiguration()

        // Ensure config directory exists
        try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Use rclone config create with stdin for 2FA code
        // The flow: rclone will prompt for 2FA, we pipe the code
        let result = await runCommandWithInput(
            arguments: [
                rclonePath,
                "--config", configPath,
                "config", "create", remoteName, "protondrive",
                "username", username,
                "password", password
            ],
            input: twoFactorCode + "\n"  // Send the 2FA code when prompted
        )

        if result.exitCode == 0 {
            logService.log(.info, category: .config, message: "Rclone authenticated with 2FA code")
            return true
        } else {
            // Check if it's a 2FA error
            if result.error.contains("2fa") || result.error.contains("2FA") {
                throw RcloneError.twoFactorRequired
            }
            throw RcloneError.connectionFailed(result.error)
        }
    }

    /// Test the connection to Proton Drive
    func testConnection() async throws -> Bool {
        let result = await runCommandAsync([
            rclonePath,
            "--config", configPath,
            "lsd", "\(remoteName):",
            "--max-depth", "1"
        ])

        if result.exitCode == 0 {
            logService.log(.info, category: .sync, message: "Rclone connection test successful")
            return true
        } else {
            logService.log(.error, category: .sync, message: "Rclone connection test failed: \(result.error)")
            throw RcloneError.connectionFailed(result.error)
        }
    }

    /// Remove the Proton Drive configuration
    func removeConfiguration() throws {
        if fileManager.fileExists(atPath: configPath) {
            try fileManager.removeItem(atPath: configPath)
            logService.log(.info, category: .config, message: "Rclone configuration removed")
        }
    }

    // MARK: - File Operations

    /// List all files in Proton Drive (returns JSON)
    func listFiles(path: String = "") async throws -> [RcloneFile] {
        let remotePath = path.isEmpty ? "\(remoteName):" : "\(remoteName):\(path)"

        let result = await runCommandAsync([
            rclonePath,
            "--config", configPath,
            "lsjson", remotePath,
            "-R", // Recursive
            "--no-mimetype",
            "--no-modtime" // We'll get modtime separately if needed
        ])

        guard result.exitCode == 0 else {
            throw RcloneError.listFailed(result.error)
        }

        guard let data = result.output.data(using: .utf8) else {
            throw RcloneError.invalidOutput
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RcloneFile].self, from: data)
    }

    /// Download a file from Proton Drive to a destination
    func downloadFile(
        remotePath: String,
        destinationPath: String,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        let remoteFile = "\(remoteName):\(remotePath)"

        // Ensure parent directory exists
        let destURL = URL(fileURLWithPath: destinationPath)
        try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let result = await runCommandAsync([
            rclonePath,
            "--config", configPath,
            "copyto", remoteFile, destinationPath,
            "--progress"
        ])

        guard result.exitCode == 0 else {
            throw RcloneError.downloadFailed(remotePath, result.error)
        }

        logService.log(.debug, category: .sync, message: "Downloaded: \(remotePath)")
    }

    /// Sync a remote directory to a local destination
    func syncToLocal(
        remotePath: String,
        localPath: String,
        progressHandler: ((String) -> Void)? = nil
    ) async throws {
        let remoteDir = remotePath.isEmpty ? "\(remoteName):" : "\(remoteName):\(remotePath)"

        // Ensure local directory exists
        try fileManager.createDirectory(atPath: localPath, withIntermediateDirectories: true)

        let result = await runCommandAsync([
            rclonePath,
            "--config", configPath,
            "sync", remoteDir, localPath,
            "--progress",
            "-v"
        ])

        guard result.exitCode == 0 else {
            throw RcloneError.syncFailed(result.error)
        }

        logService.log(.info, category: .sync, message: "Synced \(remotePath) to \(localPath)")
    }

    // MARK: - Private Helpers

    /// Obscure a password using rclone obscure command
    private func obscurePassword(_ password: String) throws -> String {
        let result = runCommand([rclonePath, "obscure", password])
        guard result.exitCode == 0 else {
            throw RcloneError.obscureFailed
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run a command synchronously
    private func runCommand(_ arguments: [String]) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            // Read pipe data BEFORE waitUntilExit to avoid deadlock
            // (subprocess blocks if pipe buffer fills, parent blocks waiting for exit)
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return CommandResult(
                exitCode: process.terminationStatus,
                output: String(data: outputData, encoding: .utf8) ?? "",
                error: String(data: errorData, encoding: .utf8) ?? ""
            )
        } catch {
            return CommandResult(exitCode: -1, output: "", error: error.localizedDescription)
        }
    }

    /// Run a command asynchronously
    private func runCommandAsync(_ arguments: [String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runCommand(arguments)
                continuation.resume(returning: result)
            }
        }
    }

    /// Run a command with stdin input (for interactive prompts like 2FA)
    private func runCommandWithInput(arguments: [String], input: String) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let inputPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: arguments[0])
                process.arguments = Array(arguments.dropFirst())
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.standardInput = inputPipe

                do {
                    try process.run()

                    // Write input to stdin
                    if let inputData = input.data(using: .utf8) {
                        inputPipe.fileHandleForWriting.write(inputData)
                        inputPipe.fileHandleForWriting.closeFile()
                    }

                    // Read pipe data BEFORE waitUntilExit to avoid deadlock
                    // (subprocess blocks if pipe buffer fills, parent blocks waiting for exit)
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    let result = CommandResult(
                        exitCode: process.terminationStatus,
                        output: String(data: outputData, encoding: .utf8) ?? "",
                        error: String(data: errorData, encoding: .utf8) ?? ""
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(returning: CommandResult(exitCode: -1, output: "", error: error.localizedDescription))
                }
            }
        }
    }
}

// MARK: - Supporting Types

struct CommandResult {
    let exitCode: Int32
    let output: String
    let error: String
}

/// Represents a file from rclone lsjson output
struct RcloneFile: Codable, Equatable {
    let path: String
    let name: String
    let size: Int64
    let mimeType: String?
    let modTime: Date?
    let isDir: Bool

    enum CodingKeys: String, CodingKey {
        case path = "Path"
        case name = "Name"
        case size = "Size"
        case mimeType = "MimeType"
        case modTime = "ModTime"
        case isDir = "IsDir"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        name = try container.decode(String.self, forKey: .name)
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        isDir = try container.decodeIfPresent(Bool.self, forKey: .isDir) ?? false

        // Handle modTime which may be in different formats
        if let modTimeString = try container.decodeIfPresent(String.self, forKey: .modTime) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            modTime = formatter.date(from: modTimeString)
        } else {
            modTime = nil
        }
    }
}

/// Errors from rclone operations
enum RcloneError: LocalizedError {
    case notInstalled
    case notConfigured
    case obscureFailed
    case connectionFailed(String)
    case twoFactorRequired
    case twoFactorInvalid
    case listFailed(String)
    case downloadFailed(String, String)
    case syncFailed(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "rclone is not installed. The app needs rclone to connect to Proton Drive."
        case .notConfigured:
            return "Proton Drive is not configured. Please sign in first."
        case .obscureFailed:
            return "Failed to secure password."
        case .connectionFailed(let error):
            return "Failed to connect to Proton Drive: \(error)"
        case .twoFactorRequired:
            return "Two-factor authentication is required. Please enter your 2FA code."
        case .twoFactorInvalid:
            return "Invalid 2FA code. Please check and try again."
        case .listFailed(let error):
            return "Failed to list files: \(error)"
        case .downloadFailed(let file, let error):
            return "Failed to download '\(file)': \(error)"
        case .syncFailed(let error):
            return "Sync failed: \(error)"
        case .invalidOutput:
            return "Invalid response from Proton Drive."
        }
    }
}
