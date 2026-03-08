import CoreLocation
import MapKit
import PocketMeshServices
import os.log

private let logger = Logger(subsystem: "com.pocketmesh", category: "HeardRepeatsMap")

/// View model for the heard repeats map.
///
/// Each `MessageRepeatDTO` has a `pathNodes` chain showing the outbound hops
/// the message traversed before reaching the last repeater, which re-broadcast
/// it back to the user. The SNR/RSSI on the repeat belongs **only** to the
/// last hop (repeater → user's radio).
///
/// The map draws:
/// - Repeater pins with hex hash labels for all intermediate hops (no signal data)
/// - Neutral-colored `PathLineOverlay` lines with arrowheads between consecutive
///   hops in the outbound chain
/// - An SNR-colored `PathLineOverlay` from each "last repeater" to the user's
///   location — this is the only hop where we have actual signal data
/// - A receiver endpoint pin at the user's location
@MainActor @Observable
final class HeardRepeatsMapViewModel {

    // MARK: - Map State

    var cameraRegion: MKCoordinateRegion?
    var cameraRegionVersion = 0
    var mapStyleSelection: MapStyleSelection = .standard
    var showLabels: Bool = true
    var showingLayersMenu: Bool = false

    var mapType: MKMapType { mapStyleSelection.mkMapType }

    // MARK: - Data State

    private(set) var isLoading = false
    private(set) var hasLocatedRepeaters = false

    // MARK: - Map Display Data

    /// Repeater pin annotations for all hops in the outbound chain
    private(set) var repeaterAnnotations: [RepeaterAnnotation] = []
    /// Path info keyed by repeater UUID (hop index, route index for label alternation)
    private(set) var pathState: [UUID: PathInfo] = [:]
    /// Compact hex hash labels keyed by repeater UUID
    private(set) var hashLabels: [UUID: String] = [:]
    /// Neutral-colored outbound path overlays + SNR-colored last-hop overlays
    private(set) var lineOverlays: [PathLineOverlay] = []
    /// SNR quality for last-hop overlays, keyed by overlay segmentIndex
    private(set) var lastHopSNR: [Int: SNRQuality] = [:]
    /// User endpoint
    private(set) var endpointAnnotations: [RouteEndpointAnnotation] = []

    struct PathInfo {
        let hopIndex: Int
        let routeIndex: Int
    }

    // MARK: - Stats

    private(set) var repeatCount: Int = 0
    private(set) var locatedRepeaterCount: Int = 0

    // MARK: - Load

    func load(
        repeats: [MessageRepeatDTO],
        contacts: [ContactDTO],
        discoveredNodes: [DiscoveredNodeDTO],
        userLocation: CLLocation?,
        userName: String
    ) {
        isLoading = true

        let repeaters = contacts.filter { $0.type == .repeater }
        repeatCount = repeats.count

        // Track unique repeaters by public key to avoid duplicate pins
        var seenRepeaters: [Data: ContactDTO] = [:]
        var allLineOverlays: [PathLineOverlay] = []
        var allPathState: [UUID: PathInfo] = [:]
        var allHashLabels: [UUID: String] = [:]
        var allLastHopSNR: [Int: SNRQuality] = [:]
        var routeIndex = 0
        var segmentIndex = 0
        var locatedRepeatCount = 0

        for repeatDTO in repeats {
            guard !repeatDTO.pathNodes.isEmpty else { continue }

            let hashes = RouteAggregator.parseHopHashes(
                pathNodes: repeatDTO.pathNodes,
                hashSize: repeatDTO.hashSize
            )
            guard !hashes.isEmpty else { continue }

            // Resolve all hops to located contacts
            var resolvedHops: [(contact: ContactDTO, hash: Data, coordinate: CLLocationCoordinate2D)] = []

            for hash in hashes {
                guard let match = RepeaterResolver.bestMatch(
                    for: hash, in: repeaters, userLocation: userLocation
                ), match.hasLocation else { continue }

                let coord = CLLocationCoordinate2D(
                    latitude: match.latitude,
                    longitude: match.longitude
                )
                guard CLLocationCoordinate2DIsValid(coord) else { continue }

                resolvedHops.append((contact: match, hash: hash, coordinate: coord))
            }

            guard !resolvedHops.isEmpty else { continue }
            locatedRepeatCount += 1

            // Register unique repeater pins
            for (hopIdx, hop) in resolvedHops.enumerated() {
                if seenRepeaters[hop.contact.publicKey] == nil {
                    seenRepeaters[hop.contact.publicKey] = hop.contact
                    allPathState[hop.contact.id] = PathInfo(hopIndex: hopIdx + 1, routeIndex: routeIndex)
                    allHashLabels[hop.contact.id] = hop.hash.hexString()
                    routeIndex += 1
                }
            }

            // Draw outbound chain: consecutive hops
            for i in 0..<(resolvedHops.count - 1) {
                let overlay = PathLineOverlay.line(
                    from: resolvedHops[i].coordinate,
                    to: resolvedHops[i + 1].coordinate,
                    segmentIndex: segmentIndex
                )
                allLineOverlays.append(overlay)
                segmentIndex += 1
            }

            // Draw last-hop → user (SNR-colored)
            if let userLocation {
                let lastHop = resolvedHops.last!
                let overlay = PathLineOverlay.line(
                    from: lastHop.coordinate,
                    to: userLocation.coordinate,
                    segmentIndex: segmentIndex
                )
                allLineOverlays.append(overlay)
                allLastHopSNR[segmentIndex] = SNRQuality(snr: repeatDTO.snr)
                segmentIndex += 1
            }
        }

        // Build annotations
        repeaterAnnotations = seenRepeaters.values.map { RepeaterAnnotation(repeater: $0) }
        pathState = allPathState
        hashLabels = allHashLabels
        lineOverlays = allLineOverlays
        lastHopSNR = allLastHopSNR
        locatedRepeaterCount = seenRepeaters.count
        hasLocatedRepeaters = !seenRepeaters.isEmpty

        // User endpoint
        if let userLocation, hasLocatedRepeaters {
            endpointAnnotations = [
                RouteEndpointAnnotation(
                    type: .receiver,
                    coordinate: userLocation.coordinate,
                    name: userName,
                    routeIndex: routeIndex
                )
            ]
        } else {
            endpointAnnotations = []
        }

        if hasLocatedRepeaters {
            centerOnData()
        }

        logger.debug("Heard repeats map: \(self.repeatCount) repeats, \(locatedRepeatCount) with location, \(self.locatedRepeaterCount) unique repeaters")
        isLoading = false
    }

    // MARK: - Camera

    func centerOnData() {
        var coordinates: [CLLocationCoordinate2D] = []
        coordinates += repeaterAnnotations.map(\.coordinate)
        coordinates += endpointAnnotations.map(\.coordinate)
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

    private func clearDisplayData() {
        repeaterAnnotations = []
        pathState = [:]
        hashLabels = [:]
        lineOverlays = []
        lastHopSNR = [:]
        endpointAnnotations = []
        locatedRepeaterCount = 0
        hasLocatedRepeaters = false
    }
}
