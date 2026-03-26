import MapKit
import UIKit
import MC1Services

/// Marker annotation view for repeaters in trace path and route maps.
/// Uses Apple's native MKMarkerAnnotationView balloon with built-in
/// title/subtitle visibility and collision avoidance.
final class TracePathRepeaterPinView: MKMarkerAnnotationView {
    static let reuseID = "TracePathRepeaterPin"
    static let clusteringID = "repeater"

    // MARK: - Tap Handling

    var onTap: (() -> Void)?

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
        markerTintColor = .systemCyan
        glyphImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
        titleVisibility = .adaptive
        animatesWhenAdded = false

        // Tap gesture fires immediately, bypassing MapKit's ~300ms selection delay
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tapGesture)
    }

    @objc private func handleTap() {
        onTap?()
    }

    // MARK: - Configuration

    func configure(
        for repeater: ContactDTO,
        inPath: Bool,
        hopIndex: Int?,
        isLastHop: Bool,
        titleMode: AnnotationLabelMode = .name
    ) {
        configure(
            displayName: repeater.displayName,
            inPath: inPath,
            hopIndex: hopIndex,
            isLastHop: isLastHop,
            titleMode: titleMode
        )
    }

    func configure(
        displayName: String,
        inPath: Bool,
        hopIndex: Int?,
        isLastHop: Bool,
        titleMode: AnnotationLabelMode = .name
    ) {
        // Clustering: in-path pins are always visible, others cluster
        if inPath {
            clusteringIdentifier = nil
            displayPriority = .required
        } else {
            clusteringIdentifier = Self.clusteringID
            displayPriority = .defaultLow
        }

        // Marker color: selected (in-path) vs default
        markerTintColor = inPath ? .systemBlue : .systemCyan

        // Glyph: show hop number when in path, antenna icon otherwise
        if let index = hopIndex {
            glyphText = "\(index)"
            glyphImage = nil
        } else {
            glyphText = nil
            glyphImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
        }

        // Title visibility based on label mode
        applyTitleMode(titleMode)

        // Accessibility
        isAccessibilityElement = true
        if inPath {
            if isLastHop {
                accessibilityLabel = L10n.Contacts.Contacts.Trace.Map.Pin.inPathLabel(displayName, hopIndex ?? 0)
                accessibilityHint = L10n.Contacts.Contacts.Trace.Map.Pin.removableHint
                accessibilityTraits = [.button, .selected]
            } else {
                accessibilityLabel = L10n.Contacts.Contacts.Trace.Map.Pin.inPathLabel(displayName, hopIndex ?? 0)
                accessibilityHint = L10n.Contacts.Contacts.Trace.Map.Pin.notRemovableHint
                accessibilityTraits = [.button, .selected, .notEnabled]
            }
        } else {
            accessibilityLabel = L10n.Contacts.Contacts.Trace.Map.Pin.availableLabel(displayName)
            accessibilityHint = L10n.Contacts.Contacts.Trace.Map.Pin.addHint
            accessibilityTraits = .button
        }
    }

    // MARK: - Title Mode

    func applyTitleMode(_ mode: AnnotationLabelMode) {
        switch mode {
        case .hidden:
            titleVisibility = .hidden
        case .hexShort, .name:
            titleVisibility = .adaptive
        }
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
        markerTintColor = .systemCyan
        glyphText = nil
        glyphImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
        titleVisibility = .adaptive
        clusteringIdentifier = Self.clusteringID
        displayPriority = .defaultLow
        accessibilityLabel = nil
        accessibilityHint = nil
    }
}
