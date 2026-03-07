import MapKit
import SwiftUI

/// UIViewRepresentable wrapping MKMapView for the traffic heatmap.
/// Displays bubble annotations for repeaters and weighted segment overlays.
struct TrafficHeatmapMKMapView: UIViewRepresentable {
    let bubbleAnnotations: [TrafficBubbleAnnotation]
    let segmentOverlays: [TrafficSegmentOverlay]
    let mapType: MKMapType
    let showLabels: Bool

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

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator

        coordinator.isUpdatingFromSwiftUI = true
        defer { coordinator.isUpdatingFromSwiftUI = false }

        coordinator.showLabels = showLabels

        mapView.mapType = mapType

        updateAnnotations(in: mapView, coordinator: coordinator)
        updateOverlays(in: mapView, coordinator: coordinator)
        updateRegion(in: mapView, coordinator: coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(setCameraRegion: { cameraRegion = $0 })
    }

    // MARK: - Annotation Updates

    private func updateAnnotations(in mapView: MKMapView, coordinator: Coordinator) {
        let currentBubbles = mapView.annotations.compactMap { $0 as? TrafficBubbleAnnotation }
        let currentKeys = Set(currentBubbles.map { $0.publicKey })
        let newKeys = Set(bubbleAnnotations.map { $0.publicKey })

        // Remove annotations no longer present
        let toRemove = currentBubbles.filter { !newKeys.contains($0.publicKey) }
        mapView.removeAnnotations(toRemove)

        // Add new annotations
        let existingKeys = currentKeys.subtracting(Set(toRemove.map { $0.publicKey }))
        let toAdd = bubbleAnnotations.filter { !existingKeys.contains($0.publicKey) }
        mapView.addAnnotations(toAdd)

        // Update visible pin views
        for annotation in mapView.annotations.compactMap({ $0 as? TrafficBubbleAnnotation }) {
            guard let view = mapView.view(for: annotation) as? TrafficBubblePinView else { continue }
            view.configure(for: annotation, showLabel: showLabels)
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

        var showLabels: Bool = true

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

            if let bubbleAnnotation = annotation as? TrafficBubbleAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: TrafficBubblePinView.reuseIdentifier,
                    for: annotation
                ) as? TrafficBubblePinView ?? TrafficBubblePinView(
                    annotation: annotation,
                    reuseIdentifier: TrafficBubblePinView.reuseIdentifier
                )
                view.configure(for: bubbleAnnotation, showLabel: showLabels)
                return view
            }

            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if overlay is TrafficSegmentOverlay {
                return TrafficSegmentRenderer(overlay: overlay)
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
