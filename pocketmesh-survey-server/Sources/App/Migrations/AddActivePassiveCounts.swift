import Fluent

/// Adds active_packet_count and passive_packet_count columns to cells and cell_contributions tables.
/// These track the breakdown of packets by survey mode (active probing vs passive listening).
struct AddActivePassiveCounts: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("cells")
            .field("active_packet_count", .int, .required, .sql(.default(0)))
            .field("passive_packet_count", .int, .required, .sql(.default(0)))
            .update()

        try await database.schema("cell_contributions")
            .field("active_packet_count", .int, .required, .sql(.default(0)))
            .field("passive_packet_count", .int, .required, .sql(.default(0)))
            .update()
    }

    func revert(on database: Database) async throws {
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
