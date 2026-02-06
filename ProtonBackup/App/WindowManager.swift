import AppKit
import SwiftUI

/// Manages app windows programmatically using NSWindow + NSHostingView.
/// This is necessary because SwiftUI `Window` scenes in a menu bar app
/// don't open automatically and `openWindow(id:)` is only available
/// inside a View context — not at app launch or from an AppDelegate.
@MainActor
final class WindowManager {

    static let shared = WindowManager()

    fileprivate var windows: [String: NSWindow] = [:]

    /// The AppState must be set before any window is opened.
    var appState: AppState?

    private init() {}

    // MARK: - Public API

    func showSetupWizard() {
        showWindow(
            id: "setup-wizard",
            title: "Proton Backup Setup",
            size: NSSize(width: 600, height: 700),
            styleMask: [.titled, .closable],
            content: {
                guard let appState else { return AnyView(EmptyView()) }
                return AnyView(
                    SetupWizardView()
                        .environmentObject(appState)
                )
            }
        )
    }

    func showLogViewer() {
        showWindow(
            id: "log-viewer",
            title: "Backup Log",
            size: NSSize(width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            content: {
                guard let appState else { return AnyView(EmptyView()) }
                return AnyView(
                    LogViewerView()
                        .environmentObject(appState)
                        .frame(minWidth: 500, minHeight: 300)
                )
            }
        )
    }

    func showRestoreHelp() {
        showWindow(
            id: "restore-help",
            title: "Restore Help",
            size: NSSize(width: 500, height: 450),
            styleMask: [.titled, .closable],
            content: {
                guard let appState else { return AnyView(EmptyView()) }
                return AnyView(
                    RestoreHelpView()
                        .environmentObject(appState)
                )
            }
        )
    }

    func showSettings() {
        // Use the native macOS settings window mechanism.
        // NSApp.sendAction for showSettingsWindow works on macOS 13+.
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    func closeWindow(id: String) {
        windows[id]?.close()
        windows.removeValue(forKey: id)
    }

    // MARK: - Private

    private func showWindow(
        id: String,
        title: String,
        size: NSSize,
        styleMask: NSWindow.StyleMask,
        content: () -> AnyView
    ) {
        // If the window already exists and is visible, just bring it forward
        if let existing = windows[id], existing.isVisible {
            activateAndFocus(window: existing)
            return
        }

        let hostingView = NSHostingView(rootView: content())
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.title = title
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = WindowCloseDelegate.shared
        window.acceptsMouseMovedEvents = true

        windows[id] = window

        activateAndFocus(window: window)
    }

    private func activateAndFocus(window: NSWindow) {
        // Temporarily switch to regular activation policy so the app can receive full focus
        // This is necessary for LSUIElement (menu bar) apps to have interactive windows
        NSApp.setActivationPolicy(.regular)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)

        // Switch back to accessory after a short delay to hide from Dock
        // but keep the window interactive
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Only switch back if we still have windows open
            if !self.windows.values.contains(where: { $0.isVisible }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

// MARK: - Window Close Delegate

/// Handles window close events to clean up references.
private class WindowCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowCloseDelegate()

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            let manager = WindowManager.shared
            for (id, w) in manager.windows where w === window {
                manager.windows.removeValue(forKey: id)
                break
            }

            // Switch back to accessory mode when all windows are closed
            // This hides the app from the Dock
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if !manager.windows.values.contains(where: { $0.isVisible }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}

