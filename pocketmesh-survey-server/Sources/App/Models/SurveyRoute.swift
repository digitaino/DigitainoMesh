import Fluent
import Vapor

/// A survey route tracked through its full lifecycle.
/// Created when a user uploads a locally-drawn or web-drawn polygon route to the server.
final class SurveyRoute: Model, Content, @unchecked Sendable {
    static let schema = "survey_routes"

    /// Short alphanumeric ID (8-char base62)
    @ID(custom: "id", generatedBy: .user)
    var id: String?

    /// Contributor who created/owns this route
    @Field(key: "contributor_id")
    var contributorID: String

    /// JSON-encoded polygon vertices: [{"latitude": 30.27, "longitude": -97.74}, ...]
    @Field(key: "polygon_json")
    var polygonJSON: String

    /// Total number of waypoints in the generated route
    @Field(key: "waypoint_count")
    var waypointCount: Int

    /// Lifecycle status: "created", "in_progress", "completed", "abandoned"
    @Field(key: "status")
    var status: String

    /// Number of waypoints completed
    @Field(key: "completed_count")
    var completedCount: Int

    /// Number of waypoints skipped
    @Field(key: "skipped_count")
    var skippedCount: Int

    /// Whether already-surveyed cells were excluded from the route
    @Field(key: "excluded_surveyed")
    var excludedSurveyed: Bool

    /// Reference latitude for hex grid alignment
    @Field(key: "reference_latitude")
    var referenceLatitude: Double

    /// Optional link to a PlanSession code (if route was drawn via web)
    @OptionalField(key: "plan_session_code")
    var planSessionCode: String?

    /// ISO 8601 creation timestamp
    @Field(key: "created_at")
    var createdAt: String

    /// ISO 8601 timestamp when navigation started
    @OptionalField(key: "started_at")
    var startedAt: String?

    /// ISO 8601 timestamp when route was completed or abandoned
    @OptionalField(key: "finished_at")
    var finishedAt: String?

    /// ISO 8601 timestamp of last status update
    @Field(key: "updated_at")
    var updatedAt: String

    /// Admin notes
    @OptionalField(key: "notes")
    var notes: String?

    init() {}

    init(
        id: String,
        contributorID: String,
        polygonJSON: String,
        waypointCount: Int,
        status: String,
        completedCount: Int = 0,
        skippedCount: Int = 0,
        excludedSurveyed: Bool,
        referenceLatitude: Double,
        planSessionCode: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.contributorID = contributorID
        self.polygonJSON = polygonJSON
        self.waypointCount = waypointCount
        self.status = status
        self.completedCount = completedCount
        self.skippedCount = skippedCount
        self.excludedSurveyed = excludedSurveyed
        self.referenceLatitude = referenceLatitude
        self.planSessionCode = planSessionCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
