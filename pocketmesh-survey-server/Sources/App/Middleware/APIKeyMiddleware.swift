import Vapor

/// Validates the X-API-Key header against the SURVEY_API_KEY environment variable.
struct APIKeyMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let expectedKey = Environment.get("SURVEY_API_KEY") else {
            request.logger.error("SURVEY_API_KEY environment variable not set")
            throw Abort(.internalServerError, reason: "Server misconfigured")
        }

        guard let providedKey = request.headers.first(name: "X-API-Key"),
              providedKey == expectedKey else {
            throw Abort(.unauthorized, reason: "Invalid or missing API key")
        }

        return try await next.respond(to: request)
    }
}
