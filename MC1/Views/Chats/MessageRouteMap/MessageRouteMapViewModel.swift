import CoreLocation
import MapKit
import SwiftUI
import MC1Services
import os.log

private let logger = Logger(subsystem: "com.pocketmesh", category: "MessageRouteMap")

/// Pre-computed path info for a repeater annotation on a route map.
/// Shared between MessageRouteMapViewModel and SharedRouteMapViewModel.
struct RouteMapPathInfo {
    let hopIndex: Int
    /// Position in the overall route sequence for label alternation
    let routeIndex: Int
}

/// View model for the message route map.
/// Resolves message path hops to geographic coordinates and builds map overlays.
@MainActor @Observable
final class MessageRouteMapViewModel {

    // MARK: - Map State

    var cameraRegion: MKCoordinateRegion?
    /// Incremented when code intentionally moves the camera
    var cameraRegionVersion = 0
    var mapStyleSelection: MapStyleSelection = .standard
    var labelMode: AnnotationLabelMode = .name
    var showingLayersMenu: Bool = false

    var mapType: MKMapType { mapStyleSelection.mkMapType }

    // MARK: - Route Data

    private(set) var isLoading = true
    private(set) var lineOverlays: [PathLineOverlay] = []
    private(set) var endpointAnnotations: [RouteEndpointAnnotation] = []
    private(set) var repeaterAnnotations: [RepeaterAnnotation] = []
    /// Pre-computed path info keyed by repeater UUID
    private(set) var pathState: [UUID: PathInfo] = [:]

    /// Whether at least two located points exist (enough to draw a route)
    private(set) var hasLocatedHops: Bool = false
    /// Total number of intermediate hops with location data
    private(set) var locatedHopCount: Int = 0
    /// Total number of intermediate hops in the path (located + unlocated)
    private(set) var totalHopCount: Int = 0

    /// Formatted total route distance. Includes "≥" prefix when hops are missing location data.
    private(set) var distanceText: String?

    typealias PathInfo = RouteMapPathInfo

    // MARK: - Private State

    private var contacts: [ContactDTO] = []
    private var repeaters: [ContactDTO] = []
    private var discoveredRepeaters: [DiscoveredNodeDTO] = []

    /// Merged pool of all repeater-type nodes (contacts + discovered) for unified resolution.
    private var allNodes: [AnyResolvable] = []

    // MARK: - Load & Build

    func loadRoute(
        message: MessageDTO,
        services: ServiceContainer,
        deviceID: UUID,
        userLocation: CLLocation?,
        receiverName: String,
        hopOverrides: [String: String] = [:]
    ) async {
        isLoading = true

        do {
            let fetched = try await services.dataStore.fetchContacts(deviceID: deviceID)
            contacts = fetched
            repeaters = fetched.filter { $0.type == .repeater }

            let nodes = try await services.dataStore.fetchDiscoveredNodes(deviceID: deviceID)
            discoveredRepeaters = nodes.filter { $0.nodeType == .repeater }
        } catch {
            logger.error("Failed to load contacts: \(error.localizedDescription)")
        }

        allNodes = RepeaterResolver.buildNodePool(repeaters: repeaters, discoveredNodes: discoveredRepeaters)

        buildRoute(message: message, userLocation: userLocation, receiverName: receiverName, snr: message.snr, hopOverrides: hopOverrides)
        isLoading = false
    }

    // MARK: - Route Building

    private func buildRoute(
        message: MessageDTO,
        userLocation: CLLocation?,
        receiverName: String,
        snr: Double?,
        hopOverrides: [String: String] = [:]
    ) {
        var points: [(coordinate: CLLocationCoordinate2D, name: String, hasGap: Bool)] = []
        /// Running index across the entire route sequence for label alternation
        var routeIndex = 0
        /// Anchor location from the previous located hop, used for context-aware resolution
        var anchorLocation: CLLocation?

        // Sender location
        if let senderKeyPrefix = message.senderKeyPrefix,
           let senderContact = contacts.first(where: { $0.publicKeyPrefix == senderKeyPrefix }),
           senderContact.hasLocation {
            let coord = CLLocationCoordinate2D(
                latitude: senderContact.latitude,
                longitude: senderContact.longitude
            )
            points.append((coord, senderContact.displayName, false))
            endpointAnnotations.append(
                RouteEndpointAnnotation(type: .sender, coordinate: coord, name: senderContact.displayName, routeIndex: routeIndex)
            )
            anchorLocation = CLLocation(latitude: senderContact.latitude, longitude: senderContact.longitude)
            routeIndex += 1
        }

        // NOTE: Do NOT fall back to userLocation when the sender has no location.
        // The forward anchor must represent the sender end of the chain. Setting it
        // to the receiver location causes the forward pass to resolve the first hop
        // based on proximity to the *receiver*, picking the wrong repeater when
        // multiple candidates share the same hash prefix. The bidirectional merge
        // step already handles the no-sender-anchor case by preferring the backward
        // (receiver-anchored) pass for hops closer to the receiver.

        // Intermediate hops — first resolve all hops, then build overlays.
        // Two-pass resolution: forward from sender, backward from receiver,
        // merge to get best result for each hop.
        let pathHops = parsePathHops(from: message)

        // Resolve hops with bidirectional anchoring
        let resolvedMatches = resolveHopsBidirectional(
            pathHops: pathHops,
            senderLocation: anchorLocation,
            receiverLocation: userLocation,
            hopOverrides: hopOverrides
        )

        var locatedCount = 0
        /// Number of consecutive unlocated hops since the last located point.
        /// Used to decide whether to draw a gap-style (dashed) line segment.
        var pendingUnlocatedCount = 0

        for (originalIndex, match) in resolvedMatches.enumerated() {
            guard let match, match.hasLocation else {
                pendingUnlocatedCount += 1
                continue
            }

            let coord = CLLocationCoordinate2D(
                latitude: match.latitude,
                longitude: match.longitude
            )
            guard CLLocationCoordinate2DIsValid(coord) else {
                pendingUnlocatedCount += 1
                continue
            }

            locatedCount += 1

            // If there were unlocated hops before this located hop, mark the
            // gap so the line segment between the previous located point and
            // this one uses a gap style.
            let hasGap = pendingUnlocatedCount > 0
            pendingUnlocatedCount = 0

            // Use 1-based original position so unlocated hops create visible
            // gaps in the numbering (e.g. 1, 2, 4 when hop 3 is unlocated).
            let hopNumber = originalIndex + 1

            points.append((coord, match.resolvableName, hasGap))
            let annotation = RepeaterAnnotation(resolvable: match)
            repeaterAnnotations.append(annotation)
            pathState[annotation.annotationID] = PathInfo(hopIndex: hopNumber, routeIndex: routeIndex)
            routeIndex += 1
        }

        // The protocol hop count from pathLength includes all hops the message
        // traversed, which may be more than the hash bytes stored in pathNodes.
        totalHopCount = Int(message.pathLength & 0x3F)
        locatedHopCount = locatedCount

        // Receiver location (user's current GPS)
        if let userLocation {
            let coord = userLocation.coordinate
            let receiverHasGap = pendingUnlocatedCount > 0
            points.append((coord, receiverName, receiverHasGap))
            endpointAnnotations.append(
                RouteEndpointAnnotation(type: .receiver, coordinate: coord, name: receiverName, routeIndex: routeIndex)
            )
        }

        hasLocatedHops = points.count >= 2

        // Build line overlays between consecutive points.
        // When the destination point has `hasGap`, the segment spans over
        // one or more unlocated hops — use the `.gap` style to indicate this.
        // The last segment (ending at the receiver) uses the message's SNR
        // for signal quality coloring, matching the heard-repeats map style.
        let segmentCount = points.count - 1
        for i in 0..<segmentCount {
            let isLastSegment = i == segmentCount - 1
            let nextPoint = points[i + 1]
            let quality: PathLineOverlay.SignalQuality
            let segmentSNR: Double

            if nextPoint.hasGap {
                quality = .gap
                segmentSNR = 0
            } else if isLastSegment, let snr {
                quality = PathLineOverlay.SignalQuality(snr: snr)
                segmentSNR = snr
            } else {
                quality = .untraced
                segmentSNR = 0
            }

            let overlay = PathLineOverlay.line(
                from: points[i].coordinate,
                to: nextPoint.coordinate,
                segmentIndex: i,
                signalQuality: quality,
                snr: segmentSNR
            )
            lineOverlays.append(overlay)
        }

        // Compute total route distance
        computeDistance(from: points)

        if hasLocatedHops {
            centerOnRoute()
        }

        logger.debug("Built route with \(points.count) points, \(self.lineOverlays.count) overlays")
    }

    // MARK: - Distance Computation

    private func computeDistance(
        from points: [(coordinate: CLLocationCoordinate2D, name: String, hasGap: Bool)]
    ) {
        guard points.count >= 2 else {
            distanceText = nil
            return
        }

        let totalMeters = RouteDistanceCalculator.chainDistance(
            between: points.map(\.coordinate)
        )

        guard totalMeters > 0 else {
            distanceText = nil
            return
        }

        let hasGaps = points.contains(where: \.hasGap)
        distanceText = RouteDistanceCalculator.formatTotal(totalMeters, hasGaps: hasGaps)
    }

    // MARK: - Bidirectional Hop Resolution

    /// Resolves hops using both forward (sender→receiver) and backward (receiver→sender) anchoring,
    /// then picks the best result for each hop based on which end was closer.
    /// Uses the merged pool of contacts + discovered nodes for unified resolution.
    private func resolveHopsBidirectional(
        pathHops: [Data],
        senderLocation: CLLocation?,
        receiverLocation: CLLocation?,
        hopOverrides: [String: String]
    ) -> [AnyResolvable?] {
        guard !pathHops.isEmpty else { return [] }

        // Check overrides first — these always win
        let overrideMatches: [AnyResolvable?] = pathHops.map { hop in
            let hexKey = hop.hexString()
            if let name = hopOverrides[hexKey] {
                return allNodes.first(where: { $0.resolvableName == name })
            }
            return nil
        }

        // Forward pass: anchor from sender
        var forwardMatches: [AnyResolvable?] = []
        var forwardAnchor = senderLocation
        var forwardHadAnchor: [Bool] = []

        for hop in pathHops {
            let hadAnchor = forwardAnchor != nil
            let match = RepeaterResolver.bestMatch(
                for: hop, in: allNodes, userLocation: receiverLocation, anchorLocation: forwardAnchor
            )
            forwardMatches.append(match)
            forwardHadAnchor.append(hadAnchor)
            if let match, match.hasLocation {
                forwardAnchor = CLLocation(latitude: match.latitude, longitude: match.longitude)
            }
        }

        // Backward pass: anchor from receiver
        var backwardMatches: [AnyResolvable?] = []
        var backwardAnchor = receiverLocation
        var backwardHadAnchor: [Bool] = []

        for hop in pathHops.reversed() {
            let hadAnchor = backwardAnchor != nil
            let match = RepeaterResolver.bestMatch(
                for: hop, in: allNodes, userLocation: receiverLocation, anchorLocation: backwardAnchor
            )
            backwardMatches.append(match)
            backwardHadAnchor.append(hadAnchor)
            if let match, match.hasLocation {
                backwardAnchor = CLLocation(latitude: match.latitude, longitude: match.longitude)
            }
        }
        backwardMatches.reverse()
        backwardHadAnchor.reverse()

        // Merge: override > closer-end anchor > forward
        var result: [AnyResolvable?] = []
        for i in pathHops.indices {
            if let overrideMatch = overrideMatches[i] {
                result.append(overrideMatch)
            } else if forwardHadAnchor[i] && backwardHadAnchor[i] {
                let distFromSender = i
                let distFromReceiver = pathHops.count - 1 - i
                result.append(distFromReceiver < distFromSender ? backwardMatches[i] : forwardMatches[i])
            } else if backwardHadAnchor[i] && !forwardHadAnchor[i] {
                result.append(backwardMatches[i])
            } else {
                result.append(forwardMatches[i])
            }
        }
        return result
    }

    // MARK: - Path Parsing

    private func parsePathHops(from message: MessageDTO) -> [Data] {
        guard let pathNodes = message.pathNodes else { return [] }
        let size = message.pathHashSize
        return stride(from: 0, to: pathNodes.count, by: size).map { start in
            let end = min(start + size, pathNodes.count)
            return Data(pathNodes[start..<end])
        }
    }

    // MARK: - Camera

    func centerOnRoute() {
        var coordinates: [CLLocationCoordinate2D] = []

        for annotation in endpointAnnotations {
            coordinates.append(annotation.coordinate)
        }

        for annotation in repeaterAnnotations {
            coordinates.append(annotation.coordinate)
        }

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
}
