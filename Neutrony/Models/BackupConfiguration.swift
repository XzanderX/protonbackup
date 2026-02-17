import Foundation

/// Persisted configuration for the backup app.
/// Stored as JSON in Application Support/Neutrony/config.json.
struct BackupConfiguration: Codable, Equatable {

    // MARK: - Source (Proton Drive folder)

    /// Path to the Proton Drive sync folder (from official Proton Drive app).
    var sourcePath: String?

    // MARK: - Destination

    /// Security-scoped bookmark data for the external backup destination.
    var destinationBookmark: Data?

    /// Display name of the destination volume (for UI only; resolution uses bookmark).
    var destinationDisplayName: String?

    // MARK: - Local mirror

    /// Path to the local mirror folder. Defaults to Application Support/Neutrony/Mirror.
    var localMirrorPath: String

    // MARK: - Polling

    /// Interval in minutes between remote change checks (5–120).
    var pollingIntervalMinutes: Int

    // MARK: - Deletion policy

    /// How deletions on the remote are handled on the destination.
    var deletionPolicy: DeletionPolicy

    // MARK: - Versioning

    /// Whether to keep replaced/deleted files in a _versions folder.
    var keepVersions: Bool

    // MARK: - Notifications

    /// Whether to send macOS notifications on backup completion or failure.
    var notificationsEnabled: Bool

    // MARK: - Login item

    /// Whether the app should start at login.
    var startAtLogin: Bool

    // MARK: - Timestamps

    /// Date of the last successful backup to the external destination.
    var lastSuccessfulBackup: Date?

    /// Date of the last successful remote sync to the local mirror.
    var lastSuccessfulSync: Date?

    // MARK: - Rclone settings

    /// Whether to use rclone for cloud access instead of local folder.
    var useRclone: Bool

    /// Whether rclone has been configured with Proton credentials.
    var rcloneConfigured: Bool

    // MARK: - Cloud verification

    /// Whether to verify files are synced with cloud before backup.
    /// When enabled, only files confirmed synced by the Proton Drive app are backed up.
    var requireCloudSync: Bool

    // MARK: - On-demand backup

    /// Whether to use on-demand backup mode.
    /// When enabled, downloads cloud-only files as needed and optionally offloads after backup.
    /// This respects the user's Proton Drive sync settings.
    var onDemandDownload: Bool

    /// Whether to offload (evict) files after backup to free up local space.
    /// Only applies to files that were downloaded for backup.
    /// This helps respect the user's Proton Drive storage settings.
    var offloadAfterBackup: Bool

    // MARK: - Point-in-time captures

    /// How to create point-in-time captures after each backup.
    /// When set to .apfsSnapshot, creates an APFS volume snapshot (instant, zero extra space).
    /// When set to .apfsClone, clones the backup tree into .history/ using APFS COW copies.
    var snapshotMode: SnapshotMode

    /// Maximum number of days to keep old clone captures in .history/.
    /// Set to 0 to keep captures indefinitely.
    var snapshotRetentionDays: Int

    // MARK: - Setup state

    /// Whether the first-run setup wizard has been completed.
    var setupCompleted: Bool

    // MARK: - Defaults

    static let `default` = BackupConfiguration(
        sourcePath: nil,
        destinationBookmark: nil,
        destinationDisplayName: nil,
        localMirrorPath: defaultMirrorPath,
        pollingIntervalMinutes: 30,
        deletionPolicy: .mirrorDeletions,
        keepVersions: false,  // Disabled for now
        notificationsEnabled: true,
        startAtLogin: false,
        lastSuccessfulBackup: nil,
        lastSuccessfulSync: nil,
        useRclone: false,
        rcloneConfigured: false,
        requireCloudSync: true,
        onDemandDownload: true,
        offloadAfterBackup: false,
        snapshotMode: .disabled,
        snapshotRetentionDays: 30,
        setupCompleted: false
    )

    static var defaultMirrorPath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Neutrony", isDirectory: true)
            .appendingPathComponent("Mirror", isDirectory: true)
            .path
    }

    // MARK: - Persistence

    private static var configURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Neutrony", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> BackupConfiguration {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(BackupConfiguration.self, from: data) else {
            return .default
        }
        return config
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.configURL, options: .atomic)
    }
}

// MARK: - Deletion Policy

enum DeletionPolicy: String, Codable, CaseIterable, Identifiable {
    /// Mirror deletions from remote to destination. Deleted files are removed.
    case mirrorDeletions

    /// Mirror deletions but move deleted files to _versions first.
    case mirrorWithVersions

    /// Never delete files on the destination.
    case neverDelete

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mirrorDeletions:
            return "Mirror deletions (remove from backup)"
        case .mirrorWithVersions:
            return "Mirror deletions (keep versions)"
        case .neverDelete:
            return "Never delete on destination"
        }
    }

    var explanation: String {
        switch self {
        case .mirrorDeletions:
            return "Files deleted from Proton Drive will also be deleted from your backup. This keeps your backup an exact mirror."
        case .mirrorWithVersions:
            return "Files deleted from Proton Drive are moved to a _versions folder on your backup drive before removal. Recommended for safety."
        case .neverDelete:
            return "Files are never deleted from your backup, even if removed from Proton Drive. Your backup will grow over time."
        }
    }
}
