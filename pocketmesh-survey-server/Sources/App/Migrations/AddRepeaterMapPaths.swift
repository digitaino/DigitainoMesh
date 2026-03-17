import Fluent

struct AddRepeaterMapPaths: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("shared_repeater_maps")
            .field("paths_json", .string)
            .field("user_latitude", .double)
            .field("user_longitude", .double)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("shared_repeater_maps")
            .deleteField("paths_json")
            .deleteField("user_latitude")
            .deleteField("user_longitude")
            .update()
    }
}
