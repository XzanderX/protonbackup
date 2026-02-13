import Foundation

/// Manages versioned backups, moving replaced/deleted files to a dated _versions folder.
final class VersionManager {

    private let logService: LogService

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(logService: LogService) {
        self.logService = logService
    }

    // MARK: - Public API

    /// Move a file to the _versions folder before it is deleted or overwritten.
    func archiveFile(atPath sourcePath: String, relativePath: String, backupRoot: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath) else { return }

        let dateString = Self.dateFormatter.string(from: Date())
        let versionsBase = (backupRoot as NSString).appendingPathComponent("_versions")
        let datedFolder = (versionsBase as NSString).appendingPathComponent(dateString)
        let destPath = (datedFolder as NSString).appendingPathComponent(relativePath)

        // Ensure parent directory exists
        let destParent = (destPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: destParent, withIntermediateDirectories: true)

        // If a version already exists for today, add a counter
        var finalPath = destPath
        if fm.fileExists(atPath: finalPath) {
            let ext = (destPath as NSString).pathExtension
            let base = (destPath as NSString).deletingPathExtension
            var counter = 1
            repeat {
                if ext.isEmpty {
                    finalPath = "\(base)_\(counter)"
                } else {
                    finalPath = "\(base)_\(counter).\(ext)"
                }
                counter += 1
            } while fm.fileExists(atPath: finalPath)
        }

        try fm.copyItem(atPath: sourcePath, toPath: finalPath)
        logService.log(.debug, category: .version, message: "Archived version", filePath: relativePath)
    }

    /// List all version dates available in the backup.
    func listVersionDates(backupRoot: String) -> [String] {
        let versionsPath = (backupRoot as NSString).appendingPathComponent("_versions")
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: versionsPath) else {
            return []
        }

        return contents
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .reversed()
            .map { $0 }
    }

    /// List versioned files for a specific date.
    func listVersionedFiles(backupRoot: String, date: String) -> [String] {
        let datePath = (backupRoot as NSString)
            .appendingPathComponent("_versions")
            .appending("/\(date)")
        let fm = FileManager.default
        let dateURL = URL(fileURLWithPath: datePath)

        guard let enumerator = fm.enumerator(
            at: dateURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                let relPath = url.path.replacingOccurrences(of: datePath + "/", with: "")
                files.append(relPath)
            }
        }

        return files.sorted()
    }

    /// Calculate the total size of the _versions folder.
    func versionsSize(backupRoot: String) -> Int64 {
        let versionsPath = (backupRoot as NSString).appendingPathComponent("_versions")
        let fm = FileManager.default
        let versionsURL = URL(fileURLWithPath: versionsPath)

        guard let enumerator = fm.enumerator(
            at: versionsURL,
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

    /// Purge versions older than a given number of days.
    func purgeOldVersions(backupRoot: String, olderThanDays: Int) throws -> Int {
        let versionsPath = (backupRoot as NSString).appendingPathComponent("_versions")
        let fm = FileManager.default
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -olderThanDays, to: Date())!
        let cutoffString = Self.dateFormatter.string(from: cutoffDate)

        guard let dateFolders = try? fm.contentsOfDirectory(atPath: versionsPath) else {
            return 0
        }

        var purgedCount = 0
        for folder in dateFolders {
            if folder < cutoffString && !folder.hasPrefix(".") {
                let folderPath = (versionsPath as NSString).appendingPathComponent(folder)
                try fm.removeItem(atPath: folderPath)
                purgedCount += 1
                logService.log(.info, category: .version, message: "Purged version folder: \(folder)")
            }
        }

        return purgedCount
    }
}
