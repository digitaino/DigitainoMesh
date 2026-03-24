import Fluent
import SQLKit

struct AddRepeaterLastHeardColumn: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try? await sql.raw("ALTER TABLE repeater_locations ADD COLUMN last_heard TEXT").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("repeater_locations")
            .deleteField("last_heard")
            .update()
    }
}
