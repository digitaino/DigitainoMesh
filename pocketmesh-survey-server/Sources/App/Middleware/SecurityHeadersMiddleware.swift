import Vapor

/// Adds standard security headers to all responses.
///
/// These headers protect against common web vulnerabilities:
/// - HSTS: forces HTTPS connections
/// - CSP: restricts resource loading to same-origin
/// - X-Frame-Options: prevents clickjacking
/// - X-Content-Type-Options: prevents MIME sniffing
/// - Referrer-Policy: limits referrer leakage
/// - Permissions-Policy: disables unused browser features
struct SecurityHeadersMiddleware: AsyncMiddleware {

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)

        response.headers.replaceOrAdd(
            name: "Strict-Transport-Security",
            value: "max-age=31536000; includeSubDomains"
        )
        // Allow Apple MapKit CDN and inline scripts (used by share/plan pages and admin)
        // Cloudflare may also inject scripts from static.cloudflareinsights.com and challenges.cloudflare.com
        response.headers.replaceOrAdd(
            name: "Content-Security-Policy",
            value: "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.apple-mapkit.com https://static.cloudflareinsights.com https://challenges.cloudflare.com; connect-src 'self' https://*.apple-mapkit.com; img-src 'self' data:"
        )
        response.headers.replaceOrAdd(
            name: "X-Frame-Options",
            value: "DENY"
        )
        response.headers.replaceOrAdd(
            name: "X-Content-Type-Options",
            value: "nosniff"
        )
        response.headers.replaceOrAdd(
            name: "Referrer-Policy",
            value: "strict-origin-when-cross-origin"
        )
        response.headers.replaceOrAdd(
            name: "Permissions-Policy",
            value: "camera=(), microphone=(), geolocation=()"
        )

        return response
    }
}
