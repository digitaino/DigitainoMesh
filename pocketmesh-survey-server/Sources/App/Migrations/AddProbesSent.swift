import Fluent

struct AddProbesSent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("cells")
            .field("probes_sent", .int)
            .update()
        try await database.schema("cell_contributions")
            .field("probes_sent", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("cells")
            .deleteField("probes_sent")
            .update()
        try await database.schema("cell_contributions")
            .deleteField("probes_sent")
            .update()
    }
}
