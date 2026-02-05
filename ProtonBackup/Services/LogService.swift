import Foundation
import os.log

/// Centralized logging service that stores structured log entries in memory and on disk.
/// Provides the backing store for the built-in log viewer.
final class LogService: ObservableObject {

    static let shared = LogService()

    /// Published log entries for the UI.
    @Published private(set) var entries: [BackupLogEntry] = []

    /// Maximum number of entries kept in memory.
    private let maxInMemoryEntries = 5000

    /// System logger for os_log integration.
    private let osLogger = Logger(subsystem: "com.protonbackup.app", category: "backup")

    /// File handle for the log file.
    private var logFileHandle: FileHandle?
    private let logQueue = DispatchQueue(label: "com.protonbackup.log", qos: .utility)

    private init() {
        openLogFile()
        loadRecentEntries()
    }

    deinit {
        logFileHandle?.closeFile()
    }

    // MARK: - Public API

    /// Log a message.
    func log(
        _ level: LogLevel,
        category: LogCategory,
        message: String,
        filePath: String? = nil
    ) {
        let entry = BackupLogEntry(
            level: level,
            category: category,
            message: message,
            filePath: filePath
        )

        // Write to os_log
        switch level {
        case .debug:
            osLogger.debug("\(entry.displayLine, privacy: .public)")
        case .info:
            osLogger.info("\(entry.displayLine, privacy: .public)")
        case .warning:
            osLogger.warning("\(entry.displayLine, privacy: .public)")
        case .error:
            osLogger.error("\(entry.displayLine, privacy: .public)")
        }

        // Write to file
        logQueue.async { [weak self] in
            self?.writeToFile(entry)
        }

        // Update in-memory entries on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxInMemoryEntries {
                self.entries.removeFirst(self.entries.count - self.maxInMemoryEntries)
            }
        }
    }

    /// Get entries filtered by level and/or category.
    func filteredEntries(
        minLevel: LogLevel? = nil,
        category: LogCategory? = nil,
        searchText: String? = nil
    ) -> [BackupLogEntry] {
        entries.filter { entry in
            if let minLevel, entry.level < minLevel { return false }
            if let category, entry.category != category { return false }
            if let searchText, !searchText.isEmpty {
                let text = searchText.lowercased()
                return entry.message.lowercased().contains(text) ||
                       (entry.filePath?.lowercased().contains(text) ?? false)
            }
            return true
        }
    }

    /// Copy all visible log entries to a string.
    func exportLogText(minLevel: LogLevel = .debug) -> String {
        filteredEntries(minLevel: minLevel)
            .map(\.displayLine)
            .joined(separator: "\n")
    }

    /// Get the path to the log file on disk.
    var logFilePath: String {
        Self.logFileURL.path
    }

    /// Clear all in-memory log entries.
    func clearEntries() {
        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
        }
    }

    // MARK: - Private

    private static var logDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport
            .appendingPathComponent("ProtonBackup", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var logFileURL: URL {
        logDirectory.appendingPathComponent("protonbackup.log")
    }

    private func openLogFile() {
        let fm = FileManager.default
        let url = Self.logFileURL

        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }

        // Rotate if over 10 MB
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64,
           size > 10 * 1024 * 1024 {
            rotateLogFile()
        }

        logFileHandle = FileHandle(forWritingAtPath: url.path)
        logFileHandle?.seekToEndOfFile()
    }

    private func rotateLogFile() {
        let url = Self.logFileURL
        let archiveURL = Self.logDirectory.appendingPathComponent("protonbackup.log.1")
        let fm = FileManager.default

        try? fm.removeItem(at: archiveURL)
        try? fm.moveItem(at: url, to: archiveURL)
        fm.createFile(atPath: url.path, contents: nil)
    }

    private func writeToFile(_ entry: BackupLogEntry) {
        guard let handle = logFileHandle else { return }
        let line = entry.displayLine + "\n"
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    }

    private func loadRecentEntries() {
        // Load last 1000 lines from the log file on startup
        guard let data = try? Data(contentsOf: Self.logFileURL),
              let content = String(data: data, encoding: .utf8) else { return }

        // The in-memory entries start fresh each launch.
        // The file log persists across launches for diagnostics export.
        _ = content.components(separatedBy: "\n").suffix(1000)
    }
}
