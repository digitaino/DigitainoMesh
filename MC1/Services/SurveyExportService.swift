import Foundation
import MC1Services
import OSLog

/// Service for exporting anonymized, grid-aggregated signal survey data.
enum SurveyExportService {
    private static let logger = Logger(subsystem: "com.mc1", category: "SurveyExport")

    /// Export format version
    static let formatVersion = "1.2"

    // MARK: - Export Format

    struct SurveyExport: Codable {
        let version: String
        let exportedAt: String
        let session: SessionInfo
        let grid: GridInfo
        let cells: [CellData]
    }

    struct SessionInfo: Codable {
        let startedAt: String
        let endedAt: String?
        let totalPoints: Int
        let cellCount: Int
    }

    struct GridInfo: Codable {
        let gridType: String
        let cellSizeMeters: Int
        let cellSizeDegrees: Double
        let boundingBox: BoundingBox
    }

    struct BoundingBox: Codable {
        let minLatitude: Double
        let maxLatitude: Double
        let minLongitude: Double
        let maxLongitude: Double
    }

    struct CellData: Codable {
        let latitude: Double
        let longitude: Double
        let averageSNR: Double?
        let averageTxSNR: Double?
        let averageRSSI: Double?
        let minSNR: Double?
        let maxSNR: Double?
        let packetCount: Int
        let routeTypeBreakdown: RouteBreakdown
        let timeRange: TimeRange?
        let repeaterHexIDs: [String]
        let hexQ: Int
        let hexR: Int
        let referenceLatitude: Double
        /// Number of packets collected during active probing (bidirectional confirmation).
        let activePacketCount: Int?
        /// Number of packets collected passively (RX only, one-way).
        let passivePacketCount: Int?
        /// Per-repeater signal metrics (SNR, RSSI, packet count per repeater in this cell).
        let repeaterMetrics: [RepeaterMetric]?
        /// Number of active probe messages sent from this cell. Nil if probing was not active.
        let probesSent: Int?
    }

    /// Resolved repeater information for community map display.
    struct RepeaterInfo: Codable {
        let hexID: String
        let name: String
        let latitude: Double
        let longitude: Double
    }

    /// Per-repeater signal metrics within a cell.
    struct RepeaterMetric: Codable {
        let hexID: String
        let averageSNR: Double?
        let averageTxSNR: Double?
        let averageRSSI: Double?
        let packetCount: Int
        /// ISO 8601 timestamp of the most recent packet from this repeater in this cell.
        let lastHeard: String?
    }

    struct RouteBreakdown: Codable {
        let flood: Int
        let direct: Int
    }

    struct TimeRange: Codable {
        let earliest: String
        let latest: String
    }

    // MARK: - Per-Repeater Metrics

    /// Compute per-repeater signal metrics from survey points within a cell.
    /// Groups points by their associated repeater hex IDs (prefix-aware), then
    /// computes average SNR/RSSI and packet count for each consolidated repeater.
    private static func computeRepeaterMetrics(
        cellPoints: [SignalSurveyPointDTO],
        consolidatedRepeaters: [String]
    ) -> [RepeaterMetric] {
        let isoFormatter = ISO8601DateFormatter()

        // Build a lookup of all points associated with each raw hex ID
        var pointsByRawHex: [String: [SignalSurveyPointDTO]] = [:]
        for point in cellPoints {
            for hexID in point.pathNodeHexIDs {
                pointsByRawHex[hexID.uppercased(), default: []].append(point)
            }
        }

        // For each consolidated repeater, collect points from all matching raw hex IDs
        return consolidatedRepeaters.map { repeaterHex in
            let matchingPoints = pointsByRawHex.filter { rawHex, _ in
                rawHex.hasPrefix(repeaterHex) || repeaterHex.hasPrefix(rawHex)
            }.values.flatMap { $0 }

            let snrs = matchingPoints.compactMap(\.snr)
            let txSnrs = matchingPoints.compactMap(\.txSnr)
            let rssis = matchingPoints.compactMap(\.rssi)
            let latestTimestamp = matchingPoints.map(\.timestamp).max()
            return RepeaterMetric(
                hexID: repeaterHex,
                averageSNR: snrs.isEmpty ? nil : snrs.reduce(0, +) / Double(snrs.count),
                averageTxSNR: txSnrs.isEmpty ? nil : txSnrs.reduce(0, +) / Double(txSnrs.count),
                averageRSSI: rssis.isEmpty ? nil : Double(rssis.reduce(0, +)) / Double(rssis.count),
                packetCount: matchingPoints.count,
                lastHeard: latestTimestamp.map { isoFormatter.string(from: $0) }
            )
        }
    }

    // MARK: - Hex ID Consolidation

    /// Consolidates hex IDs that are prefixes of each other, keeping the longest (most specific) version.
    /// For example, if a repeater appears as "0C" (1-byte hash) and "0C13" (2-byte hash) across
    /// different sessions or packets, only "0C13" is kept since it's a more specific identifier
    /// for the same repeater.
    static func consolidateHexIDs(_ hexIDs: [String]) -> [String] {
        let upper = hexIDs.map { $0.uppercased() }
        var result: [String] = []
        for id in upper {
            // Skip if we already have a longer version that starts with this id
            if result.contains(where: { $0.hasPrefix(id) && $0.count > id.count }) { continue }
            // Remove any shorter versions that this id extends
            result.removeAll { id.hasPrefix($0) && id.count > $0.count }
            if !result.contains(id) { result.append(id) }
        }
        return result
    }

    // MARK: - Cell Data Generation (shared by file export and community upload)

    struct CellDataResult {
        let cells: [CellData]
        let referenceLatitude: Double
        let points: [SignalSurveyPointDTO]
        let repeaters: [RepeaterInfo]
    }

    /// Generate aggregated cell data from a survey session.
    /// Shared by both file export and community upload.
    /// When `repeaterContacts` is provided, resolves hex IDs to names/locations for community map.
    static func generateCellData(
        sessionID: UUID,
        dataStore: PersistenceStore,
        includeTimeRange: Bool = true,
        repeaterContacts: [ContactDTO] = [],
        probesSentPerCell: [String: Int] = [:],
        deadZoneHexCoords: [(q: Int, r: Int)] = []
    ) async throws -> CellDataResult? {
        let points = try await dataStore.fetchSurveyPoints(sessionID: sessionID)
        guard !points.isEmpty else {
            logger.warning("No points for session \(sessionID)")
            return nil
        }

        // DEBUG: Log payloadType distribution and active probe stats
        let payloadTypeCounts = Dictionary(grouping: points, by: { $0.payloadType }).mapValues(\.count)
        logger.info("DEBUG generateCellData: \(points.count) points, payloadTypes: \(payloadTypeCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }).map { "\($0.key.displayName)=\($0.value)" }.joined(separator: ", "))")
        let activeProbeCount = points.filter(\.isActiveProbe).count
        logger.info("DEBUG generateCellData: isActiveProbe=true: \(activeProbeCount), isActiveProbe=false: \(points.count - activeProbeCount)")

        let avgLat = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let refLat = HexGrid.fixedReferenceLatitude(for: avgLat)
        var buckets: [HexGrid.AxialCoord: [SignalSurveyPointDTO]] = [:]

        for point in points {
            let hex = HexGrid.axialFromLatLon(latitude: point.latitude, longitude: point.longitude, referenceLatitude: refLat)
            buckets[hex, default: []].append(point)
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let cells: [CellData] = buckets.map { coord, cellPoints in
            // Use the exact hex grid center so polygons tessellate without overlap
            let center = HexGrid.centerLatLon(from: coord, referenceLatitude: refLat)
            let snrValues = cellPoints.compactMap(\.snr)
            let txSnrValues = cellPoints.compactMap(\.txSnr)
            let rssiValues = cellPoints.compactMap(\.rssi)
            let floodCount = cellPoints.filter { $0.routeType == .flood || $0.routeType == .tcFlood }.count
            let directCount = cellPoints.count - floodCount
            let timestamps = cellPoints.map(\.timestamp).sorted()

            // Extract unique repeater hex IDs from path nodes, consolidating prefix variants
            // (e.g. "0C" and "0C13" become just "0C13" — the longer, more specific hash)
            let repeaters = consolidateHexIDs(Array(Set(cellPoints.flatMap(\.pathNodeHexIDs)))).sorted()

            let timeRange: TimeRange? = includeTimeRange ? TimeRange(
                earliest: isoFormatter.string(from: timestamps.first ?? Date()),
                latest: isoFormatter.string(from: timestamps.last ?? Date())
            ) : nil

            // Active/passive breakdown
            let activeCount = cellPoints.count(where: \.isActiveProbe)
            let passiveCount = cellPoints.count - activeCount

            // Per-repeater signal metrics
            let metrics = computeRepeaterMetrics(cellPoints: cellPoints, consolidatedRepeaters: repeaters)

            return CellData(
                latitude: center.latitude,
                longitude: center.longitude,
                averageSNR: snrValues.isEmpty ? nil : snrValues.reduce(0, +) / Double(snrValues.count),
                averageTxSNR: txSnrValues.isEmpty ? nil : txSnrValues.reduce(0, +) / Double(txSnrValues.count),
                averageRSSI: rssiValues.isEmpty ? nil : Double(rssiValues.reduce(0, +)) / Double(rssiValues.count),
                minSNR: snrValues.min(),
                maxSNR: snrValues.max(),
                packetCount: cellPoints.count,
                routeTypeBreakdown: RouteBreakdown(flood: floodCount, direct: directCount),
                timeRange: timeRange,
                repeaterHexIDs: repeaters,
                hexQ: coord.q,
                hexR: coord.r,
                referenceLatitude: refLat,
                activePacketCount: activeCount > 0 ? activeCount : nil,
                passivePacketCount: passiveCount > 0 ? passiveCount : nil,
                repeaterMetrics: metrics.isEmpty ? nil : metrics,
                probesSent: probesSentPerCell["\(coord.q)_\(coord.r)"]
            )
        }

        // DEBUG: Log per-cell active/passive breakdown
        let cellsWithActive = cells.filter { $0.activePacketCount != nil }.count
        let cellsWithPassive = cells.filter { $0.passivePacketCount != nil }.count
        let totalActive = cells.compactMap(\.activePacketCount).reduce(0, +)
        let totalPassive = cells.compactMap(\.passivePacketCount).reduce(0, +)
        logger.info("DEBUG generateCellData: \(cells.count) cells — \(cellsWithActive) with active (\(totalActive) pkts), \(cellsWithPassive) with passive (\(totalPassive) pkts)")

        // Append dead zone cells (probed but no response) that don't overlap with data cells
        var allCells = cells
        if !deadZoneHexCoords.isEmpty {
            let existingKeys = Set(cells.map { "\($0.hexQ)_\($0.hexR)" })
            for dz in deadZoneHexCoords {
                let key = "\(dz.q)_\(dz.r)"
                guard !existingKeys.contains(key) else { continue }
                let probes = probesSentPerCell[key]
                guard probes != nil && probes! > 0 else { continue }
                let center = HexGrid.centerLatLon(
                    from: HexGrid.AxialCoord(q: dz.q, r: dz.r),
                    referenceLatitude: refLat
                )
                allCells.append(CellData(
                    latitude: center.latitude,
                    longitude: center.longitude,
                    averageSNR: nil,
                    averageTxSNR: nil,
                    averageRSSI: nil,
                    minSNR: nil,
                    maxSNR: nil,
                    packetCount: 0,
                    routeTypeBreakdown: RouteBreakdown(flood: 0, direct: 0),
                    timeRange: nil,
                    repeaterHexIDs: [],
                    hexQ: dz.q,
                    hexR: dz.r,
                    referenceLatitude: refLat,
                    activePacketCount: nil,
                    passivePacketCount: nil,
                    repeaterMetrics: nil,
                    probesSent: probes
                ))
            }
            if allCells.count > cells.count {
                logger.info("generateCellData: appended \(allCells.count - cells.count) dead zone cells")
            }
        }

        // Resolve unique repeater hex IDs to contact names and locations
        // (already consolidated per-cell, but consolidate across all cells too)
        let allHexIDs = Set(consolidateHexIDs(cells.flatMap(\.repeaterHexIDs)))
        let resolvedRepeaters: [RepeaterInfo] = allHexIDs.compactMap { hexID in
            guard let hashBytes = Data(hexString: hexID) else { return nil }
            guard let contact = RepeaterResolver.bestMatch(
                for: hashBytes, in: repeaterContacts, userLocation: nil
            ) else { return nil }
            guard contact.hasLocation else { return nil }
            return RepeaterInfo(
                hexID: hexID,
                name: contact.displayName,
                latitude: contact.latitude,
                longitude: contact.longitude
            )
        }

        return CellDataResult(cells: allCells, referenceLatitude: refLat, points: points, repeaters: resolvedRepeaters)
    }

    /// Generate aggregated cell data from multiple survey sessions, merging overlapping cells.
    /// Used for batch community upload of multiple sessions at once.
    static func generateCellDataForSessions(
        sessionIDs: [UUID],
        dataStore: PersistenceStore,
        repeaterContacts: [ContactDTO] = [],
        probesSentPerCell: [String: Int] = [:],
        deadZoneHexCoords: [(q: Int, r: Int)] = []
    ) async throws -> CellDataResult? {
        var allPoints: [SignalSurveyPointDTO] = []
        for sessionID in sessionIDs {
            let sessionPoints = try await dataStore.fetchSurveyPoints(sessionID: sessionID)
            allPoints.append(contentsOf: sessionPoints)
        }
        guard !allPoints.isEmpty else {
            logger.warning("No points across \(sessionIDs.count) sessions")
            return nil
        }

        logger.info("generateCellDataForSessions: \(allPoints.count) points from \(sessionIDs.count) sessions")

        let avgLat = allPoints.map(\.latitude).reduce(0, +) / Double(allPoints.count)
        let refLat = HexGrid.fixedReferenceLatitude(for: avgLat)
        var buckets: [HexGrid.AxialCoord: [SignalSurveyPointDTO]] = [:]

        for point in allPoints {
            let hex = HexGrid.axialFromLatLon(latitude: point.latitude, longitude: point.longitude, referenceLatitude: refLat)
            buckets[hex, default: []].append(point)
        }

        let cells: [CellData] = buckets.map { coord, cellPoints in
            let center = HexGrid.centerLatLon(from: coord, referenceLatitude: refLat)
            let snrValues = cellPoints.compactMap(\.snr)
            let txSnrValues = cellPoints.compactMap(\.txSnr)
            let rssiValues = cellPoints.compactMap(\.rssi)
            let floodCount = cellPoints.filter { $0.routeType == .flood || $0.routeType == .tcFlood }.count
            let directCount = cellPoints.count - floodCount
            let repeaters = consolidateHexIDs(Array(Set(cellPoints.flatMap(\.pathNodeHexIDs)))).sorted()
            let activeCount = cellPoints.count(where: \.isActiveProbe)
            let passiveCount = cellPoints.count - activeCount
            let metrics = computeRepeaterMetrics(cellPoints: cellPoints, consolidatedRepeaters: repeaters)

            return CellData(
                latitude: center.latitude,
                longitude: center.longitude,
                averageSNR: snrValues.isEmpty ? nil : snrValues.reduce(0, +) / Double(snrValues.count),
                averageTxSNR: txSnrValues.isEmpty ? nil : txSnrValues.reduce(0, +) / Double(txSnrValues.count),
                averageRSSI: rssiValues.isEmpty ? nil : Double(rssiValues.reduce(0, +)) / Double(rssiValues.count),
                minSNR: snrValues.min(),
                maxSNR: snrValues.max(),
                packetCount: cellPoints.count,
                routeTypeBreakdown: RouteBreakdown(flood: floodCount, direct: directCount),
                timeRange: nil,
                repeaterHexIDs: repeaters,
                hexQ: coord.q,
                hexR: coord.r,
                referenceLatitude: refLat,
                activePacketCount: activeCount > 0 ? activeCount : nil,
                passivePacketCount: passiveCount > 0 ? passiveCount : nil,
                repeaterMetrics: metrics.isEmpty ? nil : metrics,
                probesSent: probesSentPerCell["\(coord.q)_\(coord.r)"]
            )
        }

        // Append dead zone cells (probed but no response) that don't overlap with data cells
        var allCells = cells
        if !deadZoneHexCoords.isEmpty {
            let existingKeys = Set(cells.map { "\($0.hexQ)_\($0.hexR)" })
            for dz in deadZoneHexCoords {
                let key = "\(dz.q)_\(dz.r)"
                guard !existingKeys.contains(key) else { continue }
                let probes = probesSentPerCell[key]
                guard probes != nil && probes! > 0 else { continue }
                let center = HexGrid.centerLatLon(
                    from: HexGrid.AxialCoord(q: dz.q, r: dz.r),
                    referenceLatitude: refLat
                )
                allCells.append(CellData(
                    latitude: center.latitude,
                    longitude: center.longitude,
                    averageSNR: nil,
                    averageTxSNR: nil,
                    averageRSSI: nil,
                    minSNR: nil,
                    maxSNR: nil,
                    packetCount: 0,
                    routeTypeBreakdown: RouteBreakdown(flood: 0, direct: 0),
                    timeRange: nil,
                    repeaterHexIDs: [],
                    hexQ: dz.q,
                    hexR: dz.r,
                    referenceLatitude: refLat,
                    activePacketCount: nil,
                    passivePacketCount: nil,
                    repeaterMetrics: nil,
                    probesSent: probes
                ))
            }
        }

        let allHexIDs = Set(consolidateHexIDs(allCells.flatMap(\.repeaterHexIDs)))
        let resolvedRepeaters: [RepeaterInfo] = allHexIDs.compactMap { hexID in
            guard let hashBytes = Data(hexString: hexID) else { return nil }
            guard let contact = RepeaterResolver.bestMatch(
                for: hashBytes, in: repeaterContacts, userLocation: nil
            ) else { return nil }
            guard contact.hasLocation else { return nil }
            return RepeaterInfo(
                hexID: hexID,
                name: contact.displayName,
                latitude: contact.latitude,
                longitude: contact.longitude
            )
        }

        logger.info("generateCellDataForSessions: \(allCells.count) merged cells (\(allCells.count - cells.count) dead zones), \(resolvedRepeaters.count) repeaters")
        return CellDataResult(cells: allCells, referenceLatitude: refLat, points: allPoints, repeaters: resolvedRepeaters)
    }

    // MARK: - Generate Export

    static func generateExport(
        sessionID: UUID,
        dataStore: PersistenceStore
    ) async -> URL? {
        do {
            guard let result = try await generateCellData(
                sessionID: sessionID,
                dataStore: dataStore,
                includeTimeRange: true
            ) else {
                return nil
            }

            let sessions = try await dataStore.fetchSurveySessions(deviceID: result.points[0].deviceID)
            let session = sessions.first { $0.id == sessionID }

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime]

            // Build bounding box
            let lats = result.points.map(\.latitude)
            let lons = result.points.map(\.longitude)

            let export = SurveyExport(
                version: formatVersion,
                exportedAt: isoFormatter.string(from: Date()),
                session: SessionInfo(
                    startedAt: isoFormatter.string(from: session?.startedAt ?? Date()),
                    endedAt: session?.endedAt.map { isoFormatter.string(from: $0) },
                    totalPoints: result.points.count,
                    cellCount: result.cells.count
                ),
                grid: GridInfo(
                    gridType: "hex",
                    cellSizeMeters: 50,
                    cellSizeDegrees: HexGrid.size,
                    boundingBox: BoundingBox(
                        minLatitude: lats.min() ?? 0,
                        maxLatitude: lats.max() ?? 0,
                        minLongitude: lons.min() ?? 0,
                        maxLongitude: lons.max() ?? 0
                    )
                ),
                cells: result.cells
            )

            // Write JSON file
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(export)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let timestamp = formatter.string(from: Date())
            let filename = "DigitainoMesh-Survey-\(timestamp).json"
            let tempURL = FileManager.default.temporaryDirectory.appending(path: filename)
            try data.write(to: tempURL)

            logger.info("Exported \(result.cells.count) cells from \(result.points.count) points to \(filename)")
            return tempURL

        } catch {
            logger.error("Export failed: \(error.localizedDescription)")
            return nil
        }
    }
}
