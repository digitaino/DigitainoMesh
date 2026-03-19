import Fluent

struct AddRepeaterLastHeard: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("cell_repeaters")
            .field("last_heard", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("cell_repeaters")
            .deleteField("last_heard")
            .update()
    }
}
