import Vapor
import Foundation

/// Apache Combined Log Format style access and error logging middleware.
///
/// Logs every request in a format similar to Apache's Combined Log Format:
/// `IP - - [timestamp] "METHOD /path HTTP/version" status bytes "referer" "user-agent" duration_ms`
///
/// Errors are logged separately with the error message.
struct AccessLogMiddleware: AsyncMiddleware {

    /// ISO 8601 date formatter for log timestamps (Apache CLF uses a different format,
    /// but ISO 8601 is more useful for structured log analysis).
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MMM/yyyy:HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let start = Date()
        let clientIP = request.headers.first(name: "CF-Connecting-IP")
            ?? request.headers.first(name: "X-Forwarded-For")?.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
            ?? request.peerAddress?.description
            ?? "-"

        let method = request.method.rawValue
        let path = request.url.string
        let httpVersion = "HTTP/\(request.version.major).\(request.version.minor)"
        let referer = request.headers.first(name: .referer) ?? "-"
        let userAgent = request.headers.first(name: .userAgent) ?? "-"

        do {
            let response = try await next.respond(to: request)
            let duration = Date().timeIntervalSince(start)
            let durationMS = Int(duration * 1000)
            let timestamp = Self.dateFormatter.string(from: start)
            let status = response.status.code
            let bodySize = response.body.count

            // Access log (info level)
            request.logger.info(
                "\(clientIP) - - [\(timestamp)] \"\(method) \(path) \(httpVersion)\" \(status) \(bodySize) \"\(referer)\" \"\(userAgent)\" \(durationMS)ms"
            )

            return response
        } catch {
            let duration = Date().timeIntervalSince(start)
            let durationMS = Int(duration * 1000)
            let timestamp = Self.dateFormatter.string(from: start)

            // Determine status code from error
            let status: UInt
            if let abort = error as? Abort {
                status = abort.status.code
            } else {
                status = 500
            }

            // Error log
            request.logger.error(
                "\(clientIP) - - [\(timestamp)] \"\(method) \(path) \(httpVersion)\" \(status) 0 \"\(referer)\" \"\(userAgent)\" \(durationMS)ms ERROR: \(error.localizedDescription)"
            )

            throw error
        }
    }
}
