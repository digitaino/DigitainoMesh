import MapKit
import MC1Services
import SurveyKit

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

    /// UIColor for fill based on signal quality. Derives from the one shared
    /// 5-tier palette (`SignalQuality.uiColor`) so all overlays agree.
    var fillUIColor: UIColor {
        snrQuality.signalQuality.uiColor
    }

    /// Fill opacity scaled by contribution count (more contributions = more opaque).
    var fillOpacity: CGFloat {
        0.2 + 0.5 * min(1, CGFloat(contributionCount) / 5.0)
    }
}
