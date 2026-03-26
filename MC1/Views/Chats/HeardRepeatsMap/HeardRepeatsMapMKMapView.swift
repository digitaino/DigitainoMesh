import MapKit
import MC1Services
import SwiftUI

/// UIViewRepresentable for the heard repeats map.
/// Displays repeater pins for outbound chain hops,
/// neutral-colored line overlays between consecutive hops (with arrowheads),
/// SNR-colored last-hop lines from the heard repeater to the user, and
/// a receiver endpoint pin at the user's location.
struct HeardRepeatsMapMKMapView: UIViewRepresentable {
    let repeaterAnnotations: [RepeaterAnnotation]
    let endpointAnnotations: [RouteEndpointAnnotation]
    let lineOverlays: [PathLineOverlay]
    let mapType: MKMapType
    let pathState: [UUID: HeardRepeatsMapViewModel.PathInfo]
    /// SNR quality for last-hop overlays (keyed by overlay segmentIndex)
    let lastHopSNR: [Int: SNRQuality]
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
        coordinator.lastHopSNR = lastHopSNR
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
        let currentRepeaterIDs = Set(currentRepeaters.map { $0.annotationID })
        let newRepeaterIDs = Set(repeaterAnnotations.map { $0.annotationID })

        let repeatersToRemove = currentRepeaters.filter { !newRepeaterIDs.contains($0.annotationID) }
        mapView.removeAnnotations(repeatersToRemove)

        let existingRepeaterIDs = currentRepeaterIDs.subtracting(Set(repeatersToRemove.map { $0.annotationID }))
        let repeatersToAdd = repeaterAnnotations.filter { !existingRepeaterIDs.contains($0.annotationID) }
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

        var pathState: [UUID: HeardRepeatsMapViewModel.PathInfo] = [:]
        var lastHopSNR: [Int: SNRQuality] = [:]
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

                let info = pathState[repeaterAnnotation.annotationID]
                view.configure(
                    displayName: repeaterAnnotation.displayName,
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

                // Check if this is a last-hop overlay (has SNR data)
                if let snrQuality = lastHopSNR[pathOverlay.segmentIndex] {
                    // Color by SNR quality
                    switch snrQuality {
                    case .excellent, .good:
                        renderer.strokeColor = .systemGreen
                    case .fair:
                        renderer.strokeColor = .systemYellow
                    case .poor, .veryPoor:
                        renderer.strokeColor = .systemRed
                    case .unknown:
                        renderer.strokeColor = .systemGray
                    }
                    renderer.lineWidth = 4
                } else {
                    // Neutral outbound chain
                    renderer.strokeColor = .systemBlue
                    renderer.lineWidth = 3
                    renderer.lineDashPattern = [8, 4]
                }

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
