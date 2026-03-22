import Fluent
import SQLKit

/// Creates the contributor_profiles table for admin notes, display names,
/// and public key verification.
struct AddContributorProfiles: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("AddContributorProfiles requires an SQL database")
        }

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS contributor_profiles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                contributor_id TEXT NOT NULL UNIQUE,
                notes TEXT,
                display_name TEXT,
                public_key_hash TEXT,
                verified INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """).run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("contributor_profiles").delete()
    }
}
