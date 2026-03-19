import Fluent

struct AddRepeaterMetrics: AsyncMigration {
    func prepare(on database: Database) async throws {
        // SQLite only supports one ALTER TABLE ADD COLUMN per statement
        try await database.schema("cell_repeaters")
            .field("average_snr", .double)
            .update()
        try await database.schema("cell_repeaters")
            .field("average_rssi", .double)
            .update()
        try await database.schema("cell_repeaters")
            .field("packet_count", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("cell_repeaters")
            .deleteField("average_snr")
            .update()
        try await database.schema("cell_repeaters")
            .deleteField("average_rssi")
            .update()
        try await database.schema("cell_repeaters")
            .deleteField("packet_count")
            .update()
    }
}
