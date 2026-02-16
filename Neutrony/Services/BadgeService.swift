import Foundation

/// Service for managing Finder badge icons during backup operations.
/// Communicates with the FinderSync extension via App Groups.
final class BadgeService {

    static let shared = BadgeService()

    private let badgeManager = BadgeStateManager.shared
    private let logService = LogService.shared

    /// Currently active backup destination path
    private var activeDestination: String?

    /// Currently active source path
    private var activeSource: String?

    private init() {}

    // MARK: - Configuration

    /// Configure monitored directories for the FinderSync extension.
    func configure(sourcePath: String?, destinationPath: String?) {
        var directories: [URL] = []

        if let source = sourcePath {
            directories.append(URL(fileURLWithPath: source))
            activeSource = source
        }

        if let dest = destinationPath {
            directories.append(URL(fileURLWithPath: dest))
            activeDestination = dest
        }

        badgeManager.setMonitoredDirectories(directories)
        logService.log(.debug, category: .backup, message: "BadgeService configured: \(directories.count) directories")
    }

    // MARK: - Backup Lifecycle

    /// Called when a backup starts.
    func backupStarted(destinationPath: String) {
        activeDestination = destinationPath

        // Set syncing badge on the destination root
        badgeManager.setBadge(.syncing, for: destinationPath)
        logService.log(.debug, category: .backup, message: "Badge: backup started")
    }

    /// Called when backup completes successfully.
    func backupCompleted(destinationPath: String) {
        // Clear all syncing/downloading badges
        badgeManager.clearAllBadges()

        // Set complete badge on destination root briefly
        badgeManager.setBadge(.complete, for: destinationPath)

        // Clear the complete badge after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.badgeManager.clearBadge(for: destinationPath)
        }

        logService.log(.debug, category: .backup, message: "Badge: backup completed")
    }

    /// Called when backup fails.
    func backupFailed(destinationPath: String) {
        // Clear syncing badges, set error on root
        badgeManager.clearAllBadges()
        badgeManager.setBadge(.error, for: destinationPath)

        logService.log(.debug, category: .backup, message: "Badge: backup failed")
    }

    // MARK: - File-level Badges

    /// Mark a file as currently being processed (syncing).
    func markFileSyncing(relativePath: String) {
        guard let dest = activeDestination else { return }
        let fullPath = (dest as NSString).appendingPathComponent(relativePath)
        badgeManager.setBadge(.syncing, for: fullPath)
    }

    /// Mark a file as currently downloading from cloud.
    func markFileDownloading(relativePath: String) {
        guard let dest = activeDestination else { return }
        let fullPath = (dest as NSString).appendingPathComponent(relativePath)
        badgeManager.setBadge(.downloading, for: fullPath)
    }

    /// Mark a file as completed.
    func markFileComplete(relativePath: String) {
        guard let dest = activeDestination else { return }
        let fullPath = (dest as NSString).appendingPathComponent(relativePath)
        badgeManager.clearBadge(for: fullPath)
    }

    /// Mark a file as having an error.
    func markFileError(relativePath: String) {
        guard let dest = activeDestination else { return }
        let fullPath = (dest as NSString).appendingPathComponent(relativePath)
        badgeManager.setBadge(.error, for: fullPath)
    }

    /// Mark multiple files as pending backup.
    func markFilesPending(relativePaths: [String]) {
        guard let dest = activeDestination else { return }
        let fullPaths = relativePaths.map { (dest as NSString).appendingPathComponent($0) }
        badgeManager.setBadges(.pending, for: fullPaths)
    }

    /// Mark a folder as currently being processed.
    func markFolderSyncing(relativePath: String) {
        guard let dest = activeDestination else { return }
        let fullPath = (dest as NSString).appendingPathComponent(relativePath)
        badgeManager.setBadge(.syncing, for: fullPath)
    }

    /// Clear badge for a specific file.
    func clearBadge(relativePath: String) {
        guard let dest = activeDestination else { return }
        let fullPath = (dest as NSString).appendingPathComponent(relativePath)
        badgeManager.clearBadge(for: fullPath)
    }

    /// Clear all badges (e.g., when backup is cancelled).
    func clearAllBadges() {
        badgeManager.clearAllBadges()
        logService.log(.debug, category: .backup, message: "Badge: all badges cleared")
    }
}
