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
    private let osLogger = Logger(subsystem: "com.neutrony.app", category: "backup")

    /// Whether to also print to stderr (visible in Terminal via `make run`).
    /// Enabled when running outside an app bundle (i.e. via swift run / make run).
    let printToTerminal: Bool

    /// File handle for the log file.
    private var logFileHandle: FileHandle?
    private let logQueue = DispatchQueue(label: "com.neutrony.log", qos: .utility)

    /// Buffer for batching entry updates to reduce main thread work
    private var pendingEntries: [BackupLogEntry] = []
    private let pendingLock = NSLock()
    private var flushWorkItem: DispatchWorkItem?
    private let flushInterval: TimeInterval = 0.5  // Flush every 500ms

    private init() {
        // Detect if running from a terminal (not inside a .app bundle)
        self.printToTerminal = Bundle.main.bundlePath.hasSuffix(".app") == false
        openLogFile()
        loadRecentEntries()
        if printToTerminal {
            fputs("[Neutrony] Log service started. Log file: \(Self.logFileURL.path)\n", stderr)
        }
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

        // Print to terminal (stderr) when running via `make run` or `swift run`
        if printToTerminal {
            fputs("[Neutrony] \(entry.displayLine)\n", stderr)
        }

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

        // Batch update in-memory entries to reduce main thread work
        pendingLock.lock()
        pendingEntries.append(entry)
        pendingLock.unlock()
        scheduleFlush()
    }

    /// Schedule a batched flush of pending entries to the main thread
    private func scheduleFlush() {
        // Only schedule if there isn't already a pending flush
        // This ensures flushes happen regularly even when logs arrive rapidly
        pendingLock.lock()
        let alreadyScheduled = flushWorkItem != nil
        pendingLock.unlock()

        guard !alreadyScheduled else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingEntries()
        }

        pendingLock.lock()
        flushWorkItem = workItem
        pendingLock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + flushInterval,
            execute: workItem
        )
    }

    /// Flush pending entries to the published array
    private func flushPendingEntries() {
        pendingLock.lock()
        let entriesToAdd = pendingEntries
        pendingEntries.removeAll()
        flushWorkItem = nil  // Clear so next log schedules a new flush
        pendingLock.unlock()

        guard !entriesToAdd.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries.append(contentsOf: entriesToAdd)
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
        ).first ?? FileManager.default.temporaryDirectory
        let dir = appSupport
            .appendingPathComponent("Neutrony", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var logFileURL: URL {
        logDirectory.appendingPathComponent("neutrony.log")
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
        // Close the current handle before moving the file
        logFileHandle?.closeFile()
        logFileHandle = nil

        let url = Self.logFileURL
        let archiveURL = Self.logDirectory.appendingPathComponent("neutrony.log.1")
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
