import MapKit
import SwiftUI
import MC1Services

/// Custom annotation view displaying a colored circle with a contact-type icon and a
/// pointer triangle. Shared circle/triangle/name-label/callout chrome lives in
/// `CircularAnnotationView`; this subclass supplies the icon, colors, and callout.
final class ContactPinView: CircularAnnotationView {
    static let reuseIdentifier = "ContactPinView"

    // MARK: - UI Components

    private let iconImageView = UIImageView()

    // MARK: - Configuration

    /// Callbacks for callout actions
    var onDetail: (() -> Void)?
    var onMessage: (() -> Void)?

    // MARK: - Initialization

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        iconImageView.contentMode = .scaleAspectFit
        iconImageView.tintColor = .white
        setCenterContent(iconImageView)

        clusteringIdentifier = "contact"
        updateLayout(selected: false)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    func configure(for contact: ContactDTO) {
        // Set colors based on contact type
        let backgroundColor = pinColor(for: contact)
        circleView.backgroundColor = backgroundColor
        triangleImageView.tintColor = backgroundColor

        // Set icon
        iconImageView.image = UIImage(systemName: iconName(for: contact))

        // Set display priority
        displayPriority = contact.isFavorite ? .defaultHigh : .defaultLow

        // Update layout
        updateLayout(selected: isSelected)
    }

    // MARK: - Base Overrides

    override func centerContentSize(selected: Bool) -> CGSize {
        let size: CGFloat = selected ? 20 : 16
        return CGSize(width: size, height: size)
    }

    override func nameLabelText() -> String? {
        (annotation as? ContactAnnotation)?.contact.displayName
    }

    override func configureCalloutForSelection() {
        guard let contact = (annotation as? ContactAnnotation)?.contact else { return }
        installCallout(
            ContactCalloutContent(
                contact: contact,
                onDetail: { [weak self] in self?.onDetail?() },
                onMessage: { [weak self] in self?.onMessage?() }
            )
        )
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        onDetail = nil
        onMessage = nil
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()

        if let contact = (annotation as? ContactAnnotation)?.contact {
            configure(for: contact)
        }
    }

    // MARK: - Helpers

    private func pinColor(for contact: ContactDTO) -> UIColor {
        switch contact.type {
        case .chat:
            UIColor(red: 204.0 / 255.0, green: 122.0 / 255.0, blue: 92.0 / 255.0, alpha: 1) // coral #cc7a5c
        case .repeater:
            UIColor(red: 0, green: 170.0 / 255.0, blue: 1, alpha: 1) // MeshCore cyan #00aaff
        case .room:
            UIColor(red: 1, green: 136.0 / 255.0, blue: 0, alpha: 1) // orange #ff8800 (matches Nodes)
        }
    }

    private func iconName(for contact: ContactDTO) -> String {
        switch contact.type {
        case .chat:
            "person.fill"
        case .repeater:
            "antenna.radiowaves.left.and.right"
        case .room:
            "person.3.fill"
        }
    }
}
