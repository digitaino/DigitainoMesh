import Fluent
import Vapor
import Foundation

/// Hex grid math matching the iOS client's HexGrid.swift
private enum HexGridServer {
    static let size: Double = 0.0005

    /// Compute the exact center lat/lon for a hex cell from its axial coordinates.
    /// Must match HexGrid.centerLatLon in the iOS client.
    static func centerLatLon(hexQ: Int, hexR: Int, referenceLatitude: Double) -> (latitude: Double, longitude: Double) {
        let lonScale = cos(referenceLatitude * .pi / 180.0)
        let scaledLon = size * 3.0 / 2.0 * Double(hexQ)
        let latitude = size * sqrt(3.0) * (Double(hexR) + Double(hexQ) / 2.0)
        let longitude = scaledLon / lonScale
        return (latitude: latitude, longitude: longitude)
    }
}

struct SurveyController {

    // MARK: - Hex ID Normalization

    /// Normalizes a hex ID against a set of existing hex IDs.
    /// If the incoming ID is a prefix of an existing one, returns the longer existing ID.
    /// If an existing ID is a prefix of the incoming one, returns the incoming (longer) ID.
    /// Otherwise returns the original ID unchanged.
    private static func normalizeHexID(_ hexID: String, existing: [String]) -> String {
        let upper = hexID.uppercased()
        // Check if any existing ID is a longer version of this one
        for existingID in existing {
            let existingUpper = existingID.uppercased()
            if existingUpper.hasPrefix(upper) && existingUpper.count > upper.count {
                return existingUpper
            }
        }
        return upper
    }

    /// Given a set of hex IDs, consolidates those that are prefixes of each other,
    /// keeping only the longest version of each.
    private static func consolidateHexIDs(_ hexIDs: [String]) -> [String] {
        let upper = hexIDs.map { $0.uppercased() }
        var result: [String] = []
        for id in upper {
            // Check if this ID is already a prefix of something in result
            if result.contains(where: { $0.hasPrefix(id) && $0.count > id.count }) {
                continue // skip — a longer version already present
            }
            // Remove any existing entries that are prefixes of this ID
            result.removeAll { id.hasPrefix($0) && id.count > $0.count }
            if !result.contains(id) {
                result.append(id)
            }
        }
        return result
    }

    // MARK: - Per-Repeater Metric Merging

    /// Merge uploaded per-repeater metrics into an existing CellRepeater record using weighted averages.
    private static func mergeRepeaterMetrics(existing: CellRepeater, upload: RepeaterMetricData) {
        let oldCount = existing.packetCount ?? 0
        let newCount = upload.packetCount

        if oldCount == 0 {
            // No existing metrics — just set from upload
            existing.averageSNR = upload.averageSNR
            existing.averageRSSI = upload.averageRSSI
            existing.packetCount = newCount
        } else {
            let totalCount = oldCount + newCount
            // Weighted average for SNR
            if let oldSNR = existing.averageSNR, let newSNR = upload.averageSNR {
                existing.averageSNR = (oldSNR * Double(oldCount) + newSNR * Double(newCount)) / Double(totalCount)
            } else if let newSNR = upload.averageSNR {
                existing.averageSNR = newSNR
            }
            // Weighted average for RSSI
            if let oldRSSI = existing.averageRSSI, let newRSSI = upload.averageRSSI {
                existing.averageRSSI = (oldRSSI * Double(oldCount) + newRSSI * Double(newCount)) / Double(totalCount)
            } else if let newRSSI = upload.averageRSSI {
                existing.averageRSSI = newRSSI
            }
            existing.packetCount = totalCount
        }

        // Keep the most recent lastHeard timestamp
        if let newLastHeard = upload.lastHeard {
            if let existingLastHeard = existing.lastHeard {
                if newLastHeard > existingLastHeard {
                    existing.lastHeard = newLastHeard
                }
            } else {
                existing.lastHeard = newLastHeard
            }
        }
    }

    // MARK: - Session Deduplication

    /// Remove existing contributions for the given session IDs from this contributor,
    /// subtracting their data from cell aggregates. Returns the number of contributions removed.
    private func removeSessionContributions(
        contributorID: String,
        sessionIDs: [String],
        on db: Database
    ) async throws -> Int {
        var removedCount = 0

        for sessionID in sessionIDs {
            let existing = try await CellContribution.query(on: db)
                .filter(\.$contributorID == contributorID)
                .filter(\.$sessionID == sessionID)
                .with(\.$cell)
                .all()

            for contribution in existing {
                let cell = contribution.cell

                // Subtract this contribution's data from cell aggregates
                cell.totalSNRWeighted -= contribution.snrWeighted
                cell.totalRSSIWeighted -= contribution.rssiWeighted ?? 0
                cell.totalPacketCount -= contribution.packetCount
                cell.floodCount -= contribution.floodCount
                cell.directCount -= contribution.directCount
                cell.activePacketCount -= contribution.activePacketCount
                cell.passivePacketCount -= contribution.passivePacketCount
                if let contribProbes = contribution.probesSent, contribProbes > 0 {
                    cell.probesSent = max(0, (cell.probesSent ?? 0) - contribProbes)
                }
                cell.contributionCount -= 1

                if cell.totalPacketCount <= 0 {
                    try await cell.delete(on: db)
                } else {
                    try await cell.save(on: db)
                }

                try await contribution.delete(on: db)
                removedCount += 1
            }
        }

        return removedCount
    }

    // MARK: - POST /api/v1/survey

    @Sendable
    func uploadSurvey(req: Request) async throws -> UploadResponse {
        let payload = try req.content.decode(UploadPayload.self)

        // Validation
        guard payload.cells.count <= 10_000 else {
            throw Abort(.badRequest, reason: "Too many cells (max 10,000)")
        }

        for cell in payload.cells {
            guard (-90...90).contains(cell.latitude),
                  (-180...180).contains(cell.longitude) else {
                throw Abort(.badRequest, reason: "Invalid coordinates")
            }
            if let snr = cell.averageSNR, !(-30...30).contains(snr) {
                throw Abort(.badRequest, reason: "SNR out of range")
            }
        }

        let now = ISO8601DateFormatter().string(from: Date())
        // Normalize reference latitude to nearest 10° band for global grid alignment.
        // All clients use the same rounding so cells from different sessions merge correctly.
        let normalizedRefLat = (payload.referenceLatitude / 10.0).rounded() * 10.0

        // Session-based deduplication: if sessionIDs are provided AND this is a batch upload
        // (more than 1 cell), remove any existing contributions for those sessions before
        // adding new data. This makes re-uploading the same session idempotent.
        // Single-cell uploads (live) skip dedup so they accumulate incrementally.
        let sessionIDs = payload.sessionIDs ?? []
        if !sessionIDs.isEmpty && payload.cells.count > 1 {
            let removed = try await removeSessionContributions(
                contributorID: payload.contributorID,
                sessionIDs: sessionIDs,
                on: req.db
            )
            if removed > 0 {
                req.logger.info("Removed \(removed) existing contributions for \(sessionIDs.count) session(s) from contributor \(payload.contributorID.prefix(8))...")
            }
        }

        // Build a session tag for contribution records.
        // For single-session uploads: the session UUID directly.
        // For multi-session batch: sorted+joined so dedup works on the same combination.
        let sessionTag: String? = sessionIDs.isEmpty ? nil : sessionIDs.sorted().joined(separator: "+")

        var acceptedCount = 0

        for cellData in payload.cells {
            // Look for existing cell with same hex coordinates
            let existing = try await CellModel.query(on: req.db)
                .filter(\.$hexQ == cellData.hexQ)
                .filter(\.$hexR == cellData.hexR)
                .filter(\.$referenceLatitude == normalizedRefLat)
                .first()

            let snrWeighted = (cellData.averageSNR ?? 0) * Double(cellData.packetCount)
            let rssiWeighted = cellData.averageRSSI.map { $0 * Double(cellData.packetCount) }

            let activePkts = cellData.activePacketCount ?? 0
            let passivePkts = cellData.passivePacketCount ?? 0
            let probesSent = cellData.probesSent ?? 0

            if let existing {
                // Merge into existing cell
                existing.totalSNRWeighted += snrWeighted
                existing.totalRSSIWeighted += rssiWeighted ?? 0
                existing.totalPacketCount += cellData.packetCount
                existing.floodCount += cellData.routeTypeBreakdown.flood
                existing.directCount += cellData.routeTypeBreakdown.direct
                existing.activePacketCount += activePkts
                existing.passivePacketCount += passivePkts
                if probesSent > 0 {
                    existing.probesSent = (existing.probesSent ?? 0) + probesSent
                }
                existing.contributionCount += 1
                existing.lastUpdated = now

                if let newMin = cellData.minSNR {
                    if let existingMin = existing.minSNR {
                        existing.minSNR = min(existingMin, newMin)
                    } else {
                        existing.minSNR = newMin
                    }
                }
                if let newMax = cellData.maxSNR {
                    if let existingMax = existing.maxSNR {
                        existing.maxSNR = max(existingMax, newMax)
                    } else {
                        existing.maxSNR = newMax
                    }
                }

                try await existing.save(on: req.db)

                // Add new repeaters (with hex ID normalization and per-repeater metrics)
                if let cellID = existing.id {
                    let existingRepeaters = try await CellRepeater.query(on: req.db)
                        .filter(\.$cell.$id == cellID)
                        .all()
                    // Build lookup for per-repeater metrics from this upload
                    let metricsByHex: [String: RepeaterMetricData] = {
                        var dict: [String: RepeaterMetricData] = [:]
                        for m in cellData.repeaterMetrics ?? [] {
                            dict[m.hexID.uppercased()] = m
                        }
                        return dict
                    }()

                    for hexID in cellData.repeaterHexIDs {
                        let normalized = hexID.uppercased()
                        // Find metric for this repeater (prefix-aware)
                        let metric = metricsByHex[normalized] ?? metricsByHex.first(where: { key, _ in
                            key.hasPrefix(normalized) || normalized.hasPrefix(key)
                        })?.value

                        // Check if a shorter prefix already exists — upgrade it
                        if let match = existingRepeaters.first(where: {
                            let eid = $0.repeaterHexID.uppercased()
                            return normalized.hasPrefix(eid) && normalized.count > eid.count
                        }) {
                            match.repeaterHexID = normalized
                            // Merge per-repeater metrics using weighted average
                            if let metric {
                                Self.mergeRepeaterMetrics(existing: match, upload: metric)
                            }
                            try await match.save(on: req.db)
                        } else if let match = existingRepeaters.first(where: {
                            let eid = $0.repeaterHexID.uppercased()
                            return eid == normalized || eid.hasPrefix(normalized)
                        }) {
                            // Already have this exact ID or a longer version — merge metrics only
                            if let metric {
                                Self.mergeRepeaterMetrics(existing: match, upload: metric)
                                try await match.save(on: req.db)
                            }
                        } else {
                            let repeater = CellRepeater(
                                cellID: cellID,
                                repeaterHexID: normalized,
                                averageSNR: metric?.averageSNR,
                                averageRSSI: metric?.averageRSSI,
                                packetCount: metric?.packetCount,
                                lastHeard: metric?.lastHeard
                            )
                            try await repeater.save(on: req.db)
                        }
                    }

                    // Record contribution
                    let contribution = CellContribution(
                        cellID: cellID,
                        contributorID: payload.contributorID,
                        packetCount: cellData.packetCount,
                        snrWeighted: snrWeighted,
                        rssiWeighted: rssiWeighted,
                        floodCount: cellData.routeTypeBreakdown.flood,
                        directCount: cellData.routeTypeBreakdown.direct,
                        activePacketCount: activePkts,
                        passivePacketCount: passivePkts,
                        probesSent: probesSent > 0 ? probesSent : nil,
                        contributedAt: now,
                        sessionID: sessionTag
                    )
                    try await contribution.save(on: req.db)
                }
            } else {
                // Create new cell — compute exact hex center from axial coordinates
                let hexCenter = HexGridServer.centerLatLon(
                    hexQ: cellData.hexQ, hexR: cellData.hexR,
                    referenceLatitude: normalizedRefLat
                )
                let cell = CellModel(
                    hexQ: cellData.hexQ, hexR: cellData.hexR,
                    referenceLatitude: normalizedRefLat,
                    latitude: hexCenter.latitude, longitude: hexCenter.longitude,
                    totalSNRWeighted: snrWeighted,
                    totalRSSIWeighted: rssiWeighted ?? 0,
                    totalPacketCount: cellData.packetCount,
                    minSNR: cellData.minSNR, maxSNR: cellData.maxSNR,
                    floodCount: cellData.routeTypeBreakdown.flood,
                    directCount: cellData.routeTypeBreakdown.direct,
                    activePacketCount: activePkts,
                    passivePacketCount: passivePkts,
                    probesSent: probesSent > 0 ? probesSent : nil,
                    contributionCount: 1,
                    firstSeen: now, lastUpdated: now
                )
                try await cell.save(on: req.db)

                if let cellID = cell.id {
                    // Add repeaters (consolidated + uppercased) with per-repeater metrics
                    let consolidatedIDs = Self.consolidateHexIDs(cellData.repeaterHexIDs)
                    let metricsByHex: [String: RepeaterMetricData] = {
                        var dict: [String: RepeaterMetricData] = [:]
                        for m in cellData.repeaterMetrics ?? [] {
                            dict[m.hexID.uppercased()] = m
                        }
                        return dict
                    }()
                    for hexID in consolidatedIDs {
                        let metric = metricsByHex[hexID] ?? metricsByHex.first(where: { key, _ in
                            key.hasPrefix(hexID) || hexID.hasPrefix(key)
                        })?.value
                        let repeater = CellRepeater(
                            cellID: cellID,
                            repeaterHexID: hexID,
                            averageSNR: metric?.averageSNR,
                            averageRSSI: metric?.averageRSSI,
                            packetCount: metric?.packetCount,
                            lastHeard: metric?.lastHeard
                        )
                        try await repeater.save(on: req.db)
                    }

                    // Record contribution
                    let contribution = CellContribution(
                        cellID: cellID,
                        contributorID: payload.contributorID,
                        packetCount: cellData.packetCount,
                        snrWeighted: snrWeighted,
                        rssiWeighted: rssiWeighted,
                        floodCount: cellData.routeTypeBreakdown.flood,
                        directCount: cellData.routeTypeBreakdown.direct,
                        activePacketCount: activePkts,
                        passivePacketCount: passivePkts,
                        probesSent: probesSent > 0 ? probesSent : nil,
                        contributedAt: now,
                        sessionID: sessionTag
                    )
                    try await contribution.save(on: req.db)
                }
            }

            acceptedCount += 1
        }

        // Upsert repeater locations from resolved info (with prefix normalization)
        if let repeaterInfos = payload.repeaters {
            for info in repeaterInfos {
                guard (-90...90).contains(info.latitude),
                      (-180...180).contains(info.longitude) else { continue }

                let normalized = info.hexID.uppercased()

                // Look for exact match first
                let exact = try await RepeaterLocation.query(on: req.db)
                    .filter(\.$hexID == normalized)
                    .first()

                if let exact {
                    exact.name = info.name
                    exact.latitude = info.latitude
                    exact.longitude = info.longitude
                    exact.lastUpdated = now
                    try await exact.save(on: req.db)
                    continue
                }

                // Check if a shorter prefix exists — upgrade it
                let allRepeaters = try await RepeaterLocation.query(on: req.db).all()
                if let shorter = allRepeaters.first(where: {
                    let eid = $0.hexID.uppercased()
                    return normalized.hasPrefix(eid) && normalized.count > eid.count
                }) {
                    shorter.hexID = normalized
                    shorter.name = info.name
                    shorter.latitude = info.latitude
                    shorter.longitude = info.longitude
                    shorter.lastUpdated = now
                    try await shorter.save(on: req.db)
                    continue
                }

                // Check if a longer version already exists — skip
                if allRepeaters.contains(where: {
                    let eid = $0.hexID.uppercased()
                    return eid.hasPrefix(normalized) && eid.count > normalized.count
                }) {
                    continue
                }

                let repeater = RepeaterLocation(
                    hexID: normalized,
                    name: info.name,
                    latitude: info.latitude,
                    longitude: info.longitude,
                    lastUpdated: now
                )
                try await repeater.save(on: req.db)
            }
        }

        // Log upload
        let log = UploadLog(
            contributorID: payload.contributorID,
            uploadedAt: now,
            cellCount: acceptedCount,
            clientIP: req.peerAddress?.description,
            accepted: true
        )
        try await log.save(on: req.db)

        // Notify connected web map clients about the new data
        await SSEBroadcaster.shared.broadcast(
            event: "upload",
            data: "{\"cells\":\(acceptedCount)}"
        )

        return UploadResponse(accepted: acceptedCount, message: "ok")
    }

    // MARK: - GET /api/v1/cells

    @Sendable
    func getCells(req: Request) async throws -> CommunityCellsResponse {
        guard let minLat = req.query[Double.self, at: "minLat"],
              let maxLat = req.query[Double.self, at: "maxLat"],
              let minLon = req.query[Double.self, at: "minLon"],
              let maxLon = req.query[Double.self, at: "maxLon"] else {
            throw Abort(.badRequest, reason: "Missing bounding box parameters")
        }

        let limit = req.query[Int.self, at: "limit"] ?? 5000

        let cells = try await CellModel.query(on: req.db)
            .filter(\.$latitude >= minLat)
            .filter(\.$latitude <= maxLat)
            .filter(\.$longitude >= minLon)
            .filter(\.$longitude <= maxLon)
            .with(\.$repeaters)
            .range(..<limit)
            .all()

        let totalCount = try await CellModel.query(on: req.db)
            .filter(\.$latitude >= minLat)
            .filter(\.$latitude <= maxLat)
            .filter(\.$longitude >= minLon)
            .filter(\.$longitude <= maxLon)
            .count()

        let responseCells = cells.map { cell in
            // Build per-repeater metrics from CellRepeater records that have signal data
            let metrics: [RepeaterMetricData]? = {
                let withData = cell.repeaters.filter { $0.packetCount != nil }
                guard !withData.isEmpty else { return nil }
                return withData.map { r in
                    RepeaterMetricData(
                        hexID: r.repeaterHexID,
                        averageSNR: r.averageSNR,
                        averageRSSI: r.averageRSSI,
                        packetCount: r.packetCount ?? 0,
                        lastHeard: r.lastHeard
                    )
                }
            }()

            return CommunityCellResponse(
                latitude: cell.latitude,
                longitude: cell.longitude,
                hexQ: cell.hexQ,
                hexR: cell.hexR,
                referenceLatitude: cell.referenceLatitude,
                averageSNR: cell.averageSNR,
                packetCount: cell.totalPacketCount,
                contributionCount: cell.contributionCount,
                repeaterHexIDs: Self.consolidateHexIDs(cell.repeaters.map(\.repeaterHexID)),
                snrQuality: cell.snrQuality,
                activePacketCount: cell.activePacketCount > 0 ? cell.activePacketCount : nil,
                passivePacketCount: cell.passivePacketCount > 0 ? cell.passivePacketCount : nil,
                repeaterMetrics: metrics,
                probesSent: cell.probesSent,
                lastUpdated: cell.lastUpdated
            )
        }

        return CommunityCellsResponse(cells: responseCells, totalCells: totalCount)
    }

    // MARK: - GET /api/v1/stats

    @Sendable
    func getStats(req: Request) async throws -> StatsResponse {
        let totalCells = try await CellModel.query(on: req.db).count()
        let totalContributions = try await UploadLog.query(on: req.db)
            .filter(\.$accepted == true)
            .count()
        let uniqueRepeaters = try await CellRepeater.query(on: req.db)
            .unique()
            .all(\.$repeaterHexID)
            .count
        let uniqueContributors = try await CellContribution.query(on: req.db)
            .unique()
            .all(\.$contributorID)
            .count

        let lastUpload = try await UploadLog.query(on: req.db)
            .sort(\.$uploadedAt, .descending)
            .first()

        return StatsResponse(
            totalCells: totalCells,
            totalContributions: totalContributions,
            uniqueRepeaters: uniqueRepeaters,
            uniqueContributors: uniqueContributors,
            lastUpload: lastUpload?.uploadedAt
        )
    }

    // MARK: - DELETE /api/v1/contributor/:contributorID

    @Sendable
    func deleteContributor(req: Request) async throws -> DeleteContributorResponse {
        guard let contributorID = req.parameters.get("contributorID") else {
            throw Abort(.badRequest, reason: "Missing contributor ID")
        }

        // Find all contributions by this contributor
        let contributions = try await CellContribution.query(on: req.db)
            .filter(\.$contributorID == contributorID)
            .with(\.$cell)
            .all()

        var cellsRemoved = 0
        var cellsUpdated = 0

        for contribution in contributions {
            let cell = contribution.cell

            // Subtract this contributor's data from cell totals
            cell.totalSNRWeighted -= contribution.snrWeighted
            cell.totalRSSIWeighted -= contribution.rssiWeighted ?? 0
            cell.totalPacketCount -= contribution.packetCount
            cell.floodCount -= contribution.floodCount
            cell.directCount -= contribution.directCount
            cell.activePacketCount -= contribution.activePacketCount
            cell.passivePacketCount -= contribution.passivePacketCount
            if let contribProbes = contribution.probesSent, contribProbes > 0 {
                cell.probesSent = max(0, (cell.probesSent ?? 0) - contribProbes)
            }
            cell.contributionCount -= 1

            if cell.totalPacketCount <= 0 {
                // Delete the cell entirely
                try await cell.delete(on: req.db)
                cellsRemoved += 1
            } else {
                try await cell.save(on: req.db)
                cellsUpdated += 1
            }

            // Delete the contribution record
            try await contribution.delete(on: req.db)
        }

        // Delete upload logs
        try await UploadLog.query(on: req.db)
            .filter(\.$contributorID == contributorID)
            .delete()

        return DeleteContributorResponse(
            deletedContributions: contributions.count,
            cellsRemoved: cellsRemoved,
            cellsUpdated: cellsUpdated
        )
    }

    // MARK: - GET /api/v1/repeaters

    @Sendable
    func getRepeaters(req: Request) async throws -> RepeatersResponse {
        let minLat = req.query[Double.self, at: "minLat"]
        let maxLat = req.query[Double.self, at: "maxLat"]
        let minLon = req.query[Double.self, at: "minLon"]
        let maxLon = req.query[Double.self, at: "maxLon"]

        var query = RepeaterLocation.query(on: req.db)

        // Apply bounding box filter if all params provided
        if let minLat, let maxLat, let minLon, let maxLon {
            query = query
                .filter(\.$latitude >= minLat)
                .filter(\.$latitude <= maxLat)
                .filter(\.$longitude >= minLon)
                .filter(\.$longitude <= maxLon)
        }

        let locations = try await query.all()

        let response = locations.map {
            RepeaterLocationResponse(
                hexID: $0.hexID,
                name: $0.name,
                latitude: $0.latitude,
                longitude: $0.longitude
            )
        }

        return RepeatersResponse(repeaters: response)
    }

    // MARK: - GET /api/v1/mapkit-token

    @Sendable
    func getMapKitToken(req: Request) async throws -> Response {
        let token = try MapKitTokenGenerator.generateToken()
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/plain")
        // Cache for 1 hour (tokens are valid 24h, so this is safe)
        headers.add(name: .cacheControl, value: "max-age=3600, public")
        return Response(status: .ok, headers: headers, body: .init(string: token))
    }

    // MARK: - POST /api/v1/admin/normalize-repeaters

    @Sendable
    func normalizeRepeaters(req: Request) async throws -> NormalizeRepeatersResponse {
        // 1. Consolidate CellRepeater entries per cell
        let allCells = try await CellModel.query(on: req.db)
            .with(\.$repeaters)
            .all()

        var cellsFixed = 0
        var repeatersRemoved = 0
        var repeatersUpgraded = 0

        for cell in allCells {
            let repeaters = cell.repeaters
            guard !repeaters.isEmpty else { continue }

            let originalIDs = repeaters.map(\.repeaterHexID)
            let consolidated = Self.consolidateHexIDs(originalIDs)

            // If no change needed, skip
            if Set(originalIDs.map { $0.uppercased() }) == Set(consolidated) { continue }

            cellsFixed += 1

            // Delete all existing repeater records for this cell
            for r in repeaters {
                repeatersRemoved += 1
                try await r.delete(on: req.db)
            }

            // Re-create with consolidated IDs
            if let cellID = cell.id {
                for hexID in consolidated {
                    let r = CellRepeater(cellID: cellID, repeaterHexID: hexID)
                    try await r.save(on: req.db)
                }
            }
        }

        // 2. Consolidate RepeaterLocation entries
        let allLocations = try await RepeaterLocation.query(on: req.db).all()
        var locationsRemoved = 0
        var locationsUpgraded = 0

        // Group by prefix — find entries that are prefixes of each other
        var toDelete: Set<Int> = []
        for i in 0..<allLocations.count {
            guard let id = allLocations[i].id, !toDelete.contains(id) else { continue }
            let eid = allLocations[i].hexID.uppercased()

            for j in (i+1)..<allLocations.count {
                guard let jid = allLocations[j].id, !toDelete.contains(jid) else { continue }
                let ejd = allLocations[j].hexID.uppercased()

                if eid.hasPrefix(ejd) && eid.count > ejd.count {
                    // i is longer — delete j (shorter)
                    toDelete.insert(jid)
                    locationsRemoved += 1
                } else if ejd.hasPrefix(eid) && ejd.count > eid.count {
                    // j is longer — delete i (shorter)
                    toDelete.insert(id)
                    locationsRemoved += 1
                    break
                }
            }
        }

        for loc in allLocations {
            guard let id = loc.id else { continue }
            if toDelete.contains(id) {
                try await loc.delete(on: req.db)
            } else {
                // Uppercase existing IDs
                let upper = loc.hexID.uppercased()
                if loc.hexID != upper {
                    loc.hexID = upper
                    try await loc.save(on: req.db)
                    locationsUpgraded += 1
                }
            }
        }

        return NormalizeRepeatersResponse(
            cellsFixed: cellsFixed,
            repeatersRemoved: repeatersRemoved,
            repeatersUpgraded: repeatersUpgraded,
            locationsRemoved: locationsRemoved,
            locationsUpgraded: locationsUpgraded
        )
    }

    // MARK: - POST /api/v1/admin/fix-coordinates

    @Sendable
    func fixCellCoordinates(req: Request) async throws -> FixCoordinatesResponse {
        let allCells = try await CellModel.query(on: req.db).all()
        var fixedCount = 0

        for cell in allCells {
            let center = HexGridServer.centerLatLon(
                hexQ: cell.hexQ, hexR: cell.hexR,
                referenceLatitude: cell.referenceLatitude
            )
            if abs(cell.latitude - center.latitude) > 1e-10 ||
               abs(cell.longitude - center.longitude) > 1e-10 {
                cell.latitude = center.latitude
                cell.longitude = center.longitude
                try await cell.save(on: req.db)
                fixedCount += 1
            }
        }

        return FixCoordinatesResponse(
            totalCells: allCells.count,
            fixedCells: fixedCount
        )
    }

    // MARK: - GET /api/v1/admin/contributors

    @Sendable
    func getContributors(req: Request) async throws -> AdminContributorsResponse {
        // Get all distinct contributor IDs from contributions
        let contributorIDs = try await CellContribution.query(on: req.db)
            .unique()
            .all(\.$contributorID)

        var contributors: [AdminContributorInfo] = []

        for contributorID in contributorIDs {
            let contributions = try await CellContribution.query(on: req.db)
                .filter(\.$contributorID == contributorID)
                .all()

            let cellCount = contributions.count
            let totalPacketCount = contributions.reduce(0) { $0 + $1.packetCount }

            let uploads = try await UploadLog.query(on: req.db)
                .filter(\.$contributorID == contributorID)
                .sort(\.$uploadedAt, .ascending)
                .all()

            let uploadCount = uploads.count
            let firstSeen = uploads.first?.uploadedAt
            let lastSeen = uploads.last?.uploadedAt
            let clientIPs = Array(Set(uploads.compactMap(\.clientIP))).sorted()

            let sessionIDs = Set(contributions.compactMap(\.sessionID))
            let sessionCount = sessionIDs.count

            contributors.append(AdminContributorInfo(
                contributorID: contributorID,
                cellCount: cellCount,
                totalPacketCount: totalPacketCount,
                uploadCount: uploadCount,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
                clientIPs: clientIPs,
                sessionCount: sessionCount
            ))
        }

        // Sort by last seen (most recent first)
        contributors.sort { ($0.lastSeen ?? "") > ($1.lastSeen ?? "") }

        return AdminContributorsResponse(contributors: contributors)
    }

    // MARK: - GET /api/v1/admin/uploads

    @Sendable
    func getUploads(req: Request) async throws -> AdminUploadsResponse {
        let limit = req.query[Int.self, at: "limit"] ?? 100
        let offset = req.query[Int.self, at: "offset"] ?? 0

        let total = try await UploadLog.query(on: req.db).count()
        let uploads = try await UploadLog.query(on: req.db)
            .sort(\.$uploadedAt, .descending)
            .range(offset..<(offset + limit))
            .all()

        let items = uploads.compactMap { log -> AdminUploadInfo? in
            guard let id = log.id else { return nil }
            return AdminUploadInfo(
                id: id,
                contributorID: log.contributorID,
                uploadedAt: log.uploadedAt,
                cellCount: log.cellCount,
                clientIP: log.clientIP
            )
        }

        return AdminUploadsResponse(uploads: items, total: total)
    }

    // MARK: - GET /api/v1/admin/contributor/:id/sessions

    @Sendable
    func getContributorSessions(req: Request) async throws -> AdminContributorSessionsResponse {
        guard let contributorID = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing contributor ID")
        }

        let contributions = try await CellContribution.query(on: req.db)
            .filter(\.$contributorID == contributorID)
            .with(\.$cell)
            .all()

        // Group contributions by sessionID
        var sessionMap: [String: [CellContribution]] = [:]
        for contribution in contributions {
            let key = contribution.sessionID ?? "unknown"
            sessionMap[key, default: []].append(contribution)
        }

        var sessions: [AdminSessionInfo] = []

        for (sessionID, contribs) in sessionMap {
            let cells = contribs.map { c -> AdminSessionCell in
                let cell = c.cell
                let avgSNR = c.packetCount > 0 ? c.snrWeighted / Double(c.packetCount) : nil
                let quality: String = {
                    guard let snr = avgSNR else { return "unknown" }
                    if snr > 10 { return "excellent" }
                    if snr > 5 { return "good" }
                    if snr > 0 { return "fair" }
                    if snr > -10 { return "poor" }
                    return "veryPoor"
                }()
                return AdminSessionCell(
                    latitude: cell.latitude,
                    longitude: cell.longitude,
                    hexQ: cell.hexQ,
                    hexR: cell.hexR,
                    referenceLatitude: cell.referenceLatitude,
                    packetCount: c.packetCount,
                    averageSNR: avgSNR,
                    snrQuality: quality,
                    activePacketCount: c.activePacketCount,
                    passivePacketCount: c.passivePacketCount,
                    probesSent: c.probesSent
                )
            }

            let totalPackets = contribs.reduce(0) { $0 + $1.packetCount }
            let earliestDate = contribs.map(\.contributedAt).sorted().first

            sessions.append(AdminSessionInfo(
                sessionID: sessionID,
                cellCount: cells.count,
                totalPacketCount: totalPackets,
                contributedAt: earliestDate,
                cells: cells
            ))
        }

        // Sort by date (most recent first)
        sessions.sort { ($0.contributedAt ?? "") > ($1.contributedAt ?? "") }

        return AdminContributorSessionsResponse(
            contributorID: contributorID,
            sessions: sessions
        )
    }

    // MARK: - DELETE /api/v1/admin/contributor/:id/session/:sessionID

    /// Delete a specific session's contributions from a contributor.
    /// Subtracts the session's data from cell aggregates and removes the contribution records.
    @Sendable
    func deleteContributorSession(req: Request) async throws -> AdminDeleteSessionResponse {
        guard let contributorID = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing contributor ID")
        }
        guard let sessionID = req.parameters.get("sessionID") else {
            throw Abort(.badRequest, reason: "Missing session ID")
        }

        let contributions = try await CellContribution.query(on: req.db)
            .filter(\.$contributorID == contributorID)
            .filter(\.$sessionID == sessionID)
            .with(\.$cell)
            .all()

        guard !contributions.isEmpty else {
            throw Abort(.notFound, reason: "No contributions found for session \(sessionID)")
        }

        var cellsRemoved = 0
        var cellsUpdated = 0

        for contribution in contributions {
            let cell = contribution.cell

            cell.totalSNRWeighted -= contribution.snrWeighted
            cell.totalRSSIWeighted -= contribution.rssiWeighted ?? 0
            cell.totalPacketCount -= contribution.packetCount
            cell.floodCount -= contribution.floodCount
            cell.directCount -= contribution.directCount
            cell.activePacketCount -= contribution.activePacketCount
            cell.passivePacketCount -= contribution.passivePacketCount
            if let contribProbes = contribution.probesSent, contribProbes > 0 {
                cell.probesSent = max(0, (cell.probesSent ?? 0) - contribProbes)
            }
            cell.contributionCount -= 1

            if cell.totalPacketCount <= 0 && cell.contributionCount <= 0 {
                try await cell.delete(on: req.db)
                cellsRemoved += 1
            } else {
                try await cell.save(on: req.db)
                cellsUpdated += 1
            }

            try await contribution.delete(on: req.db)
        }

        req.logger.info("Deleted session \(sessionID) from contributor \(contributorID.prefix(8)): \(contributions.count) contributions, \(cellsRemoved) cells removed, \(cellsUpdated) cells updated")

        return AdminDeleteSessionResponse(
            contributionsRemoved: contributions.count,
            cellsRemoved: cellsRemoved,
            cellsUpdated: cellsUpdated
        )
    }

    // MARK: - POST /api/v1/admin/purge-bogus

    /// Delete all contributors whose total packet count is at or below a threshold.
    /// These are typically bogus entries from the contributor ID bug where each live upload
    /// generated a new UUID. Default threshold is 1 packet.
    @Sendable
    func purgeBogusContributors(req: Request) async throws -> AdminPurgeResponse {
        let maxPackets = req.query[Int.self, at: "maxPackets"] ?? 1

        let contributorIDs = try await CellContribution.query(on: req.db)
            .unique()
            .all(\.$contributorID)

        var totalContributorsRemoved = 0
        var totalContributionsRemoved = 0
        var totalCellsRemoved = 0
        var totalCellsUpdated = 0
        var totalUploadsRemoved = 0

        for contributorID in contributorIDs {
            let contributions = try await CellContribution.query(on: req.db)
                .filter(\.$contributorID == contributorID)
                .with(\.$cell)
                .all()

            let totalPackets = contributions.reduce(0) { $0 + $1.packetCount }
            guard totalPackets <= maxPackets else { continue }

            // Remove contributions and update cell aggregates
            var cellsRemoved = 0
            var cellsUpdated = 0

            for contribution in contributions {
                let cell = contribution.cell
                cell.totalSNRWeighted -= contribution.snrWeighted
                cell.totalRSSIWeighted -= contribution.rssiWeighted ?? 0
                cell.totalPacketCount -= contribution.packetCount
                cell.floodCount -= contribution.floodCount
                cell.directCount -= contribution.directCount
                cell.activePacketCount -= contribution.activePacketCount
                cell.passivePacketCount -= contribution.passivePacketCount
                cell.contributionCount -= 1

                if cell.totalPacketCount <= 0 {
                    try await cell.delete(on: req.db)
                    cellsRemoved += 1
                } else {
                    try await cell.save(on: req.db)
                    cellsUpdated += 1
                }

                try await contribution.delete(on: req.db)
            }

            // Delete upload logs
            let uploadsDeleted = try await UploadLog.query(on: req.db)
                .filter(\.$contributorID == contributorID)
                .count()
            try await UploadLog.query(on: req.db)
                .filter(\.$contributorID == contributorID)
                .delete()

            totalContributorsRemoved += 1
            totalContributionsRemoved += contributions.count
            totalCellsRemoved += cellsRemoved
            totalCellsUpdated += cellsUpdated
            totalUploadsRemoved += uploadsDeleted
        }

        req.logger.info("Purged \(totalContributorsRemoved) bogus contributors (maxPackets=\(maxPackets))")

        return AdminPurgeResponse(
            contributorsRemoved: totalContributorsRemoved,
            contributionsRemoved: totalContributionsRemoved,
            cellsRemoved: totalCellsRemoved,
            cellsUpdated: totalCellsUpdated,
            uploadsRemoved: totalUploadsRemoved
        )
    }

    // MARK: - GET /api/v1/events (Server-Sent Events)

    @Sendable
    func sseEvents(req: Request) async throws -> Response {
        let (clientID, stream) = await SSEBroadcaster.shared.addClient()
        req.logger.info("SSE client connected: \(clientID)")

        let headers = HTTPHeaders([
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive"),
            ("X-Accel-Buffering", "no")
        ])

        let body = Response.Body(asyncStream: { writer in
            // Send initial connection event
            try await writer.write(.buffer(.init(string: "event: connected\ndata: {}\n\n")))

            // Send heartbeat every 30s to keep connection alive
            let heartbeatTask = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(30))
                    try await writer.write(.buffer(.init(string: ": heartbeat\n\n")))
                }
            }

            // Forward broadcast events to this client
            for await message in stream {
                try await writer.write(.buffer(.init(string: message)))
            }

            heartbeatTask.cancel()
            try await writer.write(.end)
            req.logger.info("SSE client disconnected: \(clientID)")
        })

        return Response(status: .ok, headers: headers, body: body)
    }
}
