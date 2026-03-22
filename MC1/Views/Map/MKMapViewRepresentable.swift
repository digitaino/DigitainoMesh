import MapKit
import os
import SwiftUI
import MC1Services

private let logger = Logger(subsystem: "com.mc1", category: "MapRepresentable")

/// UIViewRepresentable wrapper for MKMapView with custom contact annotations
struct MKMapViewRepresentable: UIViewRepresentable {
    let contacts: [ContactDTO]
    let mapType: MKMapType
    let showLabels: Bool
    let showsUserLocation: Bool
    let communityCells: [SurveyUploadService.CommunityCell]
    let showCommunityOverlay: Bool
    let selectedCommunityCell: SurveyUploadService.CommunityCell?
    let repeaterLocations: [SurveyUploadService.RepeaterLocation]

    @Binding var selectedContact: ContactDTO?
    @Binding var cameraRegion: MKCoordinateRegion?

    // Callbacks for callout actions
    let onDetailTap: (ContactDTO) -> Void
    let onMessageTap: (ContactDTO) -> Void
    /// Called when the map region changes and community overlay is active
    var onRegionChanged: ((MKCoordinateRegion) -> Void)?
    /// Called when a community cell is tapped (nil to deselect)
    var onCommunityCellSelected: ((SurveyUploadService.CommunityCell?) -> Void)?
    /// Called when a repeater annotation is tapped — filters cells to that repeater
    var onRepeaterTapped: ((String) -> Void)?
    /// Called once with a closure that returns snapshot parameters from the actual MKMapView (bypasses async binding)
    var onSnapshotParamsGetter: ((@escaping () -> (camera: MKMapCamera, size: CGSize)?) -> Void)?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = context.coordinator.mapView

        mapView.delegate = context.coordinator
        mapView.showsUserLocation = showsUserLocation

        // Register annotation views
        mapView.register(
            ContactPinView.self,
            forAnnotationViewWithReuseIdentifier: ContactPinView.reuseIdentifier
        )
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
        )
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: "CommunityRepeaterPin"
        )

        // Add tap gesture for community cell hit testing
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapTap(_:)))
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)

        // Provide closure to get snapshot params directly from MKMapView (bypasses async binding lag)
        onSnapshotParamsGetter? { [weak mapView] in
            guard let mapView else { return nil }
            // swiftlint:disable:next force_cast
            return (camera: mapView.camera.copy() as! MKMapCamera, size: mapView.bounds.size)
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // Update binding setters each render cycle
        coordinator.setSelectedContact = { selectedContact = $0 }
        coordinator.setCameraRegion = { cameraRegion = $0 }
        coordinator.onDetailTap = onDetailTap
        coordinator.onMessageTap = onMessageTap
        coordinator.onRegionChanged = onRegionChanged
        coordinator.onCommunityCellSelected = onCommunityCellSelected
        coordinator.onRepeaterTapped = onRepeaterTapped
        coordinator.showLabels = showLabels
        coordinator.showCommunityOverlay = showCommunityOverlay
        coordinator.currentCommunityCells = communityCells
        coordinator.currentSelectedCommunityCell = selectedCommunityCell

        // Mark as programmatic update to prevent feedback loops
        coordinator.isUpdatingFromSwiftUI = true
        defer { coordinator.isUpdatingFromSwiftUI = false }

        // Update map type
        mapView.mapType = mapType

        // Update user location visibility
        mapView.showsUserLocation = showsUserLocation

        // Update annotations
        updateAnnotations(in: mapView, coordinator: coordinator)

        // Update selection state
        updateSelection(in: mapView, coordinator: coordinator)

        // Update region if changed programmatically
        if let region = cameraRegion {
            // Check if binding has caught up with pending user gesture
            if let pendingGesture = coordinator.pendingUserGestureRegion {
                if region.isApproximatelyEqual(to: pendingGesture) {
                    // Binding now reflects user gesture, clear pending state
                    logger.debug("Region: binding caught up, clearing pendingUserGestureRegion")
                    coordinator.pendingUserGestureRegion = nil
                } else {
                    // Binding is stale (hasn't caught up with user gesture), skip applying
                    logger.debug("Region: binding stale (span=\(region.span.latitudeDelta, format: .fixed(precision: 4))), pending span=\(pendingGesture.span.latitudeDelta, format: .fixed(precision: 4))), skipping")
                    return
                }
            }

            let shouldUpdate = coordinator.lastAppliedRegion == nil ||
                !coordinator.lastAppliedRegion!.isApproximatelyEqual(to: region)

            if shouldUpdate {
                logger.debug("Region: applying via setRegion (span=\(region.span.latitudeDelta, format: .fixed(precision: 4)))")
                coordinator.hasPendingProgrammaticRegion = true
                coordinator.hasAppliedInitialRegion = true
                mapView.setRegion(region, animated: coordinator.lastAppliedRegion != nil)
                coordinator.lastAppliedRegion = region
            }
        }

        // Update community hex overlays, repeater pins, polylines, and selection highlight
        updateCommunityOverlays(in: mapView, coordinator: coordinator)
        updateRepeaterPins(in: mapView, coordinator: coordinator)
        updateSelectionOverlay(in: mapView, coordinator: coordinator)
        updateCellToRepeaterPolylines(in: mapView, coordinator: coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Community Overlay Management

    private func updateCommunityOverlays(in mapView: MKMapView, coordinator: Coordinator) {
        if !showCommunityOverlay {
            // Remove all community overlays when disabled
            if !coordinator.lastOverlayCellIDs.isEmpty {
                let existing = mapView.overlays.compactMap { $0 as? CommunityHexOverlay }
                if !existing.isEmpty {
                    mapView.removeOverlays(existing)
                }
                coordinator.lastOverlayCellIDs = []
                coordinator.overlaysByID = [:]
            }
            return
        }

        // Incremental diff: only add/remove overlays that changed
        let newIDs = Set(communityCells.map(\.id))
        guard newIDs != coordinator.lastOverlayCellIDs else { return }

        let idsToRemove = coordinator.lastOverlayCellIDs.subtracting(newIDs)
        let idsToAdd = newIDs.subtracting(coordinator.lastOverlayCellIDs)

        // Remove overlays for cells no longer in the set
        if !idsToRemove.isEmpty {
            let toRemove = idsToRemove.compactMap { coordinator.overlaysByID[$0] }
            if !toRemove.isEmpty {
                mapView.removeOverlays(toRemove)
            }
            for id in idsToRemove {
                coordinator.overlaysByID.removeValue(forKey: id)
            }
        }

        // Add overlays for new cells
        if !idsToAdd.isEmpty {
            let cellsByID = Dictionary(communityCells.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            let toAdd = idsToAdd.compactMap { id -> CommunityHexOverlay? in
                guard let cell = cellsByID[id] else { return nil }
                let overlay = CommunityHexOverlay.make(from: cell)
                coordinator.overlaysByID[id] = overlay
                return overlay
            }
            if !toAdd.isEmpty {
                mapView.addOverlays(toAdd, level: .aboveRoads)
            }
        }

        coordinator.lastOverlayCellIDs = newIDs
    }

    // MARK: - Selection Overlay Management

    private func updateSelectionOverlay(in mapView: MKMapView, coordinator: Coordinator) {
        // Remove existing selection overlays
        let existing = mapView.overlays.compactMap { $0 as? SurveySelectionOverlay }
        if !existing.isEmpty {
            mapView.removeOverlays(existing)
        }

        // Add selection highlight for tapped community cell
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

    // MARK: - Repeater Pin Management

    private func updateRepeaterPins(in mapView: MKMapView, coordinator: Coordinator) {
        let existing = mapView.annotations.compactMap { $0 as? CommunityRepeaterPin }

        if !showCommunityOverlay {
            if !existing.isEmpty {
                mapView.removeAnnotations(existing)
                coordinator.lastRepeaterPinIDs = []
            }
            return
        }

        let newIDs = Set(repeaterLocations.map(\.hexID))
        guard newIDs != coordinator.lastRepeaterPinIDs else { return }

        let toRemove = existing.filter { !newIDs.contains($0.hexID) }
        if !toRemove.isEmpty {
            mapView.removeAnnotations(toRemove)
        }

        let remainingIDs = Set(existing.map(\.hexID)).subtracting(Set(toRemove.map(\.hexID)))
        let toAdd = repeaterLocations
            .filter { !remainingIDs.contains($0.hexID) }
            .map { CommunityRepeaterPin(repeater: $0) }
        if !toAdd.isEmpty {
            mapView.addAnnotations(toAdd)
        }
        coordinator.lastRepeaterPinIDs = newIDs
    }

    // MARK: - Cell-to-Repeater Polylines

    private func updateCellToRepeaterPolylines(in mapView: MKMapView, coordinator: Coordinator) {
        // Remove existing polylines
        let existing = mapView.overlays.compactMap { $0 as? SurveyCellPolyline }
        if !existing.isEmpty {
            mapView.removeOverlays(existing)
        }

        // Draw lines from selected cell to each of its repeaters (if locations are known)
        guard let cell = selectedCommunityCell, showCommunityOverlay else { return }
        let cellCenter = CLLocationCoordinate2D(latitude: cell.latitude, longitude: cell.longitude)

        // Build a lookup of repeater locations by hex ID (uppercased for prefix matching)
        let locationsByHex = Dictionary(repeaterLocations.map { ($0.hexID.uppercased(), $0) }, uniquingKeysWith: { _, new in new })

        for hexID in cell.repeaterHexIDs {
            let upper = hexID.uppercased()
            // Try exact match, then prefix match
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

    // MARK: - Annotation Management

    private func updateAnnotations(in mapView: MKMapView, coordinator: Coordinator) {
        let currentAnnotations = mapView.annotations.compactMap { $0 as? ContactAnnotation }
        let currentIDs = Set(currentAnnotations.map { $0.contact.id })
        let newIDs = Set(contacts.map { $0.id })

        // Remove annotations that are no longer in the list
        let toRemove = currentAnnotations.filter { !newIDs.contains($0.contact.id) }
        mapView.removeAnnotations(toRemove)

        // Add new annotations
        let existingIDs = currentIDs.subtracting(Set(toRemove.map { $0.contact.id }))
        let toAdd = contacts.filter { !existingIDs.contains($0.id) }
            .map { ContactAnnotation(contact: $0) }
        mapView.addAnnotations(toAdd)

        // Only update name labels if showLabels or selection actually changed
        // Iterating and calling view(for:) on every update interferes with MKMapView clustering
        let selectedID = selectedContact?.id
        let labelsChanged = showLabels != coordinator.lastShowLabels
        let selectionChanged = selectedID != coordinator.lastSelectedContactID

        if labelsChanged || selectionChanged {
            for annotation in mapView.annotations.compactMap({ $0 as? ContactAnnotation }) {
                if let view = mapView.view(for: annotation) as? ContactPinView {
                    view.showsNameLabel = showLabels && selectedID != annotation.contact.id
                }
            }
            coordinator.lastShowLabels = showLabels
            coordinator.lastSelectedContactID = selectedID
        }
    }

    private func updateSelection(in mapView: MKMapView, coordinator: Coordinator) {
        let currentlySelectedAnnotation = mapView.selectedAnnotations.first as? ContactAnnotation

        if let selectedContact {
            // Find the annotation for this contact
            guard let annotation = mapView.annotations
                .compactMap({ $0 as? ContactAnnotation })
                .first(where: { $0.contact.id == selectedContact.id }) else {
                return
            }

            // Only select if not already selected
            if currentlySelectedAnnotation?.contact.id != selectedContact.id {
                mapView.selectAnnotation(annotation, animated: true)
            }
        } else if let current = currentlySelectedAnnotation {
            // Deselect all
            mapView.deselectAnnotation(current, animated: true)
        }
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        // Binding setters for deferred updates
        var setSelectedContact: ((ContactDTO?) -> Void)?
        var setCameraRegion: ((MKCoordinateRegion?) -> Void)?

        // Callbacks
        var onDetailTap: ((ContactDTO) -> Void)?
        var onMessageTap: ((ContactDTO) -> Void)?
        var onRegionChanged: ((MKCoordinateRegion) -> Void)?
        var onCommunityCellSelected: ((SurveyUploadService.CommunityCell?) -> Void)?
        var onRepeaterTapped: ((String) -> Void)?

        // Configuration
        var showLabels: Bool = true
        var showCommunityOverlay: Bool = false

        // Community cell data for tap hit testing
        var currentCommunityCells: [SurveyUploadService.CommunityCell] = []
        var currentSelectedCommunityCell: SurveyUploadService.CommunityCell?

        // State management
        var isUpdatingFromSwiftUI = false
        var lastAppliedRegion: MKCoordinateRegion?
        var hasPendingProgrammaticRegion = false
        var hasAppliedInitialRegion = false

        /// Tracks pending user gesture region awaiting async binding sync.
        /// When set, the binding is considered stale until it matches this value.
        var pendingUserGestureRegion: MKCoordinateRegion?

        /// Timestamp of the last cluster tap handled by the gesture recognizer.
        /// Used to prevent double-handling when both gesture and delegate fire.
        var lastClusterTapTime: Date?

        /// Set before showAnnotations calls to ensure pendingUserGestureRegion is set
        /// even if hasPendingProgrammaticRegion is true from a prior setRegion.
        var hasPendingShowAnnotations = false

        // Previous state for change detection (avoid unnecessary view updates that interfere with clustering)
        var lastShowLabels: Bool = true
        var lastSelectedContactID: UUID?
        var lastOverlayCellIDs: Set<String> = []
        var overlaysByID: [String: CommunityHexOverlay] = [:]
        var lastRepeaterPinIDs: Set<String> = []

        // Lazily created map view owned by coordinator
        lazy var mapView: MKMapView = {
            let map = MKMapView()
            return map
        }()

        // MARK: - Community Cell Tap Handler

        @objc func handleMapTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, showCommunityOverlay else { return }

            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)

            // Check if tap hit a contact annotation view (let MKMapView handle those)
            for annotation in mapView.annotations {
                guard annotation is ContactAnnotation || annotation is MKClusterAnnotation else { continue }
                if mapView.view(for: annotation) != nil {
                    let annotationPoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
                    let hitRect = CGRect(x: annotationPoint.x - 22, y: annotationPoint.y - 44, width: 44, height: 44)
                    if hitRect.contains(point) {
                        return // Let MKMapView's built-in selection handle it
                    }
                }
            }

            // Check if tap hit a repeater pin — filter cells by that repeater
            for annotation in mapView.annotations {
                guard let repeaterPin = annotation as? CommunityRepeaterPin else { continue }
                let annotationPoint = mapView.convert(repeaterPin.coordinate, toPointTo: mapView)
                let hitRect = CGRect(x: annotationPoint.x - 22, y: annotationPoint.y - 44, width: 44, height: 44)
                if hitRect.contains(point) {
                    onRepeaterTapped?(repeaterPin.hexID)
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
                        onCommunityCellSelected?(cell)
                    }
                    return
                }
            }

            // Tapped empty area — deselect community cell
            if currentSelectedCommunityCell != nil {
                onCommunityCellSelected?(nil)
            }
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

        // MARK: - Cluster Tap Handler

        @objc func clusterTapped(_ gesture: UITapGestureRecognizer) {
            guard let clusterView = gesture.view as? MKAnnotationView,
                  let cluster = clusterView.annotation as? MKClusterAnnotation else {
                return
            }
            // Mark that we handled this tap to prevent delegate double-handling
            lastClusterTapTime = Date()
            // Mark that we're about to call showAnnotations so regionDidChangeAnimated
            // will set pendingUserGestureRegion to protect against stale binding values
            hasPendingShowAnnotations = true
            logger.debug("Cluster: gesture tapped, calling showAnnotations for \(cluster.memberAnnotations.count) members")
            mapView.showAnnotations(cluster.memberAnnotations, animated: true)
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            // Don't provide custom view for user location
            if annotation is MKUserLocation {
                return nil
            }

            // Handle cluster annotations
            if annotation is MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                    for: annotation
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
                )
                view.markerTintColor = .systemBlue
                view.glyphImage = UIImage(systemName: "person.2.fill")
                view.displayPriority = .defaultHigh
                view.canShowCallout = false

                // Remove existing tap gestures to avoid duplicates on reuse
                view.gestureRecognizers?.filter { $0 is UITapGestureRecognizer }.forEach {
                    view.removeGestureRecognizer($0)
                }

                // Add tap gesture for immediate response (bypasses delegate selection delay)
                let tap = UITapGestureRecognizer(target: self, action: #selector(clusterTapped(_:)))
                view.addGestureRecognizer(tap)

                return view
            }

            // Handle community repeater pins
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
                // Don't cluster repeater pins with contacts
                view.clusteringIdentifier = nil
                return view
            }

            // Handle contact annotations
            guard let contactAnnotation = annotation as? ContactAnnotation else {
                return nil
            }

            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: ContactPinView.reuseIdentifier,
                for: annotation
            ) as? ContactPinView ?? ContactPinView(
                annotation: annotation,
                reuseIdentifier: ContactPinView.reuseIdentifier
            )

            view.annotation = annotation
            view.showsNameLabel = showLabels
            // Must set clusteringIdentifier here before returning view, not in init/configure
            // MKMapView makes clustering decisions based on this value at return time
            view.clusteringIdentifier = "contact"
            view.onDetail = { [weak self] in
                self?.onDetailTap?(contactAnnotation.contact)
            }
            view.onMessage = { [weak self] in
                self?.onMessageTap?(contactAnnotation.contact)
            }

            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let hexOverlay = overlay as? CommunityHexOverlay {
                let renderer = MKPolygonRenderer(polygon: hexOverlay)
                renderer.fillColor = hexOverlay.fillUIColor.withAlphaComponent(hexOverlay.fillOpacity)
                renderer.strokeColor = hexOverlay.fillUIColor.withAlphaComponent(0.6)
                renderer.lineWidth = 0.5
                return renderer
            }

            // Selection highlight overlay (community cell tap)
            if let selection = overlay as? SurveySelectionOverlay {
                let renderer = MKPolygonRenderer(polygon: selection)
                let color = CommunityHexOverlay.uiColor(for: selection.snrQuality)
                renderer.fillColor = color.withAlphaComponent(0.35)
                renderer.strokeColor = .cyan
                renderer.lineWidth = 2
                return renderer
            }

            // Cell-to-repeater polyline
            if let polyline = overlay as? SurveyCellPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .cyan
                renderer.lineWidth = 2
                renderer.lineDashPattern = [8, 4]
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
            guard !isUpdatingFromSwiftUI else { return }

            // Ignore user location selection
            if annotation is MKUserLocation {
                return
            }

            // Handle cluster selection - zoom to show members
            // Skip if gesture recognizer already handled this tap (within 500ms)
            if let cluster = annotation as? MKClusterAnnotation {
                if let tapTime = lastClusterTapTime, Date().timeIntervalSince(tapTime) < 0.5 {
                    // Gesture already handled this tap, just deselect without zooming again
                    logger.debug("Cluster: didSelect skipped (gesture handled \(Date().timeIntervalSince(tapTime), format: .fixed(precision: 3))s ago)")
                    mapView.deselectAnnotation(cluster, animated: false)
                    return
                }
                logger.debug("Cluster: didSelect calling showAnnotations (fallback path)")
                mapView.deselectAnnotation(cluster, animated: false)
                hasPendingShowAnnotations = true
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
                return
            }

            guard let contactAnnotation = annotation as? ContactAnnotation else { return }

            logger.debug("Selection: didSelect for \(contactAnnotation.contact.displayName)")

            // Update name label visibility
            if let view = mapView.view(for: annotation) as? ContactPinView {
                view.showsNameLabel = false
            }

            // Defer binding update to avoid SwiftUI state mutation during update
            Task { @MainActor in
                logger.debug("Selection: updating selectedContact binding")
                self.setSelectedContact?(contactAnnotation.contact)
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect annotation: any MKAnnotation) {
            guard !isUpdatingFromSwiftUI else { return }

            // Update name label visibility
            if let view = mapView.view(for: annotation) as? ContactPinView {
                view.showsNameLabel = showLabels
            }

            Task { @MainActor in
                self.setSelectedContact?(nil)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isUpdatingFromSwiftUI else {
                logger.debug("Region: regionDidChangeAnimated skipped (isUpdatingFromSwiftUI)")
                return
            }

            let newSpan = mapView.region.span.latitudeDelta

            // Handle showAnnotations region changes - must set pendingUserGestureRegion
            // to protect against stale binding values, since the binding wasn't updated
            if hasPendingShowAnnotations {
                logger.debug("Region: regionDidChangeAnimated from showAnnotations (span=\(newSpan, format: .fixed(precision: 4)))")
                hasPendingShowAnnotations = false
                hasPendingProgrammaticRegion = false // Clear if also set
                lastAppliedRegion = mapView.region
                pendingUserGestureRegion = mapView.region
                Task { @MainActor in
                    logger.debug("Region: updating cameraRegion binding (from showAnnotations)")
                    self.setCameraRegion?(mapView.region)
                }
                return
            }

            // Don't overwrite binding during programmatic region changes from setRegion
            if hasPendingProgrammaticRegion {
                logger.debug("Region: regionDidChangeAnimated from programmatic change (span=\(newSpan, format: .fixed(precision: 4)))")
                hasPendingProgrammaticRegion = false
                lastAppliedRegion = mapView.region
                return
            }

            // Don't write back until we've applied at least one programmatic region
            // This prevents the initial default region from overwriting the intended region
            guard hasAppliedInitialRegion else {
                logger.debug("Region: regionDidChangeAnimated before initial region (span=\(newSpan, format: .fixed(precision: 4)))")
                lastAppliedRegion = mapView.region
                return
            }

            // Track user-initiated region changes
            // Mark as pending so stale binding values won't revert this change
            logger.debug("Region: regionDidChangeAnimated setting pendingUserGestureRegion (span=\(newSpan, format: .fixed(precision: 4)))")
            lastAppliedRegion = mapView.region
            pendingUserGestureRegion = mapView.region

            Task { @MainActor in
                logger.debug("Region: updating cameraRegion binding")
                self.setCameraRegion?(mapView.region)
            }

            // Notify for community overlay refresh
            if showCommunityOverlay {
                onRegionChanged?(mapView.region)
            }
        }
    }
}

// MARK: - MKCoordinateRegion Comparison

extension MKCoordinateRegion {
    func isApproximatelyEqual(to other: MKCoordinateRegion, tolerance: Double = 0.0001) -> Bool {
        abs(center.latitude - other.center.latitude) < tolerance &&
        abs(center.longitude - other.center.longitude) < tolerance &&
        abs(span.latitudeDelta - other.span.latitudeDelta) < tolerance &&
        abs(span.longitudeDelta - other.span.longitudeDelta) < tolerance
    }
}

// MARK: - Community Repeater Pin

/// MKAnnotation for repeater pins shown on the community overlay.
final class CommunityRepeaterPin: NSObject, MKAnnotation {
    let hexID: String
    let coordinate: CLLocationCoordinate2D
    var title: String?

    init(repeater: SurveyUploadService.RepeaterLocation) {
        self.hexID = repeater.hexID
        self.coordinate = CLLocationCoordinate2D(latitude: repeater.latitude, longitude: repeater.longitude)
        self.title = repeater.name.isEmpty ? repeater.hexID : repeater.name
    }
}
