import Foundation

// MARK: - Survey wire protocol (v2.x)
//
// The single source of truth for the client↔server survey API. The iOS app encodes
// these; the Vapor server decodes the same types (retroactively conformed to
// `Content` server-side). Field names are locked by explicit snake_case CodingKeys.
//
// Version history:
//   2.0  — H3 ingest, pubkey-first repeater identity (server-only era)
//   2.1  — per-direction repeater packet counts
//   2.2  — anonymous-by-default (optional contributor + deletion receipts),
//          full time data (time_range, first_heard, daily_counts, hop_histogram)

public enum SurveyWireVersion {
    public static let current = "2.2"
}

// MARK: Upload

public struct UploadV2Payload: Codable, Sendable {
    public var version: String
    /// Opt-in attribution. Nil = anonymous upload (v2.2 default); the server must
    /// then rely on `receiptB64` for deletion and dedup.
    public var contributor: UploadV2Contributor?
    /// Random 32 bytes, base64, generated fresh per batch and stored only on the
    /// uploading device. Presenting it to DELETE /api/v2/uploads/:receipt removes
    /// exactly this batch's contributions. v2.2+.
    public var receiptB64: String?
    public var h3Resolution: Int
    /// "live" → accumulate single-cell uploads; "batch" → session-replace semantics.
    public var mode: String
    public var cells: [UploadV2Cell]
    public var knownRepeaters: [UploadV2KnownRepeater]?

    public init(
        version: String = SurveyWireVersion.current,
        contributor: UploadV2Contributor? = nil,
        receiptB64: String? = nil,
        h3Resolution: Int = SurveyGrid.baseResolution,
        mode: String,
        cells: [UploadV2Cell],
        knownRepeaters: [UploadV2KnownRepeater]? = nil
    ) {
        self.version = version
        self.contributor = contributor
        self.receiptB64 = receiptB64
        self.h3Resolution = h3Resolution
        self.mode = mode
        self.cells = cells
        self.knownRepeaters = knownRepeaters
    }

    enum CodingKeys: String, CodingKey {
        case version
        case contributor
        case receiptB64 = "receipt_b64"
        case h3Resolution = "h3_resolution"
        case mode
        case cells
        case knownRepeaters = "known_repeaters"
    }
}

public struct UploadV2Contributor: Codable, Sendable {
    public var idB64: String
    public var displayName: String?
    public var sessionIds: [String]?

    public init(idB64: String, displayName: String? = nil, sessionIds: [String]? = nil) {
        self.idB64 = idB64
        self.displayName = displayName
        self.sessionIds = sessionIds
    }

    enum CodingKeys: String, CodingKey {
        case idB64 = "id_b64"
        case displayName = "display_name"
        case sessionIds = "session_ids"
    }
}

public struct UploadV2Cell: Codable, Sendable {
    /// H3 index (hex string form). Its encoded resolution is the cell's native
    /// resolution — normally `h3_resolution`, but coarse-tier sampling may upload
    /// res 9/8 cells.
    public var h3: String
    public var snr: UploadV2SnrStats
    public var rssiAvg: Double?
    public var packetCount: Int
    public var activePacketCount: Int?
    public var passivePacketCount: Int?
    public var probesSent: Int?
    public var routeBreakdown: UploadV2RouteBreakdown
    public var timeRange: UploadV2TimeRange?
    /// v2.2: observation counts per UTC day ("2026-07-18" → 42). Powers accurate
    /// time filtering and freshness decay without per-packet timestamps on the wire.
    public var dailyCounts: [String: Int]?
    /// v2.2: mesh-depth distribution — hop count → packets ("0" → 12, "1" → 30).
    public var hopHistogram: [String: Int]?
    public var repeaters: [UploadV2RepeaterObservation]

    public init(
        h3: String,
        snr: UploadV2SnrStats,
        rssiAvg: Double? = nil,
        packetCount: Int,
        activePacketCount: Int? = nil,
        passivePacketCount: Int? = nil,
        probesSent: Int? = nil,
        routeBreakdown: UploadV2RouteBreakdown,
        timeRange: UploadV2TimeRange? = nil,
        dailyCounts: [String: Int]? = nil,
        hopHistogram: [String: Int]? = nil,
        repeaters: [UploadV2RepeaterObservation]
    ) {
        self.h3 = h3
        self.snr = snr
        self.rssiAvg = rssiAvg
        self.packetCount = packetCount
        self.activePacketCount = activePacketCount
        self.passivePacketCount = passivePacketCount
        self.probesSent = probesSent
        self.routeBreakdown = routeBreakdown
        self.timeRange = timeRange
        self.dailyCounts = dailyCounts
        self.hopHistogram = hopHistogram
        self.repeaters = repeaters
    }

    enum CodingKeys: String, CodingKey {
        case h3
        case snr
        case rssiAvg = "rssi_avg"
        case packetCount = "packet_count"
        case activePacketCount = "active_packet_count"
        case passivePacketCount = "passive_packet_count"
        case probesSent = "probes_sent"
        case routeBreakdown = "route_breakdown"
        case timeRange = "time_range"
        case dailyCounts = "daily_counts"
        case hopHistogram = "hop_histogram"
        case repeaters
    }
}

public struct UploadV2SnrStats: Codable, Sendable {
    public var avg: Double?
    public var min: Double?
    public var max: Double?
    public var txAvg: Double?

    public init(avg: Double? = nil, min: Double? = nil, max: Double? = nil, txAvg: Double? = nil) {
        self.avg = avg
        self.min = min
        self.max = max
        self.txAvg = txAvg
    }

    enum CodingKeys: String, CodingKey {
        case avg, min, max
        case txAvg = "tx_avg"
    }
}

public struct UploadV2RouteBreakdown: Codable, Sendable {
    public var flood: Int
    public var direct: Int

    public init(flood: Int, direct: Int) {
        self.flood = flood
        self.direct = direct
    }
}

public struct UploadV2TimeRange: Codable, Sendable {
    public var earliest: String
    public var latest: String

    public init(earliest: String, latest: String) {
        self.earliest = earliest
        self.latest = latest
    }
}

/// One repeater observed in a cell — directional: `rxPacketCount` counts packets we
/// heard from/via it; `txPacketCount` counts probes of ours it confirmably relayed
/// (which is when `txSnr` — how well it hears us — is populated).
public struct UploadV2RepeaterObservation: Codable, Sendable {
    public var kind: String                     // "pubkey" | "prefix"
    public var pubkeyB64: String?
    public var prefixB64: String?
    public var anchor: UploadV2Anchor?
    public var observationLat: Double?
    public var observationLon: Double?
    public var snr: Double?
    public var rssi: Double?
    public var txSnr: Double?
    public var packetCount: Int
    public var rxPacketCount: Int?
    public var txPacketCount: Int?
    /// v2.2: when this repeater was first heard in this cell (ISO 8601).
    public var firstHeard: String?
    public var lastHeard: String?

    public init(
        kind: String,
        pubkeyB64: String? = nil,
        prefixB64: String? = nil,
        anchor: UploadV2Anchor? = nil,
        observationLat: Double? = nil,
        observationLon: Double? = nil,
        snr: Double? = nil,
        rssi: Double? = nil,
        txSnr: Double? = nil,
        packetCount: Int,
        rxPacketCount: Int? = nil,
        txPacketCount: Int? = nil,
        firstHeard: String? = nil,
        lastHeard: String? = nil
    ) {
        self.kind = kind
        self.pubkeyB64 = pubkeyB64
        self.prefixB64 = prefixB64
        self.anchor = anchor
        self.observationLat = observationLat
        self.observationLon = observationLon
        self.snr = snr
        self.rssi = rssi
        self.txSnr = txSnr
        self.packetCount = packetCount
        self.rxPacketCount = rxPacketCount
        self.txPacketCount = txPacketCount
        self.firstHeard = firstHeard
        self.lastHeard = lastHeard
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case pubkeyB64 = "pubkey_b64"
        case prefixB64 = "prefix_b64"
        case anchor
        case observationLat = "observation_lat"
        case observationLon = "observation_lon"
        case snr, rssi
        case txSnr = "tx_snr"
        case packetCount = "packet_count"
        case rxPacketCount = "rx_packet_count"
        case txPacketCount = "tx_packet_count"
        case firstHeard = "first_heard"
        case lastHeard = "last_heard"
    }
}

public struct UploadV2Anchor: Codable, Sendable {
    public var kind: String                     // "pubkey" | "coord"
    public var pubkeyB64: String?
    public var lat: Double?
    public var lon: Double?

    public init(kind: String, pubkeyB64: String? = nil, lat: Double? = nil, lon: Double? = nil) {
        self.kind = kind
        self.pubkeyB64 = pubkeyB64
        self.lat = lat
        self.lon = lon
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case pubkeyB64 = "pubkey_b64"
        case lat, lon
    }
}

public struct UploadV2KnownRepeater: Codable, Sendable {
    public var pubkeyB64: String
    public var name: String
    public var lat: Double
    public var lon: Double
    public var lastHeard: String?
    public var lastAdvert: String?

    public init(
        pubkeyB64: String,
        name: String,
        lat: Double,
        lon: Double,
        lastHeard: String? = nil,
        lastAdvert: String? = nil
    ) {
        self.pubkeyB64 = pubkeyB64
        self.name = name
        self.lat = lat
        self.lon = lon
        self.lastHeard = lastHeard
        self.lastAdvert = lastAdvert
    }

    enum CodingKeys: String, CodingKey {
        case pubkeyB64 = "pubkey_b64"
        case name, lat, lon
        case lastHeard = "last_heard"
        case lastAdvert = "last_advert"
    }
}

public struct UploadV2Response: Codable, Sendable {
    public var cellsUpdated: Int
    public var accepted: Int
    public var ambiguous: Int
    public var promoted: Int

    public init(cellsUpdated: Int, accepted: Int, ambiguous: Int, promoted: Int) {
        self.cellsUpdated = cellsUpdated
        self.accepted = accepted
        self.ambiguous = ambiguous
        self.promoted = promoted
    }

    enum CodingKeys: String, CodingKey {
        case cellsUpdated = "cells_updated"
        case accepted
        case ambiguous
        case promoted
    }
}

// MARK: Cell queries

public struct CellsV2Response: Codable, Sendable {
    public var cells: [CellV2Response]
    public var totalCells: Int
    public var totalMatching: Int?

    public init(cells: [CellV2Response], totalCells: Int, totalMatching: Int? = nil) {
        self.cells = cells
        self.totalCells = totalCells
        self.totalMatching = totalMatching
    }
}

public struct CellV2Response: Codable, Sendable {
    public var h3: String
    public var lat: Double
    public var lon: Double
    public var avgSnr: Double?
    public var avgTxSnr: Double?
    public var avgRssi: Double?
    public var minSnr: Double?
    public var maxSnr: Double?
    public var snrQuality: String
    public var packetCount: Int
    public var activePacketCount: Int
    public var passivePacketCount: Int
    public var probesSent: Int?
    public var successRate: Double?
    public var routeBreakdown: UploadV2RouteBreakdown
    public var contributionCount: Int
    public var lastUpdated: String
    public var repeaters: [CellRepeaterV2Response]
    public var isDeadZone: Bool
    public var isAmbiguous: Bool

    public init(
        h3: String,
        lat: Double,
        lon: Double,
        avgSnr: Double? = nil,
        avgTxSnr: Double? = nil,
        avgRssi: Double? = nil,
        minSnr: Double? = nil,
        maxSnr: Double? = nil,
        snrQuality: String,
        packetCount: Int,
        activePacketCount: Int,
        passivePacketCount: Int,
        probesSent: Int? = nil,
        successRate: Double? = nil,
        routeBreakdown: UploadV2RouteBreakdown,
        contributionCount: Int,
        lastUpdated: String,
        repeaters: [CellRepeaterV2Response],
        isDeadZone: Bool,
        isAmbiguous: Bool
    ) {
        self.h3 = h3
        self.lat = lat
        self.lon = lon
        self.avgSnr = avgSnr
        self.avgTxSnr = avgTxSnr
        self.avgRssi = avgRssi
        self.minSnr = minSnr
        self.maxSnr = maxSnr
        self.snrQuality = snrQuality
        self.packetCount = packetCount
        self.activePacketCount = activePacketCount
        self.passivePacketCount = passivePacketCount
        self.probesSent = probesSent
        self.successRate = successRate
        self.routeBreakdown = routeBreakdown
        self.contributionCount = contributionCount
        self.lastUpdated = lastUpdated
        self.repeaters = repeaters
        self.isDeadZone = isDeadZone
        self.isAmbiguous = isAmbiguous
    }

    enum CodingKeys: String, CodingKey {
        case h3, lat, lon
        case avgSnr = "avg_snr"
        case avgTxSnr = "avg_tx_snr"
        case avgRssi = "avg_rssi"
        case minSnr = "min_snr"
        case maxSnr = "max_snr"
        case snrQuality = "snr_quality"
        case packetCount = "packet_count"
        case activePacketCount = "active_packet_count"
        case passivePacketCount = "passive_packet_count"
        case probesSent = "probes_sent"
        case successRate = "success_rate"
        case routeBreakdown = "route_breakdown"
        case contributionCount = "contribution_count"
        case lastUpdated = "last_updated"
        case repeaters
        case isDeadZone = "is_dead_zone"
        case isAmbiguous = "is_ambiguous"
    }
}

public struct CellRepeaterV2Response: Codable, Sendable {
    public var id: String
    public var avgSnr: Double?
    public var avgTxSnr: Double?
    public var avgRssi: Double?
    public var packetCount: Int
    public var rxPacketCount: Int?
    public var txPacketCount: Int?
    public var firstHeard: String?
    public var lastHeard: String?

    public init(
        id: String,
        avgSnr: Double? = nil,
        avgTxSnr: Double? = nil,
        avgRssi: Double? = nil,
        packetCount: Int,
        rxPacketCount: Int? = nil,
        txPacketCount: Int? = nil,
        firstHeard: String? = nil,
        lastHeard: String? = nil
    ) {
        self.id = id
        self.avgSnr = avgSnr
        self.avgTxSnr = avgTxSnr
        self.avgRssi = avgRssi
        self.packetCount = packetCount
        self.rxPacketCount = rxPacketCount
        self.txPacketCount = txPacketCount
        self.firstHeard = firstHeard
        self.lastHeard = lastHeard
    }

    enum CodingKeys: String, CodingKey {
        case id
        case avgSnr = "avg_snr"
        case avgTxSnr = "avg_tx_snr"
        case avgRssi = "avg_rssi"
        case packetCount = "packet_count"
        case rxPacketCount = "rx_packet_count"
        case txPacketCount = "tx_packet_count"
        case firstHeard = "first_heard"
        case lastHeard = "last_heard"
    }
}

// MARK: Repeaters & stats

public struct RepeatersV2Response: Codable, Sendable {
    public var repeaters: [RepeaterV2Response]

    public init(repeaters: [RepeaterV2Response]) {
        self.repeaters = repeaters
    }
}

public struct RepeaterV2Response: Codable, Sendable {
    public var id: String
    public var name: String
    public var lat: Double
    public var lon: Double
    public var lastHeard: String?
    public var lastAdvert: String?

    public init(
        id: String,
        name: String,
        lat: Double,
        lon: Double,
        lastHeard: String? = nil,
        lastAdvert: String? = nil
    ) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.lastHeard = lastHeard
        self.lastAdvert = lastAdvert
    }

    enum CodingKeys: String, CodingKey {
        case id, name, lat, lon
        case lastHeard = "last_heard"
        case lastAdvert = "last_advert"
    }
}

public struct StatsV2Response: Codable, Sendable {
    public var totalCells: Int
    public var totalContributions: Int
    public var uniqueRepeaters: Int
    public var uniqueContributors: Int
    public var ambiguousObservations: Int
    public var lastUpload: String?

    public init(
        totalCells: Int,
        totalContributions: Int,
        uniqueRepeaters: Int,
        uniqueContributors: Int,
        ambiguousObservations: Int,
        lastUpload: String? = nil
    ) {
        self.totalCells = totalCells
        self.totalContributions = totalContributions
        self.uniqueRepeaters = uniqueRepeaters
        self.uniqueContributors = uniqueContributors
        self.ambiguousObservations = ambiguousObservations
        self.lastUpload = lastUpload
    }

    enum CodingKeys: String, CodingKey {
        case totalCells = "total_cells"
        case totalContributions = "total_contributions"
        case uniqueRepeaters = "unique_repeaters"
        case uniqueContributors = "unique_contributors"
        case ambiguousObservations = "ambiguous_observations"
        case lastUpload = "last_upload"
    }
}

// MARK: Receipt deletion

public struct ReceiptDeleteResponse: Codable, Sendable {
    public var deletedContributions: Int
    public var cellsUpdated: Int
    public var cellsRemoved: Int

    public init(deletedContributions: Int, cellsUpdated: Int, cellsRemoved: Int) {
        self.deletedContributions = deletedContributions
        self.cellsUpdated = cellsUpdated
        self.cellsRemoved = cellsRemoved
    }

    enum CodingKeys: String, CodingKey {
        case deletedContributions = "deleted_contributions"
        case cellsUpdated = "cells_updated"
        case cellsRemoved = "cells_removed"
    }
}
