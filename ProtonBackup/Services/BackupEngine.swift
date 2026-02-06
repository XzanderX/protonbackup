import Foundation

/// Manages copying files from Proton Drive to the external backup destination.
/// Supports two modes:
/// 1. Local folder mode: Copies from the Proton Drive app's local sync folder
/// 2. Hybrid mode: Uses rclone to query cloud, copies from local if available, downloads via rclone if not
/// Uses incremental sync (only copies changed files based on size/date comparison).
/// Handles deletion policies and versioned backups.
final class BackupEngine {

    private let logService: LogService
    private let versionManager: VersionManager
    private let rcloneService = RcloneService.shared

    init(logService: LogService, versionManager: VersionManager) {
        self.logService = logService
        self.versionManager = versionManager
    }

    // MARK: - Public API

    /// Perform an incremental backup from the source (Proton Drive folder) to the destination.
    /// Only copies files that are new or have changed since the last backup.
    /// - Parameters:
    ///   - pauseChecker: Optional closure that returns true if backup should pause. When paused, the backup waits until it returns false.
    func performBackup(
        sourcePath: String,
        destinationPath: String,
        deletionPolicy: DeletionPolicy,
        keepVersions: Bool,
        pauseChecker: (() -> Bool)? = nil,
        progressHandler: @escaping (BackupProgress) -> Void
    ) async throws -> BackupSummary {
        let startTime = Date()
        var filesUpdated = 0
        var filesDeleted = 0
        var filesSkipped = 0
        var errors: [String] = []

        let fm = FileManager.default

        logService.log(.info, category: .backup, message: "Starting backup: \(sourcePath) → \(destinationPath)")

        // Ensure destination directory exists
        let backupRoot = (destinationPath as NSString).appendingPathComponent("ProtonBackup")
        try fm.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)

        // Scan source files (excluding _versions directory)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let sourceFiles = try scanDirectory(sourceURL, excludingPrefix: "_versions")

        // Scan existing destination files
        let destURL = URL(fileURLWithPath: backupRoot)
        let destFiles = try scanDirectory(destURL, excludingPrefix: "_versions")

        // Build relative path sets
        let sourceRelative = Set(sourceFiles.map { relativePath(from: sourceURL, to: $0) })
        let destRelative = Set(destFiles.map { relativePath(from: destURL, to: $0) })

        // Find files to copy (new or modified)
        var filesToCopy: [(source: URL, relativePath: String)] = []
        for fileURL in sourceFiles {
            let relPath = relativePath(from: sourceURL, to: fileURL)
            let destFilePath = (backupRoot as NSString).appendingPathComponent(relPath)

            if !fm.fileExists(atPath: destFilePath) {
                filesToCopy.append((fileURL, relPath))
            } else if try needsUpdate(source: fileURL.path, destination: destFilePath) {
                filesToCopy.append((fileURL, relPath))
            } else {
                filesSkipped += 1
            }
        }

        // Find files to delete (in destination but not in source)
        let filesToDelete = destRelative.subtracting(sourceRelative)

        let totalWork = filesToCopy.count + filesToDelete.count

        if totalWork == 0 {
            logService.log(.info, category: .backup, message: "Backup is up to date, no changes needed")
            return BackupSummary(
                filesUpdated: 0, filesDeleted: 0, filesSkipped: filesSkipped,
                errors: [], startTime: startTime, endTime: Date()
            )
        }

        logService.log(.info, category: .backup,
                       message: "\(filesToCopy.count) to copy, \(filesToDelete.count) to process for deletion")

        // Copy files
        var completed = 0
        for (sourceURL, relPath) in filesToCopy {
            // Check for pause
            while pauseChecker?() == true {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }

            let currentProgress = BackupProgress(
                totalFiles: totalWork,
                completedFiles: completed,
                currentFileName: relPath
            )
            progressHandler(currentProgress)

            do {
                let destPath = (backupRoot as NSString).appendingPathComponent(relPath)
                try copyFile(from: sourceURL.path, to: destPath, keepVersions: keepVersions, backupRoot: backupRoot)
                filesUpdated += 1
            } catch {
                let desc = "Failed to copy \(relPath): \(error.localizedDescription)"
                errors.append(desc)
                logService.log(.error, category: .backup, message: desc, filePath: relPath)
            }

            completed += 1
        }

        // Handle deletions
        for relPath in filesToDelete {
            // Check for pause
            while pauseChecker?() == true {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }

            let currentProgress = BackupProgress(
                totalFiles: totalWork,
                completedFiles: completed,
                currentFileName: relPath
            )
            progressHandler(currentProgress)

            do {
                let destPath = (backupRoot as NSString).appendingPathComponent(relPath)
                try handleDeletion(
                    atPath: destPath,
                    relativePath: relPath,
                    policy: deletionPolicy,
                    keepVersions: keepVersions,
                    backupRoot: backupRoot
                )
                filesDeleted += 1
            } catch {
                let desc = "Failed to handle deletion of \(relPath): \(error.localizedDescription)"
                errors.append(desc)
                logService.log(.error, category: .backup, message: desc, filePath: relPath)
            }

            completed += 1
        }

        // Clean up empty directories in destination
        cleanEmptyDirectories(at: destURL)

        let summary = BackupSummary(
            filesUpdated: filesUpdated,
            filesDeleted: filesDeleted,
            filesSkipped: filesSkipped,
            errors: errors,
            startTime: startTime,
            endTime: Date()
        )

        logService.log(.info, category: .backup, message: "Backup complete: \(summary.displayText)")
        return summary
    }

    /// Perform a hybrid backup using rclone as source of truth.
    /// For each file in the cloud:
    /// - If the file exists locally (in Proton Drive app folder), copy from local
    /// - Otherwise, download via rclone
    /// This approach is faster when files are already synced locally.
    func performHybridBackup(
        localFolderPath: String?,
        destinationPath: String,
        deletionPolicy: DeletionPolicy,
        keepVersions: Bool,
        pauseChecker: (() -> Bool)? = nil,
        progressHandler: @escaping (BackupProgress) -> Void
    ) async throws -> BackupSummary {
        let startTime = Date()
        var filesUpdated = 0
        var filesDeleted = 0
        var filesSkipped = 0
        var filesDownloaded = 0
        var errors: [String] = []

        let fm = FileManager.default

        logService.log(.info, category: .backup, message: "Starting hybrid backup to: \(destinationPath)")

        // Ensure destination directory exists
        let backupRoot = (destinationPath as NSString).appendingPathComponent("ProtonBackup")
        try fm.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)

        // Get cloud file list from rclone (source of truth)
        logService.log(.info, category: .sync, message: "Fetching cloud file list from Proton Drive...")
        let cloudFiles = try await rcloneService.listFiles()
        let cloudFilesOnly = cloudFiles.filter { !$0.isDir }

        logService.log(.info, category: .sync, message: "Found \(cloudFilesOnly.count) files in cloud")

        // Scan existing destination files
        let destURL = URL(fileURLWithPath: backupRoot)
        let destFiles = try scanDirectory(destURL, excludingPrefix: "_versions")

        // Build relative path sets
        let cloudRelative = Set(cloudFilesOnly.map { $0.path })
        let destRelative = Set(destFiles.map { relativePath(from: destURL, to: $0) })

        // Find files to copy (new or modified)
        var filesToProcess: [(cloudFile: RcloneFile, needsUpdate: Bool)] = []
        for cloudFile in cloudFilesOnly {
            let destFilePath = (backupRoot as NSString).appendingPathComponent(cloudFile.path)

            if !fm.fileExists(atPath: destFilePath) {
                filesToProcess.append((cloudFile, true))
            } else if try needsUpdateFromCloud(cloudFile: cloudFile, localPath: destFilePath) {
                filesToProcess.append((cloudFile, true))
            } else {
                filesSkipped += 1
            }
        }

        // Find files to delete (in destination but not in cloud)
        let filesToDelete = destRelative.subtracting(cloudRelative)

        let totalWork = filesToProcess.count + filesToDelete.count

        if totalWork == 0 {
            logService.log(.info, category: .backup, message: "Backup is up to date, no changes needed")
            return BackupSummary(
                filesUpdated: 0, filesDeleted: 0, filesSkipped: filesSkipped,
                errors: [], startTime: startTime, endTime: Date()
            )
        }

        logService.log(.info, category: .backup,
                       message: "\(filesToProcess.count) to copy/download, \(filesToDelete.count) to process for deletion")

        // Process files
        var completed = 0
        for (cloudFile, _) in filesToProcess {
            // Check for pause
            while pauseChecker?() == true {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }

            let currentProgress = BackupProgress(
                totalFiles: totalWork,
                completedFiles: completed,
                currentFileName: cloudFile.path
            )
            progressHandler(currentProgress)

            do {
                let destPath = (backupRoot as NSString).appendingPathComponent(cloudFile.path)

                // Check if file exists locally (in Proton Drive app folder)
                var copiedFromLocal = false
                if let localFolder = localFolderPath {
                    let localPath = (localFolder as NSString).appendingPathComponent(cloudFile.path)
                    if fm.fileExists(atPath: localPath) {
                        // Verify local file matches cloud (size check)
                        let localAttrs = try? fm.attributesOfItem(atPath: localPath)
                        let localSize = localAttrs?[.size] as? Int64 ?? -1

                        if localSize == cloudFile.size {
                            // Copy from local (faster)
                            try copyFile(from: localPath, to: destPath, keepVersions: keepVersions, backupRoot: backupRoot)
                            copiedFromLocal = true
                            logService.log(.debug, category: .backup, message: "Copied from local: \(cloudFile.path)")
                        }
                    }
                }

                // If not copied from local, download via rclone
                if !copiedFromLocal {
                    try await downloadAndCopy(cloudFile: cloudFile, destPath: destPath, keepVersions: keepVersions, backupRoot: backupRoot)
                    filesDownloaded += 1
                    logService.log(.debug, category: .backup, message: "Downloaded from cloud: \(cloudFile.path)")
                }

                filesUpdated += 1
            } catch {
                let desc = "Failed to process \(cloudFile.path): \(error.localizedDescription)"
                errors.append(desc)
                logService.log(.error, category: .backup, message: desc, filePath: cloudFile.path)
            }

            completed += 1
        }

        // Handle deletions
        for relPath in filesToDelete {
            // Check for pause
            while pauseChecker?() == true {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }

            let currentProgress = BackupProgress(
                totalFiles: totalWork,
                completedFiles: completed,
                currentFileName: relPath
            )
            progressHandler(currentProgress)

            do {
                let destPath = (backupRoot as NSString).appendingPathComponent(relPath)
                try handleDeletion(
                    atPath: destPath,
                    relativePath: relPath,
                    policy: deletionPolicy,
                    keepVersions: keepVersions,
                    backupRoot: backupRoot
                )
                filesDeleted += 1
            } catch {
                let desc = "Failed to handle deletion of \(relPath): \(error.localizedDescription)"
                errors.append(desc)
                logService.log(.error, category: .backup, message: desc, filePath: relPath)
            }

            completed += 1
        }

        // Clean up empty directories in destination
        cleanEmptyDirectories(at: destURL)

        let summary = BackupSummary(
            filesUpdated: filesUpdated,
            filesDeleted: filesDeleted,
            filesSkipped: filesSkipped,
            errors: errors,
            startTime: startTime,
            endTime: Date()
        )

        logService.log(.info, category: .backup,
                       message: "Hybrid backup complete: \(summary.displayText) (\(filesDownloaded) downloaded from cloud)")
        return summary
    }

    // MARK: - Hybrid Backup Helpers

    /// Check if a cloud file is newer or different size than the local backup.
    private func needsUpdateFromCloud(cloudFile: RcloneFile, localPath: String) throws -> Bool {
        let fm = FileManager.default
        let localAttrs = try fm.attributesOfItem(atPath: localPath)

        let localSize = localAttrs[.size] as? Int64 ?? 0
        if localSize != cloudFile.size { return true }

        // If cloud file has modTime, compare with local
        if let cloudModTime = cloudFile.modTime {
            let localModTime = localAttrs[.modificationDate] as? Date ?? .distantPast
            return cloudModTime > localModTime
        }

        return false
    }

    /// Download a file from rclone and copy it to the destination.
    private func downloadAndCopy(cloudFile: RcloneFile, destPath: String, keepVersions: Bool, backupRoot: String) async throws {
        let fm = FileManager.default

        // Create a temporary file for download
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ProtonBackup")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempPath = tempDir.appendingPathComponent(UUID().uuidString + "_" + cloudFile.name).path

        defer {
            // Clean up temp file
            try? fm.removeItem(atPath: tempPath)
        }

        // Download via rclone
        try await rcloneService.downloadFile(remotePath: cloudFile.path, destinationPath: tempPath)

        // Copy to destination (with versioning if needed)
        try copyFile(from: tempPath, to: destPath, keepVersions: keepVersions, backupRoot: backupRoot)
    }

    // MARK: - Private

    /// Recursively scan a directory for all files (not directories).
    private func scanDirectory(_ url: URL, excludingPrefix: String) throws -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            let relPath = relativePath(from: url, to: fileURL)

            // Skip the excluded prefix
            if relPath.hasPrefix(excludingPrefix) {
                enumerator.skipDescendants()
                continue
            }

            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(fileURL)
            }
        }

        return files
    }

    /// Compute relative path from a base URL to a file URL.
    private func relativePath(from base: URL, to file: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path

        if filePath.hasPrefix(basePath) {
            var relative = String(filePath.dropFirst(basePath.count))
            if relative.hasPrefix("/") {
                relative = String(relative.dropFirst())
            }
            return relative
        }
        return filePath
    }

    /// Check if a source file is newer or different size than destination.
    private func needsUpdate(source: String, destination: String) throws -> Bool {
        let fm = FileManager.default
        let sourceAttrs = try fm.attributesOfItem(atPath: source)
        let destAttrs = try fm.attributesOfItem(atPath: destination)

        let sourceSize = sourceAttrs[.size] as? Int64 ?? 0
        let destSize = destAttrs[.size] as? Int64 ?? 0
        if sourceSize != destSize { return true }

        let sourceDate = sourceAttrs[.modificationDate] as? Date ?? .distantPast
        let destDate = destAttrs[.modificationDate] as? Date ?? .distantPast
        return sourceDate > destDate
    }

    /// Copy a file, optionally versioning the existing file at the destination.
    private func copyFile(from source: String, to destination: String, keepVersions: Bool, backupRoot: String) throws {
        let fm = FileManager.default

        // Ensure parent directory exists
        let parent = (destination as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        // If destination exists and versioning is on, move old version first
        if fm.fileExists(atPath: destination) && keepVersions {
            let relPath = String(destination.dropFirst(backupRoot.count + 1))
            try versionManager.archiveFile(atPath: destination, relativePath: relPath, backupRoot: backupRoot)
        }

        // Remove existing and copy new
        if fm.fileExists(atPath: destination) {
            try fm.removeItem(atPath: destination)
        }
        try fm.copyItem(atPath: source, toPath: destination)

        logService.log(.debug, category: .backup, message: "Copied", filePath: (destination as NSString).lastPathComponent)
    }

    /// Handle file deletion according to the configured policy.
    private func handleDeletion(
        atPath path: String,
        relativePath: String,
        policy: DeletionPolicy,
        keepVersions: Bool,
        backupRoot: String
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }

        switch policy {
        case .neverDelete:
            logService.log(.debug, category: .backup, message: "Kept (policy: never delete)", filePath: relativePath)

        case .mirrorWithVersions:
            try versionManager.archiveFile(atPath: path, relativePath: relativePath, backupRoot: backupRoot)
            try fm.removeItem(atPath: path)
            logService.log(.debug, category: .backup, message: "Versioned and deleted", filePath: relativePath)

        case .mirrorDeletions:
            if keepVersions {
                try versionManager.archiveFile(atPath: path, relativePath: relativePath, backupRoot: backupRoot)
            }
            try fm.removeItem(atPath: path)
            logService.log(.debug, category: .backup, message: "Deleted", filePath: relativePath)
        }
    }

    /// Remove empty directories after deletions.
    private func cleanEmptyDirectories(at url: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var directories: [URL] = []
        for case let dirURL as URL in enumerator {
            let values = try? dirURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                directories.append(dirURL)
            }
        }

        // Process deepest directories first
        for dir in directories.reversed() {
            let contents = try? fm.contentsOfDirectory(atPath: dir.path)
            if contents?.isEmpty == true {
                try? fm.removeItem(at: dir)
            }
        }
    }
}
