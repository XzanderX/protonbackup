import Foundation

/// Badge identifiers for FinderSync extension.
public enum BadgeIdentifier: String, Codable {
    case syncing = "syncing"
    case downloading = "downloading"
    case complete = "complete"
    case error = "error"
    case pending = "pending"
    case none = ""
}

/// Represents the badge state for a single file or folder.
public struct FileBadgeState: Codable, Equatable {
    public let path: String
    public let badge: BadgeIdentifier
    public let timestamp: Date

    public init(path: String, badge: BadgeIdentifier) {
        self.path = path
        self.badge = badge
        self.timestamp = Date()
    }
}

/// Shared state container for badge information.
/// Uses file-based communication via App Groups container.
public final class BadgeStateManager {

    public static let shared = BadgeStateManager()

    /// App Group identifier - must match entitlements
    public static let appGroupIdentifier = "com.neutrony.shared"

    /// Notification name for badge updates
    public static let badgeUpdateNotification = "com.neutrony.badgeUpdate"

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// The shared container URL for the App Group
    private var containerURL: URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
    }

    /// Path to the badge state file
    private var stateFileURL: URL? {
        containerURL?.appendingPathComponent("badge_state.json")
    }

    /// Path to the monitored directories file
    private var monitoredDirsURL: URL? {
        containerURL?.appendingPathComponent("monitored_directories.json")
    }

    private init() {
        // Ensure container directory exists
        if let url = containerURL {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Badge State

    /// Current badge states for all files
    public private(set) var badgeStates: [String: FileBadgeState] = [:]

    /// Set badge for a specific path
    public func setBadge(_ badge: BadgeIdentifier, for path: String) {
        let state = FileBadgeState(path: path, badge: badge)
        badgeStates[path] = state
        saveState()
        postNotification(for: path)
    }

    /// Set badges for multiple paths at once
    public func setBadges(_ badge: BadgeIdentifier, for paths: [String]) {
        for path in paths {
            let state = FileBadgeState(path: path, badge: badge)
            badgeStates[path] = state
        }
        saveState()
        postNotification(for: nil)
    }

    /// Clear badge for a specific path
    public func clearBadge(for path: String) {
        badgeStates.removeValue(forKey: path)
        saveState()
        postNotification(for: path)
    }

    /// Clear all badges
    public func clearAllBadges() {
        badgeStates.removeAll()
        saveState()
        postNotification(for: nil)
    }

    /// Get badge for a specific path
    public func badge(for path: String) -> BadgeIdentifier {
        // Only return badge if this exact path has one
        // Don't inherit from parent folders - each file/folder manages its own badge
        if let state = badgeStates[path] {
            return state.badge
        }
        return .none
    }

    /// Load state from disk
    public func loadState() {
        guard let url = stateFileURL,
              let data = try? Data(contentsOf: url),
              let states = try? decoder.decode([String: FileBadgeState].self, from: data) else {
            return
        }
        badgeStates = states
    }

    /// Save state to disk
    private func saveState() {
        guard let url = stateFileURL,
              let data = try? encoder.encode(badgeStates) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Monitored Directories

    /// Set directories to monitor
    public func setMonitoredDirectories(_ directories: [URL]) {
        guard let url = monitoredDirsURL else { return }
        let paths = directories.map { $0.path }
        if let data = try? encoder.encode(paths) {
            try? data.write(to: url, options: .atomic)
        }
        postNotification(for: nil)
    }

    /// Get monitored directories
    public func getMonitoredDirectories() -> [URL] {
        guard let url = monitoredDirsURL,
              let data = try? Data(contentsOf: url),
              let paths = try? decoder.decode([String].self, from: data) else {
            return []
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Notifications

    private func postNotification(for path: String?) {
        // Post distributed notification for cross-process communication
        let center = DistributedNotificationCenter.default()
        var userInfo: [String: Any] = [:]
        if let path = path {
            userInfo["path"] = path
        }
        center.postNotificationName(
            NSNotification.Name(Self.badgeUpdateNotification),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }
}
