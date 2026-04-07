import CoreLocation
import Foundation
import MC1Services

/// Type-erased wrapper so contacts and discovered nodes can be resolved in a single pool.
struct AnyResolvable: RepeaterResolvable {
    let publicKey: Data
    let latitude: Double
    let longitude: Double
    let hasLocation: Bool
    let lastAdvertTimestamp: UInt32
    let recencyDate: Date
    let resolvableName: String

    init(_ node: some RepeaterResolvable) {
        self.publicKey = node.publicKey
        self.latitude = node.latitude
        self.longitude = node.longitude
        self.hasLocation = node.hasLocation
        self.lastAdvertTimestamp = node.lastAdvertTimestamp
        self.recencyDate = node.recencyDate
        self.resolvableName = node.resolvableName
    }
}

/// Result of a repeater resolution including ambiguity information.
struct ResolverResult<T: RepeaterResolvable> {
    let best: T
    /// All matching candidates, sorted best-first.
    let candidates: [T]
    /// Whether the resolution is ambiguous (more than one candidate).
    var isAmbiguous: Bool { candidates.count > 1 }
}

/// Resolves repeater collisions by proximity and recency.
enum RepeaterResolver {

    // MARK: - Centralized Node Pool

    /// Threshold for considering a discovered node stale: 7 days in seconds.
    /// Used consistently across all resolution and disambiguation paths.
    static let staleThresholdSeconds: UInt32 = 7 * 24 * 3600

    /// Builds a unified, filtered pool of resolvable nodes from contacts and discovered nodes.
    ///
    /// Filters out stale discovered nodes (not heard in >7 days) to prevent
    /// deleted/offline repeaters from winning resolution over active ones.
    /// **All code that resolves hops should use this method** to ensure consistent filtering.
    static func buildNodePool(
        repeaters: [ContactDTO],
        discoveredNodes: [DiscoveredNodeDTO]
    ) -> [AnyResolvable] {
        let fresh = filterFresh(discoveredNodes)
        return repeaters.map { AnyResolvable($0) } + fresh.map { AnyResolvable($0) }
    }

    /// Filters discovered nodes to remove stale entries not heard in >7 days.
    /// Use this when you need the filtered list directly (e.g. for disambiguation candidates).
    static func filterFresh(_ nodes: [DiscoveredNodeDTO]) -> [DiscoveredNodeDTO] {
        let threshold = UInt32(Date().timeIntervalSince1970) - staleThresholdSeconds
        return nodes.filter { $0.lastAdvertTimestamp == 0 || $0.lastAdvertTimestamp > threshold }
    }

    // MARK: - Resolution

    /// Match using a PathHop: exact public key match first, then hash bytes fallback.
    static func bestMatch<T: RepeaterResolvable>(
        for hop: PathHop,
        in nodes: [T],
        userLocation: CLLocation?
    ) -> T? {
        if let key = hop.publicKey,
           let exact = nodes.first(where: { $0.publicKey == key }) {
            return exact
        }
        return bestMatch(for: hop.hashBytes, in: nodes, userLocation: userLocation)
    }

    /// Match using hash bytes (1-3 byte prefix), returning the best match.
    static func bestMatch<T: RepeaterResolvable>(
        for hashBytes: Data,
        in nodes: [T],
        userLocation: CLLocation?,
        anchorLocation: CLLocation? = nil
    ) -> T? {
        resolve(for: hashBytes, in: nodes, userLocation: userLocation, anchorLocation: anchorLocation)?.best
    }

    /// Match using hash bytes with full candidate information for disambiguation.
    static func resolve<T: RepeaterResolvable>(
        for hashBytes: Data,
        in nodes: [T],
        userLocation: CLLocation?,
        anchorLocation: CLLocation? = nil
    ) -> ResolverResult<T>? {
        let sorted = sortedCandidates(for: hashBytes, in: nodes, userLocation: userLocation, anchorLocation: anchorLocation)
        guard let best = sorted.first else { return nil }
        return ResolverResult(best: best, candidates: sorted)
    }

    /// Returns all matching candidates sorted by the standard heuristic (best first).
    ///
    /// When `anchorLocation` is provided (e.g. the location of the previous hop in a route),
    /// geographic proximity to the anchor takes priority over recency. This produces much
    /// better results for route resolution because a repeater 500 ft from the previous hop
    /// is far more likely to be the actual relay than one 100 miles away, regardless of
    /// which was heard more recently.
    static func sortedCandidates<T: RepeaterResolvable>(
        for hashBytes: Data,
        in nodes: [T],
        userLocation: CLLocation?,
        anchorLocation: CLLocation? = nil
    ) -> [T] {
        let prefixLen = hashBytes.count
        let candidates = nodes.compactMap { node -> (node: T, userDistance: Double?, anchorDistance: Double?)? in
            guard node.publicKey.prefix(prefixLen) == hashBytes else { return nil }

            let userDistance: Double?
            if let userLocation, node.hasLocation {
                let nodeLocation = CLLocation(latitude: node.latitude, longitude: node.longitude)
                userDistance = userLocation.distance(from: nodeLocation)
            } else {
                userDistance = nil
            }

            let anchorDistance: Double?
            if let anchorLocation, node.hasLocation {
                let nodeLocation = CLLocation(latitude: node.latitude, longitude: node.longitude)
                anchorDistance = anchorLocation.distance(from: nodeLocation)
            } else {
                anchorDistance = nil
            }

            return (node, userDistance, anchorDistance)
        }

        guard !candidates.isEmpty else { return [] }

        // With short prefixes (1 byte = 256 values) collisions are common.
        //
        // When an anchor location is available (from a neighboring hop in the route),
        // proximity to the anchor is the strongest signal — a repeater close to the
        // previous hop almost certainly relayed this message. We use anchor distance
        // as the primary sort criterion, with recency as a tiebreaker.
        //
        // Without an anchor, we fall back to recency-first sorting with distance
        // from the user as a secondary criterion.
        let sorted = candidates.sorted { lhs, rhs in
            if anchorLocation != nil {
                // When one candidate is dramatically more stale than another,
                // prefer the active one regardless of anchor proximity.
                // A repeater not heard in weeks may be offline or relocated.
                let lhsTS = lhs.node.lastAdvertTimestamp
                let rhsTS = rhs.node.lastAdvertTimestamp
                if lhsTS > 0 && rhsTS > 0 {
                    let nowTS = UInt32(Date().timeIntervalSince1970)
                    let staleThreshold = nowTS > staleThresholdSeconds ? nowTS - staleThresholdSeconds : 0
                    let lhsStale = lhsTS < staleThreshold
                    let rhsStale = rhsTS < staleThreshold
                    if lhsStale != rhsStale {
                        return rhsStale // non-stale wins
                    }
                }

                // Anchor-aware sorting: proximity to the previous/next hop wins
                switch (lhs.anchorDistance, rhs.anchorDistance) {
                case let (left?, right?):
                    if left != right { return left < right }
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    break
                }
            }

            // Recency: most recently advertised wins
            if lhs.node.lastAdvertTimestamp != rhs.node.lastAdvertTimestamp {
                return lhs.node.lastAdvertTimestamp > rhs.node.lastAdvertTimestamp
            }

            // Secondary recency (lastModified / lastHeard)
            if lhs.node.recencyDate != rhs.node.recencyDate {
                return lhs.node.recencyDate > rhs.node.recencyDate
            }

            // Among equally-recent candidates, prefer located over unlocated
            switch (lhs.userDistance, rhs.userDistance) {
            case let (left?, right?):
                if left != right { return left < right }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }

            // Alphabetical fallback
            return lhs.node.resolvableName.localizedStandardCompare(rhs.node.resolvableName) == .orderedAscending
        }

        return sorted.map(\.node)
    }
}
