import MapKit
import UIKit

/// Marker annotation view for sender/receiver endpoints on route maps.
/// Uses Apple's native MKMarkerAnnotationView balloon with built-in
/// title visibility and collision avoidance.
final class RouteEndpointPinView: MKMarkerAnnotationView {
    static let reuseID = "RouteEndpointPin"

    // MARK: - Initialization

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupMarker()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupMarker() {
        titleVisibility = .adaptive
        subtitleVisibility = .hidden
        animatesWhenAdded = false
        clusteringIdentifier = nil
        displayPriority = .required
    }

    // MARK: - Configuration

    func configure(for endpoint: RouteEndpointAnnotation, titleMode: AnnotationLabelMode = .name) {
        switch endpoint.endpointType {
        case .sender:
            markerTintColor = .systemTeal
            glyphImage = UIImage(systemName: "person.wave.2")
        case .receiver:
            markerTintColor = .systemBlue
            glyphImage = UIImage(systemName: "iphone.gen3")
        }

        applyTitleMode(titleMode)

        // Accessibility
        isAccessibilityElement = true
        accessibilityLabel = endpoint.title
        accessibilityTraits = .staticText
    }

    // MARK: - Title Mode

    func applyTitleMode(_ mode: AnnotationLabelMode) {
        switch mode {
        case .hidden:
            titleVisibility = .hidden
        case .hexShort, .name:
            // Endpoints are people, not mesh repeaters — always show name
            titleVisibility = .adaptive
        }
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        markerTintColor = nil
        glyphImage = nil
        titleVisibility = .adaptive
        accessibilityLabel = nil
    }
}
