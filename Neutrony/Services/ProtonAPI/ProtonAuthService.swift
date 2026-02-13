import Foundation

/// Handles authentication with Proton's API using SRP protocol.
final class ProtonAuthService {

    static let shared = ProtonAuthService()

    private let baseURL = "https://mail.proton.me/api"
    private let session = URLSession.shared
    private let keychain = KeychainService.shared

    private init() {}

    // MARK: - Public API

    /// Authenticate with username and password using Proton's SRP protocol.
    /// Returns a session on success, stores tokens in Keychain.
    func authenticate(username: String, password: String) async throws -> ProtonSession {
        // Step 1: Get auth info (salt, modulus, server ephemeral)
        let authInfo = try await getAuthInfo(username: username)

        guard let salt = authInfo.salt,
              let modulus = authInfo.modulus,
              let serverEphemeral = authInfo.serverEphemeral,
              let version = authInfo.version,
              let srpSession = authInfo.srpSession else {
            throw ProtonAuthError.invalidAuthInfo
        }

        // Step 2: Generate SRP proof
        let proof = try SRPClient.generateProof(
            password: password,
            salt: salt,
            modulus: modulus,
            serverEphemeral: serverEphemeral,
            version: version
        )

        // Step 3: Send auth request
        let authResponse = try await performAuth(
            username: username,
            clientEphemeral: proof.clientEphemeral,
            clientProof: proof.clientProof,
            srpSession: srpSession
        )

        guard authResponse.code == 1000,
              let uid = authResponse.uid,
              let accessToken = authResponse.accessToken,
              let refreshToken = authResponse.refreshToken else {
            let errorMessage = authResponse.error ?? "Authentication failed (code: \(authResponse.code))"
            throw ProtonAuthError.authenticationFailed(errorMessage)
        }

        // Step 4: Verify server proof
        if let serverProof = authResponse.serverProof,
           let serverProofData = Data(base64Encoded: serverProof) {
            if serverProofData != proof.expectedServerProof {
                throw SRPError.serverProofMismatch
            }
        }

        // Step 5: Store session
        let protonSession = ProtonSession(
            uid: uid,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: authResponse.tokenType ?? "Bearer",
            scopes: authResponse.scopes ?? []
        )

        try keychain.storeCredentials(username: username, password: password)
        try keychain.storeSession(
            uid: uid,
            accessToken: accessToken,
            refreshToken: refreshToken
        )

        return protonSession
    }

    /// Refresh the access token using the stored refresh token.
    func refreshSession() async throws -> ProtonSession {
        guard let uid = keychain.getSessionUID(),
              let refreshToken = keychain.getRefreshToken() else {
            throw ProtonAuthError.noStoredSession
        }

        let body: [String: Any] = [
            "UID": uid,
            "RefreshToken": refreshToken,
            "ResponseType": "token",
            "GrantType": "refresh_token",
            "RedirectURI": "https://protonmail.ch"
        ]

        var request = URLRequest(url: URL(string: "\(baseURL)/auth/refresh")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(uid, forHTTPHeaderField: "x-pm-uid")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ProtonAuthError.refreshFailed
        }

        let refreshResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)

        guard refreshResponse.code == 1000,
              let newAccessToken = refreshResponse.accessToken,
              let newRefreshToken = refreshResponse.refreshToken else {
            throw ProtonAuthError.refreshFailed
        }

        try keychain.storeSession(
            uid: uid,
            accessToken: newAccessToken,
            refreshToken: newRefreshToken
        )

        return ProtonSession(
            uid: uid,
            accessToken: newAccessToken,
            refreshToken: newRefreshToken,
            tokenType: refreshResponse.tokenType ?? "Bearer",
            scopes: []
        )
    }

    /// Test if we can reach the Proton API and have valid credentials.
    func testConnection() async throws -> Bool {
        guard let uid = keychain.getSessionUID(),
              let accessToken = keychain.getAccessToken() else {
            return false
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/users")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(uid, forHTTPHeaderField: "x-pm-uid")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }

        if httpResponse.statusCode == 401 {
            // Try to refresh
            _ = try await refreshSession()
            return true
        }

        if httpResponse.statusCode == 200 {
            // Verify response has correct code
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["Code"] as? Int {
                return code == 1000
            }
        }

        return false
    }

    /// Log out and clear stored session.
    func logout() async {
        if let uid = keychain.getSessionUID(),
           let accessToken = keychain.getAccessToken() {
            // Best-effort server-side logout
            var request = URLRequest(url: URL(string: "\(baseURL)/auth/v4")!)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(uid, forHTTPHeaderField: "x-pm-uid")
            _ = try? await session.data(for: request)
        }

        keychain.clearAll()
    }

    /// Check if we have a stored session.
    var hasSession: Bool {
        keychain.getSessionUID() != nil && keychain.getAccessToken() != nil
    }

    // MARK: - Private

    private func getAuthInfo(username: String) async throws -> AuthInfoResponse {
        let body = ["Username": username]

        var request = URLRequest(url: URL(string: "\(baseURL)/auth/info")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ProtonAuthError.networkError
        }

        return try JSONDecoder().decode(AuthInfoResponse.self, from: data)
    }

    private func performAuth(
        username: String,
        clientEphemeral: Data,
        clientProof: Data,
        srpSession: String
    ) async throws -> AuthResponse {
        let body: [String: Any] = [
            "Username": username,
            "ClientEphemeral": clientEphemeral.base64EncodedString(),
            "ClientProof": clientProof.base64EncodedString(),
            "SRPSession": srpSession
        ]

        var request = URLRequest(url: URL(string: "\(baseURL)/auth/v4")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ProtonAuthError.networkError
        }

        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }
}

// MARK: - Errors

enum ProtonAuthError: LocalizedError {
    case invalidAuthInfo
    case authenticationFailed(String)
    case noStoredSession
    case refreshFailed
    case networkError

    var errorDescription: String? {
        switch self {
        case .invalidAuthInfo:
            return "Received invalid authentication info from server. Please try again."
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .noStoredSession:
            return "No stored session found. Please sign in again."
        case .refreshFailed:
            return "Failed to refresh session. Please sign in again."
        case .networkError:
            return "Cannot reach Proton servers. Check your internet connection."
        }
    }
}
