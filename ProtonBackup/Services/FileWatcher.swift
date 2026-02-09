import Foundation
import CoreServices

/// Watches the local mirror directory for file system changes using FSEvents.
/// Debounces changes and notifies when the mirror has been modified.
final class FileWatcher {

    private let logService: LogService
    private var stream: FSEventStreamRef?
    private var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 30 // seconds

    /// Called when local changes are detected (after debounce).
    var onChangesDetected: (() -> Void)?

    init(logService: LogService) {
        self.logService = logService
    }

    deinit {
        stopWatching()
    }

    // MARK: - Public API

    /// Start watching the given directory for changes.
    func startWatching(path: String) {
        stopWatching()

        let pathsToWatch = [path] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        guard let stream = FSEventStreamCreate(
            nil,
            fsEventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,    // latency in seconds
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
                                     kFSEventStreamCreateFlagFileEvents |
                                     kFSEventStreamCreateFlagNoDefer)
        ) else {
            logService.log(.error, category: .fileWatcher, message: "Failed to create FSEvent stream for \(path)")
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)

        logService.log(.info, category: .fileWatcher, message: "Watching \(path) for changes")
    }

    /// Stop watching.
    func stopWatching() {
        debounceTimer?.invalidate()
        debounceTimer = nil

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            logService.log(.info, category: .fileWatcher, message: "File watching stopped")
        }
    }

    // MARK: - Internal

    /// Patterns for files to ignore (temp files, system files, partial downloads)
    private static let ignorePatterns: [String] = [
        "/_versions/",
        ".DS_Store",
        ".localized",
        ".tmp",
        ".partial",
        ".download",
        ".crdownload",
        "~$",
        ".~lock.",
        ".swp",
        ".swo",
        "Thumbs.db",
        "desktop.ini",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd"
    ]

    fileprivate func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        // Filter out temp files, system files, and version directories
        let relevantPaths = paths.filter { path in
            !Self.ignorePatterns.contains { pattern in
                path.contains(pattern)
            }
        }

        guard !relevantPaths.isEmpty else { return }

        logService.log(.debug, category: .fileWatcher,
                       message: "\(relevantPaths.count) file changes detected, debouncing…")

        // Debounce: reset timer on each change
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debounceTimer?.invalidate()
            self.debounceTimer = Timer.scheduledTimer(withTimeInterval: self.debounceInterval, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.logService.log(.info, category: .fileWatcher,
                                    message: "Debounce complete, triggering backup check")
                self.onChangesDetected?()
            }
        }
    }
}

// MARK: - C Callback

private func fsEventCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }
    let watcher = Unmanaged<FileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

    // Extract paths from CFArray
    let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    var paths: [String] = []
    var flags: [FSEventStreamEventFlags] = []

    for i in 0..<numEvents {
        if let cfPath = CFArrayGetValueAtIndex(cfPaths, i) {
            let path = Unmanaged<CFString>.fromOpaque(cfPath).takeUnretainedValue() as String
            paths.append(path)
            flags.append(eventFlags[i])
        }
    }

    watcher.handleEvents(paths: paths, flags: flags)
}
