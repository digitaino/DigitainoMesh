import Fluent
import Vapor

/// A shared "heard repeaters" map uploaded by an iOS client for web viewing.
/// Contains the list of repeaters a user has heard, with counts and signal data.
final class SharedRepeaterMap: Model, Content, @unchecked Sendable {
    static let schema = "shared_repeater_maps"

    /// Short base62 ID used in the URL (e.g., "b7Yz3q")
    @ID(custom: "id", generatedBy: .user)
    var id: String?

    /// Total number of unique repeaters heard
    @Field(key: "repeater_count")
    var repeaterCount: Int

    /// JSON-encoded array of repeater objects:
    /// [{"hexID": "80", "name": "Repeater1", "latitude": 30.27, "longitude": -97.74,
    ///   "heardCount": 42, "avgSNR": 8.5, "avgRSSI": -90.0}]
    @Field(key: "repeaters_json")
    var repeatersJSON: String

    /// ISO 8601 timestamp of creation
    @Field(key: "created_at")
    var createdAt: String

    init() {}

    init(id: String, repeaterCount: Int, repeatersJSON: String, createdAt: String) {
        self.id = id
        self.repeaterCount = repeaterCount
        self.repeatersJSON = repeatersJSON
        self.createdAt = createdAt
    }
}
