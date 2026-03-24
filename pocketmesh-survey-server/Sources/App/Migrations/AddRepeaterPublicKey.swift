import Fluent
import SQLKit

struct AddRepeaterPublicKey: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try? await sql.raw("ALTER TABLE repeater_locations ADD COLUMN public_key TEXT").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("repeater_locations")
            .deleteField("public_key")
            .update()
    }
}
