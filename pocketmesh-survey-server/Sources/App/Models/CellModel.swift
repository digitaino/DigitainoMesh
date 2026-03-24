import Fluent
import Vapor

/// Aggregated cell data — one row per unique geographic hex cell.
final class CellModel: Model, Content, @unchecked Sendable {
    static let schema = "cells"

    @ID(custom: "id", generatedBy: .database)
    var id: Int?

    // Grid position (for merging overlapping uploads)
    @Field(key: "hex_q")
    var hexQ: Int

    @Field(key: "hex_r")
    var hexR: Int

    @Field(key: "reference_latitude")
    var referenceLatitude: Double

    // Center coordinates (for quick bounding box queries)
    @Field(key: "latitude")
    var latitude: Double

    @Field(key: "longitude")
    var longitude: Double

    // Aggregated signal metrics (weighted by packet count)
    @Field(key: "total_snr_weighted")
    var totalSNRWeighted: Double

    @Field(key: "total_rssi_weighted")
    var totalRSSIWeighted: Double

    @Field(key: "total_packet_count")
    var totalPacketCount: Int

    @Field(key: "min_snr")
    var minSNR: Double?

    @Field(key: "max_snr")
    var maxSNR: Double?

    // Routing stats
    @Field(key: "flood_count")
    var floodCount: Int

    @Field(key: "direct_count")
    var directCount: Int

    // Active/passive packet breakdown
    @Field(key: "active_packet_count")
    var activePacketCount: Int

    @Field(key: "passive_packet_count")
    var passivePacketCount: Int

    // Probe tracking
    @OptionalField(key: "probes_sent")
    var probesSent: Int?

    // Admin fields
    @OptionalField(key: "hidden")
    var hidden: Bool?

    @OptionalField(key: "notes")
    var notes: String?

    // Metadata
    @Field(key: "contribution_count")
    var contributionCount: Int

    @Field(key: "first_seen")
    var firstSeen: String

    @Field(key: "last_updated")
    var lastUpdated: String

    // Relationships
    @Children(for: \.$cell)
    var repeaters: [CellRepeater]

    @Children(for: \.$cell)
    var contributions: [CellContribution]

    init() {}

    init(
        hexQ: Int, hexR: Int, referenceLatitude: Double,
        latitude: Double, longitude: Double,
        totalSNRWeighted: Double, totalRSSIWeighted: Double,
        totalPacketCount: Int, minSNR: Double?, maxSNR: Double?,
        floodCount: Int, directCount: Int,
        activePacketCount: Int = 0, passivePacketCount: Int = 0,
        probesSent: Int? = nil,
        contributionCount: Int, firstSeen: String, lastUpdated: String
    ) {
        self.hexQ = hexQ
        self.hexR = hexR
        self.referenceLatitude = referenceLatitude
        self.latitude = latitude
        self.longitude = longitude
        self.totalSNRWeighted = totalSNRWeighted
        self.totalRSSIWeighted = totalRSSIWeighted
        self.totalPacketCount = totalPacketCount
        self.minSNR = minSNR
        self.maxSNR = maxSNR
        self.floodCount = floodCount
        self.directCount = directCount
        self.activePacketCount = activePacketCount
        self.passivePacketCount = passivePacketCount
        self.probesSent = probesSent
        self.contributionCount = contributionCount
        self.firstSeen = firstSeen
        self.lastUpdated = lastUpdated
    }

    /// Computed average SNR for display.
    var averageSNR: Double? {
        totalPacketCount > 0 ? totalSNRWeighted / Double(totalPacketCount) : nil
    }

    /// SNR quality label matching iOS app scale.
    var snrQuality: String {
        guard let snr = averageSNR else { return "unknown" }
        if snr > 10 { return "excellent" }
        if snr > 5 { return "good" }
        if snr > 0 { return "fair" }
        if snr > -10 { return "poor" }
        return "veryPoor"
    }
}
