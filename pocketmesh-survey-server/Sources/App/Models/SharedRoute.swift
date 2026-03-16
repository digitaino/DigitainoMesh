import Fluent
import Vapor

/// A shared route uploaded by an iOS client for web viewing.
/// Stores the full resolved route data so anyone with the link can see the route on a map.
final class SharedRoute: Model, Content, @unchecked Sendable {
    static let schema = "shared_routes"

    /// Short base62 ID used in the URL (e.g., "a3Kx9m")
    @ID(custom: "id", generatedBy: .user)
    var id: String?

    /// Number of hops in the route
    @Field(key: "hop_count")
    var hopCount: Int

    /// Optional distance text (e.g., "2.3 mi", "≥ 12 km")
    @Field(key: "distance_text")
    var distanceText: String?

    /// JSON-encoded array of hop objects: [{"hexID": "80", "name": "Repeater1", "latitude": 30.27, "longitude": -97.74}]
    /// Hops without location data omit latitude/longitude.
    @Field(key: "hops_json")
    var hopsJSON: String

    /// ISO 8601 timestamp of creation
    @Field(key: "created_at")
    var createdAt: String

    init() {}

    init(id: String, hopCount: Int, distanceText: String?, hopsJSON: String, createdAt: String) {
        self.id = id
        self.hopCount = hopCount
        self.distanceText = distanceText
        self.hopsJSON = hopsJSON
        self.createdAt = createdAt
    }
}
