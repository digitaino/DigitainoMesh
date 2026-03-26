import Fluent
import Vapor

/// A shared path uploaded by an iOS client for web viewing.
/// Unlike SharedRoute, paths have no sender/receiver or distance — just a sequence of hex IDs.
final class SharedPath: Model, Content, @unchecked Sendable {
    static let schema = "shared_paths"

    /// Short base62 ID used in the URL (e.g., "b4Ky2nR")
    @ID(custom: "id", generatedBy: .user)
    var id: String?

    /// Number of hops in the path
    @Field(key: "hop_count")
    var hopCount: Int

    /// JSON-encoded array of hop objects: [{"hexID": "80", "name": "Repeater1", "latitude": 30.27, "longitude": -97.74}]
    @Field(key: "hops_json")
    var hopsJSON: String

    /// User latitude at time of share
    @OptionalField(key: "user_latitude")
    var userLatitude: Double?

    /// User longitude at time of share
    @OptionalField(key: "user_longitude")
    var userLongitude: Double?

    /// Display name of the person who shared this path
    @OptionalField(key: "user_name")
    var userName: String?

    /// ISO 8601 timestamp of creation
    @Field(key: "created_at")
    var createdAt: String

    init() {}

    init(id: String, hopCount: Int, hopsJSON: String, userLatitude: Double? = nil, userLongitude: Double? = nil, userName: String? = nil, createdAt: String) {
        self.id = id
        self.hopCount = hopCount
        self.hopsJSON = hopsJSON
        self.userLatitude = userLatitude
        self.userLongitude = userLongitude
        self.userName = userName
        self.createdAt = createdAt
    }
}
