import MapKit
import PocketMeshServices
import UIKit

/// Renderer for TrafficSegmentOverlay that draws lines with width and opacity
/// proportional to segment traffic frequency.
final class TrafficSegmentRenderer: MKPolylineRenderer {

    override init(overlay: any MKOverlay) {
        super.init(overlay: overlay)
        configureAppearance()
    }

    private func configureAppearance() {
        guard let segment = overlay as? TrafficSegmentOverlay else { return }

        // Width: 2pt (min) to 8pt (max) based on normalized frequency
        lineWidth = 2 + 6 * segment.normalizedFrequency

        // Color based on average SNR quality
        let quality = SNRQuality(snr: segment.averageSNR)
        let baseColor: UIColor
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

        // Alpha: 0.4 (min) to 1.0 (max) based on normalized frequency
        let alpha = 0.4 + 0.6 * segment.normalizedFrequency
        strokeColor = baseColor.withAlphaComponent(alpha)
    }
}
