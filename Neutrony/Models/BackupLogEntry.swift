import Foundation

/// A single log entry recorded by the app.
struct BackupLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
    /// Optional associated file path.
    let filePath: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        category: LogCategory,
        message: String,
        filePath: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.filePath = filePath
    }

    var formattedTimestamp: String {
        Self.timestampFormatter.string(from: timestamp)
    }

    var displayLine: String {
        let prefix = "[\(formattedTimestamp)] [\(level.rawValue.uppercased())] [\(category.rawValue)]"
        if let filePath {
            return "\(prefix) \(message) — \(filePath)"
        }
        return "\(prefix) \(message)"
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

enum LogLevel: String, Codable, CaseIterable, Comparable {
    case debug
    case info
    case warning
    case error

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .warning, .error]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

enum LogCategory: String, Codable, CaseIterable {
    case sync
    case backup
    case auth
    case driveMonitor = "drive-monitor"
    case fileWatcher = "file-watcher"
    case config
    case app
    case version
    case history
}
