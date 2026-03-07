import MapKit
import PocketMeshServices
import UIKit

/// Custom annotation view that renders a sized, colored circle representing
/// repeater traffic volume and average signal quality.
final class TrafficBubblePinView: MKAnnotationView {
    static let reuseIdentifier = "TrafficBubblePinView"

    // MARK: - Constants

    private static let minSize: CGFloat = 24
    private static let maxSize: CGFloat = 56

    // MARK: - UI Components

    private let bubbleView = UIView()
    private let countLabel = UILabel()
    private var nameLabel: UILabel?
    private var nameLabelContainer: UIView?

    private var sizeConstraintWidth: NSLayoutConstraint?
    private var sizeConstraintHeight: NSLayoutConstraint?

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
        // Bubble circle
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.layer.shadowColor = UIColor.black.cgColor
        bubbleView.layer.shadowOpacity = 0.25
        bubbleView.layer.shadowRadius = 3
        bubbleView.layer.shadowOffset = CGSize(width: 0, height: 2)
        bubbleView.layer.borderWidth = 2
        bubbleView.layer.borderColor = UIColor.white.cgColor
        addSubview(bubbleView)

        // Packet count label inside bubble
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        let baseFont = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .bold
        )
        countLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: baseFont)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .white
        countLabel.textAlignment = .center
        countLabel.minimumScaleFactor = 0.5
        countLabel.adjustsFontSizeToFitWidth = true
        bubbleView.addSubview(countLabel)

        let widthConstraint = bubbleView.widthAnchor.constraint(equalToConstant: Self.minSize)
        let heightConstraint = bubbleView.heightAnchor.constraint(equalToConstant: Self.minSize)
        sizeConstraintWidth = widthConstraint
        sizeConstraintHeight = heightConstraint

        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,
            bubbleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            bubbleView.centerYAnchor.constraint(equalTo: centerYAnchor),

            countLabel.centerXAnchor.constraint(equalTo: bubbleView.centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: bubbleView.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: bubbleView.leadingAnchor, constant: 2),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: bubbleView.trailingAnchor, constant: -2)
        ])

        frame = CGRect(x: 0, y: 0, width: Self.maxSize, height: Self.maxSize)
        centerOffset = .zero

        canShowCallout = true
        clusteringIdentifier = nil
        displayPriority = .defaultHigh
    }

    // MARK: - Configuration

    func configure(for annotation: TrafficBubbleAnnotation, showLabel: Bool) {
        let size = Self.minSize + (Self.maxSize - Self.minSize) * annotation.normalizedTraffic
        sizeConstraintWidth?.constant = size
        sizeConstraintHeight?.constant = size
        bubbleView.layer.cornerRadius = size / 2

        // Color based on SNR quality
        bubbleView.backgroundColor = uiColor(for: annotation.snrQuality)

        // Count text
        countLabel.text = formatCount(annotation.packetCount)

        // Name label
        if showLabel {
            showNameLabel(annotation.name)
        } else {
            hideNameLabel()
        }

        // Accessibility
        isAccessibilityElement = true
        accessibilityLabel = L10n.Tools.Tools.TrafficMap.bubbleAccessibility(
            annotation.name,
            annotation.packetCount,
            annotation.snrQuality.qualityLabel
        )
        accessibilityTraits = .button

        setNeedsLayout()
    }

    // MARK: - Color Mapping

    private func uiColor(for quality: SNRQuality) -> UIColor {
        switch quality {
        case .excellent, .good: .systemGreen
        case .fair: .systemYellow
        case .poor, .veryPoor: .systemRed
        case .unknown: .systemGray
        }
    }

    // MARK: - Count Formatting

    private func formatCount(_ count: Int) -> String {
        if count >= 1000 {
            return "\(count / 1000)k"
        }
        return "\(count)"
    }

    // MARK: - Name Label

    private func showNameLabel(_ name: String) {
        if nameLabelContainer == nil {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            blur.translatesAutoresizingMaskIntoConstraints = false
            blur.layer.cornerRadius = 8
            blur.layer.masksToBounds = true
            addSubview(blur)

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            let font = UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                weight: .medium
            )
            label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: font)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .label
            label.textAlignment = .center
            blur.contentView.addSubview(label)

            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: blur.topAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -4),
                label.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -8),
                blur.centerXAnchor.constraint(equalTo: bubbleView.centerXAnchor),
                blur.bottomAnchor.constraint(equalTo: bubbleView.topAnchor, constant: -4)
            ])

            nameLabelContainer = blur
            nameLabel = label
        }

        nameLabel?.text = name
        nameLabelContainer?.isHidden = false
    }

    private func hideNameLabel() {
        nameLabelContainer?.isHidden = true
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        hideNameLabel()
        accessibilityLabel = nil
    }
}
