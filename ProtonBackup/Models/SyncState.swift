import Foundation

/// Tracks the overall sync/backup pipeline state for the scheduler.
struct SyncState: Equatable {
    /// Whether a sync (Proton → mirror) is currently in progress.
    var isSyncing: Bool = false

    /// Whether a backup (mirror → destination) is currently in progress.
    var isBacking: Bool = false

    /// Whether changes are queued for backup once the destination connects.
    var pendingBackup: Bool = false

    /// The last set of detected remote changes, if not yet applied.
    var pendingRemoteChanges: [FileChange]?

    /// Debounce timer identifier for local file changes.
    var localChangeDebounceID: UUID?

    /// Whether a run is locked out (single-run lock).
    var isLocked: Bool {
        isSyncing || isBacking
    }

    /// Reset after a complete backup cycle.
    mutating func resetAfterBackup() {
        isBacking = false
        pendingBackup = false
        pendingRemoteChanges = nil
    }
}

/// Describes the result of checking remote for changes.
struct RemoteCheckResult: Equatable {
    let changes: [FileChange]
    let checkedAt: Date

    var hasChanges: Bool {
        !changes.isEmpty
    }
}

/// Volume information for an external drive.
struct VolumeInfo: Equatable, Identifiable {
    let id: String
    let name: String
    let mountPath: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    let isExternal: Bool
    let isEjectable: Bool

    var formattedAvailableSpace: String {
        ByteCountFormatter.string(fromByteCount: availableCapacity, countStyle: .file)
    }

    var formattedTotalSpace: String {
        ByteCountFormatter.string(fromByteCount: totalCapacity, countStyle: .file)
    }
}
