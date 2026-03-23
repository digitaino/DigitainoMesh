import Fluent

struct AddRepeaterAdminFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("repeater_locations")
            .field("hidden", .bool)
            .field("notes", .string)
            .field("last_contributor_id", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("repeater_locations")
            .deleteField("hidden")
            .deleteField("notes")
            .deleteField("last_contributor_id")
            .update()
    }
}
