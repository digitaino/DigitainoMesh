import CoreLocation
import MapKit
import MeshCore
import os.log
import PocketMeshServices

private let logger = Logger(subsystem: "com.pocketmesh", category: "TrafficHeatmap")

/// View model for the traffic heatmap tool.
/// Fetches RxLog entries, resolves path hops to repeaters, and aggregates
/// per-node and per-segment traffic data for map visualization.
@MainActor @Observable
final class TrafficHeatmapViewModel {

    // MARK: - Time Period

    enum TimePeriod: String, CaseIterable {
        case lastHour
        case last24Hours
        case last7Days
        case allTime

        var sinceDate: Date? {
            switch self {
            case .lastHour: Calendar.current.date(byAdding: .hour, value: -1, to: .now)
            case .last24Hours: Calendar.current.date(byAdding: .day, value: -1, to: .now)
            case .last7Days: Calendar.current.date(byAdding: .day, value: -7, to: .now)
            case .allTime: nil
            }
        }

        var displayName: String {
            switch self {
            case .lastHour: L10n.Tools.Tools.TrafficMap.Period.lastHour
            case .last24Hours: L10n.Tools.Tools.TrafficMap.Period.last24Hours
            case .last7Days: L10n.Tools.Tools.TrafficMap.Period.last7Days
            case .allTime: L10n.Tools.Tools.TrafficMap.Period.allTime
            }
        }
    }

    // MARK: - Map State

    var cameraRegion: MKCoordinateRegion?
    var cameraRegionVersion = 0
    var mapStyleSelection: MapStyleSelection = .standard
    var showLabels: Bool = true
    var showingLayersMenu: Bool = false

    var mapType: MKMapType { mapStyleSelection.mkMapType }

    // MARK: - Data State

    var selectedPeriod: TimePeriod = .last24Hours
    private(set) var isLoading = false
    private(set) var hasData = false
    private(set) var hasLocatedRepeaters = false

    // MARK: - Map Display Data

    private(set) var bubbleAnnotations: [TrafficBubbleAnnotation] = []
    private(set) var segmentOverlays: [TrafficSegmentOverlay] = []

    // MARK: - Stats

    private(set) var totalPacketsAnalyzed: Int = 0
    private(set) var locatedRepeaterCount: Int = 0
    private(set) var segmentCount: Int = 0

    // MARK: - Aggregation Internals

    private struct RepeaterTraffic {
        let node: any RepeaterResolvable
        var packetCount: Int
        var totalSNR: Double
        var snrSampleCount: Int
        var lastSeen: Date

        var averageSNR: Double? {
            snrSampleCount > 0 ? totalSNR / Double(snrSampleCount) : nil
        }
    }

    private struct SegmentKey: Hashable {
        let keyA: Data  // smaller key first for canonicalization
        let keyB: Data
    }

    private struct SegmentTraffic {
        let coordinateA: CLLocationCoordinate2D
        let coordinateB: CLLocationCoordinate2D
        var frequency: Int
        var totalSNR: Double
        var snrSampleCount: Int

        var averageSNR: Double? {
            snrSampleCount > 0 ? totalSNR / Double(snrSampleCount) : nil
        }
    }

    // MARK: - Load

    func load(
        dataStore: PersistenceStore,
        deviceID: UUID,
        userLocation: CLLocation?
    ) async {
        isLoading = true

        do {
            let contacts = try await dataStore.fetchContacts(deviceID: deviceID)
            let discoveredNodes = try await dataStore.fetchDiscoveredNodes(deviceID: deviceID)

            let entries: [RxLogEntryDTO]
            if let since = selectedPeriod.sinceDate {
                entries = try await dataStore.fetchRxLogEntries(deviceID: deviceID, since: since)
            } else {
                entries = try await dataStore.fetchRxLogEntries(deviceID: deviceID, limit: 10_000)
            }

            aggregate(
                entries: entries,
                contacts: contacts,
                discoveredNodes: discoveredNodes,
                userLocation: userLocation
            )
        } catch {
            logger.error("Failed to load traffic data: \(error.localizedDescription)")
            clearState()
        }

        isLoading = false
    }

    // MARK: - Aggregation

    private func aggregate(
        entries: [RxLogEntryDTO],
        contacts: [ContactDTO],
        discoveredNodes: [DiscoveredNodeDTO],
        userLocation: CLLocation?
    ) {
        var repeaterTraffic: [Data: RepeaterTraffic] = [:]
        var segmentTraffic: [SegmentKey: SegmentTraffic] = [:]

        for entry in entries {
            // Skip TRACE packets — pathNodes contain per-hop SNR values, not node hashes
            guard entry.payloadType != .trace else { continue }

            let hashSize = entry.pathHashSize
            guard hashSize > 0, !entry.pathNodes.isEmpty else { continue }

            // Parse hop hashes
            let hopHashes: [Data] = stride(from: 0, to: entry.pathNodes.count, by: hashSize).map { start in
                let end = min(start + hashSize, entry.pathNodes.count)
                return Data(entry.pathNodes[start..<end])
            }

            // Resolve each hop to a located node
            var locatedHops: [(publicKey: Data, coordinate: CLLocationCoordinate2D)] = []

            for hash in hopHashes {
                // Try contacts first, then discovered nodes
                let match: (any RepeaterResolvable)? =
                    RepeaterResolver.bestMatch(for: hash, in: contacts, userLocation: userLocation)
                    ?? RepeaterResolver.bestMatch(for: hash, in: discoveredNodes, userLocation: userLocation)
                guard let match, match.hasLocation else { continue }

                let coord = CLLocationCoordinate2D(
                    latitude: match.latitude,
                    longitude: match.longitude
                )
                guard CLLocationCoordinate2DIsValid(coord) else { continue }

                let key = match.publicKey

                // Accumulate repeater traffic
                if var existing = repeaterTraffic[key] {
                    existing.packetCount += 1
                    if let snr = entry.snr {
                        existing.totalSNR += snr
                        existing.snrSampleCount += 1
                    }
                    if entry.receivedAt > existing.lastSeen {
                        existing.lastSeen = entry.receivedAt
                    }
                    repeaterTraffic[key] = existing
                } else {
                    repeaterTraffic[key] = RepeaterTraffic(
                        node: match,
                        packetCount: 1,
                        totalSNR: entry.snr ?? 0,
                        snrSampleCount: entry.snr != nil ? 1 : 0,
                        lastSeen: entry.receivedAt
                    )
                }

                locatedHops.append((key, coord))
            }

            // Build segment traffic from consecutive located hops
            guard locatedHops.count >= 2 else { continue }
            for i in 0..<(locatedHops.count - 1) {
                let a = locatedHops[i]
                let b = locatedHops[i + 1]

                // Skip self-loops (same repeater appearing consecutively)
                guard a.publicKey != b.publicKey else { continue }

                // Canonicalize key so A→B == B→A
                let segKey: SegmentKey
                if a.publicKey.lexicographicallyPrecedes(b.publicKey) {
                    segKey = SegmentKey(keyA: a.publicKey, keyB: b.publicKey)
                } else {
                    segKey = SegmentKey(keyA: b.publicKey, keyB: a.publicKey)
                }

                if var existing = segmentTraffic[segKey] {
                    existing.frequency += 1
                    if let snr = entry.snr {
                        existing.totalSNR += snr
                        existing.snrSampleCount += 1
                    }
                    segmentTraffic[segKey] = existing
                } else {
                    segmentTraffic[segKey] = SegmentTraffic(
                        coordinateA: a.coordinate,
                        coordinateB: b.coordinate,
                        frequency: 1,
                        totalSNR: entry.snr ?? 0,
                        snrSampleCount: entry.snr != nil ? 1 : 0
                    )
                }
            }
        }

        // Build display data
        let maxPackets = repeaterTraffic.values.map(\.packetCount).max() ?? 1
        let maxFrequency = segmentTraffic.values.map(\.frequency).max() ?? 1

        bubbleAnnotations = repeaterTraffic.values.map { traffic in
            TrafficBubbleAnnotation(
                coordinate: CLLocationCoordinate2D(
                    latitude: traffic.node.latitude,
                    longitude: traffic.node.longitude
                ),
                name: traffic.node.resolvableName,
                publicKey: traffic.node.publicKey,
                packetCount: traffic.packetCount,
                averageSNR: traffic.averageSNR,
                snrQuality: SNRQuality(snr: traffic.averageSNR),
                lastSeen: traffic.lastSeen,
                normalizedTraffic: Double(traffic.packetCount) / Double(maxPackets)
            )
        }

        segmentOverlays = segmentTraffic.values.map { segment in
            TrafficSegmentOverlay.line(
                from: segment.coordinateA,
                to: segment.coordinateB,
                frequency: segment.frequency,
                normalizedFrequency: Double(segment.frequency) / Double(maxFrequency),
                averageSNR: segment.averageSNR
            )
        }

        totalPacketsAnalyzed = entries.count
        locatedRepeaterCount = repeaterTraffic.count
        segmentCount = segmentTraffic.count
        hasLocatedRepeaters = !bubbleAnnotations.isEmpty
        hasData = !entries.isEmpty

        if hasLocatedRepeaters {
            centerOnData()
        }

        logger.debug("Aggregated \(entries.count) entries → \(self.locatedRepeaterCount) repeaters, \(self.segmentCount) segments")
    }

    // MARK: - Camera

    func centerOnData() {
        let coordinates = bubbleAnnotations.map(\.coordinate)
        guard !coordinates.isEmpty else { return }

        var minLat = coordinates[0].latitude
        var maxLat = coordinates[0].latitude
        var minLon = coordinates[0].longitude
        var maxLon = coordinates[0].longitude

        for coord in coordinates {
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let span = MKCoordinateSpan(
            latitudeDelta: min(180, (maxLat - minLat) * 1.5 + 0.01),
            longitudeDelta: min(360, (maxLon - minLon) * 1.5 + 0.01)
        )

        cameraRegion = MKCoordinateRegion(center: center, span: span)
        cameraRegionVersion += 1
    }

    // MARK: - Private

    private func clearState() {
        bubbleAnnotations = []
        segmentOverlays = []
        totalPacketsAnalyzed = 0
        locatedRepeaterCount = 0
        segmentCount = 0
        hasData = false
        hasLocatedRepeaters = false
    }
}
