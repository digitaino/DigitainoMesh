import Vapor
import Foundation

/// Thread-safe broadcaster for Server-Sent Events.
/// Web map clients connect once and receive push notifications
/// when new survey data is uploaded, eliminating polling.
actor SSEBroadcaster {
    static let shared = SSEBroadcaster()

    private var clients: [UUID: AsyncStream<String>.Continuation] = [:]

    /// Register a new SSE client. Returns a stream of event strings.
    func addClient() -> (id: UUID, stream: AsyncStream<String>) {
        let id = UUID()
        let stream = AsyncStream<String> { continuation in
            // Store continuation for later sends
            Task { await self.storeContinuation(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeClient(id: id) }
            }
        }
        return (id, stream)
    }

    private func storeContinuation(id: UUID, continuation: AsyncStream<String>.Continuation) {
        clients[id] = continuation
    }

    func removeClient(id: UUID) {
        clients.removeValue(forKey: id)
    }

    /// Number of connected clients (for diagnostics).
    var clientCount: Int { clients.count }

    /// Broadcast an event to all connected clients.
    /// - Parameters:
    ///   - event: SSE event name (e.g. "upload")
    ///   - data: JSON string payload
    func broadcast(event: String, data: String) {
        let message = "event: \(event)\ndata: \(data)\n\n"
        for (_, continuation) in clients {
            continuation.yield(message)
        }
    }

    /// Convenience: broadcast a simple event with no data payload.
    func broadcast(event: String) {
        let message = "event: \(event)\ndata: {}\n\n"
        for (_, continuation) in clients {
            continuation.yield(message)
        }
    }
}
