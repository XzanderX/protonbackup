import Cocoa
import FinderSync

/// FinderSync extension that displays badge icons on files during backup operations.
class FinderSync: FIFinderSync {

    private let badgeManager = BadgeStateManager.shared

    override init() {
        super.init()

        // Load initial state
        badgeManager.loadState()

        // Set up monitored directories
        updateMonitoredDirectories()

        // Register badge images
        registerBadgeImages()

        // Listen for badge update notifications
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleBadgeUpdate(_:)),
            name: NSNotification.Name(BadgeStateManager.badgeUpdateNotification),
            object: nil
        )

        NSLog("FinderSync: Extension initialized")
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Badge Registration

    private func registerBadgeImages() {
        let controller = FIFinderSyncController.default()

        // Syncing badge - blue dot with white sync arrows
        if let syncingImage = createBadgeImage(
            systemName: "arrow.2.circlepath",
            color: .systemBlue
        ) {
            controller.setBadgeImage(syncingImage, label: "Syncing", forBadgeIdentifier: BadgeIdentifier.syncing.rawValue)
        }

        // Downloading badge - blue dot with white down arrow
        if let downloadingImage = createBadgeImage(
            systemName: "arrow.down",
            color: .systemBlue
        ) {
            controller.setBadgeImage(downloadingImage, label: "Downloading", forBadgeIdentifier: BadgeIdentifier.downloading.rawValue)
        }

        // Complete badge - green dot with white checkmark
        if let completeImage = createBadgeImage(
            systemName: "checkmark",
            color: .systemGreen
        ) {
            controller.setBadgeImage(completeImage, label: "Backed Up", forBadgeIdentifier: BadgeIdentifier.complete.rawValue)
        }

        // Error badge - red dot with white X
        if let errorImage = createBadgeImage(
            systemName: "xmark",
            color: .systemRed
        ) {
            controller.setBadgeImage(errorImage, label: "Error", forBadgeIdentifier: BadgeIdentifier.error.rawValue)
        }

        // Pending badge - gray dot with white clock
        if let pendingImage = createBadgeImage(
            systemName: "clock",
            color: .systemGray
        ) {
            controller.setBadgeImage(pendingImage, label: "Pending", forBadgeIdentifier: BadgeIdentifier.pending.rawValue)
        }

        NSLog("FinderSync: Badge images registered")
    }

    private func createBadgeImage(systemName: String, color: NSColor) -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)

        guard let symbolImage = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return nil
        }

        let badgeImage = NSImage(size: size, flipped: false) { rect in
            // Draw filled circle background
            let circleRect = rect.insetBy(dx: 1, dy: 1)
            let circlePath = NSBezierPath(ovalIn: circleRect)
            color.setFill()
            circlePath.fill()

            // Create white-tinted version of symbol
            let symbolSize = symbolImage.size
            let symbolRect = NSRect(
                x: (rect.width - symbolSize.width) / 2,
                y: (rect.height - symbolSize.height) / 2,
                width: symbolSize.width,
                height: symbolSize.height
            )

            // Use template mode to draw in white
            let templateImage = symbolImage.copy() as! NSImage
            templateImage.isTemplate = true

            NSGraphicsContext.saveGraphicsState()
            NSColor.white.set()
            templateImage.draw(in: symbolRect)
            NSGraphicsContext.restoreGraphicsState()

            return true
        }

        badgeImage.isTemplate = false
        return badgeImage
    }

    // MARK: - Directory Monitoring

    private func updateMonitoredDirectories() {
        let directories = badgeManager.getMonitoredDirectories()

        if directories.isEmpty {
            // No directories configured yet - monitor /Volumes so we're ready
            // when the main app sets a backup destination
            let defaultDirs: Set<URL> = [URL(fileURLWithPath: "/Volumes")]
            FIFinderSyncController.default().directoryURLs = defaultDirs
            NSLog("FinderSync: Waiting for backup destination, monitoring /Volumes")
        } else {
            // Monitor only the configured backup destination
            FIFinderSyncController.default().directoryURLs = Set(directories)
            NSLog("FinderSync: Monitoring backup destination: \(directories.map { $0.path })")
        }
    }

    // MARK: - Notification Handling

    @objc private func handleBadgeUpdate(_ notification: Notification) {
        // Reload state from disk
        badgeManager.loadState()

        // Update monitored directories if changed
        updateMonitoredDirectories()

        // Re-apply badges for all known files so Finder picks up changes
        let allStates = badgeManager.badgeStates
        let controller = FIFinderSyncController.default()
        for (path, state) in allStates {
            if state.badge != .none {
                controller.setBadgeIdentifier(state.badge.rawValue, for: URL(fileURLWithPath: path))
            }
        }

        NSLog("FinderSync: Badge update received, refreshed \(allStates.count) badges")
    }

    // MARK: - FIFinderSync Protocol

    override func beginObservingDirectory(at url: URL) {
        NSLog("FinderSync: Begin observing \(url.path)")
    }

    override func endObservingDirectory(at url: URL) {
        NSLog("FinderSync: End observing \(url.path)")
    }

    override func requestBadgeIdentifier(for url: URL) {
        let badge = badgeManager.badge(for: url.path)
        // Always set the identifier — passing "" clears any stale badge
        FIFinderSyncController.default().setBadgeIdentifier(badge.rawValue, for: url)
    }

    // MARK: - Toolbar Item (optional)

    override var toolbarItemName: String {
        return "Neutrony"
    }

    override var toolbarItemToolTip: String {
        return "Neutrony Status"
    }

    override var toolbarItemImage: NSImage {
        return NSImage(systemSymbolName: "externaldrive.badge.checkmark", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.folderName)!
    }
}
