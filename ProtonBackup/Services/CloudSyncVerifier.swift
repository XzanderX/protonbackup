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
                @unknown default:
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
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else {
            return true
        }

        // Check for special extended attributes that indicate placeholder
        let url = URL(fileURLWithPath: path)

        // Check if file has the "offline" extended attribute
        if let extAttrs = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]) {
            if extAttrs.isUbiquitousItem == true {
                // It's a cloud-managed file, check if downloaded
                if let downloadStatus = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus {
                    return downloadStatus == .notDownloaded
                }
            }
        }

        // Check file size - placeholder files are often very small
        let size = attrs[.size] as? Int64 ?? 0
        if size == 0 {
            return true
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
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return statusMap
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }

            let status = getFileStatus(at: fileURL)
            statusMap[fileURL.path] = status
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
                @unknown default:
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
            logService.log(.info, category: .sync, message: "Requested download: \(path)")
        } catch {
            logService.log(.warning, category: .sync,
                           message: "Failed to request download for \(path): \(error.localizedDescription)")
            throw error
        }
    }

    /// Wait for a file to be fully synced (with timeout).
    func waitForSync(at path: String, timeout: TimeInterval = 60) async -> Bool {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if isFileSynced(at: path) {
                return true
            }

            // Wait a bit before checking again
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }

        return false
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
