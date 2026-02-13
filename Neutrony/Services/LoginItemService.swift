import Foundation
import ServiceManagement

/// Manages the app's login item status using the modern ServiceManagement API.
final class LoginItemService {

    static let shared = LoginItemService()

    private init() {}

    // MARK: - Public API

    /// Whether the app is currently registered as a login item.
    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return false
        }
    }

    /// Enable or disable start-at-login.
    func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    /// Synchronize the login item state with the config value.
    func syncWithConfig(_ config: BackupConfiguration) {
        do {
            if config.startAtLogin != isEnabled {
                try setEnabled(config.startAtLogin)
            }
        } catch {
            // Log but don't throw - this is a non-critical feature
            LogService.shared.log(.warning, category: .app,
                                  message: "Failed to update login item: \(error.localizedDescription)")
        }
    }
}
