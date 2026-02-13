import Foundation
import Security

/// Manages secure storage of credentials in the macOS Keychain.
final class KeychainService {

    static let shared = KeychainService()

    private let serviceName = "com.protonbackup.app"

    private init() {}

    // MARK: - Public API

    /// Store Proton Drive credentials securely.
    func storeCredentials(username: String, password: String) throws {
        try storeString(password, forKey: "proton-password", account: username)
        try storeString(username, forKey: "proton-username", account: "default")
    }

    /// Store a session token (UID + access token + refresh token).
    func storeSession(uid: String, accessToken: String, refreshToken: String) throws {
        try storeString(uid, forKey: "proton-uid", account: "default")
        try storeString(accessToken, forKey: "proton-access-token", account: "default")
        try storeString(refreshToken, forKey: "proton-refresh-token", account: "default")
    }

    /// Retrieve stored username.
    func getUsername() -> String? {
        getString(forKey: "proton-username", account: "default")
    }

    /// Retrieve stored password.
    func getPassword() -> String? {
        guard let username = getUsername() else { return nil }
        return getString(forKey: "proton-password", account: username)
    }

    /// Retrieve stored session UID.
    func getSessionUID() -> String? {
        getString(forKey: "proton-uid", account: "default")
    }

    /// Retrieve stored access token.
    func getAccessToken() -> String? {
        getString(forKey: "proton-access-token", account: "default")
    }

    /// Retrieve stored refresh token.
    func getRefreshToken() -> String? {
        getString(forKey: "proton-refresh-token", account: "default")
    }

    /// Remove all stored credentials and session data.
    func clearAll() {
        let keys = [
            "proton-username", "proton-password",
            "proton-uid", "proton-access-token", "proton-refresh-token"
        ]
        for key in keys {
            deleteItem(forKey: key)
        }
    }

    /// Check if credentials are stored.
    var hasCredentials: Bool {
        getUsername() != nil && (getPassword() != nil || getAccessToken() != nil)
    }

    // MARK: - Private helpers

    private func storeString(_ value: String, forKey key: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete existing item first
        deleteItem(forKey: key, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrLabel as String: key,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status: status)
        }
    }

    private func getString(forKey key: String, account: String? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrLabel as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let account {
            query[kSecAttrAccount as String] = account
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func deleteItem(forKey key: String, account: String? = nil) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrLabel as String: key
        ]

        if let account {
            query[kSecAttrAccount as String] = account
        }

        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

enum KeychainError: LocalizedError {
    case encodingFailed
    case storeFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode value for Keychain storage."
        case .storeFailed(let status):
            return "Keychain store failed with status \(status)."
        }
    }
}
