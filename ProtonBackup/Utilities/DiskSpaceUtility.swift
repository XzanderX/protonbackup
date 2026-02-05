import Foundation

/// Utility for checking disk space availability.
enum DiskSpaceUtility {

    /// Check available space at a given path.
    static func availableSpace(atPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            // Fallback to basic capacity check
            guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]) else {
                return nil
            }
            return Int64(values.volumeAvailableCapacity ?? 0)
        }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// Check total space at a given path.
    static func totalSpace(atPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]) else {
            return nil
        }
        return Int64(values.volumeTotalCapacity ?? 0)
    }

    /// Calculate the total size of a directory recursively.
    static func directorySize(atPath path: String) -> Int64 {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Format bytes into a human-readable string.
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Check if there is enough space for a backup.
    /// Returns a warning message if space is low, nil if OK.
    static func checkSpaceWarning(atPath path: String, requiredBytes: Int64) -> String? {
        guard let available = availableSpace(atPath: path) else {
            return "Unable to determine available disk space."
        }

        if available < requiredBytes {
            return "Insufficient disk space. Available: \(formatBytes(available)), Required: \(formatBytes(requiredBytes))."
        }

        // Warn if less than 1 GB remaining after backup
        let remaining = available - requiredBytes
        if remaining < 1_073_741_824 {
            return "Low disk space warning. Only \(formatBytes(remaining)) will remain after backup."
        }

        return nil
    }
}
