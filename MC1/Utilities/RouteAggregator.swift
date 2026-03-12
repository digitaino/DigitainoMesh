import CoreLocation
import MC1Services

/// Shared route aggregation utility used by Traffic Heatmap, Per-Contact Route Map,
/// and Heard Repeats Map. Extracts common hop parsing, resolver invocation, and
/// traffic accumulation logic.
enum RouteAggregator {

    // MARK: - Types

    /// A resolved hop with geographic coordinates.
    struct LocatedHop {
        let publicKey: Data
        let coordinate: CLLocationCoordinate2D
        let name: String
    }

    /// Direction of traffic for a route.
    enum RouteDirection {
        case inbound
        case outbound
        case unspecified
    }

    /// Result of aggregating multiple routes.
    struct AggregationResult {
        let bubbleAnnotations: [TrafficBubbleAnnotation]
        let segmentData: [TrafficSegmentData]
        let locatedRepeaterCount: Int
        let segmentCount: Int
    }

    // MARK: - Hop Parsing

    /// Parse raw pathNodes data into individual hop hash chunks.
    static func parseHopHashes(pathNodes: Data, hashSize: Int) -> [Data] {
        guard hashSize > 0, !pathNodes.isEmpty else { return [] }
        return stride(from: 0, to: pathNodes.count, by: hashSize).map { start in
            let end = min(start + hashSize, pathNodes.count)
            return Data(pathNodes[start..<end])
        }
    }

    // MARK: - Hop Resolution

    /// Resolve a single hop hash to a located node.
    /// Tries contacts first, then discovered nodes. Returns nil if no match or no location.
    static func resolveHop(
        hash: Data,
        contacts: [ContactDTO],
        discoveredNodes: [DiscoveredNodeDTO],
        userLocation: CLLocation?
    ) -> LocatedHop? {
        let match: (any RepeaterResolvable)? =
            RepeaterResolver.bestMatch(for: hash, in: contacts, userLocation: userLocation)
            ?? RepeaterResolver.bestMatch(for: hash, in: discoveredNodes, userLocation: userLocation)

        guard let match, match.hasLocation else { return nil }

        let coord = CLLocationCoordinate2D(
            latitude: match.latitude,
            longitude: match.longitude
        )
        guard CLLocationCoordinate2DIsValid(coord) else { return nil }

        return LocatedHop(
            publicKey: match.publicKey,
            coordinate: coord,
            name: match.resolvableName
        )
    }

    /// Resolve a full path from raw pathNodes data into an array of located hops.
    static func resolvePath(
        pathNodes: Data,
        hashSize: Int,
        contacts: [ContactDTO],
        discoveredNodes: [DiscoveredNodeDTO],
        userLocation: CLLocation?
    ) -> [LocatedHop] {
        let hashes = parseHopHashes(pathNodes: pathNodes, hashSize: hashSize)
        return hashes.compactMap { hash in
            resolveHop(
                hash: hash,
                contacts: contacts,
                discoveredNodes: discoveredNodes,
                userLocation: userLocation
            )
        }
    }

    // MARK: - Aggregation

    /// Aggregate multiple route paths into bubble annotations and segment data.
    /// - Parameters:
    ///   - routes: Array of (resolved hops, SNR, direction) tuples
    ///   - directional: If true, A→B and B→A are kept as separate segments.
    ///     If false, segments are canonicalized so A→B == B→A.
    static func aggregate(
        routes: [(hops: [LocatedHop], snr: Double?, direction: RouteDirection)],
        directional: Bool
    ) -> AggregationResult {
        var repeaterTraffic: [Data: RepeaterTraffic] = [:]
        var segmentTraffic: [SegmentKey: SegmentTraffic] = [:]

        for route in routes {
            // Accumulate per-node traffic
            for hop in route.hops {
                if var existing = repeaterTraffic[hop.publicKey] {
                    existing.packetCount += 1
                    if let snr = route.snr {
                        existing.totalSNR += snr
                        existing.snrSampleCount += 1
                    }
                    repeaterTraffic[hop.publicKey] = existing
                } else {
                    repeaterTraffic[hop.publicKey] = RepeaterTraffic(
                        coordinate: hop.coordinate,
                        name: hop.name,
                        packetCount: 1,
                        totalSNR: route.snr ?? 0,
                        snrSampleCount: route.snr != nil ? 1 : 0
                    )
                }
            }

            // Build per-segment traffic from consecutive hops
            guard route.hops.count >= 2 else { continue }
            for i in 0..<(route.hops.count - 1) {
                let a = route.hops[i]
                let b = route.hops[i + 1]

                // Skip self-loops
                guard a.publicKey != b.publicKey else { continue }

                let segKey: SegmentKey
                let coordA: CLLocationCoordinate2D
                let coordB: CLLocationCoordinate2D

                if directional {
                    // Keep direction: A→B is distinct from B→A
                    segKey = SegmentKey(keyA: a.publicKey, keyB: b.publicKey, direction: route.direction)
                    coordA = a.coordinate
                    coordB = b.coordinate
                } else {
                    // Canonicalize: A→B == B→A
                    if a.publicKey.lexicographicallyPrecedes(b.publicKey) {
                        segKey = SegmentKey(keyA: a.publicKey, keyB: b.publicKey, direction: .unspecified)
                        coordA = a.coordinate
                        coordB = b.coordinate
                    } else {
                        segKey = SegmentKey(keyA: b.publicKey, keyB: a.publicKey, direction: .unspecified)
                        coordA = b.coordinate
                        coordB = a.coordinate
                    }
                }

                if var existing = segmentTraffic[segKey] {
                    existing.frequency += 1
                    if let snr = route.snr {
                        existing.totalSNR += snr
                        existing.snrSampleCount += 1
                    }
                    segmentTraffic[segKey] = existing
                } else {
                    segmentTraffic[segKey] = SegmentTraffic(
                        coordinateA: coordA,
                        coordinateB: coordB,
                        frequency: 1,
                        totalSNR: route.snr ?? 0,
                        snrSampleCount: route.snr != nil ? 1 : 0,
                        direction: directional ? route.direction : .unspecified
                    )
                }
            }
        }

        // Build display data
        let maxPackets = repeaterTraffic.values.map(\.packetCount).max() ?? 1
        let maxFrequency = segmentTraffic.values.map(\.frequency).max() ?? 1

        let bubbles = repeaterTraffic.map { (key, traffic) in
            TrafficBubbleAnnotation(
                coordinate: traffic.coordinate,
                name: traffic.name,
                publicKey: key,
                packetCount: traffic.packetCount,
                averageSNR: traffic.averageSNR,
                snrQuality: SNRQuality(snr: traffic.averageSNR),
                lastSeen: .now,
                normalizedTraffic: Double(traffic.packetCount) / Double(maxPackets)
            )
        }

        let segments = segmentTraffic.map { (key, segment) in
            TrafficSegmentData(
                id: "\(key.keyA.base64EncodedString())-\(key.keyB.base64EncodedString())-\(key.direction)",
                startCoordinate: segment.coordinateA,
                endCoordinate: segment.coordinateB,
                frequency: segment.frequency,
                normalizedFrequency: Double(segment.frequency) / Double(maxFrequency),
                averageSNR: segment.averageSNR,
                direction: segment.direction.segmentDirection
            )
        }

        return AggregationResult(
            bubbleAnnotations: bubbles,
            segmentData: segments,
            locatedRepeaterCount: repeaterTraffic.count,
            segmentCount: segmentTraffic.count
        )
    }

    // MARK: - Private Types

    private struct RepeaterTraffic {
        let coordinate: CLLocationCoordinate2D
        let name: String
        var packetCount: Int
        var totalSNR: Double
        var snrSampleCount: Int

        var averageSNR: Double? {
            snrSampleCount > 0 ? totalSNR / Double(snrSampleCount) : nil
        }
    }

    private struct SegmentKey: Hashable {
        let keyA: Data
        let keyB: Data
        let direction: RouteDirection

        static func == (lhs: SegmentKey, rhs: SegmentKey) -> Bool {
            lhs.keyA == rhs.keyA && lhs.keyB == rhs.keyB && lhs.direction == rhs.direction
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(keyA)
            hasher.combine(keyB)
            hasher.combine(direction)
        }
    }

    private struct SegmentTraffic {
        let coordinateA: CLLocationCoordinate2D
        let coordinateB: CLLocationCoordinate2D
        var frequency: Int
        var totalSNR: Double
        var snrSampleCount: Int
        let direction: RouteDirection

        var averageSNR: Double? {
            snrSampleCount > 0 ? totalSNR / Double(snrSampleCount) : nil
        }
    }
}

// MARK: - Direction Conversion

private extension RouteAggregator.RouteDirection {
    var segmentDirection: SegmentDirection {
        switch self {
        case .inbound: .inbound
        case .outbound: .outbound
        case .unspecified: .unspecified
        }
    }
}
