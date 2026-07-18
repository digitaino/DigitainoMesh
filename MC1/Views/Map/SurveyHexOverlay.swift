import MapKit
import MC1Services
import SurveyKit

/// MKPolygon subclass that carries survey hex cell metadata for efficient MKOverlayRenderer rendering.
/// Parallel to `CommunityHexOverlay` but for the user's own survey data.
final class SurveyHexOverlay: MKPolygon {
    /// Signal quality for coloring.
    private(set) var snrQuality: SNRQuality = .unknown

    /// Number of packets in this cell — used for opacity scaling.
    private(set) var packetCount: Int = 0

    /// Whether this cell is a dead zone (probes sent but no packets received).
    private(set) var isDeadZone: Bool = false

    /// Hex coordinate key (e.g. "0_5") for diff-based update tracking.
    private(set) var coordKey: String = ""

    /// Whether this cell is currently selected.
    private(set) var isSelected: Bool = false

    /// Creates a hex polygon overlay from a survey grid cell.
    static func make(from cell: SignalSurveyViewModel.GridCell, selected: Bool = false) -> SurveyHexOverlay {
        var coords = cell.vertices.map { $0 }
        let overlay = SurveyHexOverlay(coordinates: &coords, count: coords.count)

        overlay.snrQuality = cell.snrQuality
        overlay.packetCount = cell.packetCount
        overlay.isDeadZone = cell.isDeadZone
        overlay.coordKey = cell.coordKey
        overlay.isSelected = selected
        return overlay
    }

    /// UIColor for fill based on signal quality. Derives from the one shared
    /// 5-tier palette (`SignalQuality.uiColor`) so all overlays agree.
    var fillUIColor: UIColor {
        if isDeadZone { return .systemGray }
        return snrQuality.signalQuality.uiColor
    }

    /// Fill opacity scaled by packet count (more packets = more opaque).
    var fillOpacity: CGFloat {
        if isDeadZone { return 0.15 }
        return 0.2 + 0.5 * min(1, CGFloat(packetCount) / 10.0)
    }

    /// Stroke opacity for the cell border.
    var strokeOpacity: CGFloat {
        if isDeadZone { return 0.5 }
        return 0.6
    }
}
