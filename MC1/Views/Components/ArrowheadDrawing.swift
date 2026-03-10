import MapKit
import UIKit

/// Shared arrowhead drawing utility for polyline renderers.
/// Draws a filled triangle arrowhead at the midpoint of a line segment.
enum ArrowheadDrawing {

    /// Draw an arrowhead at the midpoint of a segment in map renderer coordinates.
    /// - Parameters:
    ///   - start: Start coordinate of the segment (direction origin)
    ///   - end: End coordinate of the segment (direction target)
    ///   - color: Fill color for the arrowhead
    ///   - lineWidth: Current line width — arrowhead scales proportionally
    ///   - zoomScale: Current map zoom scale for size compensation
    ///   - context: CoreGraphics context to draw into
    ///   - renderer: The overlay renderer (for coordinate conversion)
    static func drawArrowhead(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        color: UIColor,
        lineWidth: CGFloat,
        zoomScale: MKZoomScale,
        in context: CGContext,
        renderer: MKOverlayRenderer
    ) {
        let startMapPoint = MKMapPoint(start)
        let endMapPoint = MKMapPoint(end)

        // Midpoint in map-point space
        let midMapPoint = MKMapPoint(
            x: (startMapPoint.x + endMapPoint.x) / 2,
            y: (startMapPoint.y + endMapPoint.y) / 2
        )

        // Bearing angle from start to end in map-point space
        let dx = endMapPoint.x - startMapPoint.x
        let dy = endMapPoint.y - startMapPoint.y
        let angle = atan2(dy, dx)

        // Arrow size in map points — scales with line width, compensates for zoom
        let arrowLength = Double(lineWidth) * 3.0 / Double(zoomScale)
        let arrowHalfWidth = arrowLength * 0.4

        // Three map points forming the arrowhead triangle
        let tipX = midMapPoint.x + cos(angle) * arrowLength / 2
        let tipY = midMapPoint.y + sin(angle) * arrowLength / 2

        let leftX = midMapPoint.x - cos(angle) * arrowLength / 2 + sin(angle) * arrowHalfWidth
        let leftY = midMapPoint.y - sin(angle) * arrowLength / 2 - cos(angle) * arrowHalfWidth

        let rightX = midMapPoint.x - cos(angle) * arrowLength / 2 - sin(angle) * arrowHalfWidth
        let rightY = midMapPoint.y - sin(angle) * arrowLength / 2 + cos(angle) * arrowHalfWidth

        // Convert map points to renderer points
        let tip = renderer.point(for: MKMapPoint(x: tipX, y: tipY))
        let left = renderer.point(for: MKMapPoint(x: leftX, y: leftY))
        let right = renderer.point(for: MKMapPoint(x: rightX, y: rightY))

        // Draw filled triangle
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.beginPath()
        context.move(to: tip)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }
}
