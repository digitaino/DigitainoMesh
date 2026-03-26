import Fluent

struct AddSharedPaths: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("shared_paths")
            .field("id", .string, .identifier(auto: false))
            .field("hop_count", .int, .required)
            .field("hops_json", .string, .required)
            .field("user_latitude", .double)
            .field("user_longitude", .double)
            .field("user_name", .string)
            .field("created_at", .string, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("shared_paths").delete()
    }
}
