import MapKit
import SwiftUI
import PocketMeshServices

/// Read-only UIViewRepresentable for displaying a message's geographic route on a map.
/// Simplified variant of `TracePathMKMapView` without interactive path building.
struct MessageRouteMapMKMapView: UIViewRepresentable {
    let repeaterAnnotations: [RepeaterAnnotation]
    let endpointAnnotations: [RouteEndpointAnnotation]
    let lineOverlays: [PathLineOverlay]
    let mapType: MKMapType
    let pathState: [UUID: MessageRouteMapViewModel.PathInfo]
    let labelMode: AnnotationLabelMode

    @Binding var cameraRegion: MKCoordinateRegion?
    let cameraRegionVersion: Int

    func makeUIView(context: Context) -> MKMapView {
        let mapView = context.coordinator.mapView
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true

        mapView.register(
            TracePathRepeaterPinView.self,
            forAnnotationViewWithReuseIdentifier: TracePathRepeaterPinView.reuseID
        )
        mapView.register(
            RouteEndpointPinView.self,
            forAnnotationViewWithReuseIdentifier: RouteEndpointPinView.reuseID
        )

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator

        coordinator.isUpdatingFromSwiftUI = true
        defer { coordinator.isUpdatingFromSwiftUI = false }

        coordinator.pathState = pathState
        coordinator.labelMode = labelMode

        mapView.mapType = mapType

        updateAnnotations(in: mapView, coordinator: coordinator)
        updateOverlays(in: mapView, coordinator: coordinator)
        updateLabelMode(in: mapView, coordinator: coordinator)
        updateRegion(in: mapView, coordinator: coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(setCameraRegion: { cameraRegion = $0 })
    }

    // MARK: - Annotation Updates

    private func updateAnnotations(in mapView: MKMapView, coordinator: Coordinator) {
        // Update repeater annotations
        let currentRepeaters = mapView.annotations.compactMap { $0 as? RepeaterAnnotation }
        let currentRepeaterIDs = Set(currentRepeaters.map { $0.repeater.id })
        let newRepeaterIDs = Set(repeaterAnnotations.map { $0.repeater.id })

        let repeatersToRemove = currentRepeaters.filter { !newRepeaterIDs.contains($0.repeater.id) }
        mapView.removeAnnotations(repeatersToRemove)

        let existingRepeaterIDs = currentRepeaterIDs.subtracting(Set(repeatersToRemove.map { $0.repeater.id }))
        let repeatersToAdd = repeaterAnnotations.filter { !existingRepeaterIDs.contains($0.repeater.id) }
        for annotation in repeatersToAdd {
            annotation.applyLabelMode(labelMode)
        }
        mapView.addAnnotations(repeatersToAdd)

        // Update endpoint annotations
        let currentEndpoints = mapView.annotations.compactMap { $0 as? RouteEndpointAnnotation }
        let newEndpointIdentities = Set(endpointAnnotations.map { ObjectIdentifier($0) })
        let currentEndpointIdentities = Set(currentEndpoints.map { ObjectIdentifier($0) })

        if newEndpointIdentities != currentEndpointIdentities {
            mapView.removeAnnotations(currentEndpoints)
            mapView.addAnnotations(endpointAnnotations)
        }
    }

    private func updateOverlays(in mapView: MKMapView, coordinator: Coordinator) {
        let newIdentities = Set(lineOverlays.map { ObjectIdentifier($0) })

        guard newIdentities != coordinator.lastOverlayIdentities else { return }
        coordinator.lastOverlayIdentities = newIdentities

        let existingPathOverlays = mapView.overlays.compactMap { $0 as? PathLineOverlay }
        mapView.removeOverlays(existingPathOverlays)
        mapView.addOverlays(lineOverlays)
    }

    private func updateLabelMode(in mapView: MKMapView, coordinator: Coordinator) {
        guard labelMode != coordinator.lastLabelMode else { return }
        coordinator.lastLabelMode = labelMode

        for annotation in mapView.annotations {
            if let repeaterAnnotation = annotation as? RepeaterAnnotation {
                repeaterAnnotation.applyLabelMode(labelMode)
            }
            if let view = mapView.view(for: annotation) as? TracePathRepeaterPinView {
                view.applyTitleMode(labelMode)
            } else if let view = mapView.view(for: annotation) as? RouteEndpointPinView {
                view.applyTitleMode(labelMode)
            }
        }
    }

    private func updateRegion(in mapView: MKMapView, coordinator: Coordinator) {
        if cameraRegionVersion != coordinator.lastAppliedRegionVersion,
           let region = cameraRegion {
            coordinator.lastAppliedRegionVersion = cameraRegionVersion
            coordinator.hasPendingProgrammaticRegion = true
            mapView.setRegion(region, animated: coordinator.lastAppliedRegion != nil)
            coordinator.lastAppliedRegion = region
        }
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, MKMapViewDelegate {
        var setCameraRegion: (MKCoordinateRegion?) -> Void

        var pathState: [UUID: MessageRouteMapViewModel.PathInfo] = [:]
        var labelMode: AnnotationLabelMode = .name
        var lastLabelMode: AnnotationLabelMode = .name

        var isUpdatingFromSwiftUI = false
        var lastAppliedRegion: MKCoordinateRegion?
        var lastAppliedRegionVersion = -1
        var hasPendingProgrammaticRegion = false

        var lastOverlayIdentities: Set<ObjectIdentifier> = []

        private var hasReceivedInitialRegion = false
        private var pendingRegionTask: Task<Void, Never>?

        lazy var mapView: MKMapView = NoDoubleTapMapView()

        init(setCameraRegion: @escaping (MKCoordinateRegion?) -> Void) {
            self.setCameraRegion = setCameraRegion
        }

        deinit {
            pendingRegionTask?.cancel()
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                return nil
            }

            if let endpointAnnotation = annotation as? RouteEndpointAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: RouteEndpointPinView.reuseID,
                    for: annotation
                ) as? RouteEndpointPinView ?? RouteEndpointPinView(
                    annotation: annotation,
                    reuseIdentifier: RouteEndpointPinView.reuseID
                )
                view.configure(for: endpointAnnotation, titleMode: labelMode)
                return view
            }

            if let repeaterAnnotation = annotation as? RepeaterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: TracePathRepeaterPinView.reuseID,
                    for: annotation
                ) as? TracePathRepeaterPinView ?? TracePathRepeaterPinView(
                    annotation: annotation,
                    reuseIdentifier: TracePathRepeaterPinView.reuseID
                )

                let info = pathState[repeaterAnnotation.repeater.id]
                view.configure(
                    for: repeaterAnnotation.repeater,
                    inPath: true,
                    hopIndex: info?.hopIndex,
                    isLastHop: false,
                    titleMode: labelMode
                )

                return view
            }

            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let pathOverlay = overlay as? PathLineOverlay {
                let renderer = PathLineRenderer(overlay: pathOverlay)
                renderer.showArrowhead = true
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isUpdatingFromSwiftUI else { return }

            if hasPendingProgrammaticRegion {
                hasPendingProgrammaticRegion = false
                hasReceivedInitialRegion = true
                lastAppliedRegion = mapView.region
                return
            }

            if !hasReceivedInitialRegion {
                hasReceivedInitialRegion = true
                lastAppliedRegion = mapView.region
                return
            }

            lastAppliedRegion = mapView.region

            pendingRegionTask?.cancel()
            pendingRegionTask = Task { @MainActor in
                guard !Task.isCancelled else { return }
                self.setCameraRegion(mapView.region)
            }
        }
    }
}
