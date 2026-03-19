import Vapor
import Foundation

/// Simple in-memory rate limiter using a sliding window per IP address.
actor RateLimitStore {
    struct Entry {
        var timestamps: [Date]
    }

    private var entries: [String: Entry] = [:]
    private let maxRequests: Int
    private let windowSeconds: TimeInterval

    init(maxRequests: Int, windowSeconds: TimeInterval) {
        self.maxRequests = maxRequests
        self.windowSeconds = windowSeconds
    }

    /// Returns `true` if the request should be allowed, `false` if rate-limited.
    func allow(key: String) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-windowSeconds)

        var entry = entries[key] ?? Entry(timestamps: [])
        entry.timestamps = entry.timestamps.filter { $0 > cutoff }

        if entry.timestamps.count >= maxRequests {
            entries[key] = entry
            return false
        }

        entry.timestamps.append(now)
        entries[key] = entry
        return true
    }

    /// Periodic cleanup of expired entries to prevent memory growth.
    func cleanup() {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        for (key, entry) in entries {
            let filtered = entry.timestamps.filter { $0 > cutoff }
            if filtered.isEmpty {
                entries.removeValue(forKey: key)
            } else {
                entries[key] = Entry(timestamps: filtered)
            }
        }
    }
}

struct RateLimitMiddleware: AsyncMiddleware {
    let store: RateLimitStore

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Use CF-Connecting-IP (from Cloudflare) or fall back to peer address
        let clientIP = request.headers.first(name: "CF-Connecting-IP")
            ?? request.headers.first(name: "X-Forwarded-For")?.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
            ?? request.peerAddress?.description
            ?? "unknown"

        let allowed = await store.allow(key: clientIP)

        guard allowed else {
            throw Abort(.tooManyRequests, reason: "Rate limit exceeded. Try again later.")
        }

        return try await next.respond(to: request)
    }
}
