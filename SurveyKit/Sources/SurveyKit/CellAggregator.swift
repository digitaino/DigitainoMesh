import Foundation

/// One recorded observation, normalized for aggregation. MC1Services maps its
/// persistence DTOs into this; tests construct it directly.
public struct SurveySample: Sendable {
    public enum Route: Sendable {
        case flood
        case direct
    }

    /// Direction-aware repeater involvement in a single packet.
    public struct RepeaterSighting: Sendable {
        /// Hex-string identity: full 64-char pubkey when known, else 2–6 char prefix.
        public var id: String
        /// SNR of packets we heard from/via this repeater (RX direction).
        public var rxSnr: Double?
        /// SNR reported by the repeater for our transmission (TX direction —
        /// populated from discover/trace responses: "they heard us").
        public var txSnr: Double?
        public var rssi: Double?

        public init(id: String, rxSnr: Double? = nil, txSnr: Double? = nil, rssi: Double? = nil) {
            self.id = id
            self.rxSnr = rxSnr
            self.txSnr = txSnr
            self.rssi = rssi
        }
    }

    public var timestamp: Date
    public var coordinate: GeoCoordinate
    public var snr: Double?
    public var txSnr: Double?
    public var rssi: Double?
    public var route: Route
    public var isActiveProbe: Bool
    public var hopCount: Int?
    public var repeaters: [RepeaterSighting]

    public init(
        timestamp: Date,
        coordinate: GeoCoordinate,
        snr: Double? = nil,
        txSnr: Double? = nil,
        rssi: Double? = nil,
        route: Route,
        isActiveProbe: Bool,
        hopCount: Int? = nil,
        repeaters: [RepeaterSighting] = []
    ) {
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.snr = snr
        self.txSnr = txSnr
        self.rssi = rssi
        self.route = route
        self.isActiveProbe = isActiveProbe
        self.hopCount = hopCount
        self.repeaters = repeaters
    }
}

/// A fully aggregated cell — the one shape used for on-map display, file export, and
/// upload, so the three can never disagree about the same data again.
public struct AggregatedCell: Sendable {
    public struct RepeaterStats: Sendable {
        public var id: String
        public var rxPacketCount: Int = 0
        public var txPacketCount: Int = 0
        public var rxSnrSum: Double = 0
        public var rxSnrCount: Int = 0
        public var txSnrSum: Double = 0
        public var txSnrCount: Int = 0
        public var rssiSum: Double = 0
        public var rssiCount: Int = 0
        public var firstHeard: Date
        public var lastHeard: Date

        public var packetCount: Int { rxPacketCount + txPacketCount }
        public var avgRxSnr: Double? { rxSnrCount > 0 ? rxSnrSum / Double(rxSnrCount) : nil }
        public var avgTxSnr: Double? { txSnrCount > 0 ? txSnrSum / Double(txSnrCount) : nil }
        public var avgRssi: Double? { rssiCount > 0 ? rssiSum / Double(rssiCount) : nil }
    }

    public var cell: H3Cell
    public var packetCount: Int = 0
    public var activePacketCount: Int = 0
    public var passivePacketCount: Int = 0
    public var probesSent: Int = 0
    public var snrSum: Double = 0
    public var snrCount: Int = 0
    public var minSnr: Double?
    public var maxSnr: Double?
    public var txSnrSum: Double = 0
    public var txSnrCount: Int = 0
    public var rssiSum: Double = 0
    public var rssiCount: Int = 0
    public var floodCount: Int = 0
    public var directCount: Int = 0
    public var earliest: Date?
    public var latest: Date?
    /// UTC day ("2026-07-18") → observation count.
    public var dailyCounts: [String: Int] = [:]
    /// Hop count → packet count.
    public var hopHistogram: [Int: Int] = [:]
    public var repeaters: [String: RepeaterStats] = [:]

    public init(cell: H3Cell) {
        self.cell = cell
    }

    public var avgSnr: Double? { snrCount > 0 ? snrSum / Double(snrCount) : nil }
    public var avgTxSnr: Double? { txSnrCount > 0 ? txSnrSum / Double(txSnrCount) : nil }
    public var avgRssi: Double? { rssiCount > 0 ? rssiSum / Double(rssiCount) : nil }
    public var quality: SignalQuality { SignalQuality(snr: avgSnr) }
    /// A probed cell with zero received packets.
    public var isDeadZone: Bool { packetCount == 0 && probesSent > 0 }
}

/// The single aggregation path from samples to per-cell stats.
public enum CellAggregator {

    /// UTC day-bucket formatter for `dailyCounts` keys.
    private static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Folds one sample into a cell aggregate. O(1); usable incrementally during a
    /// live survey or in a batch fold at export time.
    public static func fold(_ sample: SurveySample, into cell: inout AggregatedCell) {
        cell.packetCount += 1
        if sample.isActiveProbe {
            cell.activePacketCount += 1
        } else {
            cell.passivePacketCount += 1
        }
        if let snr = sample.snr {
            cell.snrSum += snr
            cell.snrCount += 1
            cell.minSnr = Swift.min(cell.minSnr ?? snr, snr)
            cell.maxSnr = Swift.max(cell.maxSnr ?? snr, snr)
        }
        if let txSnr = sample.txSnr {
            cell.txSnrSum += txSnr
            cell.txSnrCount += 1
        }
        if let rssi = sample.rssi {
            cell.rssiSum += rssi
            cell.rssiCount += 1
        }
        switch sample.route {
        case .flood: cell.floodCount += 1
        case .direct: cell.directCount += 1
        }
        cell.earliest = Swift.min(cell.earliest ?? sample.timestamp, sample.timestamp)
        cell.latest = Swift.max(cell.latest ?? sample.timestamp, sample.timestamp)
        cell.dailyCounts[dayKey(for: sample.timestamp), default: 0] += 1
        if let hops = sample.hopCount {
            cell.hopHistogram[hops, default: 0] += 1
        }

        for sighting in sample.repeaters {
            var stats = cell.repeaters[sighting.id] ?? AggregatedCell.RepeaterStats(
                id: sighting.id,
                firstHeard: sample.timestamp,
                lastHeard: sample.timestamp
            )
            if let rxSnr = sighting.rxSnr {
                stats.rxSnrSum += rxSnr
                stats.rxSnrCount += 1
            }
            if let txSnr = sighting.txSnr {
                stats.txSnrSum += txSnr
                stats.txSnrCount += 1
                stats.txPacketCount += 1
            } else {
                stats.rxPacketCount += 1
            }
            if let rssi = sighting.rssi {
                stats.rssiSum += rssi
                stats.rssiCount += 1
            }
            stats.firstHeard = Swift.min(stats.firstHeard, sample.timestamp)
            stats.lastHeard = Swift.max(stats.lastHeard, sample.timestamp)
            cell.repeaters[sighting.id] = stats
        }
    }

    /// Buckets and aggregates a batch of samples at the given resolution.
    public static func aggregate(
        _ samples: [SurveySample],
        resolution: Int = SurveyGrid.baseResolution
    ) -> [H3Cell: AggregatedCell] {
        var cells: [H3Cell: AggregatedCell] = [:]
        for sample in samples {
            guard let cell = SurveyGrid.cell(containing: sample.coordinate, resolution: resolution) else {
                continue
            }
            var aggregate = cells[cell] ?? AggregatedCell(cell: cell)
            fold(sample, into: &aggregate)
            cells[cell] = aggregate
        }
        return cells
    }
}

extension AggregatedCell {

    /// The wire form of this aggregate. One conversion path for every upload trigger.
    public func wireCell(repeaterKind: (String) -> UploadV2RepeaterObservation) -> UploadV2Cell {
        let sortedRepeaters = repeaters.values.sorted { $0.packetCount > $1.packetCount }
        return UploadV2Cell(
            h3: cell.stringValue,
            snr: UploadV2SnrStats(avg: avgSnr, min: minSnr, max: maxSnr, txAvg: avgTxSnr),
            rssiAvg: avgRssi,
            packetCount: packetCount,
            activePacketCount: activePacketCount,
            passivePacketCount: passivePacketCount,
            probesSent: probesSent,
            routeBreakdown: UploadV2RouteBreakdown(flood: floodCount, direct: directCount),
            timeRange: earliest.flatMap { earliest in
                latest.map { latest in
                    UploadV2TimeRange(
                        earliest: earliest.ISO8601Format(),
                        latest: latest.ISO8601Format()
                    )
                }
            },
            dailyCounts: dailyCounts.isEmpty ? nil : dailyCounts,
            hopHistogram: hopHistogram.isEmpty ? nil : Dictionary(
                uniqueKeysWithValues: hopHistogram.map { (String($0.key), $0.value) }
            ),
            repeaters: sortedRepeaters.map { stats in
                var observation = repeaterKind(stats.id)
                observation.snr = stats.avgRxSnr
                observation.rssi = stats.avgRssi
                observation.txSnr = stats.avgTxSnr
                observation.packetCount = stats.packetCount
                observation.rxPacketCount = stats.rxPacketCount
                observation.txPacketCount = stats.txPacketCount
                observation.firstHeard = stats.firstHeard.ISO8601Format()
                observation.lastHeard = stats.lastHeard.ISO8601Format()
                return observation
            }
        )
    }
}
