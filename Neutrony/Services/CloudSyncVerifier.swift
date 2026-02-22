import Foundation

/// Verifies that local Proton Drive files are synced with the cloud.
/// Uses macOS FileProvider APIs to check sync status without needing authentication.
/// The official Proton Drive app handles auth (including passkey), we just verify sync status.
final class CloudSyncVerifier {

    static let shared = CloudSyncVerifier()

    private let logService = LogService.shared
    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Sync Status

    /// Check if a file is fully synced with the cloud.
    /// Returns true if the file is downloaded and matches the cloud version.
    func isFileSynced(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)

        // Check if file exists
        guard fileManager.fileExists(atPath: path) else {
            return false
        }

        // Check FileProvider download status
        do {
            let resourceValues = try url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey,
                .ubiquitousItemUploadingErrorKey,
                .ubiquitousItemDownloadingErrorKey
            ])

            // Check for any errors
            if resourceValues.ubiquitousItemUploadingError != nil ||
               resourceValues.ubiquitousItemDownloadingError != nil {
                return false
            }

            // Check download status
            if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                switch downloadStatus {
                case .current:
                    return true  // Fully downloaded and up to date
                case .downloaded:
                    return true  // Downloaded (may need update check)
                case .notDownloaded:
                    return false // Not downloaded yet
                default:
                    return false
                }
            }

            // If no ubiquitous attributes, it might be a regular file (not cloud-managed)
            // In that case, check if it's a placeholder/stub file
            return !isPlaceholderFile(at: path)

        } catch {
            // If we can't get resource values, assume it's a local file
            return !isPlaceholderFile(at: path)
        }
    }

    /// Check if a file is a placeholder (not fully downloaded).
    /// Placeholder files typically have zero or very small size with special attributes.
    private func isPlaceholderFile(at path: String) -> Bool {
        // Use stat() + st_blocks for reliable detection
        // Proton Drive reports cloud size via st_size even for placeholders
        var statInfo = stat()
        if stat(path, &statInfo) == 0 {
            // No disk blocks allocated = placeholder
            if statInfo.st_blocks == 0 {
                return true
            }
            // Has disk blocks = real local file
            if statInfo.st_blocks > 0 && Int64(statInfo.st_size) > 0 {
                return false
            }
        }

        // Fallback: check FileProvider download status
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) {
            if values.isUbiquitousItem == true {
                if let downloadStatus = values.ubiquitousItemDownloadingStatus {
                    return downloadStatus == .notDownloaded
                }
            }
        }

        return false
    }

    /// Get the sync status of all files in a directory.
    /// Returns a dictionary mapping file paths to their sync status.
    func getSyncStatus(forDirectory path: String) -> [String: SyncStatus] {
        var statusMap: [String: SyncStatus] = [:]

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey
            ],
            options: []  // Don't skip hidden files
        ) else {
            return statusMap
        }

        for case let fileURL as URL in enumerator {
            // Skip system files
            let fileName = fileURL.lastPathComponent
            if fileName == ".DS_Store" || fileName == ".localized" {
                continue
            }

            // Check if it's a file (not directory)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir) && !isDir.boolValue {
                let status = getFileStatus(at: fileURL)
                statusMap[fileURL.path] = status
            }
        }

        return statusMap
    }

    /// Get detailed sync status for a single file.
    private func getFileStatus(at url: URL) -> SyncStatus {
        do {
            let values = try url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey,
                .ubiquitousItemIsUploadingKey,
                .fileSizeKey
            ])

            if values.ubiquitousItemIsDownloading == true {
                return .downloading
            }

            if values.ubiquitousItemIsUploading == true {
                return .uploading
            }

            if let downloadStatus = values.ubiquitousItemDownloadingStatus {
                switch downloadStatus {
                case .current:
                    return .synced
                case .downloaded:
                    return .synced
                case .notDownloaded:
                    return .cloudOnly
                default:
                    return .unknown
                }
            }

            // No ubiquitous attributes - check if it's a valid local file
            if let size = values.fileSize, size > 0 {
                return .localOnly
            }

            return .unknown

        } catch {
            return .unknown
        }
    }

    /// Request download of a cloud-only file.
    /// This triggers the Proton Drive app to download the file.
    func requestDownload(at path: String) throws {
        let url = URL(fileURLWithPath: path)

        do {
            try fileManager.startDownloadingUbiquitousItem(at: url)
            logService.log(.debug, category: .sync, message: "Requested download: \((path as NSString).lastPathComponent)")
        } catch {
            logService.log(.warning, category: .sync,
                           message: "Failed to request download for \(path): \(error.localizedDescription)")
            throw error
        }
    }

    /// Request download and wait for completion.
    /// Returns true if file was successfully downloaded within timeout.
    /// Optional progressHandler reports per-file download progress (0.0-1.0) via st_blocks/st_size.
    func requestDownloadAndWait(at path: String, timeout: TimeInterval = 120, cancelChecker: (() -> Bool)? = nil, progressHandler: ((Double) -> Void)? = nil) async -> Bool {
        // If already synced, no need to download
        if isFileSynced(at: path) {
            progressHandler?(1.0)
            return true
        }

        // Get expected file size from st_size (Proton Drive reports cloud size even for placeholders)
        var sizeStatInfo = stat()
        let expectedSize: Int64 = (stat(path, &sizeStatInfo) == 0) ? Int64(sizeStatInfo.st_size) : 0

        // Request the download
        do {
            try requestDownload(at: path)
        } catch {
            return false
        }

        // Wait for completion with progress reporting
        return await waitForSync(at: path, timeout: timeout, expectedSize: expectedSize, cancelChecker: cancelChecker, progressHandler: progressHandler)
    }

    /// Wait for a file to be fully synced (with timeout).
    /// Reports download progress combining time-based estimation with st_blocks.
    /// Proton Drive writes files atomically (st_blocks jumps from 0 to final), so
    /// time-based estimation provides smooth intermediate progress for the UI.
    func waitForSync(at path: String, timeout: TimeInterval = 60, expectedSize: Int64 = 0, cancelChecker: (() -> Bool)? = nil, progressHandler: ((Double) -> Void)? = nil) async -> Bool {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            // Check for cancellation (e.g., system going to sleep, user cancelled)
            if cancelChecker?() == true {
                logService.log(.info, category: .sync,
                               message: "Download cancelled: \((path as NSString).lastPathComponent)")
                return false
            }

            if isFileSynced(at: path) {
                progressHandler?(1.0)
                return true
            }

            if let handler = progressHandler {
                let elapsed = Date().timeIntervalSince(startTime)

                // Time-based estimate: elapsed / (elapsed + 3.0) gives a smooth curve
                // 1s→25%, 2s→40%, 3s→50%, 5s→63%, 10s→77% — always increasing, never reaching 1.0
                let timeProgress = min(elapsed / (elapsed + 3.0), 0.95)

                // st_blocks-based progress for large files where blocks increase gradually
                var blockProgress: Double = 0
                if expectedSize > 0 {
                    var currentStat = stat()
                    if stat(path, &currentStat) == 0 {
                        let downloadedBytes = Int64(currentStat.st_blocks) * 512
                        blockProgress = min(Double(downloadedBytes) / Double(expectedSize), 0.95)
                    }
                }

                // Use whichever is higher — progress never goes backwards
                handler(max(timeProgress, blockProgress))
            }

            // Wait a bit before checking again
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }

        return false
    }

    /// Evict (offload) a file to free up local space.
    /// The file will become cloud-only and can be downloaded again later.
    func evictFile(at path: String) -> Bool {
        let fileName = (path as NSString).lastPathComponent
        let url = URL(fileURLWithPath: path)

        // Check current state — skip if already cloud-only
        var evictStatInfo = stat()
        let evictStatResult = stat(path, &evictStatInfo)
        let fileSize: Int64 = (evictStatResult == 0) ? Int64(evictStatInfo.st_size) : -1
        let fileBlocks = (evictStatResult == 0) ? evictStatInfo.st_blocks : -1

        if evictStatResult == 0 && (fileSize == 0 || fileBlocks == 0) {
            logService.log(.debug, category: .sync,
                           message: "EVICT SKIP: \(fileName) already cloud-only (size=\(fileSize) blocks=\(fileBlocks))")
            return true
        }

        logService.log(.info, category: .sync,
                       message: "EVICT START: \(fileName) size=\(fileSize) blocks=\(fileBlocks)")

        // Use NSFileManager.evictUbiquitousItem — works with both iCloud and third-party FileProviders
        do {
            try FileManager.default.evictUbiquitousItem(at: url)

            // Verify eviction by checking st_blocks
            var newStatInfo = stat()
            let newStatResult = stat(path, &newStatInfo)
            let newBlocks = (newStatResult == 0) ? newStatInfo.st_blocks : -1
            let newSize: Int64 = (newStatResult == 0) ? Int64(newStatInfo.st_size) : -1
            let success = (newSize == 0 || newBlocks == 0)
            logService.log(.info, category: .sync,
                           message: "EVICT RESULT: \(fileName) size=\(newSize) blocks=\(newBlocks) success=\(success)")
            return success
        } catch {
            logService.log(.warning, category: .sync,
                           message: "EVICT FAILED: \(fileName) - \(error.localizedDescription)")
            return false
        }
    }

    /// Evict a file with retry logic.
    /// The FileProvider may need time after a download/copy before accepting eviction.
    func evictFileWithRetry(at path: String, maxAttempts: Int = 3, delaySeconds: Double = 1.0) async -> Bool {
        let fileName = (path as NSString).lastPathComponent

        for attempt in 1...maxAttempts {
            if evictFile(at: path) {
                return true
            }

            if attempt < maxAttempts {
                logService.log(.debug, category: .sync,
                               message: "Evict retry \(attempt)/\(maxAttempts) for \(fileName)")
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }

        logService.log(.warning, category: .sync,
                       message: "Evict failed after \(maxAttempts) attempts: \(fileName)")
        return false
    }

    /// Check if a file is cloud-only (not downloaded locally).
    /// Returns true if the file exists but has no local content (cloud placeholder).
    /// IMPORTANT: This method only reads metadata - it does NOT trigger downloads.
    func isCloudOnly(at path: String) -> Bool {
        // Use stat() + st_blocks for reliable cloud-only detection.
        // Proton Drive's FileProvider reports the cloud file size via st_size
        // even for cloud-only files. st_blocks == 0 means no local disk allocation.
        var statInfo = stat()
        if stat(path, &statInfo) == 0 {
            let size = Int64(statInfo.st_size)
            let blocks = statInfo.st_blocks

            // File has local disk allocation = not cloud-only
            if size > 0 && blocks > 0 {
                return false
            }
            // No disk blocks but has size = cloud-only placeholder
            if blocks == 0 && path.contains("/Library/CloudStorage/") {
                return true
            }
            // Zero size in CloudStorage = cloud-only
            if size == 0 && path.contains("/Library/CloudStorage/") {
                return true
            }
        }

        // If we couldn't get attributes via FileManager, try URL resourceValues
        let url = URL(fileURLWithPath: path)

        do {
            let values = try url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
                .isUbiquitousItemKey,
                .fileSizeKey
            ])

            // Check ubiquitous item status if available
            if values.isUbiquitousItem == true {
                if let downloadStatus = values.ubiquitousItemDownloadingStatus {
                    return downloadStatus == .notDownloaded
                }
            }

            // Check file size
            let localSize = values.fileSize ?? 0
            if localSize == 0 && path.contains("/Library/CloudStorage/") {
                return true
            }

            return false
        } catch {
            // If file doesn't exist locally but is in CloudStorage path, assume cloud-only
            if path.contains("/Library/CloudStorage/") && !fileManager.fileExists(atPath: path) {
                return true
            }
            return false
        }
    }

    /// Get file size even for cloud-only files (from metadata).
    func getCloudFileSize(at path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)

        do {
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .totalFileSizeKey
            ])

            // totalFileSize includes cloud file size
            if let size = values.totalFileSize {
                return Int64(size)
            }
            if let size = values.fileSize {
                return Int64(size)
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Get summary of sync status for a directory.
    func getSyncSummary(forDirectory path: String) -> SyncSummary {
        let statusMap = getSyncStatus(forDirectory: path)

        var synced = 0
        var cloudOnly = 0
        var downloading = 0
        var uploading = 0
        var unknown = 0

        for (_, status) in statusMap {
            switch status {
            case .synced, .localOnly:
                synced += 1
            case .cloudOnly:
                cloudOnly += 1
            case .downloading:
                downloading += 1
            case .uploading:
                uploading += 1
            case .unknown:
                unknown += 1
            }
        }

        return SyncSummary(
            totalFiles: statusMap.count,
            syncedFiles: synced,
            cloudOnlyFiles: cloudOnly,
            downloadingFiles: downloading,
            uploadingFiles: uploading,
            unknownFiles: unknown
        )
    }
}

// MARK: - Supporting Types

enum SyncStatus {
    case synced      // File is downloaded and matches cloud
    case cloudOnly   // File exists in cloud but not downloaded locally
    case localOnly   // File exists locally (not cloud-managed or fully local)
    case downloading // File is being downloaded
    case uploading   // File is being uploaded
    case unknown     // Status cannot be determined
}

struct SyncSummary {
    let totalFiles: Int
    let syncedFiles: Int
    let cloudOnlyFiles: Int
    let downloadingFiles: Int
    let uploadingFiles: Int
    let unknownFiles: Int

    var allSynced: Bool {
        cloudOnlyFiles == 0 && downloadingFiles == 0 && uploadingFiles == 0
    }

    var syncPercentage: Double {
        guard totalFiles > 0 else { return 100.0 }
        return Double(syncedFiles) / Double(totalFiles) * 100.0
    }
}
