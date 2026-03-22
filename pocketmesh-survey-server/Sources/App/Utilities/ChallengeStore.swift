import Foundation

/// In-memory store for pending verification challenges with automatic TTL expiry.
actor ChallengeStore {
    static let shared = ChallengeStore()

    private struct PendingChallenge {
        let nonce: Data
        let publicKey: Data
        let expiresAt: Date
    }

    /// Keyed by contributorID
    private var challenges: [String: PendingChallenge] = [:]

    /// TTL for challenges (5 minutes)
    private static let ttl: TimeInterval = 300

    /// Create a new challenge nonce for a contributor.
    /// Returns a 32-byte random nonce.
    func createChallenge(contributorID: String, publicKey: Data) -> Data {
        // Clean up expired challenges opportunistically
        let now = Date()
        challenges = challenges.filter { $0.value.expiresAt > now }

        // Generate 32-byte random nonce
        var nonce = Data(count: 32)
        nonce.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }

        challenges[contributorID] = PendingChallenge(
            nonce: nonce,
            publicKey: publicKey,
            expiresAt: now.addingTimeInterval(Self.ttl)
        )

        return nonce
    }

    /// Retrieve and consume a pending challenge for verification.
    /// Returns the (nonce, publicKey) if valid and not expired, nil otherwise.
    func consumeChallenge(contributorID: String) -> (nonce: Data, publicKey: Data)? {
        guard let challenge = challenges[contributorID] else { return nil }

        // Remove it (one-time use)
        challenges.removeValue(forKey: contributorID)

        // Check expiry
        guard challenge.expiresAt > Date() else { return nil }

        return (nonce: challenge.nonce, publicKey: challenge.publicKey)
    }
}
