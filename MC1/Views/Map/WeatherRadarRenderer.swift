import MapKit

/// Custom MKOverlayRenderer that draws a 16x16 MeshWX radar reflectivity grid.
///
/// Creates a colored bitmap from the grid data using the NWS reflectivity palette
/// and draws it with interpolation for smooth appearance.
final class WeatherRadarRenderer: MKOverlayRenderer {

    private let radarOverlay: WeatherRadarOverlay

    init(overlay: WeatherRadarOverlay) {
        self.radarOverlay = overlay
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let overlayRect = self.rect(for: radarOverlay.boundingMapRect)

        // Only draw if we intersect the requested tile
        let drawRect = self.rect(for: mapRect)
        guard overlayRect.intersects(drawRect) else { return }

        // Build 16x16 RGBA bitmap
        let gridSize = 16
        var pixels = [UInt8](repeating: 0, count: gridSize * gridSize * 4)

        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let level = radarOverlay.grid[row * gridSize + col]
                let color = MeshWXRadarFrame.reflectivityColor(for: level)
                let offset = (row * gridSize + col) * 4
                pixels[offset] = color.r
                pixels[offset + 1] = color.g
                pixels[offset + 2] = color.b
                pixels[offset + 3] = color.a
            }
        }

        // Create CGImage from pixel data
        guard let dataProvider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: gridSize,
                  height: gridSize,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: gridSize * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: dataProvider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return }

        // Draw with bilinear interpolation for smooth scaling
        context.saveGState()
        context.setAlpha(0.7)
        context.interpolationQuality = .high
        context.draw(image, in: overlayRect)
        context.restoreGState()
    }
}
