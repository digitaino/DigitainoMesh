import Fluent
import Vapor

/// Known repeater locations with names, upserted from client uploads.
final class RepeaterLocation: Model, Content, @unchecked Sendable {
    static let schema = "repeater_locations"

    @ID(custom: "id", generatedBy: .database)
    var id: Int?

    /// Unique hex ID (the path hash prefix, e.g. "0A1B2C")
    @Field(key: "hex_id")
    var hexID: String

    /// Human-readable name from the contributor's contact list
    @Field(key: "name")
    var name: String

    @Field(key: "latitude")
    var latitude: Double

    @Field(key: "longitude")
    var longitude: Double

    /// ISO 8601 timestamp of last update
    @Field(key: "last_updated")
    var lastUpdated: String

    /// Whether this repeater is hidden from public API responses (admin toggle).
    @OptionalField(key: "hidden")
    var hidden: Bool?

    /// Admin notes about this repeater.
    @OptionalField(key: "notes")
    var notes: String?

    /// Contributor ID of the last person who uploaded this repeater's location.
    @OptionalField(key: "last_contributor_id")
    var lastContributorID: String?

    /// Full public key of the repeater (hex-encoded, 64 chars for 32 bytes).
    @OptionalField(key: "public_key")
    var publicKey: String?

    /// ISO 8601 timestamp of when any client last heard this repeater (newest across all sharing clients).
    @OptionalField(key: "last_heard")
    var lastHeard: String?

    init() {}

    init(hexID: String, name: String, latitude: Double, longitude: Double, lastUpdated: String) {
        self.hexID = hexID
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.lastUpdated = lastUpdated
    }
}
