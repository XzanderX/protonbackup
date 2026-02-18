import Foundation

/// Represents the current operational state of the backup system.
enum BackupState: Equatable {
    /// No backup is running; system is idle.
    case idle

    /// Currently syncing from Proton Drive to local mirror.
    case syncing(progress: BackupProgress)

    /// Currently copying from local mirror to external destination.
    case backing(progress: BackupProgress)

    /// Backup is paused by the user.
    case paused(progress: BackupProgress)

    /// Backup completed and everything is up to date.
    case upToDate

    /// The external destination is not connected.
    case destinationDisconnected

    /// An error occurred.
    case error(message: String)

    /// The app has not been configured yet.
    case notConfigured

    var isRunning: Bool {
        switch self {
        case .syncing, .backing:
            return true
        default:
            return false
        }
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    var menuBarIconName: String {
        switch self {
        case .idle:
            return "arrow.triangle.2.circlepath"
        case .syncing, .backing:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .upToDate:
            return "checkmark.circle.fill"
        case .destinationDisconnected:
            return "externaldrive.badge.xmark"
        case .error:
            return "exclamationmark.triangle.fill"
        case .notConfigured:
            return "gearshape"
        }
    }

    var statusText: String {
        switch self {
        case .idle:
            return "Idle"
        case .syncing(let progress):
            return "Syncing from Proton Drive… \(progress.summary)"
        case .backing(let progress):
            return "Backing up… \(progress.summary)"
        case .paused(let progress):
            return "Paused at \(progress.summary)"
        case .upToDate:
            return "Up to date"
        case .destinationDisconnected:
            return "Destination not connected"
        case .error(let message):
            return "Error: \(message)"
        case .notConfigured:
            return "Setup required"
        }
    }
}

/// Progress information for an ongoing backup operation.
struct BackupProgress: Equatable {
    var totalFiles: Int
    var completedFiles: Int
    var currentFileName: String?

    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(completedFiles) / Double(totalFiles)
    }

    var summary: String {
        if totalFiles > 0 {
            return "\(completedFiles)/\(totalFiles) files"
        }
        return "Scanning…"
    }
}

/// Represents a recent file operation for display in the activity list.
struct FileActivity: Identifiable, Equatable {
    let id: UUID
    let fileName: String
    let destinationFolder: String  // Full path to destination folder
    let fileSize: Int64?           // File size in bytes (optional)
    let status: FileActivityStatus
    let timestamp: Date

    init(fileName: String, destinationFolder: String, fileSize: Int64? = nil, status: FileActivityStatus) {
        self.id = UUID()
        self.fileName = fileName
        self.destinationFolder = destinationFolder
        self.fileSize = fileSize
        self.status = status
        self.timestamp = Date()
    }

    /// Display-friendly folder name (last component of path)
    var folderName: String {
        (destinationFolder as NSString).lastPathComponent
    }

    /// Full path to the file in destination
    var fullPath: String {
        (destinationFolder as NSString).appendingPathComponent(fileName)
    }

    /// File extension for icon selection
    var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    /// Formatted file size string
    var formattedSize: String? {
        guard let size = fileSize else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

enum FileActivityStatus: Equatable {
    case copying
    case copied
    case skipped
    case error(String)

    var displayText: String {
        switch self {
        case .copying: return "Copying…"
        case .copied: return "Copied"
        case .skipped: return "Skipped"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var iconName: String {
        switch self {
        case .copying: return "arrow.right.circle"
        case .copied: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle"
        case .error: return "exclamationmark.circle.fill"
        }
    }
}

/// Summary produced after a backup run completes.
struct BackupSummary: Equatable {
    var filesUpdated: Int
    var filesDeleted: Int
    var filesSkipped: Int
    var errors: [String]
    var startTime: Date
    var endTime: Date

    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    var succeeded: Bool {
        errors.isEmpty
    }

    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "\(Int(duration))s"
    }

    var displayText: String {
        var parts: [String] = []
        if filesUpdated > 0 { parts.append("\(filesUpdated) updated") }
        if filesDeleted > 0 { parts.append("\(filesDeleted) deleted") }
        if filesSkipped > 0 { parts.append("\(filesSkipped) skipped") }
        if !errors.isEmpty { parts.append("\(errors.count) errors") }
        let summary = parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
        return "\(summary) in \(formattedDuration)"
    }
}
