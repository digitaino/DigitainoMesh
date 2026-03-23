import Fluent
import SQLKit

struct AddRepeaterAdminFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        // Individual statements with error suppression to handle partially-applied prior runs
        // (SQLite has no IF NOT EXISTS for ADD COLUMN)
        try? await sql.raw("ALTER TABLE repeater_locations ADD COLUMN hidden BOOLEAN").run()
        try? await sql.raw("ALTER TABLE repeater_locations ADD COLUMN notes TEXT").run()
        try? await sql.raw("ALTER TABLE repeater_locations ADD COLUMN last_contributor_id TEXT").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("repeater_locations")
            .deleteField("hidden")
            .deleteField("notes")
            .deleteField("last_contributor_id")
            .update()
    }
}
