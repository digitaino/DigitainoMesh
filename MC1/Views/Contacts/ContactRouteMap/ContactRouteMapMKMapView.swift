import MapKit
import SwiftUI

/// UIViewRepresentable for the per-contact route history map.
/// Displays traffic bubbles, directional segment overlays with arrowheads,
/// and sender/receiver endpoint pins.
struct ContactRouteMapMKMapView: UIViewRepresentable {
    let bubbleAnnotations: [TrafficBubbleAnnotation]
    let endpointAnnotations: [RouteEndpointAnnotation]
    let segmentOverlays: [TrafficSegmentOverlay]
    let mapType: MKMapType
    let labelMode: AnnotationLabelMode

    @Binding var cameraRegion: MKCoordinateRegion?
    let cameraRegionVersion: Int

    func makeUIView(context: Context) -> MKMapView {
        let mapView = context.coordinator.mapView
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true

        mapView.register(
            TrafficBubblePinView.self,
            forAnnotationViewWithReuseIdentifier: TrafficBubblePinView.reuseIdentifier
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
        // Update bubble annotations
        let currentBubbles = mapView.annotations.compactMap { $0 as? TrafficBubbleAnnotation }
        let currentKeys = Set(currentBubbles.map { $0.publicKey })
        let newKeys = Set(bubbleAnnotations.map { $0.publicKey })

        let toRemove = currentBubbles.filter { !newKeys.contains($0.publicKey) }
        mapView.removeAnnotations(toRemove)

        let existingKeys = currentKeys.subtracting(Set(toRemove.map { $0.publicKey }))
        let toAdd = bubbleAnnotations.filter { !existingKeys.contains($0.publicKey) }
        mapView.addAnnotations(toAdd)

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
        let newIdentities = Set(segmentOverlays.map { ObjectIdentifier($0) })

        guard newIdentities != coordinator.lastOverlayIdentities else { return }
        coordinator.lastOverlayIdentities = newIdentities

        let existingSegments = mapView.overlays.compactMap { $0 as? TrafficSegmentOverlay }
        mapView.removeOverlays(existingSegments)
        mapView.addOverlays(segmentOverlays)
    }

    private func updateLabelMode(in mapView: MKMapView, coordinator: Coordinator) {
        guard labelMode != coordinator.lastLabelMode else { return }
        coordinator.lastLabelMode = labelMode

        for annotation in mapView.annotations {
            if let view = mapView.view(for: annotation) as? RouteEndpointPinView {
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

            if let bubbleAnnotation = annotation as? TrafficBubbleAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: TrafficBubblePinView.reuseIdentifier,
                    for: annotation
                ) as? TrafficBubblePinView ?? TrafficBubblePinView(
                    annotation: annotation,
                    reuseIdentifier: TrafficBubblePinView.reuseIdentifier
                )
                view.configure(for: bubbleAnnotation)
                return view
            }

            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if overlay is TrafficSegmentOverlay {
                let renderer = TrafficSegmentRenderer(overlay: overlay)
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
