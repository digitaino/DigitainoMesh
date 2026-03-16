import MapKit
import os
import SwiftUI
import MC1Services

private let logger = Logger(subsystem: "com.pocketmesh", category: "TrafficMapRepresentable")

/// UIViewRepresentable wrapper for MKMapView displaying traffic heatmap data
/// with clusterable repeater pins and polyline segment overlays.
struct TrafficMapRepresentable: UIViewRepresentable {
    let annotations: [TrafficBubbleAnnotation]
    let segments: [TrafficSegmentData]
    let mapType: MKMapType
    let showsUserLocation: Bool

    @Binding var selectedAnnotation: TrafficBubbleAnnotation?
    @Binding var cameraRegion: MKCoordinateRegion?

    let onDetailTap: (TrafficBubbleAnnotation) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = context.coordinator.mapView

        mapView.delegate = context.coordinator
        mapView.showsUserLocation = showsUserLocation

        // Register annotation views
        mapView.register(
            TrafficPinView.self,
            forAnnotationViewWithReuseIdentifier: TrafficPinView.reuseIdentifier
        )
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
        )

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // Update binding setters
        coordinator.setSelectedAnnotation = { selectedAnnotation = $0 }
        coordinator.setCameraRegion = { cameraRegion = $0 }
        coordinator.onDetailTap = onDetailTap

        coordinator.isUpdatingFromSwiftUI = true
        defer { coordinator.isUpdatingFromSwiftUI = false }

        mapView.mapType = mapType
        mapView.showsUserLocation = showsUserLocation

        updateAnnotations(in: mapView, coordinator: coordinator)
        updateSelection(in: mapView, coordinator: coordinator)
        updateOverlays(in: mapView, coordinator: coordinator)

        // Update region if changed programmatically
        if let region = cameraRegion {
            if let pendingGesture = coordinator.pendingUserGestureRegion {
                if region.isApproximatelyEqual(to: pendingGesture) {
                    // Binding caught up with the user gesture — clear pending state
                    coordinator.pendingUserGestureRegion = nil
                } else if coordinator.lastAppliedRegion != nil &&
                          !region.isApproximatelyEqual(to: coordinator.lastAppliedRegion!) {
                    // New programmatic region that differs from both the pending gesture
                    // and the last applied region — this is an intentional change
                    // (e.g., location button), so clear the pending gesture and apply it.
                    coordinator.pendingUserGestureRegion = nil
                } else {
                    // Binding is stale (hasn't caught up with the user gesture), skip
                    return
                }
            }

            let shouldUpdate = coordinator.lastAppliedRegion == nil ||
                !coordinator.lastAppliedRegion!.isApproximatelyEqual(to: region)

            if shouldUpdate {
                coordinator.hasPendingProgrammaticRegion = true
                coordinator.hasAppliedInitialRegion = true
                mapView.setRegion(region, animated: coordinator.lastAppliedRegion != nil)
                coordinator.lastAppliedRegion = region
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Annotation Management

    private func updateAnnotations(in mapView: MKMapView, coordinator: Coordinator) {
        let currentAnnotations = mapView.annotations.compactMap { $0 as? TrafficAnnotation }
        let currentIDs = Set(currentAnnotations.map { $0.bubble.publicKey })
        let newIDs = Set(annotations.map { $0.publicKey })

        let toRemove = currentAnnotations.filter { !newIDs.contains($0.bubble.publicKey) }
        mapView.removeAnnotations(toRemove)

        let existingIDs = currentIDs.subtracting(Set(toRemove.map { $0.bubble.publicKey }))
        let toAdd = annotations.filter { !existingIDs.contains($0.publicKey) }
            .map { TrafficAnnotation(bubble: $0) }
        mapView.addAnnotations(toAdd)
    }

    private func updateSelection(in mapView: MKMapView, coordinator: Coordinator) {
        let currentlySelected = mapView.selectedAnnotations.first as? TrafficAnnotation

        if let selected = selectedAnnotation {
            guard let annotation = mapView.annotations
                .compactMap({ $0 as? TrafficAnnotation })
                .first(where: { $0.bubble.publicKey == selected.publicKey }) else {
                return
            }
            if currentlySelected?.bubble.publicKey != selected.publicKey {
                mapView.selectAnnotation(annotation, animated: true)
            }
        } else if let current = currentlySelected {
            mapView.deselectAnnotation(current, animated: true)
        }
    }

    // MARK: - Overlay Management

    private func updateOverlays(in mapView: MKMapView, coordinator: Coordinator) {
        let newSegmentIDs = Set(segments.map(\.id))
        guard newSegmentIDs != coordinator.lastSegmentIDs else { return }

        // Remove old segment overlays
        let existingOverlays = mapView.overlays.compactMap { $0 as? TrafficPolyline }
        if !existingOverlays.isEmpty {
            mapView.removeOverlays(existingOverlays)
        }

        // Add new segment overlays
        let overlays = segments.map { segment -> TrafficPolyline in
            let coords = segment.coordinates
            let polyline = TrafficPolyline(
                coordinates: coords, count: coords.count
            )
            polyline.segmentData = segment
            return polyline
        }
        if !overlays.isEmpty {
            mapView.addOverlays(overlays, level: .aboveRoads)
        }
        coordinator.lastSegmentIDs = newSegmentIDs
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, MKMapViewDelegate {
        var setSelectedAnnotation: ((TrafficBubbleAnnotation?) -> Void)?
        var setCameraRegion: ((MKCoordinateRegion?) -> Void)?
        var onDetailTap: ((TrafficBubbleAnnotation) -> Void)?

        var isUpdatingFromSwiftUI = false
        var lastAppliedRegion: MKCoordinateRegion?
        var hasPendingProgrammaticRegion = false
        var hasAppliedInitialRegion = false
        var pendingUserGestureRegion: MKCoordinateRegion?
        var lastClusterTapTime: Date?
        var hasPendingShowAnnotations = false
        var lastSegmentIDs: Set<String> = []

        lazy var mapView: MKMapView = {
            let map = MKMapView()
            return map
        }()

        // MARK: - Cluster Tap Handler

        @objc func clusterTapped(_ gesture: UITapGestureRecognizer) {
            guard let clusterView = gesture.view as? MKAnnotationView,
                  let cluster = clusterView.annotation as? MKClusterAnnotation else {
                return
            }
            lastClusterTapTime = Date()
            hasPendingShowAnnotations = true
            mapView.showAnnotations(cluster.memberAnnotations, animated: true)
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                return nil
            }

            if annotation is MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                    for: annotation
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
                )
                view.markerTintColor = .systemCyan
                view.glyphImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
                view.displayPriority = .defaultHigh
                view.canShowCallout = false

                // Remove existing tap gestures to avoid duplicates
                view.gestureRecognizers?.filter { $0 is UITapGestureRecognizer }.forEach {
                    view.removeGestureRecognizer($0)
                }

                let tap = UITapGestureRecognizer(target: self, action: #selector(clusterTapped(_:)))
                view.addGestureRecognizer(tap)

                return view
            }

            guard let trafficAnnotation = annotation as? TrafficAnnotation else {
                return nil
            }

            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: TrafficPinView.reuseIdentifier,
                for: annotation
            ) as? TrafficPinView ?? TrafficPinView(
                annotation: annotation,
                reuseIdentifier: TrafficPinView.reuseIdentifier
            )

            view.annotation = annotation
            view.clusteringIdentifier = "traffic"
            view.onDetail = { [weak self] in
                self?.onDetailTap?(trafficAnnotation.bubble)
            }

            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? TrafficPolyline, let segment = polyline.segmentData {
                let renderer = MKPolylineRenderer(polyline: polyline)

                // Lines show route topology only — we don't know per-link signal quality.
                // Opacity scales with traffic volume for visual weight.
                let opacity = 0.3 + 0.5 * segment.normalizedFrequency
                renderer.strokeColor = UIColor.systemCyan.withAlphaComponent(opacity)

                // Width scales from 2pt to 8pt based on traffic volume
                renderer.lineWidth = 2 + 6 * segment.normalizedFrequency
                renderer.lineDashPattern = [8, 4]

                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
            guard !isUpdatingFromSwiftUI else { return }

            if annotation is MKUserLocation { return }

            if let cluster = annotation as? MKClusterAnnotation {
                if let tapTime = lastClusterTapTime, Date().timeIntervalSince(tapTime) < 0.5 {
                    mapView.deselectAnnotation(cluster, animated: false)
                    return
                }
                mapView.deselectAnnotation(cluster, animated: false)
                hasPendingShowAnnotations = true
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
                return
            }

            guard let trafficAnnotation = annotation as? TrafficAnnotation else { return }

            Task { @MainActor in
                self.setSelectedAnnotation?(trafficAnnotation.bubble)
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect annotation: any MKAnnotation) {
            guard !isUpdatingFromSwiftUI else { return }

            Task { @MainActor in
                self.setSelectedAnnotation?(nil)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isUpdatingFromSwiftUI else { return }

            if hasPendingShowAnnotations {
                hasPendingShowAnnotations = false
                hasPendingProgrammaticRegion = false
                lastAppliedRegion = mapView.region
                pendingUserGestureRegion = mapView.region
                Task { @MainActor in
                    self.setCameraRegion?(mapView.region)
                }
                return
            }

            if hasPendingProgrammaticRegion {
                hasPendingProgrammaticRegion = false
                lastAppliedRegion = mapView.region
                return
            }

            guard hasAppliedInitialRegion else {
                lastAppliedRegion = mapView.region
                return
            }

            lastAppliedRegion = mapView.region
            pendingUserGestureRegion = mapView.region

            Task { @MainActor in
                self.setCameraRegion?(mapView.region)
            }
        }
    }
}

// MARK: - Traffic Polyline

/// MKPolyline subclass that carries segment metadata for styling.
final class TrafficPolyline: MKPolyline {
    var segmentData: TrafficSegmentData?
}
