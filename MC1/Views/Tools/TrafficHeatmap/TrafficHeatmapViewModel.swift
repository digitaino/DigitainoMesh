import CoreLocation
import MapKit
import SwiftUI
import MeshCore
import os.log
import MC1Services

private let logger = Logger(subsystem: "com.pocketmesh", category: "TrafficHeatmap")

/// View model for the traffic heatmap tool.
/// Fetches RxLog entries, resolves path hops to repeaters, and aggregates
/// per-node and per-segment traffic data for map visualization.
@MainActor @Observable
final class TrafficHeatmapViewModel {

    // MARK: - Dynamic Time Period

    /// A time period computed from the actual data span rather than fixed durations.
    struct TimePeriod: Identifiable, Equatable {
        let id: String
        let displayName: String
        let sinceDate: Date?

        static func == (lhs: TimePeriod, rhs: TimePeriod) -> Bool { lhs.id == rhs.id }
    }

    // MARK: - Map State

    var cameraRegion: MKCoordinateRegion?
    var mapStyleSelection: MapStyleSelection = .standard
    var showingLayersMenu: Bool = false

    // MARK: - Data State

    var selectedPeriodID: String = "all"
    private(set) var availablePeriods: [TimePeriod] = []
    private(set) var isLoading = false
    private(set) var hasData = false
    private(set) var hasLocatedRepeaters = false

    // MARK: - Map Display Data

    private(set) var bubbleAnnotations: [TrafficBubbleAnnotation] = []
    private(set) var segmentData: [TrafficSegmentData] = []

    // MARK: - Stats

    private(set) var totalPacketsAnalyzed: Int = 0
    private(set) var locatedRepeaterCount: Int = 0
    private(set) var segmentCount: Int = 0
    private(set) var oldestPacketAge: TimeInterval?

    var selectedPeriod: TimePeriod? {
        availablePeriods.first { $0.id == selectedPeriodID }
    }

    // MARK: - Load

    func load(
        dataStore: PersistenceStore,
        deviceID: UUID,
        userLocation: CLLocation?
    ) async {
        isLoading = true

        do {
            // Fetch oldest packet date for data age display and dynamic window computation
            let oldestDate = try await dataStore.fetchOldestRxLogDate(deviceID: deviceID)
            if let oldestDate {
                oldestPacketAge = Date().timeIntervalSince(oldestDate)
            } else {
                oldestPacketAge = nil
            }

            // Compute dynamic time periods based on actual data span
            let periods = Self.computeTimePeriods(oldestDate: oldestDate)
            availablePeriods = periods

            // If selected period is no longer available, default to "all"
            if !periods.contains(where: { $0.id == selectedPeriodID }) {
                selectedPeriodID = "all"
            }

            let contacts = try await dataStore.fetchContacts(deviceID: deviceID)
            let discoveredNodes = try await dataStore.fetchDiscoveredNodes(deviceID: deviceID)

            let sinceDate = selectedPeriod?.sinceDate
            let entries: [RxLogEntryDTO]
            if let sinceDate {
                entries = try await dataStore.fetchRxLogEntries(deviceID: deviceID, since: sinceDate)
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

    // MARK: - Dynamic Time Periods

    /// Computes available time periods based on the actual data span.
    static func computeTimePeriods(oldestDate: Date?) -> [TimePeriod] {
        guard let oldestDate else {
            return [TimePeriod(id: "all", displayName: L10n.Tools.Tools.TrafficMap.Period.allTime, sinceDate: nil)]
        }

        let age = Date().timeIntervalSince(oldestDate)
        let now = Date()

        var periods: [TimePeriod] = []

        if age < 3600 {
            // < 1 hour: 15m / 30m / all
            periods.append(TimePeriod(id: "15m", displayName: "Last 15 min", sinceDate: now.addingTimeInterval(-900)))
            periods.append(TimePeriod(id: "30m", displayName: "Last 30 min", sinceDate: now.addingTimeInterval(-1800)))
        } else if age < 21600 {
            // < 6 hours: 30m / 1h / 3h / all
            periods.append(TimePeriod(id: "30m", displayName: "Last 30 min", sinceDate: now.addingTimeInterval(-1800)))
            periods.append(TimePeriod(id: "1h", displayName: L10n.Tools.Tools.TrafficMap.Period.lastHour, sinceDate: now.addingTimeInterval(-3600)))
            periods.append(TimePeriod(id: "3h", displayName: "Last 3 Hours", sinceDate: now.addingTimeInterval(-10800)))
        } else if age < 86400 {
            // < 24 hours: 1h / 6h / 12h / all
            periods.append(TimePeriod(id: "1h", displayName: L10n.Tools.Tools.TrafficMap.Period.lastHour, sinceDate: now.addingTimeInterval(-3600)))
            periods.append(TimePeriod(id: "6h", displayName: "Last 6 Hours", sinceDate: now.addingTimeInterval(-21600)))
            periods.append(TimePeriod(id: "12h", displayName: "Last 12 Hours", sinceDate: now.addingTimeInterval(-43200)))
        } else if age < 604800 {
            // < 7 days: 6h / 1d / 3d / all
            periods.append(TimePeriod(id: "6h", displayName: "Last 6 Hours", sinceDate: now.addingTimeInterval(-21600)))
            periods.append(TimePeriod(id: "1d", displayName: L10n.Tools.Tools.TrafficMap.Period.last24Hours, sinceDate: now.addingTimeInterval(-86400)))
            periods.append(TimePeriod(id: "3d", displayName: "Last 3 Days", sinceDate: now.addingTimeInterval(-259200)))
        } else {
            // >= 7 days: 1d / 3d / 7d / all
            periods.append(TimePeriod(id: "1d", displayName: L10n.Tools.Tools.TrafficMap.Period.last24Hours, sinceDate: now.addingTimeInterval(-86400)))
            periods.append(TimePeriod(id: "3d", displayName: "Last 3 Days", sinceDate: now.addingTimeInterval(-259200)))
            periods.append(TimePeriod(id: "7d", displayName: L10n.Tools.Tools.TrafficMap.Period.last7Days, sinceDate: now.addingTimeInterval(-604800)))
        }

        // "All Time" is always the last option
        periods.append(TimePeriod(id: "all", displayName: L10n.Tools.Tools.TrafficMap.Period.allTime, sinceDate: nil))

        return periods
    }

    /// Formats the oldest packet age for display. E.g. "12h 34m ago"
    var formattedOldestAge: String? {
        guard let age = oldestPacketAge, age > 0 else { return nil }

        let hours = Int(age / 3600)
        let minutes = Int(age.truncatingRemainder(dividingBy: 3600) / 60)

        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "\(days)d \(remainingHours)h ago"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m ago"
        } else {
            return "\(minutes)m ago"
        }
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

            for (hopIndex, hash) in hopHashes.enumerated() {
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

                // SNR/RSSI from the RxLog entry only applies to the last hop in the
                // path — that's the repeater our radio actually heard directly.
                // Earlier hops in the chain have unknown link quality.
                let isLastHop = (hopIndex == hopHashes.count - 1)

                if var existing = repeaterTraffic[key] {
                    existing.packetCount += 1
                    if isLastHop, let snr = entry.snr {
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
                        totalSNR: isLastHop ? (entry.snr ?? 0) : 0,
                        snrSampleCount: (isLastHop && entry.snr != nil) ? 1 : 0,
                        lastSeen: entry.receivedAt
                    )
                }

                locatedHops.append((key, coord))
            }

            // Build segment traffic from consecutive located hops.
            // We don't attribute SNR to segments because we only know the
            // signal quality of the final hop to our radio, not intermediate links.
            guard locatedHops.count >= 2 else { continue }
            for i in 0..<(locatedHops.count - 1) {
                let a = locatedHops[i]
                let b = locatedHops[i + 1]

                guard a.publicKey != b.publicKey else { continue }

                let segKey: SegmentKey
                if a.publicKey.lexicographicallyPrecedes(b.publicKey) {
                    segKey = SegmentKey(keyA: a.publicKey, keyB: b.publicKey)
                } else {
                    segKey = SegmentKey(keyA: b.publicKey, keyB: a.publicKey)
                }

                if var existing = segmentTraffic[segKey] {
                    existing.frequency += 1
                    segmentTraffic[segKey] = existing
                } else {
                    segmentTraffic[segKey] = SegmentTraffic(
                        coordinateA: a.coordinate,
                        coordinateB: b.coordinate,
                        frequency: 1
                    )
                }
            }
        }

        // Build display data
        let maxPackets = repeaterTraffic.values.map(\.packetCount).max() ?? 1
        let maxFrequency = segmentTraffic.values.map(\.frequency).max() ?? 1

        bubbleAnnotations = repeaterTraffic.map { (key, traffic) in
            TrafficBubbleAnnotation(
                coordinate: CLLocationCoordinate2D(
                    latitude: traffic.node.latitude,
                    longitude: traffic.node.longitude
                ),
                name: traffic.node.resolvableName,
                publicKey: key,
                packetCount: traffic.packetCount,
                averageSNR: traffic.averageSNR,
                snrQuality: SNRQuality(snr: traffic.averageSNR),
                lastSeen: traffic.lastSeen,
                normalizedTraffic: Double(traffic.packetCount) / Double(maxPackets)
            )
        }

        segmentData = segmentTraffic.map { (key, segment) in
            TrafficSegmentData(
                id: "\(key.keyA.base64EncodedString())-\(key.keyB.base64EncodedString())",
                startCoordinate: segment.coordinateA,
                endCoordinate: segment.coordinateB,
                frequency: segment.frequency,
                normalizedFrequency: Double(segment.frequency) / Double(maxFrequency),
                averageSNR: nil,
                direction: .unspecified
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
    }

    // MARK: - Private Types

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
        let keyA: Data
        let keyB: Data
    }

    private struct SegmentTraffic {
        let coordinateA: CLLocationCoordinate2D
        let coordinateB: CLLocationCoordinate2D
        var frequency: Int
    }

    // MARK: - Private

    private func clearState() {
        bubbleAnnotations = []
        segmentData = []
        totalPacketsAnalyzed = 0
        locatedRepeaterCount = 0
        segmentCount = 0
        hasData = false
        hasLocatedRepeaters = false
        oldestPacketAge = nil
    }
}
