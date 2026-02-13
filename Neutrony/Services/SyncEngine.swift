import Foundation

/// Manages synchronization from Proton Drive to the local mirror folder.
/// Detects changes, downloads new/modified files, and handles deletions.
final class SyncEngine {

    private let driveClient = ProtonDriveClient.shared
    private let logService: LogService
    private var mirrorIndex = MirrorIndex.load()
    private var lastEventID: String?

    /// Share and root link for the user's main Proton Drive.
    private var shareID: String?
    private var rootLinkID: String?

    init(logService: LogService) {
        self.logService = logService
    }

    // MARK: - Public API

    /// Initialize by discovering the main share.
    func initialize() async throws {
        let share = try await driveClient.getMainShare()
        self.shareID = share.shareID
        self.rootLinkID = share.linkID

        // Get initial event ID for change polling
        self.lastEventID = try await driveClient.getLatestEventID(shareID: share.shareID)

        logService.log(.info, category: .sync, message: "Sync engine initialized for share \(share.shareID)")
    }

    /// Perform a full sync: list all remote files, compare with mirror, download changes.
    func performFullSync(
        mirrorPath: String,
        deletionPolicy: DeletionPolicy,
        progressHandler: @escaping (BackupProgress) -> Void
    ) async throws -> BackupSummary {
        guard let shareID, let rootLinkID else {
            throw SyncError.notInitialized
        }

        let startTime = Date()
        var filesUpdated = 0
        var filesDeleted = 0
        let filesSkipped = 0
        var errors: [String] = []

        logService.log(.info, category: .sync, message: "Starting full sync to \(mirrorPath)")

        // Ensure mirror directory exists
        let fm = FileManager.default
        try fm.createDirectory(atPath: mirrorPath, withIntermediateDirectories: true)

        // List all remote files
        progressHandler(BackupProgress(totalFiles: 0, completedFiles: 0, currentFileName: "Scanning remote files…"))
        let remoteFiles = try await driveClient.listAllFiles(shareID: shareID, rootLinkID: rootLinkID)

        logService.log(.info, category: .sync, message: "Found \(remoteFiles.count) remote items")

        // Detect changes
        let changes = detectChanges(remoteFiles: remoteFiles)
        let totalWork = changes.count

        if changes.isEmpty {
            logService.log(.info, category: .sync, message: "No changes detected")
            return BackupSummary(
                filesUpdated: 0, filesDeleted: 0, filesSkipped: remoteFiles.count,
                errors: [], startTime: startTime, endTime: Date()
            )
        }

        logService.log(.info, category: .sync, message: "\(changes.count) changes to apply")

        // Apply changes
        for (index, change) in changes.enumerated() {
            let progress = BackupProgress(
                totalFiles: totalWork,
                completedFiles: index,
                currentFileName: changeFileName(change)
            )
            progressHandler(progress)

            do {
                switch change {
                case .added(let file), .modified(let file):
                    if file.isFolder {
                        try applyFolderAdd(file: file, mirrorPath: mirrorPath)
                    } else {
                        try await applyFileSync(file: file, shareID: shareID, mirrorPath: mirrorPath)
                    }
                    filesUpdated += 1

                case .deleted(let relativePath):
                    try applyDeletion(relativePath: relativePath, mirrorPath: mirrorPath, policy: deletionPolicy)
                    filesDeleted += 1
                }
            } catch {
                let desc = "Failed to sync \(changeFileName(change)): \(error.localizedDescription)"
                errors.append(desc)
                logService.log(.error, category: .sync, message: desc)
            }
        }

        // Update mirror index
        rebuildMirrorIndex(remoteFiles: remoteFiles)
        try mirrorIndex.save()

        // Update last event ID
        if let shareID = self.shareID {
            lastEventID = try? await driveClient.getLatestEventID(shareID: shareID)
        }

        let summary = BackupSummary(
            filesUpdated: filesUpdated,
            filesDeleted: filesDeleted,
            filesSkipped: filesSkipped,
            errors: errors,
            startTime: startTime,
            endTime: Date()
        )

        logService.log(.info, category: .sync, message: "Sync complete: \(summary.displayText)")
        return summary
    }

    /// Check for remote changes using the event API.
    func checkForRemoteChanges() async throws -> RemoteCheckResult {
        guard let shareID, let eventID = lastEventID else {
            throw SyncError.notInitialized
        }

        var allChanges: [FileChange] = []
        var currentEventID = eventID

        while true {
            let eventsResponse = try await driveClient.getEvents(shareID: shareID, sinceEventID: currentEventID)

            guard eventsResponse.code == 1000 else {
                throw SyncError.eventCheckFailed
            }

            if let events = eventsResponse.events {
                for event in events {
                    if let change = mapEventToChange(event) {
                        allChanges.append(change)
                    }
                }
            }

            if let newEventID = eventsResponse.eventID {
                currentEventID = newEventID
            }

            if eventsResponse.more != true {
                break
            }
        }

        lastEventID = currentEventID
        return RemoteCheckResult(changes: allChanges, checkedAt: Date())
    }

    // MARK: - Private

    private func detectChanges(remoteFiles: [ProtonFile]) -> [FileChange] {
        var changes: [FileChange] = []
        let existingPaths = Set(mirrorIndex.entries.keys)
        var remotePaths = Set<String>()

        for file in remoteFiles {
            guard let path = file.relativePath else { continue }
            remotePaths.insert(path)

            if let existing = mirrorIndex.entries[path] {
                // Check if modified
                if existing.contentHash != file.contentHash ||
                   existing.size != file.size {
                    changes.append(.modified(file))
                }
            } else {
                changes.append(.added(file))
            }
        }

        // Detect deletions
        for path in existingPaths {
            if !remotePaths.contains(path) {
                changes.append(.deleted(relativePath: path))
            }
        }

        return changes
    }

    private func applyFolderAdd(file: ProtonFile, mirrorPath: String) throws {
        guard let relativePath = file.relativePath else { return }
        let fullPath = (mirrorPath as NSString).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(atPath: fullPath, withIntermediateDirectories: true)
        logService.log(.debug, category: .sync, message: "Created folder", filePath: relativePath)
    }

    private func applyFileSync(file: ProtonFile, shareID: String, mirrorPath: String) async throws {
        guard let relativePath = file.relativePath else { return }
        let fullPath = (mirrorPath as NSString).appendingPathComponent(relativePath)

        // Ensure parent directory exists
        let parentPath = (fullPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parentPath, withIntermediateDirectories: true)

        // Download file content
        let data = try await driveClient.downloadFile(shareID: shareID, linkID: file.id)

        // Write to mirror
        try data.write(to: URL(fileURLWithPath: fullPath), options: .atomic)

        // Preserve modification date
        try FileManager.default.setAttributes(
            [.modificationDate: file.modifiedDate],
            ofItemAtPath: fullPath
        )

        logService.log(.debug, category: .sync, message: "Synced file (\(file.size) bytes)", filePath: relativePath)
    }

    private func applyDeletion(relativePath: String, mirrorPath: String, policy: DeletionPolicy) throws {
        let fullPath = (mirrorPath as NSString).appendingPathComponent(relativePath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: fullPath) else { return }

        switch policy {
        case .neverDelete:
            logService.log(.debug, category: .sync, message: "Skipping deletion (policy: never delete)", filePath: relativePath)
            return

        case .mirrorWithVersions:
            // Move to mirror's _versions folder
            let versionDir = (mirrorPath as NSString).appendingPathComponent("_versions")
            let dateString = ISO8601DateFormatter().string(from: Date()).prefix(10)
            let versionPath = (versionDir as NSString)
                .appendingPathComponent(String(dateString))
            let destPath = (versionPath as NSString).appendingPathComponent(relativePath)

            let destParent = (destPath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: destParent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: fullPath, toPath: destPath)
            logService.log(.debug, category: .sync, message: "Moved to versions", filePath: relativePath)

        case .mirrorDeletions:
            try fm.removeItem(atPath: fullPath)
            logService.log(.debug, category: .sync, message: "Deleted", filePath: relativePath)
        }
    }

    private func rebuildMirrorIndex(remoteFiles: [ProtonFile]) {
        var entries: [String: MirrorEntry] = [:]
        for file in remoteFiles {
            guard let path = file.relativePath else { continue }
            entries[path] = MirrorEntry(
                protonFileID: file.id,
                relativePath: path,
                contentHash: file.contentHash,
                size: file.size,
                modifiedDate: file.modifiedDate,
                isFolder: file.isFolder
            )
        }
        mirrorIndex = MirrorIndex(entries: entries, lastIndexDate: Date())
    }

    private func mapEventToChange(_ event: DriveEvent) -> FileChange? {
        guard let link = event.link else { return nil }

        let file = ProtonFile(
            id: link.linkID,
            parentID: link.parentLinkID,
            name: link.name,
            mimeType: link.mimeType,
            size: link.size ?? 0,
            contentHash: link.hash,
            modifiedDate: Date(timeIntervalSince1970: TimeInterval(link.modifyTime ?? 0)),
            createdDate: Date(timeIntervalSince1970: TimeInterval(link.createTime ?? 0)),
            isFolder: link.type == 1,
            relativePath: nil
        )

        switch event.eventType {
        case 1: return .added(file)      // Create
        case 2: return .modified(file)   // Update
        case 3: return .deleted(relativePath: link.name)  // Delete
        default: return nil
        }
    }

    private func changeFileName(_ change: FileChange) -> String {
        switch change {
        case .added(let f), .modified(let f):
            return f.relativePath ?? f.name
        case .deleted(let path):
            return path
        }
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case notInitialized
    case eventCheckFailed

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Sync engine not initialized. Please sign in to Proton Drive first."
        case .eventCheckFailed:
            return "Failed to check for remote changes."
        }
    }
}
