import CoreLocation
import MapKit
import SwiftUI
import PocketMeshServices
import os.log

private let logger = Logger(subsystem: "com.pocketmesh", category: "MessageRouteMap")

/// View model for the message route map.
/// Resolves message path hops to geographic coordinates and builds map overlays.
@MainActor @Observable
final class MessageRouteMapViewModel {

    // MARK: - Map State

    var cameraRegion: MKCoordinateRegion?
    /// Incremented when code intentionally moves the camera
    var cameraRegionVersion = 0
    var mapStyleSelection: MapStyleSelection = .standard
    var showLabels: Bool = true
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

    struct PathInfo {
        let hopIndex: Int
    }

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

        buildRoute(message: message, userLocation: userLocation, receiverName: receiverName)
        isLoading = false
    }

    // MARK: - Route Building

    private func buildRoute(
        message: MessageDTO,
        userLocation: CLLocation?,
        receiverName: String
    ) {
        var points: [(coordinate: CLLocationCoordinate2D, name: String)] = []

        // Sender location
        if let senderKeyPrefix = message.senderKeyPrefix,
           let senderContact = contacts.first(where: { $0.publicKeyPrefix == senderKeyPrefix }),
           senderContact.hasLocation {
            let coord = CLLocationCoordinate2D(
                latitude: senderContact.latitude,
                longitude: senderContact.longitude
            )
            points.append((coord, senderContact.displayName))
            endpointAnnotations.append(
                RouteEndpointAnnotation(type: .sender, coordinate: coord, name: senderContact.displayName)
            )
        }

        // Intermediate hops
        let pathHops = parsePathHops(from: message)
        var hopIndex = 0

        for hop in pathHops {
            guard let match = RepeaterResolver.bestMatch(
                for: hop, in: repeaters, userLocation: userLocation
            ), match.hasLocation else {
                continue
            }

            hopIndex += 1
            let coord = CLLocationCoordinate2D(
                latitude: match.latitude,
                longitude: match.longitude
            )
            guard CLLocationCoordinate2DIsValid(coord) else { continue }

            points.append((coord, match.displayName))
            repeaterAnnotations.append(RepeaterAnnotation(repeater: match))
            pathState[match.id] = PathInfo(hopIndex: hopIndex)
        }

        locatedHopCount = hopIndex

        // Receiver location (user's current GPS)
        if let userLocation {
            let coord = userLocation.coordinate
            points.append((coord, receiverName))
            endpointAnnotations.append(
                RouteEndpointAnnotation(type: .receiver, coordinate: coord, name: receiverName)
            )
        }

        hasLocatedHops = points.count >= 2

        // Build line overlays between consecutive points
        for i in 0..<(points.count - 1) {
            let overlay = PathLineOverlay.line(
                from: points[i].coordinate,
                to: points[i + 1].coordinate,
                segmentIndex: i
            )
            lineOverlays.append(overlay)
        }

        if hasLocatedHops {
            centerOnRoute()
        }

        logger.debug("Built route with \(points.count) points, \(self.lineOverlays.count) overlays")
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
