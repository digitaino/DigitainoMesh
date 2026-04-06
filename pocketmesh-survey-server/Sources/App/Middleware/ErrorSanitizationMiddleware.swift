import Vapor

/// Catches Vapor decoding/validation errors and returns generic messages
/// so internal type names and field paths are not leaked to clients.
///
/// Intentional `Abort` errors (e.g. 404 Not Found, 429 Too Many Requests)
/// are passed through unchanged since those messages are written by us.
struct ErrorSanitizationMiddleware: AsyncMiddleware {

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let abort as Abort {
            // Our own Abort errors — pass through as-is
            throw abort
        } catch let error as DecodingError {
            // Log the real error for debugging
            request.logger.error("Decoding error on \(request.method) \(request.url.path): \(error)")
            throw Abort(.badRequest, reason: "Invalid request body.")
        } catch let error as ValidationError {
            request.logger.error("Validation error on \(request.method) \(request.url.path): \(error)")
            throw Abort(.badRequest, reason: "Request validation failed.")
        } catch {
            // Any other unexpected error — log it, return 500 with generic message
            request.logger.error("Unexpected error on \(request.method) \(request.url.path): \(error)")
            throw Abort(.internalServerError, reason: "An internal error occurred.")
        }
    }
}
