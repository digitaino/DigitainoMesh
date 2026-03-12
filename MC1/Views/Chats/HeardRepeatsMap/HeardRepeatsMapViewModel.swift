import CoreLocation
import MapKit
import MC1Services
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
///
/// Supports cycling through individual repeats via `showNextRepeat()` /
/// `showPreviousRepeat()`. When `selectedRepeatIndex` is nil, all repeats
/// are shown aggregated (the default).
@MainActor @Observable
final class HeardRepeatsMapViewModel {

    // MARK: - Map State

    var cameraRegion: MKCoordinateRegion?
    var cameraRegionVersion = 0
    var mapStyleSelection: MapStyleSelection = .standard
    var labelMode: AnnotationLabelMode = .name
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

    // MARK: - Distance

    /// Formatted total route distance for the current view (single repeat or all).
    /// Includes "≥" prefix when hops are missing location data.
    private(set) var distanceText: String?

    // MARK: - Repeat Cycling

    /// nil = show all repeats aggregated, 0..<N = show single repeat
    private(set) var selectedRepeatIndex: Int?

    /// Whether there are enough located repeats to cycle through
    var canCycleRepeats: Bool { resolvedRepeats.count >= 2 }

    // MARK: - Resolved Data (for rebuilding display without re-resolving)

    struct ResolvedRepeat {
        let repeatDTO: MessageRepeatDTO
        let hops: [(contact: ContactDTO, coordinate: CLLocationCoordinate2D)]
        /// Number of hops in the path that had no location data.
        let unlocatedHopCount: Int
    }

    private var resolvedRepeats: [ResolvedRepeat] = []
    private var storedUserLocation: CLLocation?
    private var storedUserName: String = ""

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
        storedUserLocation = userLocation
        storedUserName = userName
        selectedRepeatIndex = nil

        // Phase 1: Resolve all repeats
        var resolved: [ResolvedRepeat] = []

        for repeatDTO in repeats {
            guard !repeatDTO.pathNodes.isEmpty else { continue }

            let hashes = RouteAggregator.parseHopHashes(
                pathNodes: repeatDTO.pathNodes,
                hashSize: repeatDTO.hashSize
            )
            guard !hashes.isEmpty else { continue }

            var resolvedHops: [(contact: ContactDTO, coordinate: CLLocationCoordinate2D)] = []
            var unlocatedCount = 0

            for hash in hashes {
                guard let match = RepeaterResolver.bestMatch(
                    for: hash, in: repeaters, userLocation: userLocation
                ), match.hasLocation else {
                    unlocatedCount += 1
                    continue
                }

                let coord = CLLocationCoordinate2D(
                    latitude: match.latitude,
                    longitude: match.longitude
                )
                guard CLLocationCoordinate2DIsValid(coord) else {
                    unlocatedCount += 1
                    continue
                }

                resolvedHops.append((contact: match, coordinate: coord))
            }

            guard !resolvedHops.isEmpty else { continue }
            resolved.append(ResolvedRepeat(
                repeatDTO: repeatDTO,
                hops: resolvedHops,
                unlocatedHopCount: unlocatedCount
            ))
        }

        resolvedRepeats = resolved

        // Phase 2: Build display data for current selection (all)
        rebuildDisplayData()

        logger.debug("Heard repeats map: \(self.repeatCount) repeats, \(self.resolvedRepeats.count) with location, \(self.locatedRepeaterCount) unique repeaters")
        isLoading = false
    }

    // MARK: - Repeat Navigation

    func showNextRepeat() {
        guard canCycleRepeats else { return }
        if let current = selectedRepeatIndex {
            if current + 1 < resolvedRepeats.count {
                selectedRepeatIndex = current + 1
            } else {
                selectedRepeatIndex = nil // wrap to "All"
            }
        } else {
            selectedRepeatIndex = 0
        }
        rebuildDisplayData()
        centerOnData()
    }

    func showPreviousRepeat() {
        guard canCycleRepeats else { return }
        if let current = selectedRepeatIndex {
            if current > 0 {
                selectedRepeatIndex = current - 1
            } else {
                selectedRepeatIndex = nil // wrap to "All"
            }
        } else {
            selectedRepeatIndex = resolvedRepeats.count - 1
        }
        rebuildDisplayData()
        centerOnData()
    }

    /// Summary text for the selected single repeat (e.g. "Repeat 2 of 5 · 12.3 dB · 2 hops · ≥ 4.2 km")
    var selectedRepeatSummary: String {
        guard let index = selectedRepeatIndex,
              index < resolvedRepeats.count else { return "" }

        let resolved = resolvedRepeats[index]
        let repeatNum = index + 1
        let total = resolvedRepeats.count
        let hopCount = resolved.hops.count

        let snrText: String
        if let snr = resolved.repeatDTO.snr {
            snrText = String(format: "%.1f dB", snr)
        } else {
            snrText = "— dB"
        }

        let hopWord = hopCount == 1 ? "hop" : "hops"
        var parts = ["Repeat \(repeatNum) of \(total)", snrText, "\(hopCount) \(hopWord)"]

        if let dist = distanceText {
            parts.append(dist)
        }

        return parts.joined(separator: " · ")
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

    private func rebuildDisplayData() {
        let repeatsToShow: [ResolvedRepeat]
        if let index = selectedRepeatIndex, index < resolvedRepeats.count {
            repeatsToShow = [resolvedRepeats[index]]
        } else {
            repeatsToShow = resolvedRepeats
        }

        var seenRepeaters: [Data: ContactDTO] = [:]
        var allLineOverlays: [PathLineOverlay] = []
        var allPathState: [UUID: PathInfo] = [:]
        var allLastHopSNR: [Int: SNRQuality] = [:]
        var routeIndex = 0
        var segmentIndex = 0

        for resolved in repeatsToShow {
            // Register unique repeater pins
            for (hopIdx, hop) in resolved.hops.enumerated() {
                if seenRepeaters[hop.contact.publicKey] == nil {
                    seenRepeaters[hop.contact.publicKey] = hop.contact
                    allPathState[hop.contact.id] = PathInfo(hopIndex: hopIdx + 1, routeIndex: routeIndex)
                    routeIndex += 1
                }
            }

            // Draw outbound chain: consecutive hops
            for i in 0..<(resolved.hops.count - 1) {
                let overlay = PathLineOverlay.line(
                    from: resolved.hops[i].coordinate,
                    to: resolved.hops[i + 1].coordinate,
                    segmentIndex: segmentIndex
                )
                allLineOverlays.append(overlay)
                segmentIndex += 1
            }

            // Draw last-hop → user (SNR-colored)
            if let userLocation = storedUserLocation {
                let lastHop = resolved.hops.last!
                let overlay = PathLineOverlay.line(
                    from: lastHop.coordinate,
                    to: userLocation.coordinate,
                    segmentIndex: segmentIndex
                )
                allLineOverlays.append(overlay)
                allLastHopSNR[segmentIndex] = SNRQuality(snr: resolved.repeatDTO.snr)
                segmentIndex += 1
            }
        }

        // Build annotations
        repeaterAnnotations = seenRepeaters.values.map { RepeaterAnnotation(repeater: $0) }
        pathState = allPathState
        lineOverlays = allLineOverlays
        lastHopSNR = allLastHopSNR
        locatedRepeaterCount = seenRepeaters.count
        hasLocatedRepeaters = !seenRepeaters.isEmpty

        // User endpoint
        if let userLocation = storedUserLocation, hasLocatedRepeaters {
            endpointAnnotations = [
                RouteEndpointAnnotation(
                    type: .receiver,
                    coordinate: userLocation.coordinate,
                    name: storedUserName,
                    routeIndex: routeIndex
                )
            ]
        } else {
            endpointAnnotations = []
        }

        // Compute distance
        computeDistance(for: repeatsToShow)

        if hasLocatedRepeaters, selectedRepeatIndex == nil {
            centerOnData()
        }
    }

    /// Compute total route distance for a single selected repeat.
    /// Only meaningful when viewing one repeat at a time — each repeat is an
    /// independent route, so there's no single distance for the aggregate view.
    private func computeDistance(for repeatsToShow: [ResolvedRepeat]) {
        // Only show distance when viewing a single repeat
        guard repeatsToShow.count == 1, let resolved = repeatsToShow.first else {
            distanceText = nil
            return
        }

        var coordinates = resolved.hops.map(\.coordinate)
        if let userLocation = storedUserLocation {
            coordinates.append(userLocation.coordinate)
        }

        let totalMeters = RouteDistanceCalculator.chainDistance(between: coordinates)
        guard totalMeters > 0 else {
            distanceText = nil
            return
        }

        let hasGaps = resolved.unlocatedHopCount > 0
        distanceText = RouteDistanceCalculator.formatTotal(totalMeters, hasGaps: hasGaps)
    }

    private func clearDisplayData() {
        repeaterAnnotations = []
        pathState = [:]

        lineOverlays = []
        lastHopSNR = [:]
        endpointAnnotations = []
        locatedRepeaterCount = 0
        hasLocatedRepeaters = false
        distanceText = nil
    }
}
