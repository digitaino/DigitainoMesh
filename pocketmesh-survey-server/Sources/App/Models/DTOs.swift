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
