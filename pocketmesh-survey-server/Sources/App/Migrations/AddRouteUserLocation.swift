import Fluent

struct AddRouteUserLocation: AsyncMigration {
    func prepare(on database: Database) async throws {
        // SQLite only supports one ADD COLUMN per ALTER TABLE statement
        try await database.schema("shared_routes")
            .field("user_latitude", .double)
            .update()
        try await database.schema("shared_routes")
            .field("user_longitude", .double)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("shared_routes")
            .deleteField("user_latitude")
            .update()
        try await database.schema("shared_routes")
            .deleteField("user_longitude")
            .update()
    }
}
