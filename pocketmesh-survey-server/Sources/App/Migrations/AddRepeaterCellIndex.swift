import Fluent
import SQLKit

/// Adds an index on cell_repeaters(cell_id) to speed up the eager-load query
/// that Fluent generates for `.with(\.$repeaters)` and the raw SQL GROUP_CONCAT join.
struct AddRepeaterCellIndex: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("AddRepeaterCellIndex requires an SQL database")
        }

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_cell_repeaters_cell_id ON cell_repeaters(cell_id)").run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("AddRepeaterCellIndex requires an SQL database")
        }

        try await sql.raw("DROP INDEX IF EXISTS idx_cell_repeaters_cell_id").run()
    }
}
