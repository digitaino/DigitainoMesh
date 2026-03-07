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
    let showLabels: Bool
    let pathState: [UUID: MessageRouteMapViewModel.PathInfo]

    @Binding var cameraRegion: MKCoordinateRegion?
    let cameraRegionVersion: Int

    func makeUIView(context: Context) -> MKMapView {
        let mapView = context.coordinator.mapView
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true

        mapView.register(
            TracePathRepeaterPinView.self,
            forAnnotationViewWithReuseIdentifier: TracePathRepeaterPinView.reuseIdentifier
        )
        mapView.register(
            RouteEndpointPinView.self,
            forAnnotationViewWithReuseIdentifier: RouteEndpointPinView.reuseIdentifier
        )

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator

        coordinator.isUpdatingFromSwiftUI = true
        defer { coordinator.isUpdatingFromSwiftUI = false }

        coordinator.pathState = pathState
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
        // Update repeater annotations
        let currentRepeaters = mapView.annotations.compactMap { $0 as? RepeaterAnnotation }
        let currentRepeaterIDs = Set(currentRepeaters.map { $0.repeater.id })
        let newRepeaterIDs = Set(repeaterAnnotations.map { $0.repeater.id })

        let repeatersToRemove = currentRepeaters.filter { !newRepeaterIDs.contains($0.repeater.id) }
        mapView.removeAnnotations(repeatersToRemove)

        let existingRepeaterIDs = currentRepeaterIDs.subtracting(Set(repeatersToRemove.map { $0.repeater.id }))
        let repeatersToAdd = repeaterAnnotations.filter { !existingRepeaterIDs.contains($0.repeater.id) }
        mapView.addAnnotations(repeatersToAdd)

        // Update endpoint annotations
        let currentEndpoints = mapView.annotations.compactMap { $0 as? RouteEndpointAnnotation }
        let newEndpointIdentities = Set(endpointAnnotations.map { ObjectIdentifier($0) })
        let currentEndpointIdentities = Set(currentEndpoints.map { ObjectIdentifier($0) })

        if newEndpointIdentities != currentEndpointIdentities {
            mapView.removeAnnotations(currentEndpoints)
            mapView.addAnnotations(endpointAnnotations)
        }

        // Update visible pin views
        for annotation in mapView.annotations.compactMap({ $0 as? RepeaterAnnotation }) {
            guard let view = mapView.view(for: annotation) as? TracePathRepeaterPinView else {
                continue
            }
            let info = pathState[annotation.repeater.id]
            view.configure(
                for: annotation.repeater,
                inPath: true,
                hopIndex: info?.hopIndex,
                isLastHop: false,
                showLabel: showLabels
            )
        }

        for annotation in mapView.annotations.compactMap({ $0 as? RouteEndpointAnnotation }) {
            guard let view = mapView.view(for: annotation) as? RouteEndpointPinView else {
                continue
            }
            view.configure(for: annotation, showLabel: showLabels)
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

            if let endpointAnnotation = annotation as? RouteEndpointAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: RouteEndpointPinView.reuseIdentifier,
                    for: annotation
                ) as? RouteEndpointPinView ?? RouteEndpointPinView(
                    annotation: annotation,
                    reuseIdentifier: RouteEndpointPinView.reuseIdentifier
                )
                view.configure(for: endpointAnnotation, showLabel: showLabels)
                return view
            }

            if let repeaterAnnotation = annotation as? RepeaterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: TracePathRepeaterPinView.reuseIdentifier,
                    for: annotation
                ) as? TracePathRepeaterPinView ?? TracePathRepeaterPinView(
                    annotation: annotation,
                    reuseIdentifier: TracePathRepeaterPinView.reuseIdentifier
                )

                let info = pathState[repeaterAnnotation.repeater.id]
                view.configure(
                    for: repeaterAnnotation.repeater,
                    inPath: true,
                    hopIndex: info?.hopIndex,
                    isLastHop: false,
                    showLabel: showLabels
                )

                return view
            }

            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let pathOverlay = overlay as? PathLineOverlay {
                return PathLineRenderer(overlay: pathOverlay)
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
