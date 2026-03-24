import Fluent
import SQLKit

struct AddCellAdminFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        // Individual statements with error suppression to handle partially-applied prior runs
        // (SQLite has no IF NOT EXISTS for ADD COLUMN)
        try? await sql.raw("ALTER TABLE cells ADD COLUMN hidden BOOLEAN").run()
        try? await sql.raw("ALTER TABLE cells ADD COLUMN notes TEXT").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("cells")
            .deleteField("hidden")
            .deleteField("notes")
            .update()
    }
}
