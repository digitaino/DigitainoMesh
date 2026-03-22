import Fluent
import Vapor

/// Per-contributor metadata: notes, display name, and verification status.
/// Shared by admin notes, contributor identity, and public key verification features.
final class ContributorProfile: Model, Content, @unchecked Sendable {
    static let schema = "contributor_profiles"

    @ID(custom: "id", generatedBy: .database)
    var id: Int?

    @Field(key: "contributor_id")
    var contributorID: String

    @OptionalField(key: "notes")
    var notes: String?

    @OptionalField(key: "display_name")
    var displayName: String?

    @OptionalField(key: "public_key_hash")
    var publicKeyHash: String?

    @Field(key: "verified")
    var verified: Bool

    @Field(key: "created_at")
    var createdAt: String

    @Field(key: "updated_at")
    var updatedAt: String

    /// Original UUID before migration to public-key-based ID.
    @OptionalField(key: "legacy_uuid")
    var legacyUUID: String?

    /// Name only shows on contributions after this timestamp.
    /// NULL means show for all contributions (retroactive opt-in).
    @OptionalField(key: "name_visible_from")
    var nameVisibleFrom: String?

    /// SHA256 hash of the session token for self-service auth.
    @OptionalField(key: "auth_token")
    var authToken: String?

    /// ISO 8601 expiry for the auth token.
    @OptionalField(key: "auth_token_expires")
    var authTokenExpires: String?

    init() {}

    init(
        contributorID: String,
        notes: String? = nil,
        displayName: String? = nil,
        publicKeyHash: String? = nil,
        verified: Bool = false,
        createdAt: String,
        updatedAt: String,
        legacyUUID: String? = nil,
        nameVisibleFrom: String? = nil
    ) {
        self.contributorID = contributorID
        self.notes = notes
        self.displayName = displayName
        self.publicKeyHash = publicKeyHash
        self.verified = verified
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.legacyUUID = legacyUUID
        self.nameVisibleFrom = nameVisibleFrom
    }
}
