import Fluent

struct AddRepeaterLocations: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("repeater_locations")
            .field("id", .int, .identifier(auto: true))
            .field("hex_id", .string, .required)
            .field("name", .string, .required)
            .field("latitude", .double, .required)
            .field("longitude", .double, .required)
            .field("last_updated", .string, .required)
            .unique(on: "hex_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("repeater_locations").delete()
    }
}
