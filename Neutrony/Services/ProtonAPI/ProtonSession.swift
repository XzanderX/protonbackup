import Foundation

/// Represents an authenticated Proton session.
struct ProtonSession: Codable {
    let uid: String
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let scopes: [String]

    /// Whether the session appears valid (non-empty tokens).
    var isValid: Bool {
        !uid.isEmpty && !accessToken.isEmpty
    }
}

/// Response from the Proton /auth endpoint.
struct AuthResponse: Codable {
    let code: Int
    let uid: String?
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let scopes: [String]?
    let serverProof: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case uid = "UID"
        case accessToken = "AccessToken"
        case refreshToken = "RefreshToken"
        case tokenType = "TokenType"
        case scopes = "Scopes"
        case serverProof = "ServerProof"
        case error = "Error"
    }
}

/// Response from the Proton /auth/info endpoint.
struct AuthInfoResponse: Codable {
    let code: Int
    let modulus: String?
    let serverEphemeral: String?
    let version: Int?
    let salt: String?
    let srpSession: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case modulus = "Modulus"
        case serverEphemeral = "ServerEphemeral"
        case version = "Version"
        case salt = "Salt"
        case srpSession = "SRPSession"
        case error = "Error"
    }
}

/// Response for token refresh.
struct RefreshResponse: Codable {
    let code: Int
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case accessToken = "AccessToken"
        case refreshToken = "RefreshToken"
        case tokenType = "TokenType"
        case error = "Error"
    }
}
