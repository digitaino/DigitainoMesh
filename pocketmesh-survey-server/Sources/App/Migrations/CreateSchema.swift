import Fluent

struct CreateSchema: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Cells table
        try await database.schema("cells")
            .field("id", .int, .identifier(auto: true))
            .field("hex_q", .int, .required)
            .field("hex_r", .int, .required)
            .field("reference_latitude", .double, .required)
            .field("latitude", .double, .required)
            .field("longitude", .double, .required)
            .field("total_snr_weighted", .double, .required, .custom("DEFAULT 0"))
            .field("total_rssi_weighted", .double, .required, .custom("DEFAULT 0"))
            .field("total_packet_count", .int, .required, .custom("DEFAULT 0"))
            .field("min_snr", .double)
            .field("max_snr", .double)
            .field("flood_count", .int, .required, .custom("DEFAULT 0"))
            .field("direct_count", .int, .required, .custom("DEFAULT 0"))
            .field("contribution_count", .int, .required, .custom("DEFAULT 1"))
            .field("first_seen", .string, .required)
            .field("last_updated", .string, .required)
            .unique(on: "hex_q", "hex_r", "reference_latitude")
            .create()

        // Spatial index for bounding box queries
        try await database.schema("cells")
            .field("latitude", .double)
            .field("longitude", .double)
            .update()

        // Cell repeaters table
        try await database.schema("cell_repeaters")
            .field("id", .int, .identifier(auto: true))
            .field("cell_id", .int, .required, .references("cells", "id", onDelete: .cascade))
            .field("repeater_hex_id", .string, .required)
            .unique(on: "cell_id", "repeater_hex_id")
            .create()

        // Uploads table
        try await database.schema("uploads")
            .field("id", .int, .identifier(auto: true))
            .field("contributor_id", .string, .required)
            .field("uploaded_at", .string, .required)
            .field("cell_count", .int, .required)
            .field("client_ip", .string)
            .field("accepted", .bool, .required, .custom("DEFAULT 1"))
            .create()

        // Cell contributions table
        try await database.schema("cell_contributions")
            .field("id", .int, .identifier(auto: true))
            .field("cell_id", .int, .required, .references("cells", "id", onDelete: .cascade))
            .field("contributor_id", .string, .required)
            .field("packet_count", .int, .required)
            .field("snr_weighted", .double, .required)
            .field("rssi_weighted", .double)
            .field("flood_count", .int, .required, .custom("DEFAULT 0"))
            .field("direct_count", .int, .required, .custom("DEFAULT 0"))
            .field("contributed_at", .string, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("cell_contributions").delete()
        try await database.schema("uploads").delete()
        try await database.schema("cell_repeaters").delete()
        try await database.schema("cells").delete()
    }
}
