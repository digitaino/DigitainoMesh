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

    // MARK: - Load & Build

    func loadRoute(
        message: MessageDTO,
        services: ServiceContainer,
        deviceID: UUID,
        userLocation: CLLocation?,
        receiverName: String
    ) async {
        isLoading = true

        do {
            let fetched = try await services.dataStore.fetchContacts(deviceID: deviceID)
            contacts = fetched
            repeaters = fetched.filter { $0.type == .repeater }
        } catch {
            logger.error("Failed to load contacts: \(error.localizedDescription)")
        }

        buildRoute(message: message, userLocation: userLocation, receiverName: receiverName, snr: message.snr)
        isLoading = false
    }

    // MARK: - Route Building

    private func buildRoute(
        message: MessageDTO,
        userLocation: CLLocation?,
        receiverName: String,
        snr: Double?
    ) {
        var points: [(coordinate: CLLocationCoordinate2D, name: String, hasGap: Bool)] = []
        /// Running index across the entire route sequence for label alternation
        var routeIndex = 0

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
            routeIndex += 1
        }

        // Intermediate hops
        let pathHops = parsePathHops(from: message)
        var hopIndex = 0
        /// Number of consecutive unlocated hops since the last located point.
        /// Used to decide whether to draw a gap-style (dashed) line segment.
        var pendingUnlocatedCount = 0

        for hop in pathHops {
            let match = RepeaterResolver.bestMatch(
                for: hop, in: repeaters, userLocation: userLocation
            )

            guard let match, match.hasLocation else {
                pendingUnlocatedCount += 1
                continue
            }

            hopIndex += 1
            let coord = CLLocationCoordinate2D(
                latitude: match.latitude,
                longitude: match.longitude
            )
            guard CLLocationCoordinate2DIsValid(coord) else {
                pendingUnlocatedCount += 1
                continue
            }

            // If there were unlocated hops before this located hop, mark the
            // gap so the line segment between the previous located point and
            // this one uses a gap style.
            let hasGap = pendingUnlocatedCount > 0
            pendingUnlocatedCount = 0

            points.append((coord, match.displayName, hasGap))
            repeaterAnnotations.append(RepeaterAnnotation(repeater: match))
            pathState[match.id] = PathInfo(hopIndex: hopIndex, routeIndex: routeIndex)
            routeIndex += 1
        }

        totalHopCount = pathHops.count
        locatedHopCount = hopIndex

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
