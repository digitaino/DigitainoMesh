import MapKit
import MC1Services
import os
import SwiftUI

private let logger = Logger(subsystem: "com.pocketmesh", category: "SurveyMapRepresentable")

/// UIViewRepresentable wrapper for MKMapView used by the signal survey tool.
/// Renders community hex overlays and user survey hex cells via `MKOverlayRenderer`
/// for efficient tiled rendering (instead of SwiftUI ForEach + MapPolygon).
struct SurveyMapRepresentable: UIViewRepresentable {

    // MARK: - User Survey Data

    let gridCells: [SignalSurveyViewModel.GridCell]
    let displayPoints: [SignalSurveyPointDTO]
    let visualizationMode: SignalSurveyViewModel.VisualizationMode
    let selectedCell: SignalSurveyViewModel.GridCell?

    // MARK: - Community Overlay

    let communityCells: [SurveyUploadService.CommunityCell]
    let showCommunityOverlay: Bool
    let selectedCommunityCell: SurveyUploadService.CommunityCell?
    let communityRepeaterLocations: [SurveyUploadService.RepeaterLocation]

    // MARK: - Repeater Annotations

    let repeaterAnnotations: [(hexID: String, contact: ContactDTO)]
    let selectedMapRepeater: ContactDTO?

    // MARK: - Cell-to-Repeater Line

    let selectedRepeaterContact: ContactDTO?

    // MARK: - Map Configuration

    let mapStyleSelection: MapStyleSelection
    let showsUserLocation: Bool
    let trackingUserLocation: Bool

    // MARK: - Callbacks

    var onCellSelected: (SignalSurveyViewModel.GridCell?) -> Void
    var onCommunityCellSelected: (SurveyUploadService.CommunityCell?) -> Void
    var onRepeaterTapped: (ContactDTO) -> Void
    var onRegionChanged: (MKCoordinateRegion) -> Void
    var onTrackingStopped: (() -> Void)?

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> MKMapView {
        let mapView = context.coordinator.mapView

        mapView.delegate = context.coordinator
        mapView.showsUserLocation = showsUserLocation
        mapView.pointOfInterestFilter = .excludingAll

        // Register annotation views for repeater pins
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: "SurveyRepeaterPin"
        )
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: "CommunityRepeaterPin"
        )

        // Add tap gesture for overlay hit testing
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapTap(_:)))
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)

        // Report initial region so community overlay loads immediately
        DispatchQueue.main.async {
            context.coordinator.onRegionChanged?(mapView.region)
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // Update callback closures
        coordinator.onCellSelected = onCellSelected
        coordinator.onCommunityCellSelected = onCommunityCellSelected
        coordinator.onRepeaterTapped = onRepeaterTapped
        coordinator.onRegionChanged = onRegionChanged
        coordinator.onTrackingStopped = onTrackingStopped

        // Store current data for tap hit testing
        coordinator.currentGridCells = gridCells
        coordinator.currentCommunityCells = communityCells
        coordinator.currentSelectedCell = selectedCell
        coordinator.currentSelectedCommunityCell = selectedCommunityCell
        coordinator.currentVisualizationMode = visualizationMode

        coordinator.isUpdatingFromSwiftUI = true
        defer { coordinator.isUpdatingFromSwiftUI = false }

        mapView.mapType = mapStyleSelection.mkMapType
        mapView.showsUserLocation = showsUserLocation

        // Handle user location tracking
        let desiredMode: MKUserTrackingMode = trackingUserLocation ? .follow : .none
        if mapView.userTrackingMode != desiredMode {
            mapView.setUserTrackingMode(desiredMode, animated: true)
        }

        // Update overlays
        updateCommunityOverlays(in: mapView, coordinator: coordinator)
        updateSurveyOverlays(in: mapView, coordinator: coordinator)
        updatePointAnnotations(in: mapView, coordinator: coordinator)
        updateRepeaterPins(in: mapView, coordinator: coordinator)
        updateCommunityRepeaterPins(in: mapView, coordinator: coordinator)
        updateSelectionOverlays(in: mapView, coordinator: coordinator)
        updatePolyline(in: mapView, coordinator: coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Community Overlay Management

    private func updateCommunityOverlays(in mapView: MKMapView, coordinator: Coordinator) {
        let existingOverlays = mapView.overlays.compactMap { $0 as? CommunityHexOverlay }

        if !showCommunityOverlay || visualizationMode != .gridHeatmap {
            if !existingOverlays.isEmpty {
                mapView.removeOverlays(existingOverlays)
                coordinator.lastCommunityCellIDs = []
            }
            return
        }

        let newIDs = Set(communityCells.map(\.id))
        guard newIDs != coordinator.lastCommunityCellIDs else { return }

        if !existingOverlays.isEmpty {
            mapView.removeOverlays(existingOverlays)
        }

        let overlays = communityCells.map { CommunityHexOverlay.make(from: $0) }
        if !overlays.isEmpty {
            mapView.addOverlays(overlays, level: .aboveRoads)
        }
        coordinator.lastCommunityCellIDs = newIDs
    }

    // MARK: - Survey Grid Overlay Management

    private func updateSurveyOverlays(in mapView: MKMapView, coordinator: Coordinator) {
        let existingOverlays = mapView.overlays.compactMap { $0 as? SurveyHexOverlay }

        if visualizationMode != .gridHeatmap {
            if !existingOverlays.isEmpty {
                mapView.removeOverlays(existingOverlays)
                coordinator.lastSurveyCellIDs = []
            }
            return
        }

        // Build fingerprint set: coordKey + packetCount + quality for change detection
        let newFingerprints = Set(gridCells.map { "\($0.coordKey)_\($0.packetCount)_\($0.snrQuality)_\($0.isDeadZone)" })
        guard newFingerprints != coordinator.lastSurveyCellFingerprints else { return }

        if !existingOverlays.isEmpty {
            mapView.removeOverlays(existingOverlays)
        }

        let overlays = gridCells.map { SurveyHexOverlay.make(from: $0) }
        if !overlays.isEmpty {
            mapView.addOverlays(overlays, level: .aboveLabels)
        }
        coordinator.lastSurveyCellIDs = Set(gridCells.map(\.coordKey))
        coordinator.lastSurveyCellFingerprints = newFingerprints
    }

    // MARK: - Point Cloud Annotations

    private func updatePointAnnotations(in mapView: MKMapView, coordinator: Coordinator) {
        let existingPoints = mapView.annotations.compactMap { $0 as? SurveyPointAnnotation }

        if visualizationMode != .pointCloud {
            if !existingPoints.isEmpty {
                mapView.removeAnnotations(existingPoints)
                coordinator.lastPointIDs = []
            }
            return
        }

        let newIDs = Set(displayPoints.map(\.id))
        guard newIDs != coordinator.lastPointIDs else { return }

        if !existingPoints.isEmpty {
            mapView.removeAnnotations(existingPoints)
        }

        let annotations = displayPoints.map { SurveyPointAnnotation(point: $0) }
        mapView.addAnnotations(annotations)
        coordinator.lastPointIDs = newIDs
    }

    // MARK: - Repeater Pin Annotations

    private func updateRepeaterPins(in mapView: MKMapView, coordinator: Coordinator) {
        let existing = mapView.annotations.compactMap { $0 as? SurveyRepeaterPin }
        let existingIDs = Set(existing.map(\.hexID))
        let newIDs = Set(repeaterAnnotations.map(\.hexID))

        let toRemove = existing.filter { !newIDs.contains($0.hexID) }
        if !toRemove.isEmpty {
            mapView.removeAnnotations(toRemove)
        }

        let remainingIDs = existingIDs.subtracting(Set(toRemove.map(\.hexID)))
        let toAdd = repeaterAnnotations
            .filter { !remainingIDs.contains($0.hexID) }
            .map { SurveyRepeaterPin(hexID: $0.hexID, contact: $0.contact) }
        if !toAdd.isEmpty {
            mapView.addAnnotations(toAdd)
        }
    }

    // MARK: - Community Repeater Pin Annotations

    private func updateCommunityRepeaterPins(in mapView: MKMapView, coordinator: Coordinator) {
        let existing = mapView.annotations.compactMap { $0 as? CommunityRepeaterPin }

        if !showCommunityOverlay {
            if !existing.isEmpty {
                mapView.removeAnnotations(existing)
                coordinator.lastCommunityRepeaterPinIDs = []
            }
            return
        }

        let newIDs = Set(communityRepeaterLocations.map(\.hexID))
        guard newIDs != coordinator.lastCommunityRepeaterPinIDs else { return }

        let toRemove = existing.filter { !newIDs.contains($0.hexID) }
        if !toRemove.isEmpty {
            mapView.removeAnnotations(toRemove)
        }

        let remainingIDs = Set(existing.map(\.hexID)).subtracting(Set(toRemove.map(\.hexID)))
        let toAdd = communityRepeaterLocations
            .filter { !remainingIDs.contains($0.hexID) }
            .map { CommunityRepeaterPin(repeater: $0) }
        if !toAdd.isEmpty {
            mapView.addAnnotations(toAdd)
        }
        coordinator.lastCommunityRepeaterPinIDs = newIDs
    }

    // MARK: - Selection Highlight Overlays

    private func updateSelectionOverlays(in mapView: MKMapView, coordinator: Coordinator) {
        // Remove old selection overlays
        let existingSelections = mapView.overlays.compactMap { $0 as? SurveySelectionOverlay }
        if !existingSelections.isEmpty {
            mapView.removeOverlays(existingSelections)
        }

        // Add selected survey cell highlight
        if let selected = selectedCell, visualizationMode == .gridHeatmap {
            var coords = selected.vertices.map { $0 }
            let overlay = SurveySelectionOverlay(coordinates: &coords, count: coords.count)
            overlay.isCommunity = false
            overlay.snrQuality = selected.snrQuality
            overlay.isDeadZone = selected.isDeadZone
            mapView.addOverlay(overlay, level: .aboveLabels)
        }

        // Add selected community cell highlight
        if let selected = selectedCommunityCell, showCommunityOverlay {
            let vertices = HexGrid.vertices(
                centerLatitude: selected.latitude,
                centerLongitude: selected.longitude,
                referenceLatitude: selected.referenceLatitude
            )
            var coords = vertices.map { $0 }
            let overlay = SurveySelectionOverlay(coordinates: &coords, count: coords.count)
            overlay.isCommunity = true
            overlay.snrQuality = SNRQuality(snr: selected.averageSNR)
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
    }

    // MARK: - Cell-to-Repeater Polyline

    private func updatePolyline(in mapView: MKMapView, coordinator: Coordinator) {
        // Remove existing polylines
        let existing = mapView.overlays.compactMap { $0 as? SurveyCellPolyline }
        if !existing.isEmpty {
            mapView.removeOverlays(existing)
        }

        // Draw line from selected survey cell to selected repeater contact
        if let cell = selectedCell, let repeater = selectedRepeaterContact {
            var coords = [
                CLLocationCoordinate2D(latitude: cell.centerLatitude, longitude: cell.centerLongitude),
                CLLocationCoordinate2D(latitude: repeater.latitude, longitude: repeater.longitude)
            ]
            let polyline = SurveyCellPolyline(coordinates: &coords, count: 2)
            mapView.addOverlay(polyline, level: .aboveLabels)
        }

        // Draw lines from selected community cell to its repeaters
        if let cell = selectedCommunityCell, showCommunityOverlay {
            let cellCenter = CLLocationCoordinate2D(latitude: cell.latitude, longitude: cell.longitude)
            let locationsByHex = Dictionary(communityRepeaterLocations.map { ($0.hexID.uppercased(), $0) }, uniquingKeysWith: { _, new in new })

            for hexID in cell.repeaterHexIDs {
                let upper = hexID.uppercased()
                let loc = locationsByHex[upper] ?? locationsByHex.first(where: { key, _ in
                    key.hasPrefix(upper) || upper.hasPrefix(key)
                })?.value
                guard let loc else { continue }

                var coords = [
                    cellCenter,
                    CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
                ]
                let polyline = SurveyCellPolyline(coordinates: &coords, count: 2)
                mapView.addOverlay(polyline, level: .aboveLabels)
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onCellSelected: ((SignalSurveyViewModel.GridCell?) -> Void)?
        var onCommunityCellSelected: ((SurveyUploadService.CommunityCell?) -> Void)?
        var onRepeaterTapped: ((ContactDTO) -> Void)?
        var onRegionChanged: ((MKCoordinateRegion) -> Void)?
        var onTrackingStopped: (() -> Void)?

        var isUpdatingFromSwiftUI = false
        var hasReportedInitialRegion = false

        // Diff tracking
        var lastCommunityCellIDs: Set<String> = []
        var lastCommunityRepeaterPinIDs: Set<String> = []
        var lastSurveyCellIDs: Set<String> = []
        var lastSurveyCellFingerprints: Set<String> = []
        var lastPointIDs: Set<UUID> = []

        // Current data for tap hit testing
        var currentGridCells: [SignalSurveyViewModel.GridCell] = []
        var currentCommunityCells: [SurveyUploadService.CommunityCell] = []
        var currentSelectedCell: SignalSurveyViewModel.GridCell?
        var currentSelectedCommunityCell: SurveyUploadService.CommunityCell?
        var currentVisualizationMode: SignalSurveyViewModel.VisualizationMode = .gridHeatmap

        lazy var mapView: MKMapView = {
            let map = MKMapView()
            return map
        }()

        // MARK: - Tap Handling

        @objc func handleMapTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }

            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)

            // First check repeater annotation hits (use view frames for reliable hit testing)
            for annotation in mapView.annotations {
                guard let repeater = annotation as? SurveyRepeaterPin else { continue }
                if mapView.view(for: repeater) != nil {
                    let annotationPoint = mapView.convert(repeater.coordinate, toPointTo: mapView)
                    let hitRect = CGRect(x: annotationPoint.x - 22, y: annotationPoint.y - 22, width: 44, height: 44)
                    if hitRect.contains(point) {
                        onRepeaterTapped?(repeater.contact)
                        return
                    }
                }
            }

            guard currentVisualizationMode == .gridHeatmap else { return }

            // Check survey cells (rendered on top, check first)
            for cell in currentGridCells {
                if pointInPolygon(coordinate, vertices: cell.vertices) {
                    if currentSelectedCell?.coordKey == cell.coordKey {
                        onCellSelected?(nil)
                    } else {
                        onCommunityCellSelected?(nil)
                        onCellSelected?(cell)
                    }
                    return
                }
            }

            // Check community cells
            for cell in currentCommunityCells {
                let vertices = HexGrid.vertices(
                    centerLatitude: cell.latitude,
                    centerLongitude: cell.longitude,
                    referenceLatitude: cell.referenceLatitude
                )
                if pointInPolygon(coordinate, vertices: vertices) {
                    if currentSelectedCommunityCell?.id == cell.id {
                        onCommunityCellSelected?(nil)
                    } else {
                        onCellSelected?(nil)
                        onCommunityCellSelected?(cell)
                    }
                    return
                }
            }

            // Tapped empty area — deselect
            onCellSelected?(nil)
            onCommunityCellSelected?(nil)
        }

        /// Point-in-polygon test using ray casting algorithm.
        private func pointInPolygon(_ point: CLLocationCoordinate2D, vertices: [CLLocationCoordinate2D]) -> Bool {
            var inside = false
            let n = vertices.count
            var j = n - 1
            for i in 0..<n {
                let vi = vertices[i]
                let vj = vertices[j]
                if (vi.latitude > point.latitude) != (vj.latitude > point.latitude) &&
                    point.longitude < (vj.longitude - vi.longitude) * (point.latitude - vi.latitude) / (vj.latitude - vi.latitude) + vi.longitude {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }

        // Allow tap gesture to work alongside MKMapView's built-in gestures
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if annotation is SurveyRepeaterPin {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: "SurveyRepeaterPin",
                    for: annotation
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: "SurveyRepeaterPin"
                )
                view.annotation = annotation
                view.markerTintColor = .systemCyan
                view.glyphImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
                view.displayPriority = .defaultHigh
                view.titleVisibility = .adaptive
                view.canShowCallout = false
                return view
            }

            if annotation is CommunityRepeaterPin {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: "CommunityRepeaterPin",
                    for: annotation
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: "CommunityRepeaterPin"
                )
                view.annotation = annotation
                view.markerTintColor = .systemCyan
                view.glyphImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
                view.displayPriority = .defaultHigh
                view.titleVisibility = .adaptive
                view.canShowCallout = false
                view.clusteringIdentifier = nil
                return view
            }

            if let point = annotation as? SurveyPointAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "SurveyPointDot") ??
                    MKAnnotationView(annotation: annotation, reuseIdentifier: "SurveyPointDot")
                view.annotation = annotation
                view.frame.size = CGSize(width: 10, height: 10)
                view.backgroundColor = UIColor(point.quality.color).withAlphaComponent(0.8)
                view.layer.cornerRadius = 5
                view.layer.borderWidth = 1
                view.layer.borderColor = UIColor(point.quality.color).cgColor
                return view
            }

            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            // Community hex cells
            if let hexOverlay = overlay as? CommunityHexOverlay {
                let renderer = MKPolygonRenderer(polygon: hexOverlay)
                renderer.fillColor = hexOverlay.fillUIColor.withAlphaComponent(hexOverlay.fillOpacity * 0.6)
                renderer.strokeColor = hexOverlay.fillUIColor.withAlphaComponent(0.25)
                renderer.lineWidth = 0.5
                renderer.lineDashPattern = [3, 2]
                return renderer
            }

            // User survey hex cells
            if let surveyOverlay = overlay as? SurveyHexOverlay {
                let renderer = MKPolygonRenderer(polygon: surveyOverlay)
                renderer.fillColor = surveyOverlay.fillUIColor.withAlphaComponent(surveyOverlay.fillOpacity)
                renderer.strokeColor = surveyOverlay.fillUIColor.withAlphaComponent(surveyOverlay.strokeOpacity)
                renderer.lineWidth = surveyOverlay.isDeadZone ? 1 : 0.5
                if surveyOverlay.isDeadZone {
                    renderer.lineDashPattern = [4, 3]
                }
                return renderer
            }

            // Selection highlight
            if let selection = overlay as? SurveySelectionOverlay {
                let renderer = MKPolygonRenderer(polygon: selection)
                if selection.isCommunity {
                    let color = CommunityHexOverlay.uiColor(for: selection.snrQuality)
                    renderer.fillColor = color.withAlphaComponent(0.35)
                    renderer.strokeColor = .cyan
                    renderer.lineWidth = 2
                } else {
                    let color: UIColor = selection.isDeadZone ? .systemGray : SurveyHexOverlay.uiColor(for: selection.snrQuality)
                    renderer.fillColor = color.withAlphaComponent(selection.isDeadZone ? 0.3 : 0.5)
                    renderer.strokeColor = .white
                    renderer.lineWidth = 3
                }
                return renderer
            }

            // Cell-to-repeater polyline
            if let polyline = overlay as? SurveyCellPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .tintColor
                renderer.lineWidth = 2
                renderer.lineDashPattern = [8, 4]
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isUpdatingFromSwiftUI else { return }
            onRegionChanged?(mapView.region)
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // When MKMapView stops tracking (e.g. user pans the map), notify the parent
            if mode == .none {
                onTrackingStopped?()
            }
        }
    }
}

// MARK: - Helper Overlay Types

/// Selection highlight polygon rendered on top of survey/community cells.
final class SurveySelectionOverlay: MKPolygon {
    var isCommunity: Bool = false
    var snrQuality: SNRQuality = .unknown
    var isDeadZone: Bool = false
}

/// Polyline from selected cell center to selected repeater.
final class SurveyCellPolyline: MKPolyline {}

// MARK: - Annotation Types

/// MKAnnotation for repeater pins on the survey map.
final class SurveyRepeaterPin: NSObject, MKAnnotation {
    let hexID: String
    let contact: ContactDTO
    let coordinate: CLLocationCoordinate2D

    var title: String? { contact.displayName }

    init(hexID: String, contact: ContactDTO) {
        self.hexID = hexID
        self.contact = contact
        self.coordinate = CLLocationCoordinate2D(latitude: contact.latitude, longitude: contact.longitude)
    }
}

/// MKAnnotation for individual point cloud dots.
final class SurveyPointAnnotation: NSObject, MKAnnotation {
    let point: SignalSurveyPointDTO
    let coordinate: CLLocationCoordinate2D
    let quality: SNRQuality

    init(point: SignalSurveyPointDTO) {
        self.point = point
        self.coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        self.quality = point.snrQuality
    }
}

// MARK: - Static Color Helpers

extension CommunityHexOverlay {
    static func uiColor(for quality: SNRQuality) -> UIColor {
        switch quality {
        case .excellent: UIColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 1)
        case .good:      UIColor(red: 0.918, green: 0.702, blue: 0.031, alpha: 1)
        case .fair:      UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 1)
        case .poor:      UIColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1)
        case .veryPoor:  UIColor(red: 0.600, green: 0.106, blue: 0.106, alpha: 1)
        case .unknown:   .systemGray
        }
    }
}

extension SurveyHexOverlay {
    static func uiColor(for quality: SNRQuality) -> UIColor {
        switch quality {
        case .excellent: .systemGreen
        case .good:      .systemYellow
        case .fair, .poor, .veryPoor: .systemRed
        case .unknown:   .systemGray
        }
    }
}
