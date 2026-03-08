import MapKit
import PocketMeshServices
import UIKit

/// Renderer for TrafficSegmentOverlay that draws lines with width and opacity
/// proportional to segment traffic frequency.
final class TrafficSegmentRenderer: MKPolylineRenderer {

    /// When true, draws a directional arrowhead at the midpoint of the segment.
    var showArrowhead = false

    override init(overlay: any MKOverlay) {
        super.init(overlay: overlay)
        configureAppearance()
    }

    private func configureAppearance() {
        guard let segment = overlay as? TrafficSegmentOverlay else { return }

        // Width: 2pt (min) to 8pt (max) based on normalized frequency
        lineWidth = 2 + 6 * segment.normalizedFrequency

        // Color: direction-aware or SNR-based
        let baseColor: UIColor
        switch segment.direction {
        case .inbound:
            baseColor = .systemBlue
        case .outbound:
            baseColor = .systemGreen
        case .bidirectional, .unspecified:
            // Fall back to SNR-based coloring
            let quality = SNRQuality(snr: segment.averageSNR)
            switch quality {
            case .excellent, .good:
                baseColor = .systemGreen
            case .fair:
                baseColor = .systemYellow
            case .poor, .veryPoor:
                baseColor = .systemRed
            case .unknown:
                baseColor = .systemGray
            }
        }

        // Alpha: 0.4 (min) to 1.0 (max) based on normalized frequency
        let alpha = 0.4 + 0.6 * segment.normalizedFrequency
        strokeColor = baseColor.withAlphaComponent(alpha)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        super.draw(mapRect, zoomScale: zoomScale, in: context)

        guard showArrowhead,
              let segment = overlay as? TrafficSegmentOverlay else { return }

        // Reset clip path so the arrowhead can draw outside the polyline stroke area
        context.resetClip()

        let arrowColor = strokeColor ?? .systemGray
        ArrowheadDrawing.drawArrowhead(
            from: segment.startCoordinate,
            to: segment.endCoordinate,
            color: arrowColor,
            lineWidth: lineWidth,
            zoomScale: zoomScale,
            in: context,
            renderer: self
        )
    }
}
