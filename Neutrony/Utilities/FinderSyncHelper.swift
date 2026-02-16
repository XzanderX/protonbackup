import Foundation
import AppKit

/// Helper for managing the FinderSync extension state.
final class FinderSyncHelper {

    static let shared = FinderSyncHelper()

    /// Bundle identifier of the FinderSync extension
    private let extensionBundleID = "com.neutrony.app.FinderSync"

    private init() {}

    // MARK: - Extension Status

    /// Check if the FinderSync extension is enabled.
    /// Note: There's no public API to check this directly, so we use a heuristic.
    func isExtensionEnabled() -> Bool {
        // Check if the extension process is running
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if app.bundleIdentifier == extensionBundleID {
                return true
            }
        }

        // Also check via pluginkit (extension may be enabled but not running)
        let result = runPluginKit(arguments: ["-m", "-i", extensionBundleID])
        return result.contains(extensionBundleID) && !result.contains("no matches")
    }

    /// Check if the extension is available (bundled with the app).
    func isExtensionAvailable() -> Bool {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL else {
            return false
        }
        let extensionURL = pluginsURL.appendingPathComponent("FinderSyncExtension.appex")
        return FileManager.default.fileExists(atPath: extensionURL.path)
    }

    // MARK: - System Settings

    /// Open System Settings to the Extensions pane.
    func openExtensionsSettings() {
        // macOS 13+ uses System Settings with different URL scheme
        if #available(macOS 13.0, *) {
            // Try the new System Settings URL
            if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                NSWorkspace.shared.open(url)
                return
            }
        }

        // Fallback: open System Preferences Extensions pane
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.extensions") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open Finder Extensions specifically (macOS 13+).
    func openFinderExtensionsSettings() {
        // The most direct path on macOS 13+
        if #available(macOS 13.0, *) {
            // Open Privacy & Security > Extensions
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
                NSWorkspace.shared.open(url)
                return
            }
        }

        // Fallback to general extensions
        openExtensionsSettings()
    }

    // MARK: - Extension Management

    /// Request to enable the extension by opening System Settings.
    /// Returns instructions for the user.
    func requestEnableExtension() -> String {
        openFinderExtensionsSettings()

        return """
        To enable Finder progress badges:

        1. In the window that opened, find "Added Extensions"
        2. Click on "Finder"
        3. Enable "Proton Backup Finder Extension"

        This allows the app to show sync progress directly in Finder.
        """
    }

    // MARK: - Private Helpers

    private func runPluginKit(arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
