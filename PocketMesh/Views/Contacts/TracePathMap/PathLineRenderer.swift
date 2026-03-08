import MapKit
import UIKit

/// Renderer for PathLineOverlay that draws dashed or solid colored lines
/// Note: Since PathLineOverlay is immutable, create new overlays when signal quality changes
/// rather than calling updateAppearance on existing renderers
final class PathLineRenderer: MKPolylineRenderer {

    /// When true, draws a directional arrowhead at the midpoint of the segment.
    var showArrowhead = false

    override init(overlay: any MKOverlay) {
        super.init(overlay: overlay)
        configureAppearance()
    }

    private func configureAppearance() {
        guard let pathOverlay = overlay as? PathLineOverlay else { return }

        switch pathOverlay.signalQuality {
        case .untraced:
            strokeColor = UIColor.systemGray
            lineWidth = 2
            lineDashPattern = [8, 6]

        case .good:
            strokeColor = UIColor.systemGreen
            lineWidth = 4  // Thicker for accessibility (color-blind users)
            lineDashPattern = nil

        case .medium:
            strokeColor = UIColor.systemYellow
            lineWidth = 3
            lineDashPattern = [12, 4]  // Different pattern for accessibility

        case .weak:
            strokeColor = UIColor.systemRed
            lineWidth = 3
            lineDashPattern = [4, 4]  // Different pattern for accessibility
        }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        super.draw(mapRect, zoomScale: zoomScale, in: context)

        guard showArrowhead,
              let pathOverlay = overlay as? PathLineOverlay else { return }

        // Reset clip path so the arrowhead can draw outside the polyline stroke area
        context.resetClip()

        let arrowColor = strokeColor ?? .systemGray
        ArrowheadDrawing.drawArrowhead(
            from: pathOverlay.startCoordinate,
            to: pathOverlay.endCoordinate,
            color: arrowColor,
            lineWidth: lineWidth,
            zoomScale: zoomScale,
            in: context,
            renderer: self
        )
    }
}
