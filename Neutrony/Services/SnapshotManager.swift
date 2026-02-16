import Foundation

/// Mode for creating point-in-time captures after each backup.
enum SnapshotMode: String, Codable, CaseIterable, Identifiable {
    /// Disabled: no point-in-time captures.
    case disabled

    /// Use APFS volume snapshots (tmutil localsnapshot). Fastest and most space-efficient,
    /// but requires the backup volume to be APFS and the snapshot lives on the same volume.
    case apfsSnapshot

    /// Clone the current backup tree into a dated folder under .history/ using
    /// APFS copy-on-write clones (cp -c). Works on any APFS volume, produces a
    /// browsable directory tree, and shares blocks until either side is modified.
    case apfsClone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .apfsSnapshot:
            return "APFS snapshot"
        case .apfsClone:
            return "APFS clone folder"
        }
    }

    var explanation: String {
        switch self {
        case .disabled:
            return "No point-in-time captures. Only the latest backup state is kept (plus _versions if enabled)."
        case .apfsSnapshot:
            return "Creates an APFS volume snapshot after each backup. Instant and zero extra disk usage until blocks diverge. Requires the backup drive to be APFS."
        case .apfsClone:
            return "Copies the current backup into a dated .history/ folder using APFS copy-on-write clones. Each copy is browsable in Finder and shares disk blocks until files change."
        }
    }
}

/// Manages point-in-time captures of the backup destination using either
/// APFS volume snapshots or APFS clone-aware directory copies.
///
/// Layout on the backup volume:
/// ```
/// <backupRoot>/
///   Documents/          ← current live backup
///   Photos/
///   .history/           ← point-in-time captures (clone mode)
///     2026-02-16_14-30-00/
///       Documents/
///       Photos/
///     2026-02-15_09-00-00/
///       ...
/// ```
final class SnapshotManager {

    private let logService: LogService

    /// Subfolder that holds cloned point-in-time captures.
    static let historyFolder = ".history"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(logService: LogService) {
        self.logService = logService
    }

    // MARK: - Public API

    /// Create a point-in-time capture of the backup at `backupRoot` using the given mode.
    /// Returns the name/identifier of the capture created, or nil if mode is disabled.
    @discardableResult
    func createSnapshot(backupRoot: String, mode: SnapshotMode) throws -> String? {
        switch mode {
        case .disabled:
            return nil
        case .apfsSnapshot:
            return try createAPFSSnapshot(backupRoot: backupRoot)
        case .apfsClone:
            return try createAPFSClone(backupRoot: backupRoot)
        }
    }

    /// List all point-in-time captures available under .history/, newest first.
    func listCloneCaptures(backupRoot: String) -> [SnapshotInfo] {
        let historyPath = (backupRoot as NSString).appendingPathComponent(Self.historyFolder)
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: historyPath) else {
            return []
        }

        return contents
            .filter { !$0.hasPrefix(".") }
            .compactMap { folderName -> SnapshotInfo? in
                guard let date = Self.dateFormatter.date(from: folderName) else { return nil }
                let folderPath = (historyPath as NSString).appendingPathComponent(folderName)
                return SnapshotInfo(name: folderName, date: date, path: folderPath)
            }
            .sorted { $0.date > $1.date }
    }

    /// List APFS volume snapshots on the volume containing `backupRoot`.
    /// Note: Returns all local snapshots on the volume, not just those created by this app.
    func listAPFSSnapshots(backupRoot: String) -> [String] {
        let volumeRoot = volumeMountPoint(for: backupRoot)
        let result = runProcess("/usr/bin/tmutil", arguments: ["listlocalsnapshots", volumeRoot])

        guard let output = result.output else { return [] }

        // tmutil output format varies:
        // "Snapshots for disk /Volumes/Backup:"
        // "com.apple.TimeMachine.2026-02-16-143000.local"
        // We return all snapshot names (lines that look like snapshot identifiers)
        return output
            .components(separatedBy: .newlines)
            .filter { $0.contains(".") && !$0.hasPrefix("Snapshots for") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Calculate the total disk size of .history/ clones.
    /// Note: On APFS this reports logical size; actual disk usage is lower due to block sharing.
    func historyLogicalSize(backupRoot: String) -> Int64 {
        let historyPath = (backupRoot as NSString).appendingPathComponent(Self.historyFolder)
        let fm = FileManager.default
        let historyURL = URL(fileURLWithPath: historyPath)

        guard let enumerator = fm.enumerator(
            at: historyURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                totalSize += Int64(values?.fileSize ?? 0)
            }
        }
        return totalSize
    }

    /// Purge clone captures older than the given number of days.
    func purgeOldClones(backupRoot: String, olderThanDays: Int) throws -> Int {
        let fm = FileManager.default
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -olderThanDays, to: Date())!

        let captures = listCloneCaptures(backupRoot: backupRoot)
        var purgedCount = 0

        for capture in captures where capture.date < cutoffDate {
            try fm.removeItem(atPath: capture.path)
            purgedCount += 1
            logService.log(.info, category: .history,
                           message: "Purged history capture: \(capture.name)")
        }

        return purgedCount
    }

    /// Delete a specific APFS volume snapshot by name or date.
    /// - Parameter name: Full snapshot name (e.g., "com.apple.TimeMachine.2026-02-16-143000.local")
    ///   or just the date portion (e.g., "2026-02-16-143000")
    func deleteAPFSSnapshot(name: String, backupRoot: String) -> Bool {
        // tmutil deletelocalsnapshots expects just the date portion (YYYY-MM-DD-HHMMSS)
        // Extract it from the full snapshot name if needed
        var dateString = name
        if name.hasPrefix("com.apple.TimeMachine.") {
            // Extract: "com.apple.TimeMachine.2026-02-16-143000.local" → "2026-02-16-143000"
            dateString = name
                .replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                .replacingOccurrences(of: ".local", with: "")
        }

        let result = runProcess("/usr/bin/tmutil",
                                arguments: ["deletelocalsnapshots", dateString])
        if result.exitCode != 0 {
            logService.log(.warning, category: .history,
                           message: "Failed to delete snapshot \(name): \(result.output ?? "unknown error")")
            return false
        }
        logService.log(.info, category: .history, message: "Deleted snapshot: \(dateString)")
        return true
    }

    // MARK: - APFS Snapshot

    /// Create an APFS volume snapshot using `tmutil localsnapshot`.
    /// Returns the actual snapshot name created by tmutil (e.g., "com.apple.TimeMachine.2026-02-16-143000.local").
    private func createAPFSSnapshot(backupRoot: String) throws -> String {
        let volumeRoot = volumeMountPoint(for: backupRoot)

        logService.log(.info, category: .history,
                       message: "Creating APFS snapshot on volume: \(volumeRoot)")

        // tmutil localsnapshot <mount_point> creates a snapshot of the volume.
        // We use tmutil because creating APFS snapshots requires the fs_snapshot_create
        // entitlement which sandboxed apps don't have. tmutil is the standard way.
        let result = runProcess("/usr/bin/tmutil",
                                arguments: ["localsnapshot", volumeRoot])

        if result.exitCode != 0 {
            let errorMsg = result.output ?? "Unknown error"
            logService.log(.error, category: .history,
                           message: "APFS snapshot failed: \(errorMsg)")

            // If APFS snapshot fails (e.g., non-APFS volume), surface the error
            throw SnapshotError.snapshotFailed(errorMsg)
        }

        // Parse the snapshot name from tmutil output.
        // Output format: "Created local snapshot with date: 2026-02-16-143000"
        var snapshotName = "snapshot"
        if let output = result.output {
            // Extract the date portion from the output
            let datePattern = #"(\d{4}-\d{2}-\d{2}-\d{6})"#
            if let regex = try? NSRegularExpression(pattern: datePattern),
               let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let range = Range(match.range(at: 1), in: output) {
                let dateString = String(output[range])
                snapshotName = "com.apple.TimeMachine.\(dateString).local"
            }
        }

        logService.log(.info, category: .history,
                       message: "APFS snapshot created: \(snapshotName)")
        return snapshotName
    }

    // MARK: - APFS Clone

    /// Clone the entire backup tree into .history/<timestamp>/ using `cp -c` (APFS COW clone).
    private func createAPFSClone(backupRoot: String) throws -> String {
        let fm = FileManager.default
        let timestamp = Self.dateFormatter.string(from: Date())
        let historyBase = (backupRoot as NSString).appendingPathComponent(Self.historyFolder)
        let capturePath = (historyBase as NSString).appendingPathComponent(timestamp)

        logService.log(.info, category: .history,
                       message: "Creating APFS clone capture: \(timestamp)")

        // Ensure .history/ directory exists
        try fm.createDirectory(atPath: historyBase, withIntermediateDirectories: true)

        // Use cp -c -R to perform APFS copy-on-write clone of the entire tree.
        // -c = clone (APFS COW, shares blocks until modified)
        // -R = recursive
        // -p = preserve attributes (permissions, timestamps)
        // We exclude .history/ itself and _versions/ from the clone.
        //
        // We build the source list from the top-level items in backupRoot,
        // excluding .history and _versions.
        let topLevelItems: [String]
        do {
            topLevelItems = try fm.contentsOfDirectory(atPath: backupRoot)
                .filter { $0 != Self.historyFolder && $0 != "_versions" && !$0.hasPrefix(".") }
        } catch {
            logService.log(.error, category: .history,
                           message: "Failed to list backup root: \(error.localizedDescription)")
            throw SnapshotError.cloneFailed(error.localizedDescription)
        }

        if topLevelItems.isEmpty {
            logService.log(.info, category: .history,
                           message: "No files to capture, skipping clone")
            return timestamp
        }

        // Create the capture directory
        try fm.createDirectory(atPath: capturePath, withIntermediateDirectories: true)

        // Clone each top-level item individually (so we can skip .history/_versions)
        var cloneErrors: [String] = []
        for item in topLevelItems {
            let sourcePath = (backupRoot as NSString).appendingPathComponent(item)
            let destPath = (capturePath as NSString).appendingPathComponent(item)

            // Use /bin/cp -c -R -p for APFS clone
            let result = runProcess("/bin/cp",
                                    arguments: ["-c", "-R", "-p", sourcePath, destPath])

            if result.exitCode != 0 {
                let errorMsg = result.output ?? "unknown error"

                // If -c (clone) fails, it may be a non-APFS volume.
                // Fall back to regular copy for this item.
                logService.log(.warning, category: .history,
                               message: "APFS clone failed for \(item), falling back to regular copy: \(errorMsg)")

                let fallbackResult = runProcess("/bin/cp",
                                                arguments: ["-R", "-p", sourcePath, destPath])
                if fallbackResult.exitCode != 0 {
                    let fallbackError = fallbackResult.output ?? "unknown error"
                    cloneErrors.append("\(item): \(fallbackError)")
                    logService.log(.error, category: .history,
                                   message: "Copy also failed for \(item): \(fallbackError)")
                }
            }
        }

        if !cloneErrors.isEmpty {
            logService.log(.warning, category: .history,
                           message: "\(cloneErrors.count) items had errors during clone capture")
        }

        // Verify the capture was created
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: capturePath, isDirectory: &isDir), isDir.boolValue else {
            throw SnapshotError.cloneFailed("Capture directory not created")
        }

        logService.log(.info, category: .history,
                       message: "APFS clone capture created: \(timestamp)")
        return timestamp
    }

    // MARK: - Helpers

    /// Find the mount point of the volume containing the given path.
    private func volumeMountPoint(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let volumeURL = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume {
            return volumeURL.path
        }
        // Fallback: walk up until we find a mount point
        var current = url
        while current.path != "/" {
            var isVolume: ObjCBool = false
            if FileManager.default.fileExists(atPath: current.path, isDirectory: &isVolume) {
                let values = try? current.resourceValues(forKeys: [.volumeURLKey])
                if values?.volume?.path == current.path {
                    return current.path
                }
            }
            current = current.deletingLastPathComponent()
        }
        return "/"
    }

    /// Run an external process and capture its output.
    private func runProcess(_ path: String, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            return ProcessResult(exitCode: process.terminationStatus, output: output)
        } catch {
            return ProcessResult(exitCode: -1, output: error.localizedDescription)
        }
    }
}

// MARK: - Supporting Types

struct SnapshotInfo {
    let name: String
    let date: Date
    let path: String
}

struct ProcessResult {
    let exitCode: Int32
    let output: String?
}

enum SnapshotError: LocalizedError {
    case snapshotFailed(String)
    case cloneFailed(String)

    var errorDescription: String? {
        switch self {
        case .snapshotFailed(let detail):
            return "APFS snapshot failed: \(detail)"
        case .cloneFailed(let detail):
            return "APFS clone capture failed: \(detail)"
        }
    }
}
