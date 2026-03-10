import MapKit
import PocketMeshServices
import UIKit

/// Custom annotation view that renders a sized, colored circle representing
/// repeater traffic volume and average signal quality.
/// Names are shown via native MapKit callouts (tap to see), not custom labels.
final class TrafficBubblePinView: MKAnnotationView {
    static let reuseIdentifier = "TrafficBubblePinView"

    // MARK: - Constants

    private static let minSize: CGFloat = 24
    private static let maxSize: CGFloat = 56

    // MARK: - UI Components

    private let bubbleView = UIView()
    private let countLabel = UILabel()

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

    func configure(for annotation: TrafficBubbleAnnotation) {
        let size = Self.minSize + (Self.maxSize - Self.minSize) * annotation.normalizedTraffic
        sizeConstraintWidth?.constant = size
        sizeConstraintHeight?.constant = size
        bubbleView.layer.cornerRadius = size / 2

        // Color based on SNR quality
        bubbleView.backgroundColor = uiColor(for: annotation.snrQuality)

        // Count text
        countLabel.text = formatCount(annotation.packetCount)

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

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        accessibilityLabel = nil
    }
}
