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

        // Syncing badge - blue circular arrows
        if let syncingImage = createBadgeImage(
            systemName: "arrow.triangle.2.circlepath",
            color: .systemBlue
        ) {
            controller.setBadgeImage(syncingImage, label: "Syncing", forBadgeIdentifier: BadgeIdentifier.syncing.rawValue)
        }

        // Downloading badge - blue down arrow
        if let downloadingImage = createBadgeImage(
            systemName: "arrow.down.circle.fill",
            color: .systemBlue
        ) {
            controller.setBadgeImage(downloadingImage, label: "Downloading", forBadgeIdentifier: BadgeIdentifier.downloading.rawValue)
        }

        // Complete badge - green checkmark
        if let completeImage = createBadgeImage(
            systemName: "checkmark.circle.fill",
            color: .systemGreen
        ) {
            controller.setBadgeImage(completeImage, label: "Backed Up", forBadgeIdentifier: BadgeIdentifier.complete.rawValue)
        }

        // Error badge - red X
        if let errorImage = createBadgeImage(
            systemName: "xmark.circle.fill",
            color: .systemRed
        ) {
            controller.setBadgeImage(errorImage, label: "Error", forBadgeIdentifier: BadgeIdentifier.error.rawValue)
        }

        // Pending badge - gray clock
        if let pendingImage = createBadgeImage(
            systemName: "clock.fill",
            color: .systemGray
        ) {
            controller.setBadgeImage(pendingImage, label: "Pending", forBadgeIdentifier: BadgeIdentifier.pending.rawValue)
        }

        NSLog("FinderSync: Badge images registered")
    }

    private func createBadgeImage(systemName: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return nil
        }

        // Create a colored version
        let coloredImage = NSImage(size: image.size, flipped: false) { rect in
            color.set()
            image.draw(in: rect)
            return true
        }

        coloredImage.isTemplate = false
        return coloredImage
    }

    // MARK: - Directory Monitoring

    private func updateMonitoredDirectories() {
        let directories = badgeManager.getMonitoredDirectories()

        if directories.isEmpty {
            // Default to common backup locations
            var defaultDirs: Set<URL> = []

            // Check for Proton Drive folder
            let cloudStorage = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/CloudStorage")

            if let contents = try? FileManager.default.contentsOfDirectory(
                at: cloudStorage,
                includingPropertiesForKeys: nil
            ) {
                for item in contents where item.lastPathComponent.hasPrefix("ProtonDrive-") {
                    defaultDirs.insert(item)
                }
            }

            // Add /Volumes for backup destinations
            defaultDirs.insert(URL(fileURLWithPath: "/Volumes"))

            FIFinderSyncController.default().directoryURLs = defaultDirs
            NSLog("FinderSync: Monitoring default directories: \(defaultDirs)")
        } else {
            FIFinderSyncController.default().directoryURLs = Set(directories)
            NSLog("FinderSync: Monitoring configured directories: \(directories)")
        }
    }

    // MARK: - Notification Handling

    @objc private func handleBadgeUpdate(_ notification: Notification) {
        // Reload state
        badgeManager.loadState()

        // Update monitored directories if changed
        updateMonitoredDirectories()

        // If a specific path was updated, refresh just that item
        if let path = notification.userInfo?["path"] as? String {
            let url = URL(fileURLWithPath: path)
            FIFinderSyncController.default().setBadgeIdentifier(
                badgeManager.badge(for: path).rawValue,
                for: url
            )
        }

        NSLog("FinderSync: Badge update received")
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

        if badge != .none {
            FIFinderSyncController.default().setBadgeIdentifier(badge.rawValue, for: url)
        }
    }

    // MARK: - Toolbar Item (optional)

    override var toolbarItemName: String {
        return "Proton Backup"
    }

    override var toolbarItemToolTip: String {
        return "Proton Backup Status"
    }

    override var toolbarItemImage: NSImage {
        return NSImage(systemSymbolName: "externaldrive.badge.checkmark", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.folderName)!
    }
}
