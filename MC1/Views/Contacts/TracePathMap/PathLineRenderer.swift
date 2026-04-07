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

        // Gap segments (unlocated hops skipped) — dashed orange
        if pathOverlay.isGap {
            strokeColor = UIColor.systemOrange
            lineWidth = 2
            lineDashPattern = [4, 8]
            return
        }

        guard let quality = pathOverlay.signalQuality else {
            // Untraced — dashed gray
            strokeColor = UIColor.systemGray
            lineWidth = 2
            lineDashPattern = [8, 6]
            return
        }

        strokeColor = quality.uiColor

        switch quality {
        case .excellent, .good:
            lineWidth = 4
            lineDashPattern = nil
        case .fair:
            lineWidth = 3
            lineDashPattern = [12, 4]
        case .poor, .veryPoor:
            lineWidth = 3
            lineDashPattern = [4, 4]
        case .unknown:
            lineWidth = 2
            lineDashPattern = [8, 6]
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
