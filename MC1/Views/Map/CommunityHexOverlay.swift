import MapKit
import MC1Services

/// MKPolygon subclass that carries signal quality metadata for community hex cell rendering.
final class CommunityHexOverlay: MKPolygon {
    /// Signal quality for coloring.
    private(set) var snrQuality: SNRQuality = .unknown

    /// Number of contributions — used for opacity scaling.
    private(set) var contributionCount: Int = 0

    /// Creates a hex polygon overlay from a community cell.
    static func make(from cell: SurveyUploadService.CommunityCell) -> CommunityHexOverlay {
        let vertices = HexGrid.vertices(
            centerLatitude: cell.latitude,
            centerLongitude: cell.longitude,
            referenceLatitude: cell.referenceLatitude
        )

        var coords = vertices.map { $0 }
        let overlay = CommunityHexOverlay(coordinates: &coords, count: coords.count)

        overlay.snrQuality = SNRQuality(snr: cell.averageSNR)
        overlay.contributionCount = cell.contributionCount
        return overlay
    }

    /// UIColor matching the 5-tier SNR quality palette from the web frontend.
    var fillUIColor: UIColor {
        switch snrQuality {
        case .excellent: UIColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 1) // #22c55e
        case .good:      UIColor(red: 0.918, green: 0.702, blue: 0.031, alpha: 1) // #eab308
        case .fair:      UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 1) // #f97316
        case .poor:      UIColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1) // #ef4444
        case .veryPoor:  UIColor(red: 0.600, green: 0.106, blue: 0.106, alpha: 1) // #991b1b
        case .unknown:   UIColor.systemGray
        }
    }

    /// Fill opacity scaled by contribution count (more contributions = more opaque).
    var fillOpacity: CGFloat {
        0.2 + 0.5 * min(1, CGFloat(contributionCount) / 5.0)
    }
}
