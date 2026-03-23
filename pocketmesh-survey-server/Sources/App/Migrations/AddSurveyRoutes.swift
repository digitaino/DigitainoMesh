import Fluent

struct AddSurveyRoutes: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("survey_routes")
            .field("id", .string, .identifier(auto: false))
            .field("contributor_id", .string, .required)
            .field("polygon_json", .string, .required)
            .field("waypoint_count", .int, .required)
            .field("status", .string, .required)
            .field("completed_count", .int, .required)
            .field("skipped_count", .int, .required)
            .field("excluded_surveyed", .bool, .required)
            .field("reference_latitude", .double, .required)
            .field("plan_session_code", .string)
            .field("created_at", .string, .required)
            .field("started_at", .string)
            .field("finished_at", .string)
            .field("updated_at", .string, .required)
            .field("notes", .string)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("survey_routes").delete()
    }
}
