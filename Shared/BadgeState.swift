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

    /// Lock for thread-safe access to badgeStates
    private let lock = NSLock()

    /// Queue for debounced disk writes and notifications
    private let writeQueue = DispatchQueue(label: "com.neutrony.badgeWrite")

    /// Debounce interval for disk writes (milliseconds)
    private let debounceInterval: UInt64 = 250

    /// Work item for debounced save
    private var saveWorkItem: DispatchWorkItem?

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

    /// Current badge states for all files (internal storage)
    private var _badgeStates: [String: FileBadgeState] = [:]

    /// Thread-safe accessor for badge states (returns a copy)
    public var badgeStates: [String: FileBadgeState] {
        lock.lock()
        let copy = _badgeStates
        lock.unlock()
        return copy
    }

    /// Set badge for a specific path
    public func setBadge(_ badge: BadgeIdentifier, for path: String) {
        let state = FileBadgeState(path: path, badge: badge)
        lock.lock()
        _badgeStates[path] = state
        lock.unlock()
        scheduleDebouncedSave()
    }

    /// Set badges for multiple paths at once
    public func setBadges(_ badge: BadgeIdentifier, for paths: [String]) {
        lock.lock()
        for path in paths {
            let state = FileBadgeState(path: path, badge: badge)
            _badgeStates[path] = state
        }
        lock.unlock()
        scheduleDebouncedSave()
    }

    /// Clear badge for a specific path
    public func clearBadge(for path: String) {
        lock.lock()
        _badgeStates.removeValue(forKey: path)
        lock.unlock()
        scheduleDebouncedSave()
    }

    /// Clear all badges
    public func clearAllBadges() {
        lock.lock()
        _badgeStates.removeAll()
        lock.unlock()
        // Immediate save and notify for clear all (important state change)
        saveStateNow()
        postNotification()
    }

    /// Get badge for a specific path
    public func badge(for path: String) -> BadgeIdentifier {
        // Only return badge if this exact path has one
        // Don't inherit from parent folders - each file/folder manages its own badge
        lock.lock()
        let state = _badgeStates[path]
        lock.unlock()
        if let state = state {
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
        lock.lock()
        _badgeStates = states
        lock.unlock()
    }

    /// Schedule a debounced save - coalesces rapid updates
    private func scheduleDebouncedSave() {
        writeQueue.async { [weak self] in
            guard let self = self else { return }

            // Cancel any pending save
            self.saveWorkItem?.cancel()

            // Schedule new save after debounce interval
            let workItem = DispatchWorkItem { [weak self] in
                self?.saveStateNow()
                self?.postNotification()
            }
            self.saveWorkItem = workItem

            self.writeQueue.asyncAfter(
                deadline: .now() + .milliseconds(Int(self.debounceInterval)),
                execute: workItem
            )
        }
    }

    /// Immediately save state to disk
    private func saveStateNow() {
        guard let url = stateFileURL else { return }
        lock.lock()
        let statesToSave = _badgeStates
        lock.unlock()
        guard let data = try? encoder.encode(statesToSave) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Flush any pending saves immediately (call before app termination)
    public func flushPendingChanges() {
        saveWorkItem?.cancel()
        saveStateNow()
        postNotification()
    }

    // MARK: - Monitored Directories

    /// Set directories to monitor
    public func setMonitoredDirectories(_ directories: [URL]) {
        guard let url = monitoredDirsURL else { return }
        let paths = directories.map { $0.path }
        if let data = try? encoder.encode(paths) {
            try? data.write(to: url, options: .atomic)
        }
        postNotification()
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

    private func postNotification() {
        // Post distributed notification for cross-process communication
        // Batched - doesn't include specific path since multiple may have changed
        DispatchQueue.main.async {
            let center = DistributedNotificationCenter.default()
            center.postNotificationName(
                NSNotification.Name(Self.badgeUpdateNotification),
                object: nil,
                userInfo: nil,
                deliverImmediately: false  // Allow coalescing
            )
        }
    }
}
