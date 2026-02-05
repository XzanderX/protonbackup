import Foundation
import UserNotifications

/// Manages macOS user notifications for backup events.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    /// Notification action identifiers.
    private enum ActionID {
        static let openLog = "OPEN_LOG"
        static let dismiss = "DISMISS"
    }

    /// Notification category identifiers.
    private enum CategoryID {
        static let backupComplete = "BACKUP_COMPLETE"
        static let backupFailed = "BACKUP_FAILED"
        static let destinationConnected = "DESTINATION_CONNECTED"
    }

    /// Called when the user taps "Open Log" in a notification.
    var onOpenLogRequested: (() -> Void)?

    private override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    // MARK: - Public API

    /// Request notification permission.
    func requestPermission() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Send a notification that backup completed successfully.
    func notifyBackupComplete(summary: BackupSummary) {
        let content = UNMutableNotificationContent()
        content.title = "Backup Complete"
        content.body = summary.displayText
        content.categoryIdentifier = CategoryID.backupComplete
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "backup-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request)
    }

    /// Send a notification that backup failed.
    func notifyBackupFailed(errorMessage: String) {
        let content = UNMutableNotificationContent()
        content.title = "Backup Failed"
        content.body = errorMessage
        content.categoryIdentifier = CategoryID.backupFailed
        content.sound = .defaultCritical

        let request = UNNotificationRequest(
            identifier: "backup-failed-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request)
    }

    /// Send a notification that the destination drive was connected.
    func notifyDestinationConnected(volumeName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Backup Drive Connected"
        content.body = "\(volumeName) is now available. Checking for changes…"
        content.categoryIdentifier = CategoryID.destinationConnected
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "destination-connected",
            content: content,
            trigger: nil
        )

        center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == ActionID.openLog {
            DispatchQueue.main.async { [weak self] in
                self?.onOpenLogRequested?()
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Private

    private func registerCategories() {
        let openLogAction = UNNotificationAction(
            identifier: ActionID.openLog,
            title: "Open Log",
            options: .foreground
        )

        let dismissAction = UNNotificationAction(
            identifier: ActionID.dismiss,
            title: "Dismiss",
            options: .destructive
        )

        let completeCategory = UNNotificationCategory(
            identifier: CategoryID.backupComplete,
            actions: [dismissAction],
            intentIdentifiers: []
        )

        let failedCategory = UNNotificationCategory(
            identifier: CategoryID.backupFailed,
            actions: [openLogAction, dismissAction],
            intentIdentifiers: []
        )

        let connectedCategory = UNNotificationCategory(
            identifier: CategoryID.destinationConnected,
            actions: [dismissAction],
            intentIdentifiers: []
        )

        center.setNotificationCategories([completeCategory, failedCategory, connectedCategory])
    }
}
