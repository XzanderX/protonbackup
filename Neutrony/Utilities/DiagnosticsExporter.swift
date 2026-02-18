import Foundation

/// Creates a diagnostics zip file containing logs and settings (no secrets).
enum DiagnosticsExporter {

    /// Export diagnostics to a zip file at the given destination.
    /// Returns the URL of the created file.
    @discardableResult
    static func export(to destinationURL: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("Neutrony-diagnostics-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        // 1. Export logs
        let logText = LogService.shared.exportLogText()
        let logsFile = tempDir.appendingPathComponent("backup.log")
        try logText.write(to: logsFile, atomically: true, encoding: .utf8)

        // 2. Export sanitized configuration
        let config = BackupConfiguration.load()
        let sanitized = sanitizeConfig(config)
        let configFile = tempDir.appendingPathComponent("config.json")
        try sanitized.write(to: configFile, atomically: true, encoding: .utf8)

        // 3. Export system info
        let systemInfo = gatherSystemInfo()
        let systemFile = tempDir.appendingPathComponent("system-info.txt")
        try systemInfo.write(to: systemFile, atomically: true, encoding: .utf8)

        // 4. Export mirror index summary (not the full index)
        let mirrorIndex = MirrorIndex.load()
        let indexSummary = "Mirror index entries: \(mirrorIndex.entries.count)\nLast indexed: \(mirrorIndex.lastIndexDate?.description ?? "Never")\n"
        let indexFile = tempDir.appendingPathComponent("mirror-index-summary.txt")
        try indexSummary.write(to: indexFile, atomically: true, encoding: .utf8)

        // 5. Create zip
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let zipName = "Neutrony-diagnostics-\(timestamp).zip"

        let zipURL: URL
        if let dest = destinationURL {
            zipURL = dest.appendingPathComponent(zipName)
        } else {
            zipURL = fm.temporaryDirectory.appendingPathComponent(zipName)
        }

        try createZip(from: tempDir, to: zipURL)

        return zipURL
    }

    // MARK: - Private

    /// Remove sensitive data from config before export.
    private static func sanitizeConfig(_ config: BackupConfiguration) -> String {
        var lines: [String] = []
        lines.append("Configuration (sanitized):")
        lines.append("  Setup completed: \(config.setupCompleted)")
        lines.append("  Destination: \(config.destinationDisplayName ?? "Not set")")
        lines.append("  Has destination bookmark: \(config.destinationBookmark != nil)")
        lines.append("  Local mirror path: \(config.localMirrorPath)")
        lines.append("  Polling interval: \(config.pollingIntervalMinutes) minutes")
        lines.append("  Deletion policy: \(config.deletionPolicy.rawValue)")
        lines.append("  Keep versions: \(config.keepVersions)")
        lines.append("  Notifications: \(config.notificationsEnabled)")
        lines.append("  Start at login: \(config.startAtLogin)")
        lines.append("  Last successful backup: \(config.lastSuccessfulBackup?.description ?? "Never")")
        lines.append("  Last successful sync: \(config.lastSuccessfulSync?.description ?? "Never")")
        return lines.joined(separator: "\n")
    }

    /// Gather system information for diagnostics.
    private static func gatherSystemInfo() -> String {
        var lines: [String] = []
        lines.append("System Information:")
        lines.append("  macOS version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("  Process: \(ProcessInfo.processInfo.processName)")
        lines.append("  PID: \(ProcessInfo.processInfo.processIdentifier)")
        lines.append("  Physical memory: \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))")
        lines.append("  Processor count: \(ProcessInfo.processInfo.processorCount)")

        // App version
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            lines.append("  App version: \(version) (\(build))")
        }

        // Disk space for Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if let available = DiskSpaceUtility.availableSpace(atPath: appSupport.path) {
            lines.append("  Available space (system): \(DiskSpaceUtility.formatBytes(available))")
        }

        return lines.joined(separator: "\n")
    }

    /// Create a zip archive of a directory.
    private static func createZip(from sourceDir: URL, to zipURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-j", zipURL.path, sourceDir.path]
        process.currentDirectoryURL = sourceDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Read pipe data BEFORE waitUntilExit to avoid deadlock
        // (subprocess blocks if pipe buffer fills, parent blocks waiting for exit)
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DiagnosticsError.zipCreationFailed
        }
    }
}

enum DiagnosticsError: LocalizedError {
    case zipCreationFailed

    var errorDescription: String? {
        "Failed to create diagnostics zip file."
    }
}
