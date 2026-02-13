import Foundation
import AppKit

/// Manages security-scoped bookmarks for user-selected folders.
/// This allows the app to re-access folders across launches without re-prompting.
enum BookmarkManager {

    /// Create a security-scoped bookmark from a URL selected via NSOpenPanel.
    static func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Create a read-write bookmark.
    static func createReadWriteBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a bookmark to a URL, starting security-scoped access.
    /// The caller must call `url.stopAccessingSecurityScopedResource()` when done.
    static func resolveBookmark(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return (url, isStale)
    }

    /// Resolve and start accessing a bookmarked resource.
    /// Returns the resolved URL if successful.
    static func startAccessing(bookmark: Data) -> URL? {
        guard let (url, _) = resolveBookmark(bookmark) else { return nil }

        guard url.startAccessingSecurityScopedResource() else {
            return nil
        }

        return url
    }

    /// Stop accessing a security-scoped resource.
    static func stopAccessing(url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// Present an open panel for selecting a folder.
    @MainActor
    static func selectFolder(
        title: String = "Choose Backup Destination",
        message: String = "Select the folder where backups will be stored.",
        canCreateDirectories: Bool = true
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreateDirectories
        panel.showsHiddenFiles = false

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return nil
        }

        return url
    }
}
