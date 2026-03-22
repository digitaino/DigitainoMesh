import Fluent
import SQLKit

/// Adds identity model fields to contributor_profiles for public-key-based
/// contributor IDs, forward-only name attribution, and session token auth.
struct AddContributorIdentityFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("AddContributorIdentityFields requires an SQL database")
        }

        // Store the original UUID after migrating to public-key-based ID
        try await sql.raw("ALTER TABLE contributor_profiles ADD COLUMN legacy_uuid TEXT").run()

        // Name only shows on contributions after this timestamp; NULL = show for all
        try await sql.raw("ALTER TABLE contributor_profiles ADD COLUMN name_visible_from TEXT").run()

        // SHA256 hash of session token for self-service auth
        try await sql.raw("ALTER TABLE contributor_profiles ADD COLUMN auth_token TEXT").run()

        // ISO 8601 expiry for the auth token
        try await sql.raw("ALTER TABLE contributor_profiles ADD COLUMN auth_token_expires TEXT").run()
    }

    func revert(on database: Database) async throws {
        // SQLite doesn't support DROP COLUMN prior to 3.35.0;
        // for simplicity we don't revert individual columns.
    }
}
