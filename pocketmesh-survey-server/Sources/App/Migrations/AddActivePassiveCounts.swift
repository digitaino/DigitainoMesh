import Fluent
import SQLKit

/// Adds active_packet_count and passive_packet_count columns to cells and cell_contributions tables.
/// These track the breakdown of packets by survey mode (active probing vs passive listening).
///
/// Uses raw SQL because Fluent's schema builder generates invalid SQLite for ALTER TABLE
/// when combining .required with .custom("DEFAULT 0") — it inserts a comma between
/// NOT NULL and DEFAULT 0, which is a syntax error in SQLite's ALTER TABLE ADD COLUMN.
struct AddActivePassiveCounts: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("AddActivePassiveCounts requires an SQL database")
        }

        try await sql.raw("ALTER TABLE cells ADD COLUMN active_packet_count INTEGER NOT NULL DEFAULT 0").run()
        try await sql.raw("ALTER TABLE cells ADD COLUMN passive_packet_count INTEGER NOT NULL DEFAULT 0").run()
        try await sql.raw("ALTER TABLE cell_contributions ADD COLUMN active_packet_count INTEGER NOT NULL DEFAULT 0").run()
        try await sql.raw("ALTER TABLE cell_contributions ADD COLUMN passive_packet_count INTEGER NOT NULL DEFAULT 0").run()
    }

    func revert(on database: Database) async throws {
        // SQLite doesn't support DROP COLUMN before 3.35.0.
        // Fluent's deleteField on .update() works for supported versions.
        try await database.schema("cells")
            .deleteField("active_packet_count")
            .deleteField("passive_packet_count")
            .update()

        try await database.schema("cell_contributions")
            .deleteField("active_packet_count")
            .deleteField("passive_packet_count")
            .update()
    }
}
