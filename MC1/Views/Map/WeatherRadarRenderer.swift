import MapKit

/// Custom MKOverlayRenderer that draws a MeshWX radar reflectivity grid (16×16, 32×32, or 64×64).
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

        let drawRect = self.rect(for: mapRect)
        guard overlayRect.intersects(drawRect) else { return }

        let gridSize = radarOverlay.gridSize
        var pixels = [UInt8](repeating: 0, count: gridSize * gridSize * 4)

        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let level = radarOverlay.grid[row * gridSize + col]
                let color = MeshWXRadarFrame.reflectivityColor(for: level)
                let offset = (row * gridSize + col) * 4
                pixels[offset]     = color.r
                pixels[offset + 1] = color.g
                pixels[offset + 2] = color.b
                pixels[offset + 3] = color.a
            }
        }

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

        context.saveGState()
        context.setAlpha(0.7)
        context.interpolationQuality = .high
        context.draw(image, in: overlayRect)
        context.restoreGState()
    }
}
