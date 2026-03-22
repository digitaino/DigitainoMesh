import Fluent

/// Adds a `user_name` column to `shared_routes` and `shared_repeater_maps`
/// so the web viewer can show the sharer's name instead of "You".
struct AddShareUserName: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("shared_routes")
            .field("user_name", .string)
            .update()
        try await database.schema("shared_repeater_maps")
            .field("user_name", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("shared_routes")
            .deleteField("user_name")
            .update()
        try await database.schema("shared_repeater_maps")
            .deleteField("user_name")
            .update()
    }
}
