import Vapor

/// Predefined caching policies for different endpoint categories.
enum CachePolicy {
    /// Frequently changing data (cells, repeaters): cache briefly to absorb rapid pan/zoom.
    /// 30s max-age, must revalidate after expiry.
    case shortLived

    /// Slowly changing data (stats, shared links): cache for a few minutes.
    /// 5 min max-age.
    case mediumLived

    /// Auth tokens, MapKit tokens: cache for their validity period.
    /// Custom max-age in seconds.
    case custom(maxAge: Int)

    /// Never cache (auth endpoints, write operations, SSE).
    case noStore

    var headerValue: String {
        switch self {
        case .shortLived:
            return "public, max-age=30, must-revalidate"
        case .mediumLived:
            return "public, max-age=300"
        case .custom(let maxAge):
            return "private, max-age=\(maxAge)"
        case .noStore:
            return "no-store"
        }
    }
}

/// Middleware that sets `Cache-Control` headers on successful GET responses.
///
/// Usage in `routes.swift`:
/// ```swift
/// let cached = api.grouped(CacheControlMiddleware(.shortLived))
/// cached.get("cells", use: controller.getCells)
/// ```
///
/// Only applies to GET responses with 2xx status codes. POST/PUT/DELETE
/// and error responses are never cached regardless of policy.
struct CacheControlMiddleware: AsyncMiddleware {
    let policy: CachePolicy

    init(_ policy: CachePolicy) {
        self.policy = policy
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)

        // Only cache successful GET responses
        guard request.method == .GET,
              response.status.code >= 200,
              response.status.code < 300 else {
            return response
        }

        // Don't override if the handler already set Cache-Control
        guard response.headers.first(name: .cacheControl) == nil else {
            return response
        }

        response.headers.replaceOrAdd(name: .cacheControl, value: policy.headerValue)

        return response
    }
}
