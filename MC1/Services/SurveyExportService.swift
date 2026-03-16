import Foundation
import MC1Services
import OSLog

/// Service for exporting anonymized, grid-aggregated signal survey data.
enum SurveyExportService {
    private static let logger = Logger(subsystem: "com.mc1", category: "SurveyExport")

    /// Export format version
    static let formatVersion = "1.1"

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
    }

    /// Resolved repeater information for community map display.
    struct RepeaterInfo: Codable {
        let hexID: String
        let name: String
        let latitude: Double
        let longitude: Double
    }

    struct RouteBreakdown: Codable {
        let flood: Int
        let direct: Int
    }

    struct TimeRange: Codable {
        let earliest: String
        let latest: String
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
        repeaterContacts: [ContactDTO] = []
    ) async throws -> CellDataResult? {
        let points = try await dataStore.fetchSurveyPoints(sessionID: sessionID)
        guard !points.isEmpty else {
            logger.warning("No points for session \(sessionID)")
            return nil
        }

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
            let rssiValues = cellPoints.compactMap(\.rssi)
            let floodCount = cellPoints.filter { $0.routeType == .flood || $0.routeType == .tcFlood }.count
            let directCount = cellPoints.count - floodCount
            let timestamps = cellPoints.map(\.timestamp).sorted()

            // Extract unique repeater hex IDs from path nodes
            let repeaters = Array(Set(cellPoints.flatMap(\.pathNodeHexIDs)).sorted())

            let timeRange: TimeRange? = includeTimeRange ? TimeRange(
                earliest: isoFormatter.string(from: timestamps.first ?? Date()),
                latest: isoFormatter.string(from: timestamps.last ?? Date())
            ) : nil

            // Active/passive breakdown
            let activeCount = cellPoints.count(where: \.isActiveProbe)
            let passiveCount = cellPoints.count - activeCount

            return CellData(
                latitude: center.latitude,
                longitude: center.longitude,
                averageSNR: snrValues.isEmpty ? nil : snrValues.reduce(0, +) / Double(snrValues.count),
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
                passivePacketCount: passiveCount > 0 ? passiveCount : nil
            )
        }

        // Resolve unique repeater hex IDs to contact names and locations
        let allHexIDs = Set(cells.flatMap(\.repeaterHexIDs))
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

        return CellDataResult(cells: cells, referenceLatitude: refLat, points: points, repeaters: resolvedRepeaters)
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
