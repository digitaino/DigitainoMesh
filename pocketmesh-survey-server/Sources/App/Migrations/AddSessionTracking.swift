import Fluent
import SQLKit

/// Adds session_id column to cell_contributions table.
/// This enables idempotent uploads — re-uploading the same session replaces previous data
/// instead of accumulating duplicates.
struct AddSessionTracking: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("AddSessionTracking requires an SQL database")
        }

        // session_id is optional (NULL) for backward compat with existing contributions
        // that were created before session tracking was added.
        try await sql.raw("ALTER TABLE cell_contributions ADD COLUMN session_id TEXT").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("cell_contributions")
            .deleteField("session_id")
            .update()
    }
}
