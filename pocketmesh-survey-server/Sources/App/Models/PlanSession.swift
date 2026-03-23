import Fluent
import Vapor

/// An ephemeral pairing session for web-to-app survey route planning.
/// The app creates a session (6-char code), the web submits a polygon, and the app polls for it.
/// Sessions expire after 1 hour.
final class PlanSession: Model, Content, @unchecked Sendable {
    static let schema = "plan_sessions"

    /// Short alphanumeric code used for pairing (e.g., "A3Kx9m")
    @ID(custom: "id", generatedBy: .user)
    var id: String?

    /// JSON-encoded polygon vertices: [{"latitude": 30.27, "longitude": -97.74}, ...]
    /// Null until the web submits a polygon.
    @OptionalField(key: "polygon_json")
    var polygonJSON: String?

    /// Session status: "waiting", "submitted", "consumed"
    @Field(key: "status")
    var status: String

    /// ISO 8601 timestamp of creation
    @Field(key: "created_at")
    var createdAt: String

    /// ISO 8601 timestamp of expiry (created_at + 1 hour)
    @Field(key: "expires_at")
    var expiresAt: String

    init() {}

    init(id: String, status: String, createdAt: String, expiresAt: String) {
        self.id = id
        self.status = status
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}
