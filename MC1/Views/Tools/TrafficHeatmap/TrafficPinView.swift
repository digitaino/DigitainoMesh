import MapKit
import SwiftUI
import MC1Services

/// Custom annotation view for traffic map repeaters.
/// Same visual style as ContactPinView (colored circle + center glyph + pointer triangle)
/// via the shared `CircularAnnotationView`, but the circle is colored by SNR quality and
/// shows the first byte of the public key as a hex label instead of an icon.
final class TrafficPinView: CircularAnnotationView {
    static let reuseIdentifier = "TrafficPinView"

    // MARK: - UI Components

    private let hexLabel = UILabel()

    // MARK: - Configuration

    /// Callback when user taps "Details" in the callout
    var onDetail: (() -> Void)?

    // MARK: - Initialization

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        // Configure hex label (shows first byte of public key)
        hexLabel.textAlignment = .center
        hexLabel.textColor = .white
        hexLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        hexLabel.adjustsFontSizeToFitWidth = true
        hexLabel.minimumScaleFactor = 0.6
        setCenterContent(hexLabel)

        clusteringIdentifier = "traffic"
        updateLayout(selected: false)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    // MARK: - Base Overrides

    override func centerContentSize(selected: Bool) -> CGSize {
        let size: CGFloat = selected ? 28 : 24
        return CGSize(width: size, height: size)
    }

    override func updateLayout(selected: Bool) {
        // Scale the hex label font with selection before applying shared geometry
        hexLabel.font = .monospacedSystemFont(ofSize: selected ? 15 : 12, weight: .bold)
        super.updateLayout(selected: selected)
    }

    override func nameLabelText() -> String? {
        (annotation as? TrafficAnnotation)?.bubble.name
    }

    override func configureCalloutForSelection() {
        guard let bubble = (annotation as? TrafficAnnotation)?.bubble else { return }
        installCallout(
            TrafficCalloutContent(
                bubble: bubble,
                onDetail: { [weak self] in self?.onDetail?() }
            )
        )
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        onDetail = nil
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        if let bubble = (annotation as? TrafficAnnotation)?.bubble {
            configure(for: bubble)
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
