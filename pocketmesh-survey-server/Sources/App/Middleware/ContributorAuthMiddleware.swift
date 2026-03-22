import Crypto
import Fluent
import Vapor

/// Authenticates contributors using a short-lived Bearer token issued after
/// challenge-response verification. The token is SHA256-hashed before storage
/// so the raw token is never persisted.
struct ContributorAuthMiddleware: AsyncMiddleware {

    /// Storage key for the authenticated contributor ID.
    struct AuthenticatedContributor: StorageKey {
        typealias Value = String
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let bearer = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing authorization token")
        }

        // Hash the raw token to match what's stored in the database
        let tokenHash = SHA256.hash(data: Data(bearer.token.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()

        guard let profile = try await ContributorProfile.query(on: request.db)
            .filter(\.$authToken == tokenHash)
            .first() else {
            throw Abort(.unauthorized, reason: "Invalid authorization token")
        }

        // Check token expiry
        if let expires = profile.authTokenExpires {
            let now = ISO8601DateFormatter().string(from: Date())
            guard now < expires else {
                throw Abort(.unauthorized, reason: "Authorization token expired — re-verify to get a new one")
            }
        }

        // Store the authenticated contributor ID for downstream handlers
        request.storage[AuthenticatedContributor.self] = profile.contributorID

        return try await next.respond(to: request)
    }
}

// MARK: - Request Extension

extension Request {
    /// The authenticated contributor ID, set by `ContributorAuthMiddleware`.
    var authenticatedContributorID: String? {
        storage[ContributorAuthMiddleware.AuthenticatedContributor.self]
    }
}
