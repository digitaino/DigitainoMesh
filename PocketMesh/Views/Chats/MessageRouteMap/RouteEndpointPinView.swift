import MapKit
import UIKit

/// Custom pin view for sender/receiver endpoints on the message route map.
/// Follows the same UIKit construction pattern as `TracePathRepeaterPinView`.
final class RouteEndpointPinView: MKAnnotationView {
    static let reuseIdentifier = "RouteEndpointPinView"

    // MARK: - UI Components

    private let circleView = UIView()
    private let iconImageView = UIImageView()
    private let triangleImageView = UIImageView()
    private var nameLabel: UILabel?
    private var nameLabelContainer: UIView?
    private var nameLabelPositionConstraint: NSLayoutConstraint?
    private var currentLabelPosition: TracePathRepeaterPinView.LabelPosition = .above

    // MARK: - Initialization

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        let circleSize: CGFloat = 36
        let iconSize: CGFloat = 16
        let triangleSize: CGFloat = 10

        // Circle
        circleView.translatesAutoresizingMaskIntoConstraints = false
        circleView.layer.cornerRadius = circleSize / 2
        circleView.layer.shadowColor = UIColor.black.cgColor
        circleView.layer.shadowOpacity = 0.3
        circleView.layer.shadowRadius = 2
        circleView.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(circleView)

        // Icon
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.tintColor = .white
        circleView.addSubview(iconImageView)

        // Triangle
        triangleImageView.translatesAutoresizingMaskIntoConstraints = false
        triangleImageView.contentMode = .scaleAspectFit
        triangleImageView.image = UIImage(systemName: "triangle.fill")
        triangleImageView.transform = CGAffineTransform(rotationAngle: .pi)
        addSubview(triangleImageView)

        NSLayoutConstraint.activate([
            // Circle
            circleView.widthAnchor.constraint(equalToConstant: circleSize),
            circleView.heightAnchor.constraint(equalToConstant: circleSize),
            circleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            circleView.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            // Icon
            iconImageView.widthAnchor.constraint(equalToConstant: iconSize),
            iconImageView.heightAnchor.constraint(equalToConstant: iconSize),
            iconImageView.centerXAnchor.constraint(equalTo: circleView.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: circleView.centerYAnchor),

            // Triangle
            triangleImageView.widthAnchor.constraint(equalToConstant: triangleSize),
            triangleImageView.heightAnchor.constraint(equalToConstant: triangleSize),
            triangleImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            triangleImageView.topAnchor.constraint(equalTo: circleView.bottomAnchor, constant: -3)
        ])

        let totalHeight = circleSize + triangleSize + 4
        frame = CGRect(x: 0, y: 0, width: circleSize, height: totalHeight)
        centerOffset = CGPoint(x: 0, y: -totalHeight / 2)

        canShowCallout = false
        clusteringIdentifier = nil
        displayPriority = .required
    }

    // MARK: - Configuration

    func configure(
        for endpoint: RouteEndpointAnnotation,
        showLabel: Bool,
        labelPosition: TracePathRepeaterPinView.LabelPosition = .above
    ) {
        switch endpoint.endpointType {
        case .sender:
            circleView.backgroundColor = .systemTeal
            triangleImageView.tintColor = .systemTeal
            iconImageView.image = UIImage(systemName: "person.wave.2")
        case .receiver:
            circleView.backgroundColor = .systemBlue
            triangleImageView.tintColor = .systemBlue
            iconImageView.image = UIImage(systemName: "iphone.gen3")
        }

        if showLabel, let name = endpoint.title {
            showNameLabel(name, position: labelPosition)
        } else {
            hideNameLabel()
        }

        // Accessibility
        isAccessibilityElement = true
        accessibilityLabel = endpoint.title
        accessibilityTraits = .staticText
    }

    // MARK: - Name Label

    private func showNameLabel(_ name: String, position: TracePathRepeaterPinView.LabelPosition = .above) {
        if nameLabelContainer == nil {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            blur.translatesAutoresizingMaskIntoConstraints = false
            blur.layer.cornerRadius = 8
            blur.layer.masksToBounds = true
            addSubview(blur)

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            let baseFont = UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                weight: .medium
            )
            label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: baseFont)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .label
            label.textAlignment = .center
            blur.contentView.addSubview(label)

            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: blur.topAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -4),
                label.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -8),
                blur.centerXAnchor.constraint(equalTo: circleView.centerXAnchor)
            ])

            nameLabelContainer = blur
            nameLabel = label
            currentLabelPosition = position
            applyLabelPositionConstraint(position, container: blur)
        } else if position != currentLabelPosition {
            currentLabelPosition = position
            if let container = nameLabelContainer {
                nameLabelPositionConstraint?.isActive = false
                applyLabelPositionConstraint(position, container: container)
            }
        }

        nameLabel?.text = name
        nameLabelContainer?.isHidden = false
    }

    private func applyLabelPositionConstraint(
        _ position: TracePathRepeaterPinView.LabelPosition,
        container: UIView
    ) {
        let constraint: NSLayoutConstraint
        switch position {
        case .above:
            constraint = container.bottomAnchor.constraint(equalTo: circleView.topAnchor, constant: -4)
        case .below:
            constraint = container.topAnchor.constraint(equalTo: triangleImageView.bottomAnchor, constant: 4)
        }
        constraint.isActive = true
        nameLabelPositionConstraint = constraint
    }

    private func hideNameLabel() {
        nameLabelContainer?.isHidden = true
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        hideNameLabel()
        nameLabelPositionConstraint?.isActive = false
        nameLabelPositionConstraint = nil
        currentLabelPosition = .above
        accessibilityLabel = nil
    }
}
