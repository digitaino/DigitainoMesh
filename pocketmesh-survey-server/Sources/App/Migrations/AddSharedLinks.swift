import Fluent

struct AddSharedLinks: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Shared routes table
        try await database.schema("shared_routes")
            .field("id", .string, .identifier(auto: false))
            .field("hop_count", .int, .required)
            .field("distance_text", .string)
            .field("hops_json", .string, .required)
            .field("created_at", .string, .required)
            .create()

        // Shared repeater maps table
        try await database.schema("shared_repeater_maps")
            .field("id", .string, .identifier(auto: false))
            .field("repeater_count", .int, .required)
            .field("repeaters_json", .string, .required)
            .field("created_at", .string, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("shared_repeater_maps").delete()
        try await database.schema("shared_routes").delete()
    }
}
