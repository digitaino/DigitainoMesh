import MapKit

/// Custom MKOverlayRenderer that draws a MeshWX radar reflectivity grid (16×16, 32×32, or 64×64).
///
/// Builds a bilinearly-upscaled bitmap once in `init` (the overlay grid is immutable, so this is
/// safe to cache and reuse across all tile draw calls). Upscaling is done by bilinear interpolation
/// of the fractional reflectivity level, then mapping to palette colors — producing smooth
/// gradients between grid cells rather than hard block edges.
///
/// Per-level alpha makes light echoes semi-transparent (map features show through) while
/// intense precipitation is rendered at higher opacity. Warning polygon overlays should be
/// added at .aboveLabels so they draw on top of this layer (which sits at .aboveRoads).
final class WeatherRadarRenderer: MKOverlayRenderer {

    private let radarOverlay: WeatherRadarOverlay
    /// Pre-built upscaled image — computed once since the grid never changes after creation.
    private let cachedImage: CGImage?

    init(overlay: WeatherRadarOverlay) {
        self.radarOverlay = overlay
        self.cachedImage = WeatherRadarRenderer.buildImage(overlay: overlay)
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let image = cachedImage else { return }
        let overlayRect = rect(for: radarOverlay.boundingMapRect)
        guard overlayRect.intersects(rect(for: mapRect)) else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: overlayRect)
        context.restoreGState()
    }

    // MARK: - Image Builder

    /// Per-level alpha (0–1). Level 0 is fully transparent; opacity scales with intensity.
    /// This lets the base map and warning polygons show through weak echoes.
    private static let levelAlpha: [Float] = [
        0.00,  // 0: no echo
        0.35,  // 1: light trace
        0.42,  // 2
        0.48,  // 3
        0.54,  // 4
        0.60,  // 5
        0.65,  // 6
        0.69,  // 7
        0.72,  // 8
        0.75,  // 9
        0.79,  // 10
        0.82,  // 11
        0.84,  // 12
        0.84,  // 13
        0.84,  // 14
    ]

    /// Returns a premultiplied RGBA pixel for a fractional reflectivity level by blending
    /// adjacent palette entries. Bilinear interpolation of levels produces smooth color gradients.
    private static func blendedColor(level: Float) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let clamped = max(0, min(14.0, level))
        let lo = Int(clamped)
        let hi = min(lo + 1, 14)
        let t = clamped - Float(lo)
        let clo = MeshWXRadarFrame.reflectivityColor(for: UInt8(lo))
        let chi = MeshWXRadarFrame.reflectivityColor(for: UInt8(hi))
        let alpha = levelAlpha[lo] + (levelAlpha[hi] - levelAlpha[lo]) * t
        let r = Float(clo.r) + (Float(chi.r) - Float(clo.r)) * t
        let g = Float(clo.g) + (Float(chi.g) - Float(clo.g)) * t
        let b = Float(clo.b) + (Float(chi.b) - Float(clo.b)) * t
        // Premultiply RGB by alpha for premultipliedLast bitmap format
        return (
            UInt8(min(255, (r * alpha).rounded())),
            UInt8(min(255, (g * alpha).rounded())),
            UInt8(min(255, (b * alpha).rounded())),
            UInt8(min(255, (alpha * 255).rounded()))
        )
    }

    private static func buildImage(overlay: WeatherRadarOverlay) -> CGImage? {
        let gridSize = overlay.gridSize
        // 8× upscale: 32×32 → 256×256, 64×64 → 512×512. Fast since grid is small and
        // the result is cached for the overlay's lifetime.
        let upscale = 8
        let outSize = gridSize * upscale
        var pixels = [UInt8](repeating: 0, count: outSize * outSize * 4)

        for row in 0..<outSize {
            for col in 0..<outSize {
                // Map output pixel to fractional grid coordinates.
                // gx=0 → left edge (col 0), gx=gridSize-1 → right edge (col gridSize-1).
                let gx = Double(col) * Double(gridSize - 1) / Double(outSize - 1)
                let gy = Double(row) * Double(gridSize - 1) / Double(outSize - 1)

                // Bilinear sample: find the four surrounding grid cells.
                let x0 = max(0, min(gridSize - 2, Int(gx)))
                let y0 = max(0, min(gridSize - 2, Int(gy)))
                let x1 = x0 + 1
                let y1 = y0 + 1
                let fx = Float(gx - Double(x0))
                let fy = Float(gy - Double(y0))

                let l00 = Float(overlay.grid[y0 * gridSize + x0])
                let l10 = Float(overlay.grid[y0 * gridSize + x1])
                let l01 = Float(overlay.grid[y1 * gridSize + x0])
                let l11 = Float(overlay.grid[y1 * gridSize + x1])

                // Bilinear interpolation of the reflectivity level (scalar).
                let level = (l00 + (l10 - l00) * fx) * (1 - fy)
                          + (l01 + (l11 - l01) * fx) * fy

                let color = blendedColor(level: level)
                let offset = (row * outSize + col) * 4
                pixels[offset]     = color.r
                pixels[offset + 1] = color.g
                pixels[offset + 2] = color.b
                pixels[offset + 3] = color.a
            }
        }

        guard let dataProvider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: outSize,
            height: outSize,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
