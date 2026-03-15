import Fluent
import Vapor

struct SurveyController {

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

            if let existing {
                // Merge into existing cell
                existing.totalSNRWeighted += snrWeighted
                existing.totalRSSIWeighted += rssiWeighted ?? 0
                existing.totalPacketCount += cellData.packetCount
                existing.floodCount += cellData.routeTypeBreakdown.flood
                existing.directCount += cellData.routeTypeBreakdown.direct
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

                // Add new repeaters
                if let cellID = existing.id {
                    for hexID in cellData.repeaterHexIDs {
                        let existingRepeater = try await CellRepeater.query(on: req.db)
                            .filter(\.$cell.$id == cellID)
                            .filter(\.$repeaterHexID == hexID)
                            .first()
                        if existingRepeater == nil {
                            let repeater = CellRepeater(cellID: cellID, repeaterHexID: hexID)
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
                        contributedAt: now
                    )
                    try await contribution.save(on: req.db)
                }
            } else {
                // Create new cell
                let cell = CellModel(
                    hexQ: cellData.hexQ, hexR: cellData.hexR,
                    referenceLatitude: normalizedRefLat,
                    latitude: cellData.latitude, longitude: cellData.longitude,
                    totalSNRWeighted: snrWeighted,
                    totalRSSIWeighted: rssiWeighted ?? 0,
                    totalPacketCount: cellData.packetCount,
                    minSNR: cellData.minSNR, maxSNR: cellData.maxSNR,
                    floodCount: cellData.routeTypeBreakdown.flood,
                    directCount: cellData.routeTypeBreakdown.direct,
                    contributionCount: 1,
                    firstSeen: now, lastUpdated: now
                )
                try await cell.save(on: req.db)

                if let cellID = cell.id {
                    // Add repeaters
                    for hexID in cellData.repeaterHexIDs {
                        let repeater = CellRepeater(cellID: cellID, repeaterHexID: hexID)
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
                        contributedAt: now
                    )
                    try await contribution.save(on: req.db)
                }
            }

            acceptedCount += 1
        }

        // Upsert repeater locations from resolved info
        if let repeaterInfos = payload.repeaters {
            for info in repeaterInfos {
                guard (-90...90).contains(info.latitude),
                      (-180...180).contains(info.longitude) else { continue }

                let existing = try await RepeaterLocation.query(on: req.db)
                    .filter(\.$hexID == info.hexID)
                    .first()

                if let existing {
                    existing.name = info.name
                    existing.latitude = info.latitude
                    existing.longitude = info.longitude
                    existing.lastUpdated = now
                    try await existing.save(on: req.db)
                } else {
                    let repeater = RepeaterLocation(
                        hexID: info.hexID,
                        name: info.name,
                        latitude: info.latitude,
                        longitude: info.longitude,
                        lastUpdated: now
                    )
                    try await repeater.save(on: req.db)
                }
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
            CommunityCellResponse(
                latitude: cell.latitude,
                longitude: cell.longitude,
                hexQ: cell.hexQ,
                hexR: cell.hexR,
                referenceLatitude: cell.referenceLatitude,
                averageSNR: cell.averageSNR,
                packetCount: cell.totalPacketCount,
                contributionCount: cell.contributionCount,
                repeaterHexIDs: cell.repeaters.map(\.repeaterHexID),
                snrQuality: cell.snrQuality
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
}
