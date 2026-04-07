import CoreLocation
import MC1Services
import os.log

private let logger = Logger(subsystem: "com.pocketmesh", category: "PathMapGenerator")

/// View model for the Path Map Generator tool.
/// Parses hex ID input, resolves hops locally, and manages map display and sharing.
@MainActor @Observable
final class PathMapGeneratorViewModel {

    // MARK: - Input State

    var inputText: String = ""
    var errorMessage: String?

    // MARK: - Map State

    var hexPath: HexPath?
    var isLoading = false
    private(set) var mapViewModel: SharedRouteMapViewModel?

    // MARK: - Share State

    var isSharing = false
    var shareURL: URL?
    var showShareConfirmation = false

    // MARK: - Computed

    var isInputValid: Bool {
        HexPathParser.parse(inputText) != nil
    }

    var canShare: Bool {
        hexPath != nil && !isSharing
    }

    // MARK: - Generate Map

    func generateMap(services: ServiceContainer, deviceID: UUID, userLocation: CLLocation?) async {
        guard let path = HexPathParser.parse(inputText) else {
            errorMessage = "Enter valid hex IDs (2-6 hex chars each, or full 64-char keys)"
            return
        }

        errorMessage = nil
        hexPath = path
        shareURL = nil
        isLoading = true

        let mapVM = SharedRouteMapViewModel()
        mapViewModel = mapVM

        await mapVM.loadRoute(
            sharedRoute: path.asSharedRoute,
            services: services,
            deviceID: deviceID,
            userLocation: userLocation
        )

        isLoading = false
        logger.info("Generated path map: \(path.hopCount) hops, \(mapVM.locatedHopCount) located")
    }

    // MARK: - Share

    func sharePath(userLatitude: Double?, userLongitude: Double?, userName: String?) async {
        guard let hexPath, let mapVM = mapViewModel else { return }
        isSharing = true
        defer { isSharing = false }

        // Build RouteHops from the hex path, enriched with resolved location data
        let hops = buildShareHops(hexPath: hexPath, mapVM: mapVM)

        let service = RouteShareService()
        let url = await service.sharePath(
            hops: hops,
            userLatitude: userLatitude,
            userLongitude: userLongitude,
            userName: userName
        )

        if let url {
            shareURL = url
            showShareConfirmation = true
            logger.info("Shared path: \(url.absoluteString, privacy: .public)")
        } else {
            errorMessage = "Failed to share path. Please try again."
        }
    }

    // MARK: - Helpers

    /// Build RouteHop array from hex path, enriching with resolved names and locations
    /// from the map view model's repeater annotations.
    private func buildShareHops(hexPath: HexPath, mapVM: SharedRouteMapViewModel) -> [RouteShareService.RouteHop] {
        // Build a lookup from annotation IDs to annotations
        let annotationsByID = Dictionary(uniqueKeysWithValues: mapVM.repeaterAnnotations.map { ($0.annotationID, $0) })

        return hexPath.hexIDs.enumerated().map { index, hexID in
            // Try to find the resolved annotation for this hop
            let matchedAnnotation = annotationsByID.values.first { annotation in
                guard let pathInfo = mapVM.pathState[annotation.annotationID] else { return false }
                return pathInfo.hopIndex == index + 1
            }

            if let annotation = matchedAnnotation {
                return RouteShareService.RouteHop(
                    hexID: hexID,
                    name: annotation.title,
                    latitude: annotation.coordinate.latitude,
                    longitude: annotation.coordinate.longitude
                )
            } else {
                return RouteShareService.RouteHop(
                    hexID: hexID,
                    name: nil,
                    latitude: nil,
                    longitude: nil
                )
            }
        }
    }
}
