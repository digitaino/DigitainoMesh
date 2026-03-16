import MapKit
import SwiftUI
import MC1Services

/// Custom annotation view for traffic map repeaters.
/// Same visual style as ContactPinView (colored circle + icon + pointer triangle)
/// but colored by SNR quality and always showing the repeater antenna icon.
final class TrafficPinView: MKAnnotationView {
    static let reuseIdentifier = "TrafficPinView"

    // MARK: - UI Components

    private let circleView = UIView()
    private let hexLabel = UILabel()
    private let triangleImageView = UIImageView()
    private var nameLabel: UILabel?
    private var nameLabelContainer: UIView?
    private var nameLabelShadow: UIView?
    private var hostingController: UIHostingController<TrafficCalloutContent>?

    // MARK: - Configuration

    var showsNameLabel: Bool = false {
        didSet { updateNameLabel() }
    }

    /// Callback when user taps "Details" in the callout
    var onDetail: (() -> Void)?

    // MARK: - Initialization

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupViews()
        canShowCallout = true
        clusteringIdentifier = "traffic"
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        // Configure circle
        circleView.translatesAutoresizingMaskIntoConstraints = false
        circleView.layer.shadowColor = UIColor.black.cgColor
        circleView.layer.shadowOpacity = 0.3
        circleView.layer.shadowRadius = 2
        circleView.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(circleView)

        // Configure hex label (shows first byte of public key)
        hexLabel.translatesAutoresizingMaskIntoConstraints = false
        hexLabel.textAlignment = .center
        hexLabel.textColor = .white
        hexLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        hexLabel.adjustsFontSizeToFitWidth = true
        hexLabel.minimumScaleFactor = 0.6
        circleView.addSubview(hexLabel)

        // Configure triangle pointer
        triangleImageView.translatesAutoresizingMaskIntoConstraints = false
        triangleImageView.contentMode = .scaleAspectFit
        triangleImageView.image = UIImage(systemName: "triangle.fill")
        triangleImageView.transform = CGAffineTransform(rotationAngle: .pi)
        addSubview(triangleImageView)

        // Initial layout for unselected state
        updateLayout(selected: false)
    }

    // MARK: - Configuration

    func configure(for bubble: TrafficBubbleAnnotation) {
        let color = UIColor(bubble.snrQuality.color)
        circleView.backgroundColor = color
        triangleImageView.tintColor = color

        // Show first byte of public key as hex
        if let firstByte = bubble.publicKey.first {
            hexLabel.text = firstByte.hexString
        }

        // Higher-traffic nodes get higher display priority
        displayPriority = bubble.normalizedTraffic > 0.5 ? .defaultHigh : .defaultLow

        updateLayout(selected: isSelected)
    }

    // MARK: - Selection

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseInOut) {
                self.updateLayout(selected: selected)
            }
        } else {
            updateLayout(selected: selected)
        }

        updateNameLabel()

        if selected, let trafficAnnotation = annotation as? TrafficAnnotation {
            configureCalloutContent(for: trafficAnnotation.bubble)
        }
    }

    private func configureCalloutContent(for bubble: TrafficBubbleAnnotation) {
        let calloutContent = TrafficCalloutContent(
            bubble: bubble,
            onDetail: { [weak self] in self?.onDetail?() }
        )

        let hosting = UIHostingController(rootView: calloutContent)
        hosting.view.backgroundColor = .clear

        let size = hosting.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        hosting.view.frame = CGRect(origin: .zero, size: size)

        detailCalloutAccessoryView = hosting.view
        hostingController = hosting
    }

    // MARK: - Layout

    private func updateLayout(selected: Bool) {
        let circleSize: CGFloat = selected ? 44 : 36
        let labelSize: CGFloat = selected ? 28 : 24
        let triangleSize: CGFloat = 10

        // Remove existing constraints
        circleView.constraints.forEach { circleView.removeConstraint($0) }
        hexLabel.constraints.forEach { hexLabel.removeConstraint($0) }
        triangleImageView.constraints.forEach { triangleImageView.removeConstraint($0) }

        // Update hex label font size
        hexLabel.font = .monospacedSystemFont(ofSize: selected ? 15 : 12, weight: .bold)

        // Circle constraints
        NSLayoutConstraint.activate([
            circleView.widthAnchor.constraint(equalToConstant: circleSize),
            circleView.heightAnchor.constraint(equalToConstant: circleSize),
            circleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            circleView.topAnchor.constraint(equalTo: topAnchor)
        ])

        // Hex label constraints
        NSLayoutConstraint.activate([
            hexLabel.widthAnchor.constraint(equalToConstant: labelSize),
            hexLabel.heightAnchor.constraint(equalToConstant: labelSize),
            hexLabel.centerXAnchor.constraint(equalTo: circleView.centerXAnchor),
            hexLabel.centerYAnchor.constraint(equalTo: circleView.centerYAnchor)
        ])

        // Triangle constraints
        NSLayoutConstraint.activate([
            triangleImageView.widthAnchor.constraint(equalToConstant: triangleSize),
            triangleImageView.heightAnchor.constraint(equalToConstant: triangleSize),
            triangleImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            triangleImageView.topAnchor.constraint(equalTo: circleView.bottomAnchor, constant: -3)
        ])

        circleView.layer.cornerRadius = circleSize / 2

        if selected {
            circleView.layer.borderWidth = 3
            circleView.layer.borderColor = UIColor.white.cgColor
        } else {
            circleView.layer.borderWidth = 0
        }

        let totalHeight = circleSize + triangleSize - 3
        frame = CGRect(x: 0, y: 0, width: circleSize, height: totalHeight)
        centerOffset = CGPoint(x: 0, y: -totalHeight / 2)
    }

    // MARK: - Name Label

    private func updateNameLabel() {
        if showsNameLabel && !isSelected {
            if nameLabel == nil {
                let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
                blur.translatesAutoresizingMaskIntoConstraints = false
                blur.layer.cornerRadius = 8
                blur.layer.masksToBounds = true
                addSubview(blur)

                let shadow = UIView()
                shadow.translatesAutoresizingMaskIntoConstraints = false
                shadow.backgroundColor = .clear
                shadow.layer.shadowColor = UIColor.black.cgColor
                shadow.layer.shadowOpacity = 0.3
                shadow.layer.shadowRadius = 3
                shadow.layer.shadowOffset = CGSize(width: 0, height: 1.5)
                insertSubview(shadow, belowSubview: blur)
                nameLabelContainer = blur
                nameLabelShadow = shadow

                let label = UILabel()
                let baseFont = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .medium)
                label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: baseFont)
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .label
                label.textAlignment = .center
                label.translatesAutoresizingMaskIntoConstraints = false
                blur.contentView.addSubview(label)
                nameLabel = label

                NSLayoutConstraint.activate([
                    blur.centerXAnchor.constraint(equalTo: centerXAnchor),
                    blur.bottomAnchor.constraint(equalTo: topAnchor, constant: -4),
                    shadow.topAnchor.constraint(equalTo: blur.topAnchor),
                    shadow.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
                    shadow.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                    shadow.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                    label.topAnchor.constraint(equalTo: blur.topAnchor, constant: 4),
                    label.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -4),
                    label.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 8),
                    label.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -8)
                ])
            }

            if let trafficAnnotation = annotation as? TrafficAnnotation {
                nameLabel?.text = trafficAnnotation.bubble.name
            }
            nameLabelContainer?.isHidden = false
            nameLabelShadow?.isHidden = false
        } else {
            nameLabelContainer?.isHidden = true
            nameLabelShadow?.isHidden = true
        }
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        onDetail = nil
        hostingController = nil
        detailCalloutAccessoryView = nil
        nameLabelContainer?.isHidden = true
        nameLabelShadow?.isHidden = true
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        if let trafficAnnotation = annotation as? TrafficAnnotation {
            configure(for: trafficAnnotation.bubble)
        }
    }
}

// MARK: - Traffic Callout Content

/// SwiftUI content displayed in the native MKAnnotationView callout for traffic pins.
struct TrafficCalloutContent: View {
    let bubble: TrafficBubbleAnnotation
    let onDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Public key prefix
            Text(bubble.publicKey.prefix(3).map { $0.hexString }.joined(separator: " "))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)

            // Packet count
            HStack(spacing: 6) {
                Image(systemName: "wave.3.right")
                    .foregroundStyle(bubble.snrQuality.color)
                Text("\(bubble.packetCount) packets")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // SNR if available
            if let snr = bubble.averageSNR {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(bubble.snrQuality.color)
                    Text(String(format: "%.1f dB SNR", snr))
                        .font(.subheadline)
                        .foregroundStyle(bubble.snrQuality.color)
                }
            }

            // Last seen
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text(bubble.lastSeen, style: .relative)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Details", systemImage: "info.circle", action: onDetail)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(width: 180)
    }
}
