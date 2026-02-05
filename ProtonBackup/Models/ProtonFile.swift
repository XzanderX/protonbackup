import Foundation

/// Represents a file or folder in the user's Proton Drive.
struct ProtonFile: Identifiable, Codable, Equatable, Hashable {
    /// Unique identifier from the Proton Drive API.
    let id: String

    /// Parent folder ID (nil for root).
    let parentID: String?

    /// Display name of the file or folder.
    let name: String

    /// MIME type (nil for folders).
    let mimeType: String?

    /// File size in bytes (0 for folders).
    let size: Int64

    /// SHA-256 hash of the decrypted content (nil for folders).
    let contentHash: String?

    /// Last modification date.
    let modifiedDate: Date

    /// Creation date.
    let createdDate: Date

    /// Whether this entry is a folder.
    let isFolder: Bool

    /// Relative path from the drive root (computed during tree traversal).
    var relativePath: String?

    var isFile: Bool { !isFolder }
}

/// Represents the state of the local mirror's index, used for incremental sync.
struct MirrorIndex: Codable {
    /// Map of relative path → file metadata at last sync.
    var entries: [String: MirrorEntry]

    /// Timestamp of the last full index build.
    var lastIndexDate: Date?

    static let empty = MirrorIndex(entries: [:], lastIndexDate: nil)

    // MARK: - Persistence

    private static var indexURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("ProtonBackup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mirror-index.json")
    }

    static func load() -> MirrorIndex {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(MirrorIndex.self, from: data) else {
            return .empty
        }
        return index
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(self)
        try data.write(to: Self.indexURL, options: .atomic)
    }
}

/// Metadata for a single file in the mirror index.
struct MirrorEntry: Codable, Equatable {
    let protonFileID: String
    let relativePath: String
    let contentHash: String?
    let size: Int64
    let modifiedDate: Date
    let isFolder: Bool
}

/// Describes a change detected between remote and local states.
enum FileChange: Equatable {
    case added(ProtonFile)
    case modified(ProtonFile)
    case deleted(relativePath: String)

    var description: String {
        switch self {
        case .added(let file):
            return "Added: \(file.relativePath ?? file.name)"
        case .modified(let file):
            return "Modified: \(file.relativePath ?? file.name)"
        case .deleted(let path):
            return "Deleted: \(path)"
        }
    }
}
