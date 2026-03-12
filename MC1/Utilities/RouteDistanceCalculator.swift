import CoreLocation
import Foundation
import MC1Services

/// Calculates and formats distances along a message route through mesh repeaters.
///
/// When intermediate repeaters in the route don't have location data, the computed
/// total is a **minimum** — the true distance could be longer because the unlocated
/// repeaters might add extra path length. The `hasGaps` flag tells callers when this
/// applies so they can communicate it clearly to the user (e.g. with a "≥" prefix).
enum RouteDistanceCalculator {

    // MARK: - Formatting

    /// Formats a distance in meters using the user's locale (km / mi).
    static func formatDistance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// Formats a total distance with a "minimum" qualifier when the route has gaps.
    /// Returns e.g. "12.4 km" or "≥ 12.4 km" when hops are missing location data.
    static func formatTotal(_ meters: Double, hasGaps: Bool) -> String {
        let base = formatDistance(meters)
        return hasGaps ? "≥ \(base)" : base
    }

    // MARK: - Chain Distance

    /// Sums great-circle distances between consecutive coordinates.
    /// This is the shared core used by map view models and route info formatting.
    /// Returns 0 when fewer than 2 coordinates are provided.
    static func chainDistance(between coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        var totalMeters: Double = 0
        for i in 0..<(coordinates.count - 1) {
            let a = CLLocation(latitude: coordinates[i].latitude, longitude: coordinates[i].longitude)
            let b = CLLocation(latitude: coordinates[i + 1].latitude, longitude: coordinates[i + 1].longitude)
            totalMeters += a.distance(from: b)
        }
        return totalMeters
    }

    // MARK: - Route Info

    /// Computes distance along a message's path using known contacts/discovered nodes.
    /// Returns (totalMeters, hasGaps) or nil if distance can't be computed.
    static func computeRouteDistance(
        message: MessageDTO,
        contacts: [ContactDTO],
        discoveredNodes: [DiscoveredNodeDTO],
        userLocation: CLLocation?
    ) -> (meters: Double, hasGaps: Bool)? {
        guard let pathNodes = message.pathNodes, !pathNodes.isEmpty else { return nil }

        let hashSize = message.pathHashSize
        let hops = stride(from: 0, to: pathNodes.count, by: hashSize).map { start in
            Data(pathNodes[start..<min(start + hashSize, pathNodes.count)])
        }

        guard !hops.isEmpty else { return nil }

        // Build coordinate chain: sender → hops → receiver (user)
        var locatedCoordinates: [CLLocationCoordinate2D] = []
        // Only intermediate repeaters with unknown location count as gaps,
        // because unlocated repeaters could add extra path length.
        // Missing sender/receiver locations just shorten the measured chain.
        var hasGaps = false

        // Helper to resolve a hash against contacts then discovered nodes
        func resolveLocation(for hashBytes: Data) -> CLLocationCoordinate2D? {
            if let match = RepeaterResolver.bestMatch(for: hashBytes, in: contacts, userLocation: userLocation),
               match.hasLocation {
                return CLLocationCoordinate2D(latitude: match.latitude, longitude: match.longitude)
            }
            if let match = RepeaterResolver.bestMatch(for: hashBytes, in: discoveredNodes, userLocation: userLocation),
               match.hasLocation {
                return CLLocationCoordinate2D(latitude: match.latitude, longitude: match.longitude)
            }
            return nil
        }

        // Try to locate sender from senderKeyPrefix
        if let senderKey = message.senderKeyPrefix, let coord = resolveLocation(for: senderKey) {
            locatedCoordinates.append(coord)
        }

        // Resolve each intermediate hop (repeater)
        for hop in hops {
            if let coord = resolveLocation(for: hop) {
                locatedCoordinates.append(coord)
            } else {
                hasGaps = true
            }
        }

        // Add receiver (user) location
        if let userLocation {
            locatedCoordinates.append(userLocation.coordinate)
        }

        let totalMeters = chainDistance(between: locatedCoordinates)
        guard totalMeters > 0 else { return nil }
        return (totalMeters, hasGaps)
    }

    /// Formats a route info line for use in reply text.
    /// Example: "Via 3 hops · ≥ 12 mi (80,16,78)"
    static func formatRouteInfo(
        message: MessageDTO,
        contacts: [ContactDTO] = [],
        discoveredNodes: [DiscoveredNodeDTO] = [],
        userLocation: CLLocation? = nil
    ) -> String? {
        let hopCount = Int(message.pathLength & 0x3F) // lower 6 bits
        guard hopCount > 0 else { return nil }

        let pathHex = message.pathNodesHex.joined(separator: ",")
        guard !pathHex.isEmpty else { return nil }

        // Try to compute distance
        let distancePart: String
        if let result = computeRouteDistance(
            message: message,
            contacts: contacts,
            discoveredNodes: discoveredNodes,
            userLocation: userLocation
        ) {
            distancePart = " · \(formatTotal(result.meters, hasGaps: result.hasGaps))"
        } else {
            distancePart = ""
        }

        let hopWord = hopCount == 1 ? "hop" : "hops"
        return "Via \(hopCount) \(hopWord)\(distancePart) (\(pathHex))"
    }
}
