import Fluent
import SQLKit

/// Adds a compound index on (latitude, longitude) for faster bounding-box
/// queries when serving community cell data.
struct AddCellSpatialIndex: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("AddCellSpatialIndex requires an SQL database")
        }

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_cells_lat_lon ON cells(latitude, longitude)").run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("AddCellSpatialIndex requires an SQL database")
        }

        try await sql.raw("DROP INDEX IF EXISTS idx_cells_lat_lon").run()
    }
}
