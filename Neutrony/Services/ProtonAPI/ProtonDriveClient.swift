import Foundation

/// Client for the Proton Drive API.
/// Handles listing files, downloading content, and checking for changes.
final class ProtonDriveClient {

    static let shared = ProtonDriveClient()

    private let baseURL = "https://drive.proton.me/api"
    private let urlSession = URLSession.shared
    private let keychain = KeychainService.shared
    private let authService = ProtonAuthService.shared

    private init() {}

    // MARK: - Public API

    /// List all shares accessible to the user.
    func listShares() async throws -> [DriveShare] {
        let data = try await authenticatedRequest(path: "/shares")
        let response = try JSONDecoder().decode(SharesResponse.self, from: data)

        guard response.code == 1000 else {
            throw DriveClientError.apiError(code: response.code, message: "Failed to list shares")
        }

        return response.shares
    }

    /// Get the main share (user's "My files" root).
    func getMainShare() async throws -> DriveShare {
        let shares = try await listShares()
        guard let mainShare = shares.first(where: { $0.type == 1 }) else {
            throw DriveClientError.noMainShare
        }
        return mainShare
    }

    /// List children of a folder.
    func listFolder(shareID: String, linkID: String) async throws -> [DriveLink] {
        var allLinks: [DriveLink] = []
        var page = 0
        let pageSize = 150

        while true {
            let path = "/shares/\(shareID)/folders/\(linkID)/children?Page=\(page)&PageSize=\(pageSize)"
            let data = try await authenticatedRequest(path: path)
            let response = try JSONDecoder().decode(FolderChildrenResponse.self, from: data)

            guard response.code == 1000 else {
                throw DriveClientError.apiError(code: response.code, message: "Failed to list folder")
            }

            allLinks.append(contentsOf: response.links)

            if response.links.count < pageSize {
                break
            }
            page += 1
        }

        return allLinks
    }

    /// Recursively list all files in the drive, building the full tree.
    func listAllFiles(shareID: String, rootLinkID: String) async throws -> [ProtonFile] {
        var allFiles: [ProtonFile] = []
        try await listRecursive(
            shareID: shareID,
            linkID: rootLinkID,
            parentPath: "",
            results: &allFiles
        )
        return allFiles
    }

    /// Download a file's content.
    func downloadFile(shareID: String, linkID: String) async throws -> Data {
        let path = "/shares/\(shareID)/files/\(linkID)/revisions/active"
        let data = try await authenticatedRequest(path: path)
        let response = try JSONDecoder().decode(RevisionResponse.self, from: data)

        guard response.code == 1000, let blocks = response.revision?.blocks else {
            throw DriveClientError.downloadFailed
        }

        // Download all blocks and concatenate
        var fileData = Data()
        for block in blocks.sorted(by: { $0.index < $1.index }) {
            let blockData = try await downloadBlock(url: block.url)
            fileData.append(blockData)
        }

        return fileData
    }

    /// Get share events (changes) since a given event ID.
    func getEvents(shareID: String, sinceEventID: String) async throws -> DriveEventsResponse {
        let path = "/shares/\(shareID)/events/\(sinceEventID)"
        let data = try await authenticatedRequest(path: path)
        return try JSONDecoder().decode(DriveEventsResponse.self, from: data)
    }

    /// Get the latest event ID for a share (used as anchor for polling).
    func getLatestEventID(shareID: String) async throws -> String {
        let path = "/shares/\(shareID)/events/latest"
        let data = try await authenticatedRequest(path: path)
        let response = try JSONDecoder().decode(LatestEventResponse.self, from: data)

        guard response.code == 1000, let eventID = response.eventID else {
            throw DriveClientError.apiError(code: response.code, message: "Failed to get latest event")
        }

        return eventID
    }

    // MARK: - Private

    private func listRecursive(
        shareID: String,
        linkID: String,
        parentPath: String,
        results: inout [ProtonFile]
    ) async throws {
        let children = try await listFolder(shareID: shareID, linkID: linkID)

        for link in children {
            let relativePath = parentPath.isEmpty ? link.name : "\(parentPath)/\(link.name)"

            let file = ProtonFile(
                id: link.linkID,
                parentID: link.parentLinkID,
                name: link.name,
                mimeType: link.mimeType,
                size: link.size ?? 0,
                contentHash: link.hash,
                modifiedDate: Date(timeIntervalSince1970: TimeInterval(link.modifyTime ?? 0)),
                createdDate: Date(timeIntervalSince1970: TimeInterval(link.createTime ?? 0)),
                isFolder: link.type == 1,
                relativePath: relativePath
            )

            results.append(file)

            if link.type == 1 {
                try await listRecursive(
                    shareID: shareID,
                    linkID: link.linkID,
                    parentPath: relativePath,
                    results: &results
                )
            }
        }
    }

    private func authenticatedRequest(path: String) async throws -> Data {
        guard let uid = keychain.getSessionUID(),
              var accessToken = keychain.getAccessToken() else {
            throw DriveClientError.notAuthenticated
        }

        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(uid, forHTTPHeaderField: "x-pm-uid")
        request.timeoutInterval = 30

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DriveClientError.networkError
        }

        // Handle 401 with token refresh
        if httpResponse.statusCode == 401 {
            let newSession = try await authService.refreshSession()
            accessToken = newSession.accessToken

            var retryRequest = request
            retryRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await urlSession.data(for: retryRequest)

            guard let retryHTTP = retryResponse as? HTTPURLResponse,
                  retryHTTP.statusCode == 200 else {
                throw DriveClientError.notAuthenticated
            }
            return retryData
        }

        guard httpResponse.statusCode == 200 else {
            throw DriveClientError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }

    private func downloadBlock(url: String) async throws -> Data {
        guard let blockURL = URL(string: url) else {
            throw DriveClientError.downloadFailed
        }

        let request = URLRequest(url: blockURL)
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DriveClientError.downloadFailed
        }

        return data
    }
}

// MARK: - API Response Models

struct SharesResponse: Codable {
    let code: Int
    let shares: [DriveShare]

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case shares = "Shares"
    }
}

struct DriveShare: Codable {
    let shareID: String
    let type: Int
    let linkID: String
    let volumeID: String

    enum CodingKeys: String, CodingKey {
        case shareID = "ShareID"
        case type = "Type"
        case linkID = "LinkID"
        case volumeID = "VolumeID"
    }
}

struct FolderChildrenResponse: Codable {
    let code: Int
    let links: [DriveLink]

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case links = "Links"
    }
}

struct DriveLink: Codable {
    let linkID: String
    let parentLinkID: String?
    let type: Int
    let name: String
    let mimeType: String?
    let size: Int64?
    let hash: String?
    let modifyTime: Int64?
    let createTime: Int64?

    enum CodingKeys: String, CodingKey {
        case linkID = "LinkID"
        case parentLinkID = "ParentLinkID"
        case type = "Type"
        case name = "Name"
        case mimeType = "MIMEType"
        case size = "Size"
        case hash = "Hash"
        case modifyTime = "ModifyTime"
        case createTime = "CreateTime"
    }
}

struct RevisionResponse: Codable {
    let code: Int
    let revision: DriveRevision?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case revision = "Revision"
    }
}

struct DriveRevision: Codable {
    let blocks: [DriveBlock]?

    enum CodingKeys: String, CodingKey {
        case blocks = "Blocks"
    }
}

struct DriveBlock: Codable {
    let index: Int
    let url: String

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case url = "URL"
    }
}

struct DriveEventsResponse: Codable {
    let code: Int
    let eventID: String?
    let events: [DriveEvent]?
    let more: Bool?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case eventID = "EventID"
        case events = "Events"
        case more = "More"
    }
}

struct DriveEvent: Codable {
    let eventType: Int
    let link: DriveLink?

    enum CodingKeys: String, CodingKey {
        case eventType = "EventType"
        case link = "Link"
    }
}

struct LatestEventResponse: Codable {
    let code: Int
    let eventID: String?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case eventID = "EventID"
    }
}

// MARK: - Errors

enum DriveClientError: LocalizedError {
    case notAuthenticated
    case networkError
    case httpError(statusCode: Int)
    case noMainShare
    case apiError(code: Int, message: String)
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated. Please sign in to Proton Drive."
        case .networkError:
            return "Network error. Check your internet connection."
        case .httpError(let code):
            return "Server returned HTTP \(code)."
        case .noMainShare:
            return "Could not find your Proton Drive. Ensure Proton Drive is enabled for your account."
        case .apiError(_, let message):
            return message
        case .downloadFailed:
            return "Failed to download file from Proton Drive."
        }
    }
}
