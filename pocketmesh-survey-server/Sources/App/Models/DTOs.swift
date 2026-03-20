import Vapor

// MARK: - Upload Request

struct UploadPayload: Content {
    let version: String
    let contributorID: String
    let gridType: String
    let cellSizeDegrees: Double
    let referenceLatitude: Double
    let cells: [UploadCellData]
    let repeaters: [UploadRepeaterInfo]?
    /// Client session UUIDs included in this upload.
    /// When provided, the server replaces any existing contributions for these sessions
    /// from this contributor, making uploads idempotent per session.
    let sessionIDs: [String]?
}

struct UploadRepeaterInfo: Content {
    let hexID: String
    let name: String
    let latitude: Double
    let longitude: Double
}

struct UploadCellData: Content {
    let latitude: Double
    let longitude: Double
    let averageSNR: Double?
    let averageRSSI: Double?
    let minSNR: Double?
    let maxSNR: Double?
    let packetCount: Int
    let routeTypeBreakdown: RouteBreakdown
    let repeaterHexIDs: [String]
    let hexQ: Int
    let hexR: Int
    let referenceLatitude: Double
    /// Packets collected during active probing (bidirectional confirmation). Optional for backward compat.
    let activePacketCount: Int?
    /// Packets collected passively (RX only). Optional for backward compat.
    let passivePacketCount: Int?
    /// Per-repeater signal metrics. Optional for backward compat with older clients.
    let repeaterMetrics: [RepeaterMetricData]?
    /// Number of active probe messages sent from this cell. Optional for backward compat.
    let probesSent: Int?
}

/// Per-repeater signal metrics within a cell.
struct RepeaterMetricData: Content {
    let hexID: String
    let averageSNR: Double?
    let averageRSSI: Double?
    let packetCount: Int
    /// ISO 8601 timestamp of the most recent packet from this repeater in this cell.
    let lastHeard: String?
}

struct RouteBreakdown: Content {
    let flood: Int
    let direct: Int
}

// MARK: - Upload Response

struct UploadResponse: Content {
    let accepted: Int
    let message: String?
}

// MARK: - Cells Response

struct CommunityCellResponse: Content {
    let latitude: Double
    let longitude: Double
    let hexQ: Int
    let hexR: Int
    let referenceLatitude: Double
    let averageSNR: Double?
    let packetCount: Int
    let contributionCount: Int
    let repeaterHexIDs: [String]
    let snrQuality: String
    let activePacketCount: Int?
    let passivePacketCount: Int?
    /// Per-repeater signal metrics. Nil for legacy cells without this data.
    let repeaterMetrics: [RepeaterMetricData]?
    /// Number of active probe messages sent from this cell. Nil for legacy cells.
    let probesSent: Int?
    /// ISO 8601 timestamp of last data update for this cell.
    let lastUpdated: String?
}

struct CommunityCellsResponse: Content {
    let cells: [CommunityCellResponse]
    let totalCells: Int
}

// MARK: - Stats Response

struct StatsResponse: Content {
    let totalCells: Int
    let totalContributions: Int
    let uniqueRepeaters: Int
    let uniqueContributors: Int
    let lastUpload: String?
}

// MARK: - Repeaters Response

struct RepeaterLocationResponse: Content {
    let hexID: String
    let name: String
    let latitude: Double
    let longitude: Double
}

struct RepeatersResponse: Content {
    let repeaters: [RepeaterLocationResponse]
}

// MARK: - Delete Response

struct DeleteContributorResponse: Content {
    let deletedContributions: Int
    let cellsRemoved: Int
    let cellsUpdated: Int
}

// MARK: - Admin Response

struct FixCoordinatesResponse: Content {
    let totalCells: Int
    let fixedCells: Int
}

struct NormalizeRepeatersResponse: Content {
    let cellsFixed: Int
    let repeatersRemoved: Int
    let repeatersUpgraded: Int
    let locationsRemoved: Int
    let locationsUpgraded: Int
}

// MARK: - Admin Contributors Response

struct AdminContributorInfo: Content {
    let contributorID: String
    let cellCount: Int
    let totalPacketCount: Int
    let uploadCount: Int
    let firstSeen: String?
    let lastSeen: String?
    let clientIPs: [String]
    let sessionCount: Int
}

struct AdminContributorsResponse: Content {
    let contributors: [AdminContributorInfo]
}

// MARK: - Admin Uploads Response

struct AdminUploadInfo: Content {
    let id: Int
    let contributorID: String
    let uploadedAt: String
    let cellCount: Int
    let clientIP: String?
}

struct AdminUploadsResponse: Content {
    let uploads: [AdminUploadInfo]
    let total: Int
}

// MARK: - Admin Contributor Sessions Response

struct AdminSessionCell: Content {
    let latitude: Double
    let longitude: Double
    let hexQ: Int
    let hexR: Int
    let referenceLatitude: Double
    let packetCount: Int
    let averageSNR: Double?
    let snrQuality: String
    let activePacketCount: Int
    let passivePacketCount: Int
    let probesSent: Int?
}

struct AdminSessionInfo: Content {
    let sessionID: String
    let cellCount: Int
    let totalPacketCount: Int
    let contributedAt: String?
    let cells: [AdminSessionCell]
}

struct AdminContributorSessionsResponse: Content {
    let contributorID: String
    let sessions: [AdminSessionInfo]
}

// MARK: - Admin Delete Session Response

struct AdminDeleteSessionResponse: Content {
    let contributionsRemoved: Int
    let cellsRemoved: Int
    let cellsUpdated: Int
}

// MARK: - Admin Purge Response

struct AdminPurgeResponse: Content {
    let contributorsRemoved: Int
    let contributionsRemoved: Int
    let cellsRemoved: Int
    let cellsUpdated: Int
    let uploadsRemoved: Int
}

// MARK: - Shared Route

struct SharedRouteHop: Content {
    let hexID: String
    let name: String?
    let latitude: Double?
    let longitude: Double?
}

struct CreateSharedRouteRequest: Content {
    let hopCount: Int
    let distanceText: String?
    let hops: [SharedRouteHop]
    /// User latitude at time of share (for drawing user→first-hop lines)
    let userLatitude: Double?
    /// User longitude at time of share
    let userLongitude: Double?
}

struct CreateSharedRouteResponse: Content {
    let id: String
    let url: String
}

struct SharedRouteResponse: Content {
    let id: String
    let hopCount: Int
    let distanceText: String?
    let hops: [SharedRouteHop]
    let userLatitude: Double?
    let userLongitude: Double?
    let createdAt: String
}

// MARK: - Shared Repeater Map

struct SharedRepeaterInfo: Content {
    let hexID: String
    let name: String?
    let latitude: Double?
    let longitude: Double?
    let heardCount: Int
    let avgSNR: Double?
    let avgRSSI: Double?
}

/// A single heard-repeat path: the ordered hop chain plus last-hop signal data.
struct SharedRepeatPath: Content {
    /// Ordered repeater hex IDs from first hop to last hop
    let hops: [String]
    /// SNR of the last hop (repeater → user)
    let snr: Double?
}

struct CreateSharedRepeaterMapRequest: Content {
    let repeaters: [SharedRepeaterInfo]
    /// Per-repeat paths for drawing lines on the map (optional for backwards compat)
    let paths: [SharedRepeatPath]?
    /// User latitude at time of share (for drawing last-hop lines)
    let userLatitude: Double?
    /// User longitude at time of share
    let userLongitude: Double?
}

struct CreateSharedRepeaterMapResponse: Content {
    let id: String
    let url: String
}

struct SharedRepeaterMapResponse: Content {
    let id: String
    let repeaterCount: Int
    let repeaters: [SharedRepeaterInfo]
    let paths: [SharedRepeatPath]?
    let userLatitude: Double?
    let userLongitude: Double?
    let createdAt: String
}
