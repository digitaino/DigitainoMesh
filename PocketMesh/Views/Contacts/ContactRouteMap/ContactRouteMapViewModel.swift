import CoreLocation
import MapKit
import PocketMeshServices
import os.log

private let logger = Logger(subsystem: "com.pocketmesh", category: "ContactRouteMap")

/// View model for the per-contact route history map.
/// Aggregates inbound and outbound DM paths for a specific contact
/// using `RouteAggregator` with directional mode.
@MainActor @Observable
final class ContactRouteMapViewModel {

    // MARK: - Map State

    var cameraRegion: MKCoordinateRegion?
    var cameraRegionVersion = 0
    var mapStyleSelection: MapStyleSelection = .standard
    var showLabels: Bool = true
    var showingLayersMenu: Bool = false

    var mapType: MKMapType { mapStyleSelection.mkMapType }

    // MARK: - Time Period (reuses TrafficHeatmapViewModel.TimePeriod)

    var selectedPeriod: TrafficHeatmapViewModel.TimePeriod = .allTime

    // MARK: - Data State

    private(set) var isLoading = false
    private(set) var hasData = false
    private(set) var hasLocatedRepeaters = false

    // MARK: - Map Display Data

    private(set) var bubbleAnnotations: [TrafficBubbleAnnotation] = []
    private(set) var segmentOverlays: [TrafficSegmentOverlay] = []
    private(set) var endpointAnnotations: [RouteEndpointAnnotation] = []

    // MARK: - Stats

    private(set) var inboundCount: Int = 0
    private(set) var outboundCount: Int = 0
    private(set) var locatedRepeaterCount: Int = 0

    // MARK: - Find Path

    private(set) var isFindingPath = false

    // MARK: - Load

    func load(
        contact: ContactDTO,
        dataStore: PersistenceStore,
        deviceID: UUID,
        userLocation: CLLocation?,
        userName: String
    ) async {
        isLoading = true

        do {
            let contacts = try await dataStore.fetchContacts(deviceID: deviceID)
            let discoveredNodes = try await dataStore.fetchDiscoveredNodes(deviceID: deviceID)
            let repeaters = contacts.filter { $0.type == .repeater }

            // Fetch all DM messages for this contact (use a large limit)
            let messages = try await dataStore.fetchMessages(
                contactID: contact.id,
                limit: 10_000,
                offset: 0
            )

            // Filter by time period
            let filteredMessages: [MessageDTO]
            if let since = selectedPeriod.sinceDate {
                filteredMessages = messages.filter { $0.createdAt >= since }
            } else {
                filteredMessages = messages
            }

            // Build endpoint hops for user and contact so segments connect to them
            let userHop: RouteAggregator.LocatedHop? = userLocation.map { loc in
                // Stable synthetic key so the aggregator deduplicates the user node
                let syntheticKey = Data("__user_endpoint__".utf8)
                return RouteAggregator.LocatedHop(
                    publicKey: syntheticKey,
                    coordinate: loc.coordinate,
                    name: userName
                )
            }

            let contactHop: RouteAggregator.LocatedHop? = contact.hasLocation ? {
                let syntheticKey = Data("__contact_endpoint__".utf8)
                let coord = CLLocationCoordinate2D(
                    latitude: contact.latitude,
                    longitude: contact.longitude
                )
                return RouteAggregator.LocatedHop(
                    publicKey: syntheticKey,
                    coordinate: coord,
                    name: contact.displayName
                )
            }() : nil

            // Build routes
            var routes: [(hops: [RouteAggregator.LocatedHop], snr: Double?, direction: RouteAggregator.RouteDirection)] = []

            var inCount = 0
            var outCount = 0

            for message in filteredMessages {
                guard let pathNodes = message.pathNodes, !pathNodes.isEmpty else { continue }

                let intermediateHops = RouteAggregator.resolvePath(
                    pathNodes: pathNodes,
                    hashSize: message.pathHashSize,
                    contacts: repeaters,
                    discoveredNodes: discoveredNodes,
                    userLocation: userLocation
                )

                guard !intermediateHops.isEmpty else { continue }

                let direction: RouteAggregator.RouteDirection = message.isOutgoing ? .outbound : .inbound

                // Build full path including endpoints:
                // Outbound (user → contact): user → repeaters → contact
                // Inbound (contact → user): contact → repeaters → user
                var fullHops: [RouteAggregator.LocatedHop] = []
                if message.isOutgoing {
                    if let userHop { fullHops.append(userHop) }
                    fullHops.append(contentsOf: intermediateHops)
                    if let contactHop { fullHops.append(contactHop) }
                } else {
                    if let contactHop { fullHops.append(contactHop) }
                    fullHops.append(contentsOf: intermediateHops)
                    if let userHop { fullHops.append(userHop) }
                }

                routes.append((hops: fullHops, snr: message.snr, direction: direction))

                if message.isOutgoing {
                    outCount += 1
                } else {
                    inCount += 1
                }
            }

            inboundCount = inCount
            outboundCount = outCount

            // Fallback: if no messages had per-message path data, use the
            // contact's current outPath (the route shown on the contact detail).
            if routes.isEmpty, !contact.isFloodRouted, contact.pathHopCount > 0 {
                let currentPathHops = RouteAggregator.resolvePath(
                    pathNodes: contact.outPath.prefix(contact.pathByteLength),
                    hashSize: contact.pathHashSize,
                    contacts: repeaters,
                    discoveredNodes: discoveredNodes,
                    userLocation: userLocation
                )
                if !currentPathHops.isEmpty {
                    var fullHops: [RouteAggregator.LocatedHop] = []
                    if let userHop { fullHops.append(userHop) }
                    fullHops.append(contentsOf: currentPathHops)
                    if let contactHop { fullHops.append(contactHop) }
                    routes.append((hops: fullHops, snr: nil, direction: .unspecified))
                }
            }

            hasData = !filteredMessages.isEmpty || !routes.isEmpty

            // Synthetic keys used for endpoints — exclude from bubble annotations
            let syntheticKeys: Set<Data> = [
                Data("__user_endpoint__".utf8),
                Data("__contact_endpoint__".utf8),
            ]

            if routes.isEmpty {
                clearDisplayData()
            } else {
                let result = RouteAggregator.aggregate(routes: routes, directional: true)
                // Filter out endpoint bubbles — they're shown as endpoint pins instead
                bubbleAnnotations = result.bubbleAnnotations.filter { !syntheticKeys.contains($0.publicKey) }
                segmentOverlays = result.segmentOverlays
                let repeaterBubbleCount = bubbleAnnotations.count
                locatedRepeaterCount = repeaterBubbleCount
                hasLocatedRepeaters = !bubbleAnnotations.isEmpty

                // Build endpoint annotations
                buildEndpoints(contact: contact, userLocation: userLocation, userName: userName)
            }

            if hasLocatedRepeaters {
                centerOnData()
            }

            logger.debug("Contact route map: \(inCount) inbound, \(outCount) outbound, \(self.locatedRepeaterCount) repeaters")
        } catch {
            logger.error("Failed to load contact route data: \(error.localizedDescription)")
            clearDisplayData()
        }

        isLoading = false
    }

    // MARK: - Endpoints

    private func buildEndpoints(
        contact: ContactDTO,
        userLocation: CLLocation?,
        userName: String
    ) {
        endpointAnnotations = []

        // Contact endpoint (sender for inbound, target for outbound)
        if contact.hasLocation {
            let coord = CLLocationCoordinate2D(
                latitude: contact.latitude,
                longitude: contact.longitude
            )
            endpointAnnotations.append(
                RouteEndpointAnnotation(type: .sender, coordinate: coord, name: contact.displayName, routeIndex: 0)
            )
        }

        // User endpoint
        if let userLocation {
            endpointAnnotations.append(
                RouteEndpointAnnotation(type: .receiver, coordinate: userLocation.coordinate, name: userName, routeIndex: 1)
            )
        }
    }

    // MARK: - Camera

    func centerOnData() {
        var coordinates: [CLLocationCoordinate2D] = []
        coordinates += bubbleAnnotations.map(\.coordinate)
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

    // MARK: - Find Path

    func findPath(
        for contact: ContactDTO,
        contactService: ContactService,
        dataStore: PersistenceStore,
        deviceID: UUID,
        userLocation: CLLocation?,
        userName: String
    ) async {
        isFindingPath = true
        do {
            let response = try await contactService.sendPathDiscovery(
                deviceID: contact.deviceID,
                publicKey: contact.publicKey
            )
            let timeoutSeconds = PathManagementViewModel.sanitizedDiscoveryTimeoutSeconds(
                suggestedTimeoutMs: response.suggestedTimeoutMs
            )
            try await Task.sleep(for: .seconds(timeoutSeconds))
        } catch is CancellationError {
            // User navigated away
        } catch {
            logger.error("Find path failed: \(error.localizedDescription)")
        }
        isFindingPath = false

        // Reload to pick up any new path data
        await load(
            contact: contact,
            dataStore: dataStore,
            deviceID: deviceID,
            userLocation: userLocation,
            userName: userName
        )
    }

    // MARK: - Private

    private func clearDisplayData() {
        bubbleAnnotations = []
        segmentOverlays = []
        endpointAnnotations = []
        locatedRepeaterCount = 0
        hasLocatedRepeaters = false
    }
}
