import Fluent

struct AddPlanSessions: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("plan_sessions")
            .field("id", .string, .identifier(auto: false))
            .field("polygon_json", .string)
            .field("status", .string, .required)
            .field("created_at", .string, .required)
            .field("expires_at", .string, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("plan_sessions").delete()
    }
}
