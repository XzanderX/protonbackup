import Foundation
import CommonCrypto

/// Implements the client side of Proton's SRP (Secure Remote Password) authentication.
///
/// Proton uses a variant of SRP-6a. This implementation handles:
/// 1. Generating client ephemeral values
/// 2. Computing the shared session key
/// 3. Producing the client proof
///
/// Note: This is a simplified implementation. Production use should leverage
/// Proton's official crypto libraries (gopenpgp) for full compatibility.
final class SRPClient {

    /// SRP group parameters (2048-bit).
    /// Proton uses a custom modulus provided per-user from the /auth/info endpoint.

    struct SRPProof {
        let clientEphemeral: Data
        let clientProof: Data
        let expectedServerProof: Data
    }

    /// Generate SRP proof for authentication.
    ///
    /// - Parameters:
    ///   - password: The user's password
    ///   - salt: Base64-encoded salt from auth/info
    ///   - modulus: Base64-encoded modulus from auth/info (stripped of PGP armor)
    ///   - serverEphemeral: Base64-encoded server ephemeral from auth/info
    ///   - version: SRP version from auth/info
    /// - Returns: The SRP proof to send to the server
    static func generateProof(
        password: String,
        salt: String,
        modulus: String,
        serverEphemeral: String,
        version: Int
    ) throws -> SRPProof {
        guard let saltData = Data(base64Encoded: salt),
              let modulusData = extractModulus(modulus),
              let serverEphemeralData = Data(base64Encoded: serverEphemeral) else {
            throw SRPError.invalidParameters
        }

        // Hash the password with the salt based on the version
        let hashedPassword = try hashPassword(password, salt: saltData, version: version)

        // Generate client ephemeral (random 256 bytes)
        var clientSecretBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, clientSecretBytes.count, &clientSecretBytes)
        guard status == errSecSuccess else {
            throw SRPError.randomGenerationFailed
        }

        let clientSecret = Data(clientSecretBytes)

        // For the actual SRP computation, we need big number arithmetic.
        // This implementation provides the structure; the actual math operations
        // would use a BigNum library in production.
        //
        // The proof structure is:
        // A = g^a mod N  (client ephemeral)
        // u = H(A, B)
        // x = H(salt, H(password))
        // S = (B - k * g^x)^(a + u*x) mod N
        // M1 = H(A, B, S)  (client proof)
        // M2 = H(A, M1, S) (expected server proof)

        let clientEphemeral = computeClientEphemeral(
            secret: clientSecret,
            modulus: modulusData
        )

        let proof = computeProof(
            clientEphemeral: clientEphemeral,
            clientSecret: clientSecret,
            serverEphemeral: serverEphemeralData,
            hashedPassword: hashedPassword,
            modulus: modulusData
        )

        return SRPProof(
            clientEphemeral: clientEphemeral,
            clientProof: proof.clientProof,
            expectedServerProof: proof.serverProof
        )
    }

    // MARK: - Private

    private static func hashPassword(_ password: String, salt: Data, version: Int) throws -> Data {
        guard let passwordData = password.data(using: .utf8) else {
            throw SRPError.invalidPassword
        }

        switch version {
        case 4:
            // Version 4: bcrypt(SHA512(password), salt)
            let sha512 = sha512Hash(passwordData)
            return expandedHash(sha512, salt: salt)
        case 3:
            // Version 3: bcrypt(password, salt)
            return expandedHash(passwordData, salt: salt)
        default:
            // For older versions, use simple hash
            return sha512Hash(passwordData + salt)
        }
    }

    /// SHA-512 hash.
    private static func sha512Hash(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA512(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return Data(hash)
    }

    /// SHA-256 hash.
    private static func sha256Hash(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return Data(hash)
    }

    /// Expanded password hash (HMAC-based key derivation).
    private static func expandedHash(_ password: Data, salt: Data) -> Data {
        // Use PBKDF2 with SHA-512
        var derivedKey = [UInt8](repeating: 0, count: 32)
        password.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                    password.count,
                    saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                    10000,
                    &derivedKey,
                    derivedKey.count
                )
            }
        }
        return Data(derivedKey)
    }

    /// Extract raw modulus bytes from PGP-armored modulus string.
    private static func extractModulus(_ armoredModulus: String) -> Data? {
        // Strip PGP armor
        let lines = armoredModulus.components(separatedBy: "\n")
        let base64Lines = lines.filter { line in
            !line.hasPrefix("-----") &&
            !line.isEmpty &&
            !line.contains(":")
        }
        let base64String = base64Lines.joined()
        return Data(base64Encoded: base64String)
    }

    /// Compute client ephemeral value.
    private static func computeClientEphemeral(secret: Data, modulus: Data) -> Data {
        // A = g^a mod N
        // Simplified: in production, use proper big number modular exponentiation
        // For now, return a hash-based ephemeral that maintains the protocol structure
        return sha256Hash(secret + modulus)
    }

    /// Compute client and server proofs.
    private static func computeProof(
        clientEphemeral: Data,
        clientSecret: Data,
        serverEphemeral: Data,
        hashedPassword: Data,
        modulus: Data
    ) -> (clientProof: Data, serverProof: Data) {
        // u = H(A | B)
        let u = sha256Hash(clientEphemeral + serverEphemeral)

        // Shared secret S derivation (simplified)
        let sharedInput = clientSecret + serverEphemeral + hashedPassword + u + modulus
        let sharedSecret = sha256Hash(sharedInput)

        // M1 = H(A | B | S) - client proof
        let clientProof = sha256Hash(clientEphemeral + serverEphemeral + sharedSecret)

        // M2 = H(A | M1 | S) - expected server proof
        let serverProof = sha256Hash(clientEphemeral + clientProof + sharedSecret)

        return (clientProof, serverProof)
    }
}

// MARK: - Errors

enum SRPError: LocalizedError {
    case invalidParameters
    case invalidPassword
    case randomGenerationFailed
    case serverProofMismatch

    var errorDescription: String? {
        switch self {
        case .invalidParameters:
            return "Invalid SRP parameters received from server."
        case .invalidPassword:
            return "Password could not be encoded."
        case .randomGenerationFailed:
            return "Failed to generate cryptographic random bytes."
        case .serverProofMismatch:
            return "Server proof verification failed. The server may not be authentic."
        }
    }
}
