import Foundation
import MC1Services
import OSLog

/// Performs challenge-response verification of a contributor's identity
/// using the MeshCore device's Ed25519 signing capability.
actor ContributorVerificationService {
    private static let logger = Logger(subsystem: "com.mc1", category: "ContributorVerification")

    private let session: URLSession
    private static let serverBaseURL = SurveyUploadService.serverBaseURL
    private static let apiKey = SurveyUploadService.apiKey

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - DTOs

    private struct ChallengeRequest: Codable {
        let publicKey: String
    }

    private struct ChallengeResponse: Codable {
        let nonce: String
        let expiresIn: Int
    }

    private struct VerifyRequest: Codable {
        let publicKey: String
        let nonce: String
        let signature: String
    }

    private struct VerifyResponse: Codable {
        let verified: Bool
        let contributorID: String
        let migrated: Bool?
        let newContributorID: String?
        let authToken: String?
        let authTokenExpires: String?
    }

    /// Result of a verification attempt, including migration info.
    struct VerificationResult {
        let verified: Bool
        /// The new public-key-based contributor ID if migration occurred.
        let newContributorID: String?
        /// Short-lived auth token for self-service API calls.
        let authToken: String?
        /// ISO 8601 expiry for the auth token.
        let authTokenExpires: String?
    }

    // MARK: - Verification

    enum VerificationError: LocalizedError {
        case noPublicKey
        case signingFailed(String)
        case networkError(String)
        case serverError(String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .noPublicKey: return "Could not get device public key"
            case .signingFailed(let msg): return "Signing failed: \(msg)"
            case .networkError(let msg): return "Network error: \(msg)"
            case .serverError(let msg): return "Server error: \(msg)"
            case .verificationFailed: return "Signature verification failed on server"
            }
        }
    }

    /// Perform the full challenge-response verification flow.
    /// 1. Get the device's public key via settingsService.getSelfInfo()
    /// 2. POST /challenge with the public key → get nonce
    /// 3. Sign the nonce using settingsService.sign()
    /// 4. POST /verify with publicKey + nonce + signature
    func verify(
        settingsService: SettingsService,
        contributorID: String
    ) async throws -> VerificationResult {
        // Step 1: Get device public key
        Self.logger.info("Starting verification for contributor \(contributorID.prefix(8))...")

        let selfInfo: MeshCore.SelfInfo
        do {
            selfInfo = try await settingsService.getSelfInfo()
        } catch {
            throw VerificationError.noPublicKey
        }

        let publicKey = selfInfo.publicKey
        guard publicKey.count == 32 else {
            throw VerificationError.noPublicKey
        }

        let publicKeyBase64 = publicKey.base64EncodedString()

        // Step 2: Request challenge nonce from server
        Self.logger.info("Requesting challenge nonce...")

        let challengeURL = Self.serverBaseURL
            .appendingPathComponent("contributor")
            .appendingPathComponent(contributorID)
            .appendingPathComponent("challenge")

        var challengeReq = URLRequest(url: challengeURL)
        challengeReq.httpMethod = "POST"
        challengeReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        challengeReq.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
        challengeReq.httpBody = try JSONEncoder().encode(ChallengeRequest(publicKey: publicKeyBase64))

        let (challengeData, challengeResp) = try await session.data(for: challengeReq)
        guard let httpResp = challengeResp as? HTTPURLResponse else {
            throw VerificationError.networkError("Invalid response")
        }
        guard httpResp.statusCode == 200 else {
            let body = String(data: challengeData, encoding: .utf8) ?? ""
            throw VerificationError.serverError("Challenge failed (\(httpResp.statusCode)): \(body)")
        }

        let challenge = try JSONDecoder().decode(ChallengeResponse.self, from: challengeData)

        guard let nonceData = Data(base64Encoded: challenge.nonce), nonceData.count == 32 else {
            throw VerificationError.serverError("Invalid nonce from server")
        }

        // Step 3: Sign the nonce using the device's private key
        Self.logger.info("Signing nonce with device key...")

        let signature: Data
        do {
            signature = try await settingsService.sign(nonceData)
        } catch {
            throw VerificationError.signingFailed(error.localizedDescription)
        }

        guard signature.count == 64 else {
            throw VerificationError.signingFailed("Unexpected signature length: \(signature.count)")
        }

        // Step 4: Send verification to server
        Self.logger.info("Submitting verification...")

        let verifyURL = Self.serverBaseURL
            .appendingPathComponent("contributor")
            .appendingPathComponent(contributorID)
            .appendingPathComponent("verify")

        var verifyReq = URLRequest(url: verifyURL)
        verifyReq.httpMethod = "POST"
        verifyReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        verifyReq.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
        verifyReq.httpBody = try JSONEncoder().encode(VerifyRequest(
            publicKey: publicKeyBase64,
            nonce: challenge.nonce,
            signature: signature.base64EncodedString()
        ))

        let (verifyData, verifyResp) = try await session.data(for: verifyReq)
        guard let httpVerifyResp = verifyResp as? HTTPURLResponse else {
            throw VerificationError.networkError("Invalid response")
        }
        guard httpVerifyResp.statusCode == 200 else {
            let body = String(data: verifyData, encoding: .utf8) ?? ""
            throw VerificationError.serverError("Verify failed (\(httpVerifyResp.statusCode)): \(body)")
        }

        let result = try JSONDecoder().decode(VerifyResponse.self, from: verifyData)

        if result.verified {
            if result.migrated == true, let newID = result.newContributorID {
                Self.logger.info("Verification succeeded — migrated to \(newID.prefix(16))...")
            } else {
                Self.logger.info("Verification succeeded for contributor \(contributorID.prefix(8))...")
            }
        } else {
            Self.logger.warning("Verification returned false for contributor \(contributorID.prefix(8))...")
        }

        return VerificationResult(
            verified: result.verified,
            newContributorID: result.newContributorID,
            authToken: result.authToken,
            authTokenExpires: result.authTokenExpires
        )
    }

    // MARK: - Keychain Auth Token Storage

    private static let keychainService = "com.pocketmesh.community"
    private static let keychainTokenAccount = "contributorAuthToken"
    private static let keychainTokenExpiresAccount = "contributorAuthTokenExpires"

    /// Store the auth token and its expiry in the Keychain.
    nonisolated func storeAuthToken(_ token: String, expires: String?) {
        storeKeychainValue(token, account: Self.keychainTokenAccount)
        if let expires {
            storeKeychainValue(expires, account: Self.keychainTokenExpiresAccount)
        }
        Self.logger.info("Stored auth token in keychain")
    }

    /// Retrieve the auth token from the Keychain, or nil if expired/missing.
    nonisolated func getAuthToken() -> String? {
        guard let token = retrieveKeychainValue(account: Self.keychainTokenAccount) else {
            return nil
        }
        // Check expiry
        if let expires = retrieveKeychainValue(account: Self.keychainTokenExpiresAccount) {
            let now = ISO8601DateFormatter().string(from: Date())
            if now >= expires {
                Self.logger.info("Auth token expired")
                return nil
            }
        }
        return token
    }

    private nonisolated func storeKeychainValue(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            Self.logger.error("Failed to store keychain value for \(account): \(status)")
        }
    }

    private nonisolated func retrieveKeychainValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }
}
