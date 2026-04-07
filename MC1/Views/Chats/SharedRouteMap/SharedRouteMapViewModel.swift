import CoreLocation
import MapKit
import SwiftUI
import MC1Services
import os.log

private let logger = Logger(subsystem: "com.pocketmesh", category: "SharedRouteMap")

/// View model for the shared route map.
/// Resolves hex IDs parsed from message text to geographic coordinates and builds map overlays.
@MainActor @Observable
final class SharedRouteMapViewModel {

    // MARK: - Map State

    var cameraRegion: MKCoordinateRegion?
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
    private(set) var pathState: [UUID: RouteMapPathInfo] = [:]

    private(set) var hasLocatedHops: Bool = false
    private(set) var locatedHopCount: Int = 0
    private(set) var totalHopCount: Int = 0

    // MARK: - Load & Build

    func loadRoute(
        sharedRoute: SharedRoute,
        services: ServiceContainer,
        deviceID: UUID,
        userLocation: CLLocation?
    ) async {
        isLoading = true

        var contacts: [ContactDTO] = []
        var discoveredNodes: [DiscoveredNodeDTO] = []
        do {
            contacts = try await services.dataStore.fetchContacts(deviceID: deviceID)
            discoveredNodes = try await services.dataStore.fetchDiscoveredNodes(deviceID: deviceID)
        } catch {
            logger.error("Failed to load nodes: \(error.localizedDescription)")
        }

        let repeaters = contacts.filter { $0.type == .repeater }

        buildRoute(
            sharedRoute: sharedRoute,
            repeaters: repeaters,
            allContacts: contacts,
            discoveredNodes: discoveredNodes,
            userLocation: userLocation
        )

        isLoading = false
    }

    // MARK: - Route Building

    private func buildRoute(
        sharedRoute: SharedRoute,
        repeaters: [ContactDTO],
        allContacts: [ContactDTO],
        discoveredNodes: [DiscoveredNodeDTO],
        userLocation: CLLocation?
    ) {
        let hops = sharedRoute.hashBytesPerHop
        totalHopCount = hops.count

        // Use centralized pool builder for consistent stale filtering
        let allNodes = RepeaterResolver.buildNodePool(
            repeaters: repeaters, discoveredNodes: discoveredNodes
        )

        var locatedPoints: [(coordinate: CLLocationCoordinate2D, name: String, hasGap: Bool)] = []
        var routeIndex = 0
        var hopIndex = 0
        var pendingUnlocatedCount = 0

        for (originalIndex, hop) in hops.enumerated() {
            guard let match = RepeaterResolver.bestMatch(
                for: hop, in: allNodes, userLocation: userLocation
            ), match.hasLocation else {
                pendingUnlocatedCount += 1
                continue
            }

            let coord = CLLocationCoordinate2D(
                latitude: match.latitude, longitude: match.longitude
            )
            guard CLLocationCoordinate2DIsValid(coord) else {
                pendingUnlocatedCount += 1
                continue
            }

            hopIndex += 1

            let hasGap = pendingUnlocatedCount > 0
            pendingUnlocatedCount = 0

            // Use 1-based original position so unlocated hops create visible
            // gaps in the numbering (e.g. 1, 2, 4 when hop 3 is unlocated).
            let hopNumber = originalIndex + 1

            locatedPoints.append((coord, match.resolvableName, hasGap))

            let annotation = RepeaterAnnotation(resolvable: match)
            repeaterAnnotations.append(annotation)
            pathState[annotation.annotationID] = RouteMapPathInfo(hopIndex: hopNumber, routeIndex: routeIndex)
            routeIndex += 1
        }

        locatedHopCount = hopIndex
        hasLocatedHops = locatedPoints.count >= 1

        // Build line overlays between consecutive located points
        for i in 0..<(locatedPoints.count - 1) {
            let nextPoint = locatedPoints[i + 1]
            let quality: PathLineOverlay.SignalQuality = nextPoint.hasGap ? .gap : .untraced

            let overlay = PathLineOverlay.line(
                from: locatedPoints[i].coordinate,
                to: nextPoint.coordinate,
                segmentIndex: i,
                signalQuality: quality,
                snr: 0
            )
            lineOverlays.append(overlay)
        }

        if hasLocatedHops {
            centerOnRoute()
        }

        logger.debug("Built shared route: \(locatedPoints.count) located of \(self.totalHopCount) total hops")
    }

    // MARK: - Camera

    func centerOnRoute() {
        var coordinates: [CLLocationCoordinate2D] = []
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
