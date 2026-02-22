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
    var version: Int = 2
    let sourcePath: String
    let scanDate: Date
    let files: [CachedFileInfo]
    let directories: [String]
    let directoryModTimes: [String: TimeInterval]?  // relPath → modTime (optional for compat)
    let totalScanned: Int
}

/// Cache of destination file sizes to speed up reconnection
struct DestinationCache: Codable {
    var version: Int = 2
    let destinationPath: String
    let scanDate: Date
    let fileSizes: [String: Int64]
    let fileModTimes: [String: TimeInterval]?  // Optional for backward compat

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
    private(set) var directoryModTimes: [String: TimeInterval] = [:]

    /// Destination data — set once via configure(), read many times without copying
    private var destFileSizes: [String: Int64] = [:]
    private var destModTimes: [String: TimeInterval] = [:]
    private var backupRoot: String = ""

    /// Map of relPath -> shouldOffload from previous cache.
    /// Used to preserve offload status for files that failed to evict.
    private var previousShouldOffload: [String: Bool] = [:]

    /// Configure destination data once (avoids copying large dicts on every call).
    func configure(destFileSizes: [String: Int64], destModTimes: [String: TimeInterval], backupRoot: String) {
        self.destFileSizes = destFileSizes
        self.destModTimes = destModTimes
        self.backupRoot = backupRoot
    }

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

    func addDirectoryModTime(relPath: String, modTime: TimeInterval) {
        directoryModTimes[relPath] = modTime
    }

    func getPlaceholderCount() -> Int {
        return placeholdersToCreate.count
    }

    /// Get all progress-related values in a single actor hop
    func getProgressSnapshot() -> (dirsScanned: Int, filesFound: Int, filesSkipped: Int) {
        return (directoriesScanned, totalFilesFound, filesSkipped)
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
        items: [(item: URL, relPath: String, isDir: Bool, isCloudOnly: Bool, localSize: Int64, modTime: TimeInterval)]
    ) {
        for item in items {
            if item.isDir {
                let destDirPath = (backupRoot as NSString).appendingPathComponent(item.relPath.sanitizedForExternalVolume())
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
                    modTime: Date(timeIntervalSince1970: item.modTime),
                    shouldOffload: shouldOffload
                ))

                // Determine if backup needed
                let sanitizedRelPath = item.relPath.sanitizedForExternalVolume()
                let destFilePath = (backupRoot as NSString).appendingPathComponent(sanitizedRelPath)
                let needsBackup: Bool
                if let existingSize = destFileSizes[sanitizedRelPath] {
                    if item.isCloudOnly {
                        needsBackup = existingSize == 0
                    } else if item.localSize != existingSize {
                        needsBackup = true
                    } else if let destMtime = destModTimes[sanitizedRelPath], item.modTime > destMtime + 1.0 {
                        needsBackup = true  // Same size but source is newer
                    } else {
                        needsBackup = false
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
        items: [(item: URL, relPath: String, isDir: Bool, isCloudOnly: Bool, localSize: Int64, modTime: TimeInterval)]
    ) -> [(sourceURL: URL, destPath: String, relPath: String)] {
        var localFilesForCopy: [(sourceURL: URL, destPath: String, relPath: String)] = []

        for item in items {
            if item.isDir {
                let destDirPath = (backupRoot as NSString).appendingPathComponent(item.relPath.sanitizedForExternalVolume())
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
                    modTime: Date(timeIntervalSince1970: item.modTime),
                    shouldOffload: shouldOffload
                ))

                // Determine if backup needed — compare size first, then modTime
                let sanitizedRelPath = item.relPath.sanitizedForExternalVolume()
                let destFilePath = (backupRoot as NSString).appendingPathComponent(sanitizedRelPath)
                let needsBackup: Bool
                if let existingSize = destFileSizes[sanitizedRelPath] {
                    if item.isCloudOnly {
                        needsBackup = existingSize == 0
                    } else if item.localSize != existingSize {
                        needsBackup = true
                    } else if let destMtime = destModTimes[sanitizedRelPath], item.modTime > destMtime + 1.0 {
                        needsBackup = true  // Same size but source is newer
                    } else {
                        needsBackup = false
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

    func getStats() -> (queued: Int, processed: Int, currentFile: String?) {
        return (filesQueued, filesProcessed, currentRelPath)
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

/// Thread-safe tracker for Phase 1 concurrent download+copy+evict operations
private actor Phase1Tracker {
    private(set) var filesUpdated = 0
    private(set) var filesDownloaded = 0
    private(set) var filesOffloaded = 0
    private(set) var cloudCompleted = 0
    private(set) var errors: [String] = []
    private(set) var evictedFiles = Set<String>()

    func recordUpdated() { filesUpdated += 1 }
    func recordDownloaded() { filesDownloaded += 1 }
    func recordOffloaded() { filesOffloaded += 1 }
    func recordCompleted() { cloudCompleted += 1 }
    func recordError(_ msg: String) { errors.append(msg) }
    func recordEvicted(_ relPath: String) {
        evictedFiles.insert(relPath)
        filesOffloaded += 1
    }
    func getCompleted() -> Int { cloudCompleted }
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
    private let maxConcurrentOperations = 4

    /// Concurrency limit for parallel cloud file downloads in Phase 1
    private let maxConcurrentDownloads = 4

    /// Concurrency limit for parallel directory scanning
    private let maxConcurrentScans = 4

    /// Files to skip during backup - organized for O(1) lookups where possible
    private let skipExactNames: Set<String> = [
        ".DS_Store", "Thumbs.db", "desktop.ini", ".localized",
        ".Spotlight-V100", ".Trashes", ".fseventsd"
    ]
    private let skipSuffixes: [String] = [".tmp", ".partial", ".download", ".crdownload", ".swp", ".swo"]
    private let skipPrefixes: [String] = ["~$", ".~lock."]

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

            // Reject old cache versions that lack directoryModTimes
            guard cache.version >= 2 else {
                logService.log(.info, category: .backup,
                               message: "Cache version \(cache.version) too old, will rescan")
                return nil
            }

            logService.log(.info, category: .backup,
                           message: "Loaded structure cache: \(cache.files.count) files, \(cache.directories.count) dirs (age: \(Int(Date().timeIntervalSince(cache.scanDate)))s)")
            return cache
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
    private func saveCache(backupRoot: String, sourcePath: String, files: [CachedFileInfo], directories: [String], directoryModTimes: [String: TimeInterval] = [:]) {
        let cache = FileStructureCache(
            sourcePath: sourcePath,
            scanDate: Date(),
            files: files,
            directories: directories,
            directoryModTimes: directoryModTimes,
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
    private func saveDestCache(backupRoot: String, fileSizes: [String: Int64], modTimes: [String: TimeInterval] = [:]) {
        let cache = DestinationCache(
            destinationPath: backupRoot,
            scanDate: Date(),
            fileSizes: fileSizes,
            fileModTimes: modTimes.isEmpty ? nil : modTimes
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
    private func scanDestinationSizes(destURL: URL) -> (sizes: [String: Int64], modTimes: [String: TimeInterval]) {
        let fm = FileManager.default
        let basePath = destURL.path
        let basePathCount = basePath.count

        // Recursive scan using stat() - collects results into flat array (no merging)
        func scanDir(_ dirPath: String, into results: inout [(String, Int64, TimeInterval)]) {
            guard let items = try? fm.contentsOfDirectory(atPath: dirPath) else { return }

            for itemName in items {
                // Skip hidden files and system files
                if itemName.hasPrefix(".") { continue }
                if itemName == "_versions" { continue }

                let itemPath = (dirPath as NSString).appendingPathComponent(itemName)

                var statInfo = stat()
                guard stat(itemPath, &statInfo) == 0 else { continue }

                let isDirectory = (statInfo.st_mode & S_IFMT) == S_IFDIR
                if isDirectory {
                    // Recurse into subdirectory
                    scanDir(itemPath, into: &results)
                } else {
                    // Compute relative path and add to results
                    var relPath = String(itemPath.dropFirst(basePathCount))
                    if relPath.hasPrefix("/") { relPath = String(relPath.dropFirst()) }
                    let mtime = TimeInterval(statInfo.st_mtimespec.tv_sec) + TimeInterval(statInfo.st_mtimespec.tv_nsec) / 1_000_000_000
                    results.append((relPath, Int64(statInfo.st_size), mtime))
                }
            }
        }

        // Start scan - use DispatchQueue for parallelism on top-level dirs
        guard let topItems = try? fm.contentsOfDirectory(atPath: basePath) else { return ([:], [:]) }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.neutrony.destScan", attributes: .concurrent)

        // Collect worker results - each worker builds its own array, lock only at end
        var allResults: [[(String, Int64, TimeInterval)]] = []
        let resultsLock = NSLock()

        var topLevelFiles: [(String, Int64, TimeInterval)] = []

        for itemName in topItems {
            if itemName.hasPrefix(".") || itemName == "_versions" { continue }

            let itemPath = (basePath as NSString).appendingPathComponent(itemName)
            var statInfo = stat()
            guard stat(itemPath, &statInfo) == 0 else { continue }

            let isDirectory = (statInfo.st_mode & S_IFMT) == S_IFDIR
            if isDirectory {
                group.enter()
                queue.async {
                    var workerResults: [(String, Int64, TimeInterval)] = []
                    scanDir(itemPath, into: &workerResults)
                    resultsLock.lock()
                    allResults.append(workerResults)
                    resultsLock.unlock()
                    group.leave()
                }
            } else {
                var relPath = String(itemPath.dropFirst(basePathCount))
                if relPath.hasPrefix("/") { relPath = String(relPath.dropFirst()) }
                let mtime = TimeInterval(statInfo.st_mtimespec.tv_sec) + TimeInterval(statInfo.st_mtimespec.tv_nsec) / 1_000_000_000
                topLevelFiles.append((relPath, Int64(statInfo.st_size), mtime))
            }
        }

        group.wait()

        // Build dictionaries from flat arrays
        let totalCount = topLevelFiles.count + allResults.reduce(0) { $0 + $1.count }
        var finalSizes: [String: Int64] = [:]
        var finalModTimes: [String: TimeInterval] = [:]
        finalSizes.reserveCapacity(totalCount)
        finalModTimes.reserveCapacity(totalCount)

        for (path, size, mtime) in topLevelFiles {
            finalSizes[path] = size
            finalModTimes[path] = mtime
        }
        for workerResult in allResults {
            for (path, size, mtime) in workerResult {
                finalSizes[path] = size
                finalModTimes[path] = mtime
            }
        }

        return (finalSizes, finalModTimes)
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

        // Build relative path sets (sanitize source paths to match destination filesystem names)
        let sourceRelative = Set(sourceFiles.map { relativePath(from: sourceURL, to: $0).sanitizedForExternalVolume() })
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

            let destFilePath = (backupRoot as NSString).appendingPathComponent(relPath.sanitizedForExternalVolume())

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
                filesDownloaded: 0, filesOffloaded: 0,
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
                let destPath = (backupRoot as NSString).appendingPathComponent(relPath.sanitizedForExternalVolume())
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
                currentFileName: "🗑 \(relPath)"
            )
            progressHandler(currentProgress)

            do {
                let destPath = (backupRoot as NSString).appendingPathComponent(relPath.sanitizedForExternalVolume())
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
            filesDownloaded: 0,
            filesOffloaded: 0,
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

        // Build relative path sets (sanitize source paths to match destination filesystem names)
        let sourceRelative = Set(sourceFiles.map { relativePath(from: sourceURL, to: $0).sanitizedForExternalVolume() })
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

            let destFilePath = (backupRoot as NSString).appendingPathComponent(relPath.sanitizedForExternalVolume())

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
                filesDownloaded: 0, filesOffloaded: 0,
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
                let destPath = (backupRoot as NSString).appendingPathComponent(relPath.sanitizedForExternalVolume())
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
                let destPath = (backupRoot as NSString).appendingPathComponent(relPath.sanitizedForExternalVolume())
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
            filesDownloaded: 0,
            filesOffloaded: 0,
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
        var destModTimes: [String: TimeInterval]
        if let destCache = loadDestCache(backupRoot: backupRoot) {
            destFileSizes = destCache.fileSizes
            destModTimes = destCache.fileModTimes ?? [:]
            logService.log(.info, category: .backup,
                           message: "Using cached destination: \(destFileSizes.count) files (instant)")
        } else {
            logService.log(.info, category: .backup, message: "Scanning destination with stat()...")
            let destScan = scanDestinationSizes(destURL: destURL)
            destFileSizes = destScan.sizes
            destModTimes = destScan.modTimes
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
                       message: "========== PHASE 0 START ==========")

        var localFilesToBackup: [(url: URL, relPath: String)] = []
        var cloudOnlyFilesToBackup: [(url: URL, relPath: String, cloudSize: Int64?)] = []
        var foldersAlreadyCreated: Set<String> = []  // Track folders created for dedup
        var totalFilesFound = 0
        var cachedFileInfos: [CachedFileInfo] = []  // For saving to cache
        var cachedDirectories: [String] = []  // For saving to cache
        var cachedDirModTimes: [String: TimeInterval] = [:]  // For incremental scan
        var usedCache = false

        // Try to load cached structure for faster startup
        if let cache = loadCache(backupRoot: backupRoot, sourcePath: sourcePath) {
            usedCache = true
            let incrementalStart = Date()

            // Immediately show progress so UI doesn't appear frozen
            progressHandler(BackupProgress(
                totalFiles: 0, completedFiles: 0,
                currentFileName: "Checking for changes…"
            ))
            await Task.yield()

            // Build shouldOffload map and group files by directory in a single pass
            var previousShouldOffload: [String: Bool] = [:]
            var filesByDir: [String: [CachedFileInfo]] = [:]
            for (i, file) in cache.files.enumerated() {
                previousShouldOffload[file.relPath] = file.shouldOffload
                let parentDir = (file.relPath as NSString).deletingLastPathComponent
                filesByDir[parentDir, default: []].append(file)
                if i % 5000 == 0 { await Task.yield() }
            }

            // Check which directories changed by comparing modTimes
            let cachedDirModTimesMap = cache.directoryModTimes ?? [:]
            var changedDirs: Set<String> = []
            var newDirModTimes: [String: TimeInterval] = [:]
            var deletedDirs: Set<String> = []

            // Build set of all known directory relPaths (including root "")
            var knownDirs = Set(cache.directories)
            knownDirs.insert("")  // root is always known

            // Check root directory modTime
            var rootStatInfo = stat()
            if stat(sourcePath, &rootStatInfo) == 0 {
                let rootModTime = TimeInterval(rootStatInfo.st_mtimespec.tv_sec) + TimeInterval(rootStatInfo.st_mtimespec.tv_nsec) / 1_000_000_000
                newDirModTimes[""] = rootModTime
                if let cachedMtime = cachedDirModTimesMap[""], rootModTime == cachedMtime {
                    // Root unchanged
                } else {
                    changedDirs.insert("")
                }
            }

            // Check each cached subdirectory
            for (i, dirRelPath) in cache.directories.enumerated() {
                let fullPath = (sourcePath as NSString).appendingPathComponent(dirRelPath)
                var dirStatInfo = stat()
                if stat(fullPath, &dirStatInfo) == 0 {
                    let currentModTime = TimeInterval(dirStatInfo.st_mtimespec.tv_sec) + TimeInterval(dirStatInfo.st_mtimespec.tv_nsec) / 1_000_000_000
                    newDirModTimes[dirRelPath] = currentModTime
                    if let cachedMtime = cachedDirModTimesMap[dirRelPath], currentModTime == cachedMtime {
                        // Unchanged
                    } else {
                        changedDirs.insert(dirRelPath)
                    }
                } else {
                    deletedDirs.insert(dirRelPath)
                }
                if i % 200 == 0 { await Task.yield() }
            }

            logService.log(.info, category: .backup,
                           message: "Incremental scan: \(changedDirs.count) dirs changed, \(deletedDirs.count) deleted out of \(knownDirs.count) total")

            // Rescan changed directories and discover new ones
            var dirsToScan: [String] = Array(changedDirs)
            var freshFilesByDir: [String: [CachedFileInfo]] = [:]

            while !dirsToScan.isEmpty {
                let dirRelPath = dirsToScan.removeFirst()
                let dirURL: URL
                if dirRelPath.isEmpty {
                    dirURL = sourceURL
                } else {
                    dirURL = URL(fileURLWithPath: (sourcePath as NSString).appendingPathComponent(dirRelPath))
                }

                if let items = scanDirectoryContents(directory: dirURL, sourceURL: sourceURL, backupRoot: backupRoot) {
                    var freshFiles: [CachedFileInfo] = []
                    for item in items {
                        if item.isDir {
                            // Discover new subdirectories not in cache
                            if !knownDirs.contains(item.relPath) && !deletedDirs.contains(item.relPath) {
                                knownDirs.insert(item.relPath)
                                dirsToScan.append(item.relPath)
                                // Stat new dir for its modTime
                                var newDirStat = stat()
                                if stat(item.item.path, &newDirStat) == 0 {
                                    let dirMtime = TimeInterval(newDirStat.st_mtimespec.tv_sec) + TimeInterval(newDirStat.st_mtimespec.tv_nsec) / 1_000_000_000
                                    newDirModTimes[item.relPath] = dirMtime
                                }
                            }
                        } else {
                            let shouldOffload = item.isCloudOnly || (previousShouldOffload[item.relPath] ?? false)
                            freshFiles.append(CachedFileInfo(
                                relPath: item.relPath,
                                isDirectory: false,
                                isCloudOnly: item.isCloudOnly,
                                size: item.localSize,
                                modTime: Date(timeIntervalSince1970: item.modTime),
                                shouldOffload: shouldOffload
                            ))
                        }
                    }
                    freshFilesByDir[dirRelPath] = freshFiles
                }
            }

            // Build merged file list and directory list
            var mergedFiles: [CachedFileInfo] = []
            var mergedDirs: [String] = []

            // Handle root files
            if changedDirs.contains("") {
                if let freshFiles = freshFilesByDir[""] { mergedFiles.append(contentsOf: freshFiles) }
            } else {
                if let cachedFiles = filesByDir[""] { mergedFiles.append(contentsOf: cachedFiles) }
            }

            // Handle cached subdirectories
            for dirRelPath in cache.directories {
                if deletedDirs.contains(dirRelPath) { continue }
                mergedDirs.append(dirRelPath)
                if changedDirs.contains(dirRelPath) {
                    if let freshFiles = freshFilesByDir[dirRelPath] { mergedFiles.append(contentsOf: freshFiles) }
                } else {
                    if let cachedFiles = filesByDir[dirRelPath] { mergedFiles.append(contentsOf: cachedFiles) }
                }
            }

            // Add newly discovered directories and their files
            for dirRelPath in knownDirs {
                if dirRelPath.isEmpty || cache.directories.contains(dirRelPath) || deletedDirs.contains(dirRelPath) { continue }
                mergedDirs.append(dirRelPath)
                if let freshFiles = freshFilesByDir[dirRelPath] { mergedFiles.append(contentsOf: freshFiles) }
            }

            // Update outer-scope cache data
            cachedFileInfos = mergedFiles
            cachedDirectories = mergedDirs
            cachedDirModTimes = newDirModTimes

            // Create all directories at destination
            for dirPath in mergedDirs {
                let destDirPath = (backupRoot as NSString).appendingPathComponent(dirPath.sanitizedForExternalVolume())
                if !foldersAlreadyCreated.contains(destDirPath) {
                    try? fm.createDirectory(atPath: destDirPath, withIntermediateDirectories: true, attributes: nil)
                    foldersAlreadyCreated.insert(destDirPath)
                    foldersCreated += 1
                }
            }

            // Process all merged files — determine which need backup
            for fileInfo in mergedFiles {
                let sanitizedRelPath = fileInfo.relPath.sanitizedForExternalVolume()
                let destFilePath = (backupRoot as NSString).appendingPathComponent(sanitizedRelPath)
                let fileURL = sourceURL.appendingPathComponent(fileInfo.relPath)

                let needsBackup: Bool
                if let existingSize = destFileSizes[sanitizedRelPath] {
                    if fileInfo.isCloudOnly {
                        needsBackup = existingSize == 0
                    } else if fileInfo.size != existingSize {
                        needsBackup = true
                    } else if let cachedModTime = fileInfo.modTime,
                              let destMtime = destModTimes[sanitizedRelPath],
                              cachedModTime.timeIntervalSince1970 > destMtime + 1.0 {
                        needsBackup = true  // Same size but source is newer
                    } else {
                        needsBackup = false
                    }
                } else {
                    needsBackup = true
                }

                if needsBackup {
                    if !fm.fileExists(atPath: destFilePath) {
                        let destParent = (destFilePath as NSString).deletingLastPathComponent
                        if !foldersAlreadyCreated.contains(destParent) {
                            try? fm.createDirectory(atPath: destParent, withIntermediateDirectories: true)
                            foldersAlreadyCreated.insert(destParent)
                        }
                        fm.createFile(atPath: destFilePath, contents: nil, attributes: nil)
                        placeholdersCreated += 1
                    }

                    if fileInfo.isCloudOnly {
                        cloudOnlyFilesToBackup.append((fileURL, fileInfo.relPath, nil))
                    } else {
                        localFilesToBackup.append((fileURL, fileInfo.relPath))
                    }
                    totalFilesFound += 1
                } else {
                    filesSkipped += 1
                }

                if (totalFilesFound + filesSkipped) % 1000 == 0 {
                    await Task.yield()
                    let progress = BackupProgress(
                        totalFiles: mergedFiles.count,
                        completedFiles: totalFilesFound + filesSkipped,
                        currentFileName: "Checking for changes…"
                    )
                    progressHandler(progress)
                }
            }

            let incrementalDuration = Date().timeIntervalSince(incrementalStart)
            logService.log(.info, category: .backup,
                           message: "Incremental scan complete in \(String(format: "%.2f", incrementalDuration))s: \(changedDirs.count) dirs rescanned, \(totalFilesFound) to backup, \(filesSkipped) skipped")

            // Save updated cache with fresh directory modTimes
            saveCache(backupRoot: backupRoot, sourcePath: sourcePath, files: cachedFileInfos, directories: cachedDirectories, directoryModTimes: cachedDirModTimes)
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

            // Configure destination data once to avoid copying large dicts on every actor call
            await collector.configure(destFileSizes: destFileSizes, destModTimes: destModTimes, backupRoot: backupRoot)

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

                            // Run synchronous directory scan on a non-cooperative thread
                            // to avoid blocking the Swift concurrency thread pool if the
                            // file provider (Proton Drive / iCloud) stalls on I/O
                            let items = await withCheckedContinuation { continuation in
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let result = self.scanDirectoryContents(directory: directory, sourceURL: sourceURL, backupRoot: backupRoot)
                                    continuation.resume(returning: result)
                                }
                            }
                            if let items {
                                var subdirs: [URL] = []
                                for item in items {
                                    if item.isDir {
                                        subdirs.append(item.item)
                                    }
                                }

                                if !subdirs.isEmpty {
                                    await dirQueue.addDirectories(subdirs)
                                }

                                // Record directory's own modTime for incremental scanning
                                var dirStatInfo = stat()
                                if stat(directory.path, &dirStatInfo) == 0 {
                                    let dirModTime = TimeInterval(dirStatInfo.st_mtimespec.tv_sec) + TimeInterval(dirStatInfo.st_mtimespec.tv_nsec) / 1_000_000_000
                                    let dirRelPath = self.relativePath(from: sourceURL, to: directory)
                                    await collector.addDirectoryModTime(relPath: dirRelPath, modTime: dirModTime)
                                }

                                // Use the new method that returns local files for immediate copying
                                let localFilesForCopy = await collector.addBatchResultsWithCopyQueue(
                                    items: items
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
                            await Task.yield()  // Prevent thread pool starvation
                        }
                    }
                }

                // File copy workers - start copying immediately as files are discovered
                for _ in 0..<maxConcurrentOperations {
                    group.addTask { [self] in
                        while true {
                            // Try to get a file to copy
                            guard let file = await copyQueue.dequeue() else {
                                // No files in queue - exit if scan is done (no more will come)
                                if !(await dirQueue.hasWork()) {
                                    break
                                }
                                try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                                continue
                            }

                            // Ensure parent directory exists (check actor, create outside)
                            if let parentPath = await tracker.parentFolderIfNeeded(file.destPath) {
                                try? fm.createDirectory(atPath: parentPath, withIntermediateDirectories: true, attributes: nil)
                                await tracker.recordParentEnsured(parentPath)
                            }

                            // Re-check file status before copying (status may have changed since scan)
                            // Use stat() + st_blocks to detect cloud-only (Proton Drive reports cloud size via st_size)
                            var recheckStat = stat()
                            let recheckResult = stat(file.sourceURL.path, &recheckStat)
                            let recheckBlocks = (recheckResult == 0) ? recheckStat.st_blocks : 0
                            let recheckSize = (recheckResult == 0) ? Int64(recheckStat.st_size) : 0
                            let isNowCloudOnly = (recheckSize == 0 || recheckBlocks == 0)

                            if isNowCloudOnly {
                                // File is now cloud-only - skip, will be handled in Phase 1
                                logService.log(.debug, category: .backup,
                                               message: "[Phase0] Skipping \(file.relPath) - cloud-only (size=\(recheckSize) blocks=\(recheckBlocks))")
                                await copyQueue.incrementProcessed()
                                continue
                            }

                            // Mark file as syncing
                            badgeService.markFileSyncing(relativePath: file.relPath)

                            do {
                                try await copyFileWithRetry(from: file.sourceURL.path, to: file.destPath, keepVersions: keepVersions, backupRoot: backupRoot)
                                await tracker.recordFileUpdated()
                                badgeService.markFileComplete(relativePath: file.relPath)
                                logService.log(.debug, category: .backup,
                                               message: "[Phase0] Copied local file: \(file.relPath)")
                            } catch {
                                let desc = "[Phase0] Failed to backup \(file.relPath): \(error.localizedDescription)"
                                await tracker.recordError(desc)
                                logService.log(.error, category: .backup, message: desc, filePath: file.relPath)
                                badgeService.markFileError(relativePath: file.relPath)
                            }

                            await copyQueue.incrementProcessed()
                            await Task.yield()  // Prevent thread pool starvation
                        }
                    }
                }

                // Progress update task — uses batched actor calls to minimize contention
                group.addTask { [self] in
                    var lastDirs = 0
                    var lastFound = 0
                    var lastCopied = 0
                    var unchangedCycles = 0
                    while true {
                        try? await Task.sleep(nanoseconds: 500_000_000) // Update every 500ms

                        // Batch actor calls: one hop each for collector, copyQueue, dirQueue
                        let snapshot = await collector.getProgressSnapshot()
                        let (queued, copied, currentFile) = await copyQueue.getStats()

                        // Exit when scan is done and all queued files are copied
                        let scanRunning = await dirQueue.hasWork()
                        if !scanRunning && queued == copied { break }

                        let elapsed = Date().timeIntervalSince(scanStartTime)
                        let scanRate = elapsed > 0 ? Double(snapshot.dirsScanned) / elapsed : 0

                        // Log when values change, or emit heartbeat every 10s if scan appears stuck
                        if snapshot.dirsScanned != lastDirs || snapshot.filesFound != lastFound || copied != lastCopied {
                            logService.log(.debug, category: .backup,
                                           message: "[Phase0] Scan+Copy: \(snapshot.dirsScanned) dirs (\(String(format: "%.0f", scanRate))/s), \(snapshot.filesFound) found, \(copied)/\(queued) copied")
                            lastDirs = snapshot.dirsScanned
                            lastFound = snapshot.filesFound
                            lastCopied = copied
                            unchangedCycles = 0
                        } else {
                            unchangedCycles += 1
                            if unchangedCycles % 20 == 0 { // Every ~10s of no change
                                let queueSize = await dirQueue.getQueueSize()
                                logService.log(.debug, category: .backup,
                                               message: "[Phase0] Heartbeat: \(snapshot.dirsScanned) dirs, \(snapshot.filesFound) found, \(copied)/\(queued) copied, dirQueue=\(queueSize) scanRunning=\(scanRunning)")
                            }
                        }

                        // Report the current file being copied (or scanning status if no file yet)
                        let totalScanned = snapshot.filesFound + snapshot.filesSkipped
                        let totalCompleted = copied + snapshot.filesSkipped

                        let displayName = currentFile ?? "Scanning files…"
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
            cachedDirModTimes = await collector.directoryModTimes

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
                           message: "[Phase0] Scan+Copy complete: \(dirsScanned) dirs, \(totalFilesFound) files, \(copiedDuringScan) copied in \(String(format: "%.1f", scanDuration))s")

            // Save the structure cache for faster subsequent backups
            saveCache(backupRoot: backupRoot, sourcePath: sourcePath, files: cachedFileInfos, directories: cachedDirectories, directoryModTimes: cachedDirModTimes)
        }

        logService.log(.info, category: .backup,
                       message: "[Phase0] Complete: \(foldersCreated) folders, \(filesUpdated) local files copied")

        logService.log(.info, category: .backup,
                       message: "[Phase0] Remaining for Phase1: \(cloudOnlyFilesToBackup.count) cloud-only files")

        // Calculate files to delete — all source files (cached or scanned) vs destination
        // Sanitize source paths to match destination keys (which use sanitized names on disk)
        let sourceRelative = Set(cachedFileInfos.map { $0.relPath.sanitizedForExternalVolume() })
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
                filesDownloaded: 0, filesOffloaded: 0,
                errors: [], startTime: startTime, endTime: Date()
            )
        }

        // ============================================
        // PHASE 1: Download cloud-only files (this is when downloads start)
        // Local files were already copied during the scan phase
        // Downloads run in parallel (up to maxConcurrentDownloads) for throughput
        // ============================================
        // Track successfully evicted files to update cache
        var evictedFiles = Set<String>()

        logService.log(.info, category: .backup,
                       message: "========== PHASE 1 START ==========")
        logService.log(.info, category: .backup,
                       message: "[Phase1] \(cloudOnlyFilesToBackup.count) cloud-only files, offloadAfterBackup=\(offloadAfterBackup), concurrency=\(maxConcurrentDownloads)")

        // Log first few files for debugging
        if !cloudOnlyFilesToBackup.isEmpty {
            let sampleFiles = cloudOnlyFilesToBackup.prefix(5).map { $0.relPath }
            logService.log(.info, category: .backup,
                           message: "[Phase1] Sample files: \(sampleFiles.joined(separator: ", "))")
            logService.log(.info, category: .backup,
                           message: "[Phase1] Downloading \(cloudOnlyFilesToBackup.count) cloud-only files...")

            let phase1 = Phase1Tracker()
            let phase1StartTime = Date()

            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0

                for (fileURL, relPath, _) in cloudOnlyFilesToBackup {
                    // Check for pause before launching new downloads
                    while pauseChecker?() == true {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }

                    // Limit concurrency — wait for one task to finish before spawning another
                    if inFlight >= maxConcurrentDownloads {
                        await group.next()
                        inFlight -= 1
                    }

                    inFlight += 1
                    group.addTask { [self] in
                        let completed = await phase1.getCompleted()
                        let currentProgress = BackupProgress(
                            totalFiles: totalAllFiles,
                            completedFiles: baseCompleted + completed,
                            currentFileName: "⬇ \(relPath)",
                            currentFileProgress: 0.0
                        )
                        progressHandler(currentProgress)

                        // Mark file as downloading in Finder
                        badgeService.markFileDownloading(relativePath: relPath)

                        do {
                            let destPath = (backupRoot as NSString).appendingPathComponent(relPath.sanitizedForExternalVolume())

                            // Re-check file status before downloading (status may have changed since scan)
                            var p1StatInfo = stat()
                            let p1StatResult = stat(fileURL.path, &p1StatInfo)
                            let currentSize: Int64 = (p1StatResult == 0) ? Int64(p1StatInfo.st_size) : 0
                            let currentBlocks = (p1StatResult == 0) ? p1StatInfo.st_blocks : 0
                            let needsDownload = (currentSize == 0 || currentBlocks == 0)

                            logService.log(.info, category: .backup,
                                           message: "[Phase1] CHECK: \(relPath) size=\(currentSize) blocks=\(currentBlocks) needsDownload=\(needsDownload)")

                            var weDownloadedIt = false

                            if needsDownload {
                                logService.log(.info, category: .backup, message: "[Phase1] DOWNLOADING: \(relPath)")
                                let downloaded = await syncVerifier.requestDownloadAndWait(at: fileURL.path, timeout: 120) { dlProgress in
                                    let dlUpdate = BackupProgress(
                                        totalFiles: totalAllFiles,
                                        completedFiles: baseCompleted + completed,
                                        currentFileName: "⬇ \(relPath)",
                                        currentFileProgress: dlProgress
                                    )
                                    progressHandler(dlUpdate)
                                }

                                if !downloaded {
                                    await phase1.recordError("[Phase1] Download timeout: \(relPath) (placeholder kept)")
                                    logService.log(.warning, category: .backup, message: "[Phase1] Download timeout: \(relPath)")
                                    badgeService.markFileError(relativePath: relPath)
                                    await phase1.recordCompleted()
                                    return
                                }
                                await phase1.recordDownloaded()
                                weDownloadedIt = true
                                logService.log(.info, category: .backup, message: "[Phase1] DOWNLOADED: \(relPath) weDownloadedIt=TRUE")
                            } else {
                                logService.log(.info, category: .backup, message: "[Phase1] SKIP_DOWNLOAD: \(relPath) size=\(currentSize) weDownloadedIt=FALSE")
                            }

                            badgeService.markFileSyncing(relativePath: relPath)

                            try await copyFileWithRetry(from: fileURL.path, to: destPath, keepVersions: false, backupRoot: backupRoot)
                            await phase1.recordUpdated()
                            badgeService.markFileComplete(relativePath: relPath)

                            logService.log(.info, category: .backup,
                                           message: "[Phase1] OFFLOAD_CHECK: \(relPath) offloadAfterBackup=\(offloadAfterBackup) weDownloadedIt=\(weDownloadedIt)")

                            if offloadAfterBackup && weDownloadedIt {
                                logService.log(.info, category: .backup, message: "[Phase1] EVICTING: \(relPath)")
                                if await syncVerifier.evictFileWithRetry(at: fileURL.path) {
                                    await phase1.recordEvicted(relPath)
                                    logService.log(.info, category: .backup, message: "[Phase1] EVICTED_OK: \(relPath)")
                                } else {
                                    logService.log(.warning, category: .backup, message: "[Phase1] EVICT_FAILED: \(relPath)")
                                }
                            } else if !offloadAfterBackup {
                                logService.log(.info, category: .backup, message: "[Phase1] NO_OFFLOAD: \(relPath) (offloadAfterBackup is disabled)")
                            } else if !weDownloadedIt {
                                logService.log(.info, category: .backup, message: "[Phase1] NO_OFFLOAD: \(relPath) (we didn't download it)")
                            }

                        } catch {
                            let desc = "[Phase1] Failed to backup \(relPath): \(error.localizedDescription)"
                            await phase1.recordError(desc)
                            logService.log(.error, category: .backup, message: desc, filePath: relPath)
                            badgeService.markFileError(relativePath: relPath)
                        }

                        await phase1.recordCompleted()
                    }
                }
            }

            // Merge Phase 1 results back into local variables
            filesUpdated += await phase1.filesUpdated
            filesDownloaded += await phase1.filesDownloaded
            filesOffloaded += await phase1.filesOffloaded
            cloudCompleted = await phase1.cloudCompleted
            errors.append(contentsOf: await phase1.errors)
            evictedFiles = await phase1.evictedFiles

            let phase1Duration = Date().timeIntervalSince(phase1StartTime)
            let filesPerSec = phase1Duration > 0 ? Double(cloudCompleted) / phase1Duration : 0
            logService.log(.info, category: .backup,
                           message: "[Phase1] Complete: \(filesDownloaded) downloaded, \(filesOffloaded) offloaded in \(String(format: "%.1f", phase1Duration))s (\(String(format: "%.1f", filesPerSec)) files/s)")
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
                               message: "[Retry] Retrying eviction for \(filesToRetryEviction.count) files from previous backup...")

                for fileInfo in filesToRetryEviction {
                    // Update progress to show offloading status
                    let offloadProgress = BackupProgress(
                        totalFiles: totalAllFiles,
                        completedFiles: baseCompleted + cloudCompleted,
                        currentFileName: "⬆ \(fileInfo.relPath)"
                    )
                    progressHandler(offloadProgress)

                    let fileURL = sourceURL.appendingPathComponent(fileInfo.relPath)
                    if await syncVerifier.evictFileWithRetry(at: fileURL.path) {
                        filesOffloaded += 1
                        evictedFiles.insert(fileInfo.relPath)
                        logService.log(.info, category: .backup,
                                       message: "[Retry] EVICTED_OK: \(fileInfo.relPath)")

                        // Update progress to show offloaded status
                        let offloadedProgress = BackupProgress(
                            totalFiles: totalAllFiles,
                            completedFiles: baseCompleted + cloudCompleted,
                            currentFileName: "☁ \(fileInfo.relPath)"
                        )
                        progressHandler(offloadedProgress)
                    }
                }

                if !evictedFiles.isEmpty {
                    logService.log(.info, category: .backup,
                                   message: "[Retry] Complete: \(evictedFiles.count) files offloaded")
                }
            }
        }

        // ============================================
        // PHASE 2: Handle deletions
        // ============================================
        if !filesToDelete.isEmpty {
            logService.log(.info, category: .backup,
                           message: "========== PHASE 2 START ==========")
            logService.log(.info, category: .backup,
                           message: "[Phase2] Processing \(filesToDelete.count) deletions...")

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
                    let destPath = (backupRoot as NSString).appendingPathComponent(relPath.sanitizedForExternalVolume())
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
            filesDownloaded: filesDownloaded,
            filesOffloaded: filesOffloaded,
            errors: errors,
            startTime: startTime,
            endTime: Date()
        )

        logService.log(.info, category: .backup,
                       message: "On-demand backup complete: \(summary.displayText)")

        // Save updated destination cache for fast reconnection
        // After backup, update dest sizes and modTimes based on what we know changed
        var updatedDestSizes = destFileSizes
        var updatedDestModTimes = destModTimes
        // Update local files that were copied during scan
        for fileInfo in cachedFileInfos where !fileInfo.isCloudOnly {
            let sanitizedRelPath = fileInfo.relPath.sanitizedForExternalVolume()
            if updatedDestSizes[sanitizedRelPath] != fileInfo.size {
                updatedDestSizes[sanitizedRelPath] = fileInfo.size
            }
            // After copy, dest modTime matches source modTime (copyItem preserves it)
            if let modTime = fileInfo.modTime {
                updatedDestModTimes[sanitizedRelPath] = modTime.timeIntervalSince1970
            }
        }
        // Update cloud files that were downloaded
        for (_, relPath, _) in cloudOnlyFilesToBackup {
            let sanitizedRelPath = relPath.sanitizedForExternalVolume()
            let destPath = (backupRoot as NSString).appendingPathComponent(sanitizedRelPath)
            var statInfo = stat()
            if stat(destPath, &statInfo) == 0 {
                updatedDestSizes[sanitizedRelPath] = Int64(statInfo.st_size)
                updatedDestModTimes[sanitizedRelPath] = TimeInterval(statInfo.st_mtimespec.tv_sec) + TimeInterval(statInfo.st_mtimespec.tv_nsec) / 1_000_000_000
            }
        }
        // Remove deleted files
        for relPath in filesToDelete {
            updatedDestSizes.removeValue(forKey: relPath)
            updatedDestModTimes.removeValue(forKey: relPath)
        }
        saveDestCache(backupRoot: backupRoot, fileSizes: updatedDestSizes, modTimes: updatedDestModTimes)

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
            saveCache(backupRoot: backupRoot, sourcePath: sourcePath, files: updatedCachedInfos, directories: cachedDirectories, directoryModTimes: cachedDirModTimes)
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

        // Build relative path sets (sanitize cloud paths to match destination filesystem names)
        let cloudRelative = Set(cloudFilesOnly.map { $0.path.sanitizedForExternalVolume() })
        let destRelative = Set(destFiles.map { relativePath(from: destURL, to: $0) })

        // Find files to copy (new or modified)
        var filesToProcess: [(cloudFile: RcloneFile, needsUpdate: Bool)] = []
        for cloudFile in cloudFilesOnly {
            let destFilePath = (backupRoot as NSString).appendingPathComponent(cloudFile.path.sanitizedForExternalVolume())

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
                filesDownloaded: 0, filesOffloaded: 0,
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
                let destPath = (backupRoot as NSString).appendingPathComponent(cloudFile.path.sanitizedForExternalVolume())

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
                currentFileName: "🗑 \(relPath)"
            )
            progressHandler(currentProgress)

            do {
                let destPath = (backupRoot as NSString).appendingPathComponent(relPath.sanitizedForExternalVolume())
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
            filesDownloaded: filesDownloaded,
            filesOffloaded: 0,
            errors: errors,
            startTime: startTime,
            endTime: Date()
        )

        logService.log(.info, category: .backup,
                       message: "Hybrid backup complete: \(summary.displayText)")
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
    ) -> [(item: URL, relPath: String, isDir: Bool, isCloudOnly: Bool, localSize: Int64, modTime: TimeInterval)]? {
        let fm = FileManager.default
        let dirPath = directory.path

        // Use simple path-based directory listing - faster and doesn't fetch cloud metadata
        guard let itemNames = try? fm.contentsOfDirectory(atPath: dirPath) else {
            return nil
        }

        var results: [(item: URL, relPath: String, isDir: Bool, isCloudOnly: Bool, localSize: Int64, modTime: TimeInterval)] = []
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

                let mtime = TimeInterval(statInfo.st_mtimespec.tv_sec) + TimeInterval(statInfo.st_mtimespec.tv_nsec) / 1_000_000_000

                if isDirectory {
                    results.append((itemURL, relPath, true, false, 0, mtime))
                } else {
                    // File exists locally - check if it's a cloud-only placeholder
                    // Proton Drive's FileProvider reports the cloud file size via st_size
                    // even for cloud-only files. We must check st_blocks (actual disk allocation)
                    // to detect if the file content is really local.
                    // st_blocks == 0 means no disk blocks allocated = cloud-only placeholder
                    let isCloudOnly = isInCloudStorage && (fileSize == 0 || statInfo.st_blocks == 0)
                    results.append((itemURL, relPath, false, isCloudOnly, fileSize, mtime))
                }
            } else {
                // Item listed but stat failed - likely cloud-only (not downloaded)
                // Use extension heuristic to determine if directory or file
                let pathExtension = (itemName as NSString).pathExtension
                let isLikelyDirectory = pathExtension.isEmpty

                if isLikelyDirectory {
                    results.append((itemURL, relPath, true, true, 0, 0))
                } else {
                    results.append((itemURL, relPath, false, true, 0, 0))
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

        // O(1) exact name check
        if skipExactNames.contains(fileName) { return true }

        // Check prefixes and suffixes (small arrays, fast iteration)
        for prefix in skipPrefixes {
            if fileName.hasPrefix(prefix) { return true }
        }
        for suffix in skipSuffixes {
            if fileName.hasSuffix(suffix) { return true }
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
