import Vapor

/// Validates the X-API-Key header against the SURVEY_API_KEY environment variable.
/// Also accepts SURVEY_API_KEY_OLD for zero-downtime key rotation.
struct APIKeyMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let expectedKey = Environment.get("SURVEY_API_KEY") else {
            request.logger.error("SURVEY_API_KEY environment variable not set")
            throw Abort(.internalServerError, reason: "Server misconfigured")
        }

        guard let providedKey = request.headers.first(name: "X-API-Key") else {
            throw Abort(.unauthorized, reason: "Invalid or missing API key")
        }

        // Accept current key or legacy key (for zero-downtime rotation)
        let legacyKey = Environment.get("SURVEY_API_KEY_OLD")
        guard providedKey == expectedKey || (legacyKey != nil && providedKey == legacyKey) else {
            request.logger.warning("API key mismatch — expected[\(expectedKey.prefix(8))...] len=\(expectedKey.count), got[\(providedKey.prefix(8))...] len=\(providedKey.count)")
            throw Abort(.unauthorized, reason: "Invalid or missing API key")
        }

        return try await next.respond(to: request)
    }
}
