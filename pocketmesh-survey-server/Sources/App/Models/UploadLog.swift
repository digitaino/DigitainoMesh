import Fluent
import Vapor

/// Upload log for rate limiting, audit, and contributor data deletion.
final class UploadLog: Model, Content, @unchecked Sendable {
    static let schema = "uploads"

    @ID(custom: "id", generatedBy: .database)
    var id: Int?

    @Field(key: "contributor_id")
    var contributorID: String

    @Field(key: "uploaded_at")
    var uploadedAt: String

    @Field(key: "cell_count")
    var cellCount: Int

    @Field(key: "client_ip")
    var clientIP: String?

    @Field(key: "accepted")
    var accepted: Bool

    init() {}

    init(contributorID: String, uploadedAt: String, cellCount: Int, clientIP: String?, accepted: Bool) {
        self.contributorID = contributorID
        self.uploadedAt = uploadedAt
        self.cellCount = cellCount
        self.clientIP = clientIP
        self.accepted = accepted
    }
}
