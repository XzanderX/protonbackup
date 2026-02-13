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
    private let syncVerifier = CloudSyncVerifier.shared

    /// Maximum retry attempts for transient errors
    private let maxRetryAttempts = 3

    /// Files/patterns to skip during backup (temp files, system files, partial downloads)
    private let skipPatterns: [String] = [
        ".DS_Store",
        ".localized",
        ".tmp",
        ".partial",
        ".download",
        ".crdownload",
        "~$",           // Office temp files
        ".~lock.",      // LibreOffice locks
        ".swp",         // Vim swap
        ".swo",
        "Thumbs.db",
        "desktop.ini",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd"
    ]

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

        // Verify source exists
        guard fm.fileExists(atPath: sourcePath) else {
            logService.log(.error, category: .backup, message: "Source path does not exist: \(sourcePath)")
            throw BackupEngineError.sourceNotFound(sourcePath)
        }

        // Ensure destination directory exists
        let backupRoot = (destinationPath as NSString).appendingPathComponent("ProtonBackup")
        try fm.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)
        logService.log(.debug, category: .backup, message: "Backup root: \(backupRoot)")

        // Scan source files (excluding _versions directory)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        logService.log(.info, category: .backup, message: "Scanning source directory: \(sourceURL.path)")
        let sourceFiles = try scanDirectory(sourceURL, excludingPrefix: "_versions")
        logService.log(.info, category: .backup, message: "Found \(sourceFiles.count) files in source")

        // Scan existing destination files
        let destURL = URL(fileURLWithPath: backupRoot)
        let destFiles = try scanDirectory(destURL, excludingPrefix: "_versions")

        // Build relative path sets
        let sourceRelative = Set(sourceFiles.map { relativePath(from: sourceURL, to: $0) })
        let destRelative = Set(destFiles.map { relativePath(from: destURL, to: $0) })

        // Find files to copy (new or modified), filtering out temp/system files
        var filesToCopy: [(source: URL, relativePath: String)] = []
        for fileURL in sourceFiles {
            let relPath = relativePath(from: sourceURL, to: fileURL)

            // Skip temporary and system files
            if shouldSkipFile(fileURL.path) {
                logService.log(.debug, category: .backup, message: "Skipping temp/system file: \(relPath)")
                continue
            }

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
                try copyFileWithRetry(from: sourceURL.path, to: destPath, keepVersions: keepVersions, backupRoot: backupRoot)
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

    /// Perform a cloud-verified backup from the Proton Drive local folder.
    /// This method verifies each file is synced with the cloud before backing up.
    /// Uses macOS FileProvider APIs to check sync status - no authentication needed.
    /// The official Proton Drive app handles auth (including passkey).
    ///
    /// - Parameters:
    ///   - sourcePath: Path to the Proton Drive local folder
    ///   - destinationPath: Path to the backup destination
    ///   - deletionPolicy: How to handle deleted files
    ///   - keepVersions: Whether to keep old versions
    ///   - requireSync: If true, skips files not synced; if false, backs up all local files
    ///   - pauseChecker: Optional closure to check if backup should pause
    ///   - progressHandler: Progress callback
    func performCloudVerifiedBackup(
        sourcePath: String,
        destinationPath: String,
        deletionPolicy: DeletionPolicy,
        keepVersions: Bool,
        requireSync: Bool = true,
        pauseChecker: (() -> Bool)? = nil,
        progressHandler: @escaping (BackupProgress) -> Void
    ) async throws -> BackupSummary {
        let startTime = Date()
        var filesUpdated = 0
        var filesDeleted = 0
        var filesSkipped = 0
        var filesNotSynced = 0
        var errors: [String] = []

        let fm = FileManager.default

        // First, check overall sync status
        let syncSummary = syncVerifier.getSyncSummary(forDirectory: sourcePath)
        logService.log(.info, category: .backup,
                       message: "Sync status: \(syncSummary.syncedFiles)/\(syncSummary.totalFiles) files synced (\(String(format: "%.1f", syncSummary.syncPercentage))%)")

        if syncSummary.cloudOnlyFiles > 0 {
            logService.log(.warning, category: .backup,
                           message: "\(syncSummary.cloudOnlyFiles) files are cloud-only (not downloaded locally)")
        }

        if syncSummary.downloadingFiles > 0 || syncSummary.uploadingFiles > 0 {
            logService.log(.info, category: .backup,
                           message: "\(syncSummary.downloadingFiles) downloading, \(syncSummary.uploadingFiles) uploading")
        }

        logService.log(.info, category: .backup,
                       message: "Starting cloud-verified backup: \(sourcePath) → \(destinationPath)")

        // Verify source exists
        guard fm.fileExists(atPath: sourcePath) else {
            logService.log(.error, category: .backup, message: "Source path does not exist: \(sourcePath)")
            throw BackupEngineError.sourceNotFound(sourcePath)
        }

        // Ensure destination directory exists
        let backupRoot = (destinationPath as NSString).appendingPathComponent("ProtonBackup")
        try fm.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)
        logService.log(.debug, category: .backup, message: "Backup root: \(backupRoot)")

        // Scan source files (excluding _versions directory)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        logService.log(.info, category: .backup, message: "Scanning source directory: \(sourceURL.path)")
        let sourceFiles = try scanDirectory(sourceURL, excludingPrefix: "_versions")
        logService.log(.info, category: .backup, message: "Found \(sourceFiles.count) files in source")

        // Scan existing destination files
        let destURL = URL(fileURLWithPath: backupRoot)
        let destFiles = try scanDirectory(destURL, excludingPrefix: "_versions")

        // Build relative path sets
        let sourceRelative = Set(sourceFiles.map { relativePath(from: sourceURL, to: $0) })
        let destRelative = Set(destFiles.map { relativePath(from: destURL, to: $0) })

        // Find files to copy (new or modified), with sync verification
        var filesToCopy: [(source: URL, relativePath: String)] = []
        for fileURL in sourceFiles {
            let relPath = relativePath(from: sourceURL, to: fileURL)

            // Skip temporary and system files
            if shouldSkipFile(fileURL.path) {
                logService.log(.debug, category: .backup, message: "Skipping temp/system file: \(relPath)")
                continue
            }

            // Check if file is synced with cloud
            if requireSync && !syncVerifier.isFileSynced(at: fileURL.path) {
                filesNotSynced += 1
                logService.log(.debug, category: .backup, message: "Skipping unsynced file: \(relPath)")
                continue
            }

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

        if totalWork == 0 && filesNotSynced == 0 {
            logService.log(.info, category: .backup, message: "Backup is up to date, no changes needed")
            return BackupSummary(
                filesUpdated: 0, filesDeleted: 0, filesSkipped: filesSkipped,
                errors: [], startTime: startTime, endTime: Date()
            )
        }

        logService.log(.info, category: .backup,
                       message: "\(filesToCopy.count) to copy, \(filesToDelete.count) to delete, \(filesNotSynced) not synced")

        // Copy files
        var completed = 0
        for (sourceURL, relPath) in filesToCopy {
            // Check for pause
            while pauseChecker?() == true {
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            let currentProgress = BackupProgress(
                totalFiles: totalWork,
                completedFiles: completed,
                currentFileName: relPath
            )
            progressHandler(currentProgress)

            do {
                let destPath = (backupRoot as NSString).appendingPathComponent(relPath)
                try copyFileWithRetry(from: sourceURL.path, to: destPath, keepVersions: keepVersions, backupRoot: backupRoot)
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
            while pauseChecker?() == true {
                try await Task.sleep(nanoseconds: 500_000_000)
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

        // Clean up empty directories
        cleanEmptyDirectories(at: destURL)

        // Add warning about unsynced files
        if filesNotSynced > 0 {
            errors.append("\(filesNotSynced) files were skipped because they're not synced with cloud")
        }

        let summary = BackupSummary(
            filesUpdated: filesUpdated,
            filesDeleted: filesDeleted,
            filesSkipped: filesSkipped,
            errors: errors,
            startTime: startTime,
            endTime: Date()
        )

        logService.log(.info, category: .backup,
                       message: "Cloud-verified backup complete: \(summary.displayText) (\(filesNotSynced) unsynced files skipped)")
        return summary
    }

    /// Perform an on-demand backup that respects the user's Proton Drive sync settings.
    /// This smart backup:
    /// 1. Only downloads files that need to be backed up (changed or new)
    /// 2. Processes folder by folder to minimize disk usage
    /// 3. Optionally offloads files after backup to free up local space
    ///
    /// This is ideal for users who keep only some folders downloaded locally.
    func performOnDemandBackup(
        sourcePath: String,
        destinationPath: String,
        deletionPolicy: DeletionPolicy,
        keepVersions: Bool,
        offloadAfterBackup: Bool = false,
        pauseChecker: (() -> Bool)? = nil,
        progressHandler: @escaping (BackupProgress) -> Void
    ) async throws -> BackupSummary {
        let startTime = Date()
        var filesUpdated = 0
        var filesDeleted = 0
        var filesSkipped = 0
        var filesDownloaded = 0
        var filesOffloaded = 0
        var errors: [String] = []

        let fm = FileManager.default

        logService.log(.info, category: .backup,
                       message: "Starting on-demand backup: \(sourcePath) → \(destinationPath)")
        logService.log(.info, category: .backup,
                       message: "Offload after backup: \(offloadAfterBackup)")

        // Verify source exists
        guard fm.fileExists(atPath: sourcePath) else {
            logService.log(.error, category: .backup, message: "Source path does not exist: \(sourcePath)")
            throw BackupEngineError.sourceNotFound(sourcePath)
        }

        // Ensure destination directory exists
        let backupRoot = (destinationPath as NSString).appendingPathComponent("ProtonBackup")
        try fm.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)

        // Scan source - this includes cloud-only files (they appear as placeholders)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        logService.log(.info, category: .backup, message: "Scanning source directory (including cloud-only files)...")
        let allSourceFiles = try scanDirectoryIncludingCloudOnly(sourceURL, excludingPrefix: "_versions")
        logService.log(.info, category: .backup, message: "Found \(allSourceFiles.count) files in source")

        // Scan existing destination files
        let destURL = URL(fileURLWithPath: backupRoot)
        let destFiles = try scanDirectory(destURL, excludingPrefix: "_versions")

        // Build destination lookup by relative path
        var destFileLookup: [String: URL] = [:]
        for destFile in destFiles {
            let relPath = relativePath(from: destURL, to: destFile)
            destFileLookup[relPath] = destFile
        }

        // Group files by folder for batch processing
        var filesByFolder: [String: [(url: URL, relPath: String, isCloudOnly: Bool)]] = [:]
        for fileURL in allSourceFiles {
            let relPath = relativePath(from: sourceURL, to: fileURL)

            // Skip temp/system files
            if shouldSkipFile(fileURL.path) {
                continue
            }

            // Check if this file needs backup (compare with destination)
            let destFilePath = (backupRoot as NSString).appendingPathComponent(relPath)
            let needsBackup: Bool

            if !fm.fileExists(atPath: destFilePath) {
                needsBackup = true
            } else if let cloudSize = syncVerifier.getCloudFileSize(at: fileURL.path) {
                // Compare with cloud file size
                let destAttrs = try? fm.attributesOfItem(atPath: destFilePath)
                let destSize = destAttrs?[.size] as? Int64 ?? -1
                needsBackup = (cloudSize != destSize)
            } else {
                // Fall back to local comparison if possible
                needsBackup = (try? needsUpdate(source: fileURL.path, destination: destFilePath)) ?? true
            }

            if !needsBackup {
                filesSkipped += 1
                continue
            }

            // Check if file is cloud-only
            let isCloudOnly = syncVerifier.isCloudOnly(at: fileURL.path)

            // Group by parent folder
            let folder = (relPath as NSString).deletingLastPathComponent
            if filesByFolder[folder] == nil {
                filesByFolder[folder] = []
            }
            filesByFolder[folder]?.append((fileURL, relPath, isCloudOnly))
        }

        // Calculate total work
        let filesToBackup = filesByFolder.values.flatMap { $0 }
        let sourceRelative = Set(allSourceFiles.map { relativePath(from: sourceURL, to: $0) })
        let destRelative = Set(destFiles.map { relativePath(from: destURL, to: $0) })
        let filesToDelete = destRelative.subtracting(sourceRelative)
        let totalWork = filesToBackup.count + filesToDelete.count

        if totalWork == 0 {
            logService.log(.info, category: .backup, message: "Backup is up to date, no changes needed")
            return BackupSummary(
                filesUpdated: 0, filesDeleted: 0, filesSkipped: filesSkipped,
                errors: [], startTime: startTime, endTime: Date()
            )
        }

        // Separate local and cloud-only files - process local files FIRST
        let localFiles = filesToBackup.filter { !$0.isCloudOnly }
        let cloudOnlyFiles = filesToBackup.filter { $0.isCloudOnly }

        logService.log(.info, category: .backup,
                       message: "\(filesToBackup.count) files to backup (\(localFiles.count) local, \(cloudOnlyFiles.count) need download), \(filesToDelete.count) to delete")

        // Process local files first, then cloud-only files
        var completed = 0
        let allFilesOrdered = localFiles + cloudOnlyFiles

        // Log the processing order
        if !localFiles.isEmpty {
            logService.log(.info, category: .backup, message: "Phase 1: Backing up \(localFiles.count) local files...")
        }

        for (fileURL, relPath, isCloudOnly) in allFilesOrdered {
            // Log when switching to cloud-only phase
            if isCloudOnly && completed == localFiles.count && !cloudOnlyFiles.isEmpty {
                logService.log(.info, category: .backup, message: "Phase 2: Downloading and backing up \(cloudOnlyFiles.count) cloud-only files...")
            }

            // Check for pause
            while pauseChecker?() == true {
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            let currentProgress = BackupProgress(
                totalFiles: totalWork,
                completedFiles: completed,
                currentFileName: isCloudOnly ? "⬇ \(relPath)" : relPath
            )
            progressHandler(currentProgress)

            do {
                let destPath = (backupRoot as NSString).appendingPathComponent(relPath)

                if isCloudOnly {
                    // Download the file first
                    logService.log(.debug, category: .backup, message: "Downloading cloud-only file: \(relPath)")
                    let downloaded = await syncVerifier.requestDownloadAndWait(at: fileURL.path, timeout: 120)

                    if !downloaded {
                        errors.append("Failed to download: \(relPath)")
                        logService.log(.warning, category: .backup, message: "Download timeout: \(relPath)")
                        completed += 1
                        continue
                    }
                    filesDownloaded += 1
                }

                // Copy the file
                try copyFileWithRetry(from: fileURL.path, to: destPath, keepVersions: keepVersions, backupRoot: backupRoot)
                filesUpdated += 1

                // Offload if requested (only for files we downloaded)
                if offloadAfterBackup && isCloudOnly {
                    if syncVerifier.evictFile(at: fileURL.path) {
                        filesOffloaded += 1
                    }
                }

            } catch {
                let desc = "Failed to backup \(relPath): \(error.localizedDescription)"
                errors.append(desc)
                logService.log(.error, category: .backup, message: desc, filePath: relPath)
            }

            completed += 1
        }

        // Handle deletions
        for relPath in filesToDelete {
            while pauseChecker?() == true {
                try await Task.sleep(nanoseconds: 500_000_000)
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

        // Clean up empty directories
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
                       message: "On-demand backup complete: \(summary.displayText)")
        logService.log(.info, category: .backup,
                       message: "Downloaded: \(filesDownloaded), Offloaded: \(filesOffloaded)")

        return summary
    }

    /// Scan directory including cloud-only placeholder files.
    private func scanDirectoryIncludingCloudOnly(_ url: URL, excludingPrefix: String) throws -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []

        // Use options that include cloud-only files
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .ubiquitousItemDownloadingStatusKey,
                .isUbiquitousItemKey
            ],
            options: [] // Don't skip anything
        ) else {
            logService.log(.warning, category: .backup, message: "Could not create enumerator for: \(url.path)")
            return []
        }

        for case let fileURL as URL in enumerator {
            let relPath = relativePath(from: url, to: fileURL)

            // Skip the excluded prefix (e.g., _versions)
            if relPath.hasPrefix(excludingPrefix) {
                enumerator.skipDescendants()
                continue
            }

            // Skip .DS_Store and system files
            let fileName = fileURL.lastPathComponent
            if fileName == ".DS_Store" || fileName == ".localized" || fileName.hasPrefix(".") {
                continue
            }

            do {
                let values = try fileURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .ubiquitousItemDownloadingStatusKey
                ])

                // Include regular files AND cloud-only placeholders
                if values.isRegularFile == true {
                    files.append(fileURL)
                } else if values.isDirectory == false {
                    // Could be a cloud-only placeholder - check download status
                    if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                        files.append(fileURL)
                    }
                }
            } catch {
                logService.log(.debug, category: .backup, message: "Could not read attributes for: \(relPath)")
            }
        }

        logService.log(.debug, category: .backup, message: "Scanned \(url.path): found \(files.count) files (including cloud-only)")
        return files
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

        // Don't skip hidden files - Proton Drive may use them
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        ) else {
            logService.log(.warning, category: .backup, message: "Could not create enumerator for: \(url.path)")
            return []
        }

        for case let fileURL as URL in enumerator {
            let relPath = relativePath(from: url, to: fileURL)

            // Skip the excluded prefix (e.g., _versions)
            if relPath.hasPrefix(excludingPrefix) {
                enumerator.skipDescendants()
                continue
            }

            // Skip .DS_Store and other system files at scan time
            let fileName = fileURL.lastPathComponent
            if fileName == ".DS_Store" || fileName == ".localized" {
                continue
            }

            do {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true {
                    files.append(fileURL)
                }
            } catch {
                // Log but don't fail on individual file errors
                logService.log(.debug, category: .backup, message: "Could not read attributes for: \(relPath)")
            }
        }

        logService.log(.debug, category: .backup, message: "Scanned \(url.path): found \(files.count) files")
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

    // MARK: - Stability Helpers

    /// Check if a file should be skipped (temp files, system files, partial downloads).
    private func shouldSkipFile(_ path: String) -> Bool {
        let fileName = (path as NSString).lastPathComponent

        for pattern in skipPatterns {
            if fileName.hasPrefix(pattern) || fileName.hasSuffix(pattern) || fileName.contains(pattern) {
                return true
            }
        }

        // Skip zero-byte files (likely incomplete downloads)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64,
           size == 0 {
            return true
        }

        return false
    }

    /// Copy a file with retry logic for transient errors.
    private func copyFileWithRetry(from source: String, to destination: String, keepVersions: Bool, backupRoot: String) throws {
        var lastError: Error?

        for attempt in 1...maxRetryAttempts {
            do {
                try copyFile(from: source, to: destination, keepVersions: keepVersions, backupRoot: backupRoot)

                // Verify the copy was successful (size check)
                if verifyFileCopy(source: source, destination: destination) {
                    return
                } else {
                    throw BackupEngineError.verificationFailed(destination)
                }
            } catch {
                lastError = error

                // Don't retry for certain errors
                if isNonRetryableError(error) {
                    throw error
                }

                if attempt < maxRetryAttempts {
                    logService.log(.warning, category: .backup,
                                   message: "Retry \(attempt)/\(maxRetryAttempts) for \((source as NSString).lastPathComponent): \(error.localizedDescription)")
                    // Brief delay before retry
                    Thread.sleep(forTimeInterval: Double(attempt) * 0.5)
                }
            }
        }

        throw lastError ?? BackupEngineError.maxRetriesExceeded
    }

    /// Verify that a file was copied correctly by comparing sizes.
    private func verifyFileCopy(source: String, destination: String) -> Bool {
        let fm = FileManager.default

        guard let sourceAttrs = try? fm.attributesOfItem(atPath: source),
              let destAttrs = try? fm.attributesOfItem(atPath: destination) else {
            return false
        }

        let sourceSize = sourceAttrs[.size] as? Int64 ?? -1
        let destSize = destAttrs[.size] as? Int64 ?? -2

        return sourceSize == destSize && sourceSize >= 0
    }

    /// Check if an error should not be retried.
    private func isNonRetryableError(_ error: Error) -> Bool {
        let nsError = error as NSError

        // Don't retry permission errors, disk full, etc.
        let nonRetryableCodes: [Int] = [
            NSFileNoSuchFileError,
            NSFileWriteNoPermissionError,
            NSFileWriteOutOfSpaceError,
            NSFileWriteVolumeReadOnlyError
        ]

        return nonRetryableCodes.contains(nsError.code)
    }
}

// MARK: - Backup Engine Errors

enum BackupEngineError: LocalizedError {
    case verificationFailed(String)
    case maxRetriesExceeded
    case sourceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .verificationFailed(let path):
            return "File verification failed after copy: \(path)"
        case .maxRetriesExceeded:
            return "Maximum retry attempts exceeded"
        case .sourceNotFound(let path):
            return "Source folder not found: \(path)"
        }
    }
}
