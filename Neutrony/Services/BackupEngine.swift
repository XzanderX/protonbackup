import Foundation

// MARK: - File Structure Cache

/// Cached information about a file in the source directory
struct CachedFileInfo: Codable {
    let relPath: String
    let isDirectory: Bool
    let isCloudOnly: Bool
    let size: Int64
    let modTime: Date?
    /// Whether this file should be offloaded after backup.
    /// Set to true when file was originally cloud-only, persists until successful eviction.
    let shouldOffload: Bool

    init(relPath: String, isDirectory: Bool, isCloudOnly: Bool, size: Int64, modTime: Date?, shouldOffload: Bool? = nil) {
        self.relPath = relPath
        self.isDirectory = isDirectory
        self.isCloudOnly = isCloudOnly
        self.size = size
        self.modTime = modTime
        // Default: shouldOffload = isCloudOnly (cloud-only files should be offloaded)
        self.shouldOffload = shouldOffload ?? isCloudOnly
    }
}

/// Cache of the source file structure to speed up subsequent backups
struct FileStructureCache: Codable {
    var version: Int = 1
    let sourcePath: String
    let scanDate: Date
    let files: [CachedFileInfo]
    let directories: [String]
    let totalScanned: Int

    /// Cache is considered fresh if less than 4 hours old
    var isFresh: Bool {
        Date().timeIntervalSince(scanDate) < 14400
    }
}

/// Cache of destination file sizes to speed up reconnection
struct DestinationCache: Codable {
    var version: Int = 1
    let destinationPath: String
    let scanDate: Date
    let fileSizes: [String: Int64]

    /// Cache is fresh if less than 4 hours old
    var isFresh: Bool {
        Date().timeIntervalSince(scanDate) < 14400
    }
}

/// Thread-safe collector for parallel directory scanning results
actor ScanResultsCollector {
    private(set) var localFiles: [(url: URL, relPath: String)] = []
    private(set) var cloudOnlyFiles: [(url: URL, relPath: String, cloudSize: Int64?)] = []
    private(set) var foldersToCreate: Set<String> = []
    private(set) var placeholdersToCreate: [(destPath: String, relPath: String, isCloudOnly: Bool, sourceURL: URL)] = []
    private(set) var cachedFileInfos: [CachedFileInfo] = []
    private(set) var cachedDirectories: [String] = []
    private(set) var allSourceRelPaths: Set<String> = []  // All files found in source (for deletion calc)
    private(set) var totalFilesFound: Int = 0
    private(set) var filesSkipped: Int = 0
    private(set) var directoriesScanned: Int = 0

    /// Map of relPath -> shouldOffload from previous cache.
    /// Used to preserve offload status for files that failed to evict.
    private var previousShouldOffload: [String: Bool] = [:]

    /// Set the previous shouldOffload map from a loaded cache.
    func setPreviousShouldOffload(_ map: [String: Bool]) {
        previousShouldOffload = map
    }

    /// Check if a file should be offloaded based on current scan and previous cache.
    private func shouldFileBeOffloaded(relPath: String, isCurrentlyCloudOnly: Bool) -> Bool {
        // If currently cloud-only, it should be offloaded
        if isCurrentlyCloudOnly {
            return true
        }
        // If previously marked for offload (was cloud-only but eviction failed), preserve that
        return previousShouldOffload[relPath] ?? false
    }

    func addLocalFile(_ file: (url: URL, relPath: String)) {
        localFiles.append(file)
    }

    func addCloudOnlyFile(_ file: (url: URL, relPath: String, cloudSize: Int64?)) {
        cloudOnlyFiles.append(file)
    }

    func addFolderToCreate(_ path: String) {
        foldersToCreate.insert(path)
    }

    func addPlaceholderToCreate(_ item: (destPath: String, relPath: String, isCloudOnly: Bool, sourceURL: URL)) {
        placeholdersToCreate.append(item)
    }

    func addCachedFileInfo(_ info: CachedFileInfo) {
        cachedFileInfos.append(info)
    }

    func addCachedDirectory(_ path: String) {
        cachedDirectories.append(path)
    }

    func incrementFilesFound() {
        totalFilesFound += 1
    }

    func incrementFilesSkipped() {
        filesSkipped += 1
    }

    func incrementDirectoriesScanned() {
        directoriesScanned += 1
    }

    func getPlaceholderCount() -> Int {
        return placeholdersToCreate.count
    }

    /// Extract items for flushing and clear internal buffers
    func extractForFlush() -> (
        folders: Set<String>,
        placeholders: [(destPath: String, relPath: String, isCloudOnly: Bool, sourceURL: URL)]
    ) {
        let folders = foldersToCreate
        let placeholders = placeholdersToCreate
        foldersToCreate.removeAll()
        placeholdersToCreate.removeAll()
        return (folders, placeholders)
    }

    /// Batch add multiple items from a directory scan
    func addBatchResults(
        items: [(item: URL, relPath: String, isDir: Bool, isCloudOnly: Bool, localSize: Int64)],
        destFileSizes: [String: Int64],
        backupRoot: String
    ) {
        for item in items {
            if item.isDir {
                let destDirPath = (backupRoot as NSString).appendingPathComponent(item.relPath)
                foldersToCreate.insert(destDirPath)
                cachedDirectories.append(item.relPath)
            } else {
                // Determine shouldOffload: preserve from previous cache or set based on current cloud-only status
                let shouldOffload = shouldFileBeOffloaded(relPath: item.relPath, isCurrentlyCloudOnly: item.isCloudOnly)

                // Cache file info
                cachedFileInfos.append(CachedFileInfo(
                    relPath: item.relPath,
                    isDirectory: false,
                    isCloudOnly: item.isCloudOnly,
                    size: item.localSize,
                    modTime: nil,
                    shouldOffload: shouldOffload
                ))

                // Determine if backup needed
                let destFilePath = (backupRoot as NSString).appendingPathComponent(item.relPath)
                let needsBackup: Bool
                if let existingSize = destFileSizes[item.relPath] {
                    if item.isCloudOnly {
                        needsBackup = existingSize == 0
                    } else {
                        needsBackup = item.localSize != existingSize
                    }
                } else {
                    needsBackup = true
                }

                if needsBackup {
                    placeholdersToCreate.append((destFilePath, item.relPath, item.isCloudOnly, item.item))
                    totalFilesFound += 1
                } else {
                    filesSkipped += 1
                }
            }
        }
        directoriesScanned += 1
    }

    /// Batch add with immediate copy queue support - returns local files for immediate copying
    func addBatchResultsWithCopyQueue(
        items: [(item: URL, relPath: String, isDir: Bool, isCloudOnly: Bool, localSize: Int64)],
        destFileSizes: [String: Int64],
        backupRoot: String
    ) -> [(sourceURL: URL, destPath: String, relPath: String)] {
        var localFilesForCopy: [(sourceURL: URL, destPath: String, relPath: String)] = []

        for item in items {
            if item.isDir {
                let destDirPath = (backupRoot as NSString).appendingPathComponent(item.relPath)
                foldersToCreate.insert(destDirPath)
                cachedDirectories.append(item.relPath)
            } else {
                // Track all source files for deletion calculation
                allSourceRelPaths.insert(item.relPath)

                // Cache file info - preserve shouldOffload status across scans
                let shouldOffload = shouldFileBeOffloaded(relPath: item.relPath, isCurrentlyCloudOnly: item.isCloudOnly)
                cachedFileInfos.append(CachedFileInfo(
                    relPath: item.relPath,
                    isDirectory: false,
                    isCloudOnly: item.isCloudOnly,
                    size: item.localSize,
                    modTime: nil,
                    shouldOffload: shouldOffload
                ))

                // Determine if backup needed
                let destFilePath = (backupRoot as NSString).appendingPathComponent(item.relPath)
                let needsBackup: Bool
                if let existingSize = destFileSizes[item.relPath] {
                    if item.isCloudOnly {
                        needsBackup = existingSize == 0
                    } else {
                        needsBackup = item.localSize != existingSize
                    }
                } else {
                    needsBackup = true
                }

                if needsBackup {
                    totalFilesFound += 1
                    if item.isCloudOnly {
                        // Cloud-only files need download first - queue for later
                        cloudOnlyFiles.append((item.item, item.relPath, nil))
                    } else {
                        // Local files can be copied immediately
                        localFilesForCopy.append((item.item, destFilePath, item.relPath))
                    }
                } else {
                    filesSkipped += 1
                }
            }
        }
        directoriesScanned += 1
        return localFilesForCopy
    }
}

/// Thread-safe queue for files to copy - enables immediate copying during scan
actor FileCopyQueue {
    private var queue: [(sourceURL: URL, destPath: String, relPath: String)] = []
    private var isComplete = false
    private(set) var filesQueued = 0
    private(set) var filesProcessed = 0
    private(set) var currentRelPath: String?

    func enqueue(_ files: [(sourceURL: URL, destPath: String, relPath: String)]) {
        queue.append(contentsOf: files)
        filesQueued += files.count
    }

    func dequeue() -> (sourceURL: URL, destPath: String, relPath: String)? {
        guard !queue.isEmpty else { return nil }
        let file = queue.removeFirst()
        currentRelPath = file.relPath
        return file
    }

    func dequeueBatch(maxCount: Int) -> [(sourceURL: URL, destPath: String, relPath: String)] {
        let count = min(maxCount, queue.count)
        guard count > 0 else { return [] }
        let batch = Array(queue.prefix(count))
        queue.removeFirst(count)
        if let last = batch.last {
            currentRelPath = last.relPath
        }
        return batch
    }

    func markComplete() {
        isComplete = true
    }

    func isDone() -> Bool {
        return isComplete && queue.isEmpty
    }

    func hasWork() -> Bool {
        return !queue.isEmpty || !isComplete
    }

    func incrementProcessed() {
        filesProcessed += 1
    }

    func getStats() -> (queued: Int, processed: Int, pending: Int) {
        return (filesQueued, filesProcessed, queue.count)
    }
}

/// Thread-safe tracker for shared mutable state during concurrent scan + copy
actor ConcurrentBackupTracker {
    private(set) var foldersAlreadyCreated: Set<String> = []
    private(set) var foldersCreated: Int = 0
    private(set) var filesUpdated: Int = 0
    private(set) var errors: [String] = []

    /// Check if folder needs to be created (returns true if not yet tracked)
    func needsFolder(_ path: String) -> Bool {
        return !foldersAlreadyCreated.contains(path)
    }

    /// Record that a folder was created (call after creating directory)
    func recordFolderCreated(_ path: String) {
        if !foldersAlreadyCreated.contains(path) {
            foldersAlreadyCreated.insert(path)
            foldersCreated += 1
        }
    }

    /// Check if parent folder needs creation and return its path if so
    func parentFolderIfNeeded(_ filePath: String) -> String? {
        let parent = (filePath as NSString).deletingLastPathComponent
        return foldersAlreadyCreated.contains(parent) ? nil : parent
    }

    /// Record that a parent folder was ensured
    func recordParentEnsured(_ path: String) {
        foldersAlreadyCreated.insert(path)
    }

    func recordFileUpdated() {
        filesUpdated += 1
    }

    private(set) var filesOffloaded: Int = 0

    func recordFileOffloaded() {
        filesOffloaded += 1
    }

    func recordError(_ message: String) {
        errors.append(message)
    }

    func preloadFolders(_ folders: Set<String>) {
        foldersAlreadyCreated.formUnion(folders)
    }
}

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
    private let badgeService = BadgeService.shared

    /// Maximum retry attempts for transient errors
    private let maxRetryAttempts = 3

    /// Concurrency limit for parallel file operations
    private let maxConcurrentOperations = 8

    /// Concurrency limit for parallel directory scanning
    private let maxConcurrentScans = 16

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

    // MARK: - Cache Management

    /// Path to the structure cache file in the backup's .backup folder
    private func cachePath(for backupRoot: String) -> String {
        let backupFolder = (backupRoot as NSString).appendingPathComponent(".backup")
        return (backupFolder as NSString).appendingPathComponent("structure-cache.json")
    }

    /// Load the cached file structure from the backup destination
    private func loadCache(backupRoot: String, sourcePath: String) -> FileStructureCache? {
        let path = cachePath(for: backupRoot)
        guard let data = FileManager.default.contents(atPath: path) else {
            logService.log(.debug, category: .backup, message: "No structure cache found")
            return nil
        }

        do {
            let cache = try JSONDecoder().decode(FileStructureCache.self, from: data)

            // Verify cache is for the same source
            guard cache.sourcePath == sourcePath else {
                logService.log(.info, category: .backup, message: "Cache source mismatch, will rescan")
                return nil
            }

            // Check if cache is fresh
            if cache.isFresh {
                logService.log(.info, category: .backup,
                               message: "Loaded structure cache: \(cache.files.count) files, \(cache.directories.count) dirs (age: \(Int(Date().timeIntervalSince(cache.scanDate)))s)")
                return cache
            } else {
                logService.log(.info, category: .backup,
                               message: "Cache is stale (age: \(Int(Date().timeIntervalSince(cache.scanDate)/60))min), will rescan")
                return nil
            }
        } catch {
            logService.log(.warning, category: .backup, message: "Failed to load cache: \(error.localizedDescription)")
            return nil
        }
    }

    /// Load the shouldOffload map from any existing cache (even if stale).
    /// This ensures we don't lose track of files that need offloading across multiple backups.
    private func loadPreviousShouldOffload(backupRoot: String) -> [String: Bool] {
        let path = cachePath(for: backupRoot)
        guard let data = FileManager.default.contents(atPath: path) else {
            return [:]
        }

        do {
            let cache = try JSONDecoder().decode(FileStructureCache.self, from: data)
            var map: [String: Bool] = [:]
            for file in cache.files {
                map[file.relPath] = file.shouldOffload
            }
            if !map.isEmpty {
                logService.log(.debug, category: .backup,
                               message: "Loaded shouldOffload status for \(map.filter { $0.value }.count) files")
            }
            return map
        } catch {
            return [:]
        }
    }

    /// Save the scanned file structure to cache
    private func saveCache(backupRoot: String, sourcePath: String, files: [CachedFileInfo], directories: [String]) {
        let cache = FileStructureCache(
            sourcePath: sourcePath,
            scanDate: Date(),
            files: files,
            directories: directories,
            totalScanned: files.count + directories.count
        )

        let path = cachePath(for: backupRoot)
        let backupFolder = (path as NSString).deletingLastPathComponent

        do {
            // Ensure .backup folder exists
            try FileManager.default.createDirectory(atPath: backupFolder, withIntermediateDirectories: true)

            let data = try JSONEncoder().encode(cache)
            try data.write(to: URL(fileURLWithPath: path))

            logService.log(.info, category: .backup,
                           message: "Saved structure cache: \(files.count) files, \(directories.count) dirs")
        } catch {
            logService.log(.warning, category: .backup, message: "Failed to save cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Destination Cache

    /// Path to the destination cache file
    private func destCachePath(for backupRoot: String) -> String {
        let backupFolder = (backupRoot as NSString).appendingPathComponent(".backup")
        return (backupFolder as NSString).appendingPathComponent("dest-cache.json")
    }

    /// Load cached destination file sizes for fast reconnection
    private func loadDestCache(backupRoot: String) -> DestinationCache? {
        let path = destCachePath(for: backupRoot)
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }

        do {
            let cache = try JSONDecoder().decode(DestinationCache.self, from: data)
            guard cache.destinationPath == backupRoot, cache.isFresh else {
                logService.log(.info, category: .backup, message: "Destination cache stale, will rescan")
                return nil
            }
            logService.log(.info, category: .backup,
                           message: "Loaded destination cache: \(cache.fileSizes.count) files (age: \(Int(Date().timeIntervalSince(cache.scanDate)))s)")
            return cache
        } catch {
            return nil
        }
    }

    /// Save destination file sizes to cache
    private func saveDestCache(backupRoot: String, fileSizes: [String: Int64]) {
        let cache = DestinationCache(
            destinationPath: backupRoot,
            scanDate: Date(),
            fileSizes: fileSizes
        )

        let path = destCachePath(for: backupRoot)
        let backupFolder = (path as NSString).deletingLastPathComponent

        do {
            try FileManager.default.createDirectory(atPath: backupFolder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: URL(fileURLWithPath: path))
            logService.log(.debug, category: .backup,
                           message: "Saved destination cache: \(fileSizes.count) files")
        } catch {
            logService.log(.warning, category: .backup, message: "Failed to save dest cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Fast Destination Scanner

    /// Scan destination directory using stat() for fast file size collection.
    /// Returns a dictionary of relative paths to file sizes.
    /// Uses parallel directory traversal for speed.
    private func scanDestinationSizes(destURL: URL) -> [String: Int64] {
        let fm = FileManager.default
        let basePath = destURL.path
        var results: [String: Int64] = [:]
        let lock = NSLock()

        // Recursive scan using stat() - much faster than attributesOfItem
        func scanDir(_ dirPath: String) {
            guard let items = try? fm.contentsOfDirectory(atPath: dirPath) else { return }

            var subdirs: [String] = []
            var localResults: [(String, Int64)] = []

            for itemName in items {
                // Skip hidden files and system files
                if itemName.hasPrefix(".") { continue }
                if itemName == "_versions" { continue }

                let itemPath = (dirPath as NSString).appendingPathComponent(itemName)

                var statInfo = stat()
                guard stat(itemPath, &statInfo) == 0 else { continue }

                let isDirectory = (statInfo.st_mode & S_IFMT) == S_IFDIR
                if isDirectory {
                    subdirs.append(itemPath)
                } else {
                    // Compute relative path
                    var relPath = String(itemPath.dropFirst(basePath.count))
                    if relPath.hasPrefix("/") { relPath = String(relPath.dropFirst()) }
                    localResults.append((relPath, Int64(statInfo.st_size)))
                }
            }

            // Batch insert results
            if !localResults.isEmpty {
                lock.lock()
                for (path, size) in localResults {
                    results[path] = size
                }
                lock.unlock()
            }

            // Recurse into subdirectories
            for subdir in subdirs {
                scanDir(subdir)
            }
        }

        // Start scan - use DispatchQueue for parallelism on top-level dirs
        guard let topItems = try? fm.contentsOfDirectory(atPath: basePath) else { return results }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.neutrony.destScan", attributes: .concurrent)

        for itemName in topItems {
            if itemName.hasPrefix(".") || itemName == "_versions" { continue }

            let itemPath = (basePath as NSString).appendingPathComponent(itemName)
            var statInfo = stat()
            guard stat(itemPath, &statInfo) == 0 else { continue }

            let isDirectory = (statInfo.st_mode & S_IFMT) == S_IFDIR
            if isDirectory {
                group.enter()
                queue.async {
                    scanDir(itemPath)
                    group.leave()
                }
            } else {
                var relPath = String(itemPath.dropFirst(basePath.count))
                if relPath.hasPrefix("/") { relPath = String(relPath.dropFirst()) }
                results[relPath] = Int64(statInfo.st_size)
            }
        }

        group.wait()
        return results
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
        let backupRoot = destinationPath
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
                try await copyFileWithRetry(from: sourceURL.path, to: destPath, keepVersions: keepVersions, backupRoot: backupRoot)
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
        let backupRoot = destinationPath
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
                try await copyFileWithRetry(from: sourceURL.path, to: destPath, keepVersions: keepVersions, backupRoot: backupRoot)
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
    /// Creates placeholders in real-time as files are discovered (immediate visual feedback).
    /// Then copies local files, then downloads cloud files.
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
        var placeholdersCreated = 0
        var foldersCreated = 0
        var errors: [String] = []

        let fm = FileManager.default

        logService.log(.info, category: .backup,
                       message: "Starting on-demand backup: \(sourcePath) → \(destinationPath)")
        logService.log(.info, category: .backup,
                       message: "Offload after backup: \(offloadAfterBackup)")

        // Configure badge service for this backup
        badgeService.configure(sourcePath: sourcePath, destinationPath: destinationPath)
        badgeService.backupStarted(destinationPath: destinationPath)

        // Verify source exists
        guard fm.fileExists(atPath: sourcePath) else {
            logService.log(.error, category: .backup, message: "Source path does not exist: \(sourcePath)")
            throw BackupEngineError.sourceNotFound(sourcePath)
        }

        // Ensure destination directory exists
        let backupRoot = destinationPath
        try fm.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destURL = URL(fileURLWithPath: backupRoot)

        // Get existing destination files for comparison
        // Try cached destination first for fast reconnection
        let destScanStart = Date()
        var destFileSizes: [String: Int64]
        if let destCache = loadDestCache(backupRoot: backupRoot) {
            destFileSizes = destCache.fileSizes
            logService.log(.info, category: .backup,
                           message: "Using cached destination: \(destFileSizes.count) files (instant)")
        } else {
            logService.log(.info, category: .backup, message: "Scanning destination with stat()...")
            destFileSizes = scanDestinationSizes(destURL: destURL)
            let scanTime = Date().timeIntervalSince(destScanStart)
            logService.log(.info, category: .backup,
                           message: "Destination scan complete: \(destFileSizes.count) files in \(String(format: "%.1f", scanTime))s")
        }
        let zeroByteCount = destFileSizes.values.filter { $0 == 0 }.count
        logService.log(.info, category: .backup,
                       message: "Destination has \(destFileSizes.count) files (\(zeroByteCount) are 0-byte placeholders)")

        // ============================================
        // PHASE 0: Fast sequential scan with batched structure creation
        // Uses cache when available to speed up subsequent backups
        // ============================================
        logService.log(.info, category: .backup,
                       message: "Phase 0: Scanning directory structure...")

        var localFilesToBackup: [(url: URL, relPath: String)] = []
        var cloudOnlyFilesToBackup: [(url: URL, relPath: String, cloudSize: Int64?)] = []
        var foldersAlreadyCreated: Set<String> = []  // Track folders created for dedup
        var totalFilesFound = 0
        var cachedFileInfos: [CachedFileInfo] = []  // For saving to cache
        var cachedDirectories: [String] = []  // For saving to cache
        var usedCache = false

        // Try to load cached structure for faster startup
        if let cache = loadCache(backupRoot: backupRoot, sourcePath: sourcePath) {
            logService.log(.info, category: .backup,
                           message: "Using cached structure (\(cache.files.count) files, \(cache.directories.count) dirs)")
            usedCache = true

            // Copy cache data for later updates (e.g., after eviction)
            cachedFileInfos = cache.files
            cachedDirectories = cache.directories

            // Create all directories from cache
            for dirPath in cache.directories {
                let destDirPath = (backupRoot as NSString).appendingPathComponent(dirPath)
                if !foldersAlreadyCreated.contains(destDirPath) {
                    try? fm.createDirectory(atPath: destDirPath, withIntermediateDirectories: true, attributes: nil)
                    foldersAlreadyCreated.insert(destDirPath)
                    foldersCreated += 1
                }
            }

            // Process files from cache
            for fileInfo in cache.files {
                let destFilePath = (backupRoot as NSString).appendingPathComponent(fileInfo.relPath)
                let fileURL = sourceURL.appendingPathComponent(fileInfo.relPath)

                // Determine if backup needed
                let needsBackup: Bool
                if let existingSize = destFileSizes[fileInfo.relPath] {
                    if fileInfo.isCloudOnly {
                        needsBackup = existingSize == 0
                    } else {
                        needsBackup = fileInfo.size != existingSize
                    }
                } else {
                    needsBackup = true
                }

                if needsBackup {
                    // Create placeholder if doesn't exist
                    if !fm.fileExists(atPath: destFilePath) {
                        // Ensure parent directory exists
                        let destParent = (destFilePath as NSString).deletingLastPathComponent
                        if !foldersAlreadyCreated.contains(destParent) {
                            try? fm.createDirectory(atPath: destParent, withIntermediateDirectories: true)
                            foldersAlreadyCreated.insert(destParent)
                        }
                        fm.createFile(atPath: destFilePath, contents: nil, attributes: nil)
                        placeholdersCreated += 1
                    }

                    // Categorize for later phases
                    if fileInfo.isCloudOnly {
                        cloudOnlyFilesToBackup.append((fileURL, fileInfo.relPath, nil))
                    } else {
                        localFilesToBackup.append((fileURL, fileInfo.relPath))
                    }
                    totalFilesFound += 1
                } else {
                    filesSkipped += 1
                }

                // Update progress periodically
                if (totalFilesFound + filesSkipped) % 1000 == 0 {
                    await Task.yield()
                    let progress = BackupProgress(
                        totalFiles: cache.files.count,
                        completedFiles: totalFilesFound + filesSkipped,
                        currentFileName: "Processing cached structure..."
                    )
                    progressHandler(progress)
                }
            }

            logService.log(.info, category: .backup,
                           message: "Cache processed: \(totalFilesFound) files to backup, \(filesSkipped) skipped")
        }

        // Only do full scan if we didn't use cached structure
        if !usedCache {
            // ============================================
            // PARALLEL SCAN + IMMEDIATE COPY
            // Scans directories and starts copying local files immediately
            // ============================================
            let collector = ScanResultsCollector()
            let copyQueue = FileCopyQueue()
            let tracker = ConcurrentBackupTracker()

            // Load previous shouldOffload status to preserve across scans
            // This ensures files that failed to evict will be retried
            let previousShouldOffloadMap = loadPreviousShouldOffload(backupRoot: backupRoot)
            await collector.setPreviousShouldOffload(previousShouldOffloadMap)

            // Preload folders from the cache path if any were created
            if !foldersAlreadyCreated.isEmpty {
                await tracker.preloadFolders(foldersAlreadyCreated)
            }

            // Thread-safe directory queue using actor
            actor DirectoryQueue {
                private var queue: [URL]
                private var activeWorkers = 0
                private var isComplete = false

                init(initial: URL) {
                    self.queue = [initial]
                }

                func take() -> URL? {
                    guard !queue.isEmpty else { return nil }
                    activeWorkers += 1
                    return queue.removeFirst()
                }

                func addDirectories(_ dirs: [URL]) {
                    queue.append(contentsOf: dirs)
                }

                func finishWorker() {
                    activeWorkers -= 1
                }

                func hasWork() -> Bool {
                    return !queue.isEmpty || activeWorkers > 0
                }

                func markComplete() {
                    isComplete = true
                }

                func isFinished() -> Bool {
                    return isComplete
                }

                func getQueueSize() -> Int {
                    return queue.count
                }
            }

            let dirQueue = DirectoryQueue(initial: sourceURL)
            let scanStartTime = Date()

            // Run scan workers, copy workers, and progress updater concurrently
            await withTaskGroup(of: Void.self) { group in
                // Directory scanning workers - scan and queue local files for immediate copy
                for _ in 0..<maxConcurrentScans {
                    group.addTask { [self] in
                        while true {
                            guard let directory = await dirQueue.take() else {
                                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                                if await !dirQueue.hasWork() {
                                    break
                                }
                                continue
                            }

                            if let items = scanDirectoryContents(directory: directory, sourceURL: sourceURL, backupRoot: backupRoot) {
                                var subdirs: [URL] = []
                                for item in items {
                                    if item.isDir {
                                        subdirs.append(item.item)
                                    }
                                }

                                if !subdirs.isEmpty {
                                    await dirQueue.addDirectories(subdirs)
                                }

                                // Use the new method that returns local files for immediate copying
                                let localFilesForCopy = await collector.addBatchResultsWithCopyQueue(
                                    items: items,
                                    destFileSizes: destFileSizes,
                                    backupRoot: backupRoot
                                )

                                // Queue local files for immediate copying
                                if !localFilesForCopy.isEmpty {
                                    await copyQueue.enqueue(localFilesForCopy)
                                }

                                // Create folders for this batch (check actor, create outside, record)
                                let (folders, _) = await collector.extractForFlush()
                                for folderPath in folders {
                                    if await tracker.needsFolder(folderPath) {
                                        try? fm.createDirectory(atPath: folderPath, withIntermediateDirectories: true, attributes: nil)
                                        await tracker.recordFolderCreated(folderPath)
                                    }
                                }
                            }

                            await dirQueue.finishWorker()
                        }
                    }
                }

                // File copy workers - start copying immediately as files are discovered
                for _ in 0..<maxConcurrentOperations {
                    group.addTask { [self] in
                        while true {
                            // Check if there's work or if more might come
                            let queueDone = await copyQueue.isDone()
                            let scanDone = await dirQueue.isFinished()
                            if queueDone && scanDone {
                                break
                            }

                            // Try to get a file to copy
                            guard let file = await copyQueue.dequeue() else {
                                // No files ready yet, wait briefly
                                try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                                continue
                            }

                            // Ensure parent directory exists (check actor, create outside)
                            if let parentPath = await tracker.parentFolderIfNeeded(file.destPath) {
                                try? fm.createDirectory(atPath: parentPath, withIntermediateDirectories: true, attributes: nil)
                                await tracker.recordParentEnsured(parentPath)
                            }

                            // Re-check file status before copying (status may have changed since scan)
                            let currentSize = (try? FileManager.default.attributesOfItem(atPath: file.sourceURL.path)[.size] as? Int64) ?? 0
                            if currentSize == 0 {
                                // File is now cloud-only - skip, will be handled in Phase 1
                                logService.log(.debug, category: .backup,
                                               message: "Skipping \(file.relPath) - became cloud-only since scan")
                                await copyQueue.incrementProcessed()
                                continue
                            }

                            // Mark file as syncing
                            badgeService.markFileSyncing(relativePath: file.relPath)

                            do {
                                try await copyFileWithRetry(from: file.sourceURL.path, to: file.destPath, keepVersions: keepVersions, backupRoot: backupRoot)
                                await tracker.recordFileUpdated()
                                badgeService.markFileComplete(relativePath: file.relPath)
                                // Phase 0: Local files stay local - no offloading
                            } catch {
                                let desc = "Failed to backup \(file.relPath): \(error.localizedDescription)"
                                await tracker.recordError(desc)
                                logService.log(.error, category: .backup, message: desc, filePath: file.relPath)
                                badgeService.markFileError(relativePath: file.relPath)
                            }

                            await copyQueue.incrementProcessed()
                        }
                    }
                }

                // Progress update task
                group.addTask { [self] in
                    while true {
                        let dirHasWork = await dirQueue.hasWork()
                        let copyHasWork = await copyQueue.hasWork()
                        guard dirHasWork || copyHasWork else { break }

                        try? await Task.sleep(nanoseconds: 200_000_000) // Update every 200ms
                        let dirsScanned = await collector.directoriesScanned
                        let filesFound = await collector.totalFilesFound
                        let (queued, copied, _) = await copyQueue.getStats()

                        let elapsed = Date().timeIntervalSince(scanStartTime)
                        let scanRate = elapsed > 0 ? Double(dirsScanned) / elapsed : 0

                        logService.log(.debug, category: .backup,
                                       message: "Scan+Copy: \(dirsScanned) dirs (\(String(format: "%.0f", scanRate))/s), \(filesFound) found, \(copied)/\(queued) copied")

                        // Report the current file being copied (or scanning status if no file yet)
                        // Include skipped files (already up-to-date) in the completed count
                        let skipped = await collector.filesSkipped
                        let totalScanned = filesFound + skipped
                        let totalCompleted = copied + skipped

                        let currentFile = await copyQueue.currentRelPath
                        let displayName = currentFile ?? "Scanning & copying: \(totalScanned) found, \(totalCompleted) done..."
                        let scanProgress = BackupProgress(
                            totalFiles: totalScanned,
                            completedFiles: totalCompleted,
                            currentFileName: displayName
                        )
                        progressHandler(scanProgress)
                    }
                }

                await group.waitForAll()
            }

            // Mark scanning complete
            await dirQueue.markComplete()
            await copyQueue.markComplete()

            // Get final results from collector and tracker
            totalFilesFound = await collector.totalFilesFound
            filesSkipped = await collector.filesSkipped
            cachedFileInfos = await collector.cachedFileInfos
            cachedDirectories = await collector.cachedDirectories
            cloudOnlyFilesToBackup = await collector.cloudOnlyFiles

            // Merge tracker results back into local variables
            foldersCreated = await tracker.foldersCreated
            filesUpdated = await tracker.filesUpdated
            filesOffloaded = await tracker.filesOffloaded
            errors.append(contentsOf: await tracker.errors)
            foldersAlreadyCreated = await tracker.foldersAlreadyCreated

            let scanDuration = Date().timeIntervalSince(scanStartTime)
            let dirsScanned = await collector.directoriesScanned
            let (_, copiedDuringScan, _) = await copyQueue.getStats()
            logService.log(.info, category: .backup,
                           message: "Scan+Copy complete: \(dirsScanned) dirs, \(totalFilesFound) files, \(copiedDuringScan) copied during scan in \(String(format: "%.1f", scanDuration))s")

            // Save the structure cache for faster subsequent backups
            saveCache(backupRoot: backupRoot, sourcePath: sourcePath, files: cachedFileInfos, directories: cachedDirectories)
        }

        logService.log(.info, category: .backup,
                       message: "Phase 0 complete: \(foldersCreated) folders, \(filesUpdated) local files copied")

        logService.log(.info, category: .backup,
                       message: "Remaining: \(cloudOnlyFilesToBackup.count) cloud-only files to download")

        // Calculate files to delete (use cached file info for source relative paths)
        var sourceRelative: Set<String>
        if usedCache {
            // From cache: combine local + cloud files
            sourceRelative = Set(localFilesToBackup.map { $0.relPath } + cloudOnlyFilesToBackup.map { $0.relPath })
        } else {
            // From scan: use the tracked source paths
            sourceRelative = Set(cachedFileInfos.map { $0.relPath })
        }
        let destRelative = Set(destFileSizes.keys)
        let filesToDelete = destRelative.subtracting(sourceRelative)

        // Calculate totals including skipped files for accurate progress display
        // Total = all files scanned (those needing update + those already up-to-date)
        // Completed = skipped + local files copied + cloud files processed
        let totalAllFiles = totalFilesFound + filesSkipped
        let baseCompleted = filesSkipped + filesUpdated  // Already done before Phase 1
        var cloudCompleted = 0

        if cloudOnlyFilesToBackup.isEmpty && filesToDelete.isEmpty && filesUpdated == 0 {
            logService.log(.info, category: .backup, message: "Backup is up to date, no changes needed")
            return BackupSummary(
                filesUpdated: 0, filesDeleted: 0, filesSkipped: filesSkipped,
                errors: [], startTime: startTime, endTime: Date()
            )
        }

        // ============================================
        // PHASE 1: Download cloud-only files (this is when downloads start)
        // Local files were already copied during the scan phase
        // ============================================
        // Track successfully evicted files to update cache
        var evictedFiles = Set<String>()

        logService.log(.info, category: .backup,
                       message: "Phase 1 starting: \(cloudOnlyFilesToBackup.count) cloud files, offloadAfterBackup=\(offloadAfterBackup)")

        if !cloudOnlyFilesToBackup.isEmpty {
            logService.log(.info, category: .backup,
                           message: "Phase 1: Downloading \(cloudOnlyFilesToBackup.count) cloud-only files...")

            for (fileURL, relPath, _) in cloudOnlyFilesToBackup {
                // Check for pause
                while pauseChecker?() == true {
                    try await Task.sleep(nanoseconds: 500_000_000)
                }

                let currentProgress = BackupProgress(
                    totalFiles: totalAllFiles,
                    completedFiles: baseCompleted + cloudCompleted,
                    currentFileName: "⬇ \(relPath)"
                )
                progressHandler(currentProgress)

                // Mark file as downloading in Finder
                badgeService.markFileDownloading(relativePath: relPath)

                do {
                    let destPath = (backupRoot as NSString).appendingPathComponent(relPath)

                    // Re-check file status before downloading (status may have changed since scan)
                    let currentSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                    let needsDownload = (currentSize == 0)

                    if needsDownload {
                        // File is still cloud-only - download it
                        logService.log(.debug, category: .backup, message: "Downloading: \(relPath)")
                        let downloaded = await syncVerifier.requestDownloadAndWait(at: fileURL.path, timeout: 120)

                        if !downloaded {
                            // Keep the placeholder, log warning
                            errors.append("Download timeout: \(relPath) (placeholder kept)")
                            logService.log(.warning, category: .backup, message: "Download timeout: \(relPath)")
                            badgeService.markFileError(relativePath: relPath)
                            cloudCompleted += 1
                            continue
                        }
                        filesDownloaded += 1
                    } else {
                        // File is now local (was downloaded since scan) - just copy it
                        logService.log(.debug, category: .backup, message: "File already local (was cloud-only at scan): \(relPath)")
                    }

                    // Mark as syncing during copy
                    badgeService.markFileSyncing(relativePath: relPath)

                    // Copy the downloaded file (replaces placeholder)
                    try await copyFileWithRetry(from: fileURL.path, to: destPath, keepVersions: false, backupRoot: backupRoot)
                    filesUpdated += 1
                    badgeService.markFileComplete(relativePath: relPath)

                    // Offload (evict) file back to cloud-only if requested
                    // This restores the file to its original cloud-only state
                    logService.log(.info, category: .backup, message: "File copied, offloadAfterBackup=\(offloadAfterBackup) for: \(relPath)")
                    if offloadAfterBackup {
                        logService.log(.info, category: .backup, message: ">>> STARTING OFFLOAD for: \(relPath)")
                        logService.log(.info, category: .backup, message: ">>> Source path: \(fileURL.path)")
                        if await syncVerifier.evictFileWithRetry(at: fileURL.path) {
                            filesOffloaded += 1
                            evictedFiles.insert(relPath)  // Track for cache update
                            logService.log(.info, category: .backup, message: ">>> OFFLOAD SUCCESS: \(relPath)")
                        } else {
                            let warn = ">>> OFFLOAD FAILED: \(relPath) - file remains downloaded locally"
                            errors.append(warn)
                            logService.log(.warning, category: .backup, message: warn, filePath: relPath)
                            // File stays in shouldOffload list for retry on next backup
                        }
                    } else {
                        logService.log(.info, category: .backup, message: ">>> OFFLOAD DISABLED - skipping: \(relPath)")
                    }

                } catch {
                    let desc = "Failed to backup \(relPath): \(error.localizedDescription)"
                    errors.append(desc)
                    logService.log(.error, category: .backup, message: desc, filePath: relPath)
                    badgeService.markFileError(relativePath: relPath)
                }

                cloudCompleted += 1
            }

            logService.log(.info, category: .backup,
                           message: "Phase 1 complete: \(filesDownloaded) cloud files downloaded")
        }

        // ============================================
        // RETRY EVICTION: For files that failed to evict on previous backups
        // These files have shouldOffload=true but weren't processed in Phase 1
        // ============================================
        if offloadAfterBackup {
            // Find files that need eviction but weren't in this Phase 1
            let phase1RelPaths = Set(cloudOnlyFilesToBackup.map { $0.relPath })
            let filesToRetryEviction = cachedFileInfos.filter { info in
                info.shouldOffload &&
                !info.isCloudOnly &&  // File is currently downloaded
                !phase1RelPaths.contains(info.relPath)  // Wasn't processed in Phase 1
            }

            if !filesToRetryEviction.isEmpty {
                logService.log(.info, category: .backup,
                               message: "Retrying eviction for \(filesToRetryEviction.count) files from previous backup...")

                for fileInfo in filesToRetryEviction {
                    let fileURL = sourceURL.appendingPathComponent(fileInfo.relPath)
                    if await syncVerifier.evictFileWithRetry(at: fileURL.path) {
                        filesOffloaded += 1
                        evictedFiles.insert(fileInfo.relPath)
                        logService.log(.debug, category: .backup,
                                       message: "Retry eviction succeeded: \(fileInfo.relPath)")
                    }
                }

                if !evictedFiles.isEmpty {
                    logService.log(.info, category: .backup,
                                   message: "Eviction retry complete: \(evictedFiles.count) files offloaded")
                }
            }
        }

        // ============================================
        // PHASE 2: Handle deletions
        // ============================================
        if !filesToDelete.isEmpty {
            logService.log(.info, category: .backup,
                           message: "Phase 2: Processing \(filesToDelete.count) deletions...")

            for relPath in filesToDelete {
                while pauseChecker?() == true {
                    try await Task.sleep(nanoseconds: 500_000_000)
                }

                // Deletions don't affect file count, just show current status
                let currentProgress = BackupProgress(
                    totalFiles: totalAllFiles,
                    completedFiles: baseCompleted + cloudCompleted,
                    currentFileName: "🗑 \(relPath)"
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
            }
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
                       message: "Stats: \(placeholdersCreated) placeholders, \(filesDownloaded) downloaded, \(filesOffloaded) offloaded")

        // Save updated destination cache for fast reconnection
        // After backup, update dest sizes based on what we know changed
        var updatedDestSizes = destFileSizes
        // Update local files that were copied during scan
        for fileInfo in cachedFileInfos where !fileInfo.isCloudOnly {
            if updatedDestSizes[fileInfo.relPath] != fileInfo.size {
                updatedDestSizes[fileInfo.relPath] = fileInfo.size
            }
        }
        // Update cloud files that were downloaded
        for (_, relPath, _) in cloudOnlyFilesToBackup {
            let destPath = (backupRoot as NSString).appendingPathComponent(relPath)
            var statInfo = stat()
            if stat(destPath, &statInfo) == 0 {
                updatedDestSizes[relPath] = Int64(statInfo.st_size)
            }
        }
        // Remove deleted files
        for relPath in filesToDelete {
            updatedDestSizes.removeValue(forKey: relPath)
        }
        saveDestCache(backupRoot: backupRoot, fileSizes: updatedDestSizes)

        // Update structure cache with eviction status
        // Files that were successfully evicted no longer need shouldOffload
        if !evictedFiles.isEmpty && !cachedFileInfos.isEmpty {
            var updatedCachedInfos: [CachedFileInfo] = []
            for info in cachedFileInfos {
                if evictedFiles.contains(info.relPath) {
                    // Successfully evicted - update to shouldOffload = false
                    updatedCachedInfos.append(CachedFileInfo(
                        relPath: info.relPath,
                        isDirectory: info.isDirectory,
                        isCloudOnly: true,  // File is now cloud-only again
                        size: 0,  // Cloud-only has size 0
                        modTime: info.modTime,
                        shouldOffload: false  // No longer needs offload
                    ))
                } else {
                    updatedCachedInfos.append(info)
                }
            }
            // Save updated cache
            saveCache(backupRoot: backupRoot, sourcePath: sourcePath, files: updatedCachedInfos, directories: cachedDirectories)
            logService.log(.info, category: .backup,
                           message: "Updated cache: \(evictedFiles.count) files marked as evicted")
        }

        // Mark backup as complete in Finder
        badgeService.backupCompleted(destinationPath: destinationPath)

        return summary
    }

    /// Scan directory including cloud-only placeholder files.
    /// Uses recursive directory listing instead of enumerator for better CloudStorage compatibility.
    /// IMPORTANT: This scan is READ-ONLY and does NOT trigger any downloads.
    /// Downloads only happen later in Phase 2 via explicit requestDownloadAndWait().
    private func scanDirectoryIncludingCloudOnly(_ url: URL, excludingPrefix: String) throws -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        var directoriesScanned = 0

        logService.log(.debug, category: .backup, message: "Starting scan of: \(url.path) (read-only, no downloads)")

        // Verify the directory exists
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            logService.log(.error, category: .backup, message: "Source is not a directory: \(url.path)")
            return []
        }

        // Use recursive helper function instead of enumerator (more reliable for CloudStorage)
        // This only reads directory listings - never triggers downloads
        func scanRecursively(directory: URL, relativeTo baseURL: URL) {
            let dirPath = directory.path

            // Get directory contents - this is a metadata-only operation
            guard let contents = try? fm.contentsOfDirectory(atPath: dirPath) else {
                logService.log(.warning, category: .backup, message: "Could not list directory: \(dirPath)")
                return
            }

            logService.log(.debug, category: .backup, message: "Scanning \(directory.lastPathComponent): \(contents.count) items")

            for itemName in contents {
                // Skip system files and snapshot history
                if itemName == ".DS_Store" || itemName == ".localized" || itemName == ".Spotlight-V100" || itemName == ".Trashes" || itemName == ".fseventsd" || itemName == ".Trash" || itemName == ".history" {
                    continue
                }

                let itemURL = directory.appendingPathComponent(itemName)
                let relPath = relativePath(from: baseURL, to: itemURL)

                // Skip excluded prefix
                if relPath.hasPrefix(excludingPrefix) {
                    continue
                }

                // Check if it's a directory or file using fileExists only (no resourceValues to avoid triggering downloads)
                var itemIsDir: ObjCBool = false
                let exists = fm.fileExists(atPath: itemURL.path, isDirectory: &itemIsDir)

                if exists {
                    if itemIsDir.boolValue {
                        directoriesScanned += 1
                        scanRecursively(directory: itemURL, relativeTo: baseURL)
                    } else {
                        files.append(itemURL)
                    }
                } else {
                    // Item listed in directory but doesn't "exist" locally
                    // This is a cloud-only file - add it without checking resourceValues
                    // We'll determine if it's a directory by trying to list its contents
                    if let _ = try? fm.contentsOfDirectory(atPath: itemURL.path) {
                        // It's a directory (cloud-only directory)
                        directoriesScanned += 1
                        scanRecursively(directory: itemURL, relativeTo: baseURL)
                    } else {
                        // It's a file (cloud-only file)
                        files.append(itemURL)
                    }
                }
            }
        }

        // List top-level contents for debugging
        if let contents = try? fm.contentsOfDirectory(atPath: url.path) {
            logService.log(.debug, category: .backup, message: "Top-level contents (\(contents.count) items): \(contents.prefix(10).joined(separator: ", "))\(contents.count > 10 ? "..." : "")")
        }

        // Start recursive scan
        scanRecursively(directory: url, relativeTo: url)

        logService.log(.info, category: .backup, message: "Scan complete: \(directoriesScanned) directories, \(files.count) files found")
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
        let backupRoot = destinationPath
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
        let tempDir = fm.temporaryDirectory.appendingPathComponent("Neutrony")
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

    /// Scan contents of a single directory for concurrent processing.
    /// Returns items with their metadata without recursing (recursion handled by caller).
    /// Uses path-based API to avoid blocking on cloud metadata fetches.
    private func scanDirectoryContents(
        directory: URL,
        sourceURL: URL,
        backupRoot: String
    ) -> [(item: URL, relPath: String, isDir: Bool, isCloudOnly: Bool, localSize: Int64)]? {
        let fm = FileManager.default
        let dirPath = directory.path

        // Use simple path-based directory listing - faster and doesn't fetch cloud metadata
        guard let itemNames = try? fm.contentsOfDirectory(atPath: dirPath) else {
            return nil
        }

        var results: [(item: URL, relPath: String, isDir: Bool, isCloudOnly: Bool, localSize: Int64)] = []
        results.reserveCapacity(itemNames.count)

        let isInCloudStorage = dirPath.contains("/Library/CloudStorage/")

        for itemName in itemNames {
            // Skip hidden files and system files
            if itemName.hasPrefix(".") {
                continue
            }

            // Skip system directories
            if itemName == "Spotlight-V100" || itemName == "Trashes" ||
               itemName == "fseventsd" || itemName == "Trash" ||
               itemName == "history" {
                continue
            }

            let itemPath = (dirPath as NSString).appendingPathComponent(itemName)
            let itemURL = URL(fileURLWithPath: itemPath)
            let relPath = relativePath(from: sourceURL, to: itemURL)

            // Skip _versions
            if relPath.hasPrefix("_versions") {
                continue
            }

            // Use stat() directly - faster than FileManager and doesn't trigger cloud downloads
            var statInfo = stat()
            let statResult = stat(itemPath, &statInfo)

            if statResult == 0 {
                // Item exists locally
                let isDirectory = (statInfo.st_mode & S_IFMT) == S_IFDIR
                let fileSize = Int64(statInfo.st_size)

                if isDirectory {
                    results.append((itemURL, relPath, true, false, 0))
                } else {
                    // File exists locally - check if it's a placeholder (size 0 in CloudStorage)
                    let isCloudOnly = (isInCloudStorage && fileSize == 0)
                    results.append((itemURL, relPath, false, isCloudOnly, fileSize))
                }
            } else {
                // Item listed but stat failed - likely cloud-only (not downloaded)
                // Use extension heuristic to determine if directory or file
                let pathExtension = (itemName as NSString).pathExtension
                let isLikelyDirectory = pathExtension.isEmpty

                if isLikelyDirectory {
                    results.append((itemURL, relPath, true, true, 0))
                } else {
                    results.append((itemURL, relPath, false, true, 0))
                }
            }
        }

        return results
    }

    /// Recursively scan a directory for all files (not directories).
    /// Uses recursive directory listing for better CloudStorage compatibility.
    private func scanDirectory(_ url: URL, excludingPrefix: String) throws -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        var directoriesScanned = 0

        // Verify the directory exists
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            logService.log(.warning, category: .backup, message: "Not a directory: \(url.path)")
            return []
        }

        // Use recursive helper function (more reliable for CloudStorage than enumerator)
        func scanRecursively(directory: URL, relativeTo baseURL: URL) {
            guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else {
                return
            }

            for itemName in contents {
                // Skip system files and snapshot history
                if itemName == ".DS_Store" || itemName == ".localized" || itemName == ".Spotlight-V100" || itemName == ".Trashes" || itemName == ".fseventsd" || itemName == ".Trash" || itemName == ".history" {
                    continue
                }

                let itemURL = directory.appendingPathComponent(itemName)
                let relPath = relativePath(from: baseURL, to: itemURL)

                // Skip excluded prefix
                if relPath.hasPrefix(excludingPrefix) {
                    continue
                }

                var itemIsDir: ObjCBool = false
                if fm.fileExists(atPath: itemURL.path, isDirectory: &itemIsDir) {
                    if itemIsDir.boolValue {
                        directoriesScanned += 1
                        scanRecursively(directory: itemURL, relativeTo: baseURL)
                    } else {
                        files.append(itemURL)
                    }
                }
            }
        }

        scanRecursively(directory: url, relativeTo: url)

        logService.log(.debug, category: .backup, message: "Scanned \(url.path): \(directoriesScanned) directories, \(files.count) files")
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
    /// - Parameters:
    ///   - path: File path to check
    ///   - skipZeroByteFiles: If true, skips zero-byte files (default). Set to false for on-demand backup
    ///     since cloud-only files may appear as zero-byte placeholders.
    private func shouldSkipFile(_ path: String, skipZeroByteFiles: Bool = true) -> Bool {
        let fileName = (path as NSString).lastPathComponent

        for pattern in skipPatterns {
            if fileName.hasPrefix(pattern) || fileName.hasSuffix(pattern) || fileName.contains(pattern) {
                return true
            }
        }

        // Skip zero-byte files (likely incomplete downloads) - but not for on-demand backup
        if skipZeroByteFiles {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64,
               size == 0 {
                return true
            }
        }

        return false
    }

    /// Copy a file with retry logic for transient errors.
    private func copyFileWithRetry(from source: String, to destination: String, keepVersions: Bool, backupRoot: String) async throws {
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
                    // Brief async delay before retry (doesn't block thread)
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
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
