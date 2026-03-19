import Fluent

struct AddRouteUserLocation: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("shared_routes")
            .field("user_latitude", .double)
            .field("user_longitude", .double)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("shared_routes")
            .deleteField("user_latitude")
            .deleteField("user_longitude")
            .update()
    }
}
