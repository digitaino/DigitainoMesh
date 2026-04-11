import MapKit

/// MKPolygon subclass that carries MeshWX warning metadata for map rendering.
final class WeatherWarningOverlay: MKPolygon {

    /// VTEC phenomena index (0x00–0x40 from the v3 protocol table).
    private(set) var phenomenaIndex: UInt8 = 0

    /// VTEC significance: 0=Warning(W), 1=Watch(A), 2=Advisory(Y), 3=Statement(S), etc.
    private(set) var vtecSignificance: UInt8 = 0

    /// Headline text from the warning message.
    private(set) var headline: String = ""

    /// Unique ID for identity-based change detection.
    private(set) var warningID: UUID = UUID()

    /// Display title combining type and severity.
    private(set) var displayTitle: String = ""

    /// Creates a warning polygon overlay from a decoded MeshWX warning.
    static func make(from warning: MeshWXWarning) -> WeatherWarningOverlay? {
        guard warning.vertices.count >= 3 else { return nil }

        var coords = warning.vertices.map { $0 }
        let overlay = WeatherWarningOverlay(coordinates: &coords, count: coords.count)
        overlay.phenomenaIndex    = warning.phenomenaIndex
        overlay.vtecSignificance  = warning.vtecSignificance
        overlay.headline          = warning.headline
        overlay.warningID         = warning.id
        overlay.displayTitle      = warning.displayTitle
        return overlay
    }

    /// Whether this is a watch (dashed border) vs warning (solid border).
    var isWatch: Bool { vtecSignificance == 0x1 }

    // MARK: - Colors (NWS-aligned, keyed by VTEC significance + phenomena overrides)

    /// Stroke color for the warning polygon.
    var strokeUIColor: UIColor {
        switch vtecSignificance {
        case 0x0: return warningUIColor
        case 0x1: return watchUIColor
        case 0x2: return .systemYellow
        case 0x3: return .systemBlue
        default:  return .systemGray
        }
    }

    private var warningUIColor: UIColor {
        switch phenomenaIndex {
        case 0x33: return .systemRed                                          // Tornado
        case 0x30: return UIColor(red: 1.0, green: 0.3, blue: 0, alpha: 1)  // Severe Thunderstorm
        case 0x0E: return .systemGreen                                        // Flash Flood
        case 0x10: return UIColor(red: 0, green: 0.5, blue: 0, alpha: 1)    // Flood
        case 0x3B: return .systemBlue                                         // Winter Storm
        case 0x35: return .systemPurple                                       // Tsunami
        case 0x12: return UIColor(red: 0.8, green: 0.4, blue: 0, alpha: 1)  // Fire Weather
        default:   return .systemRed
        }
    }

    private var watchUIColor: UIColor {
        switch phenomenaIndex {
        case 0x33: return UIColor(red: 1.0, green: 0.5, blue: 0, alpha: 1)  // Tornado Watch
        case 0x0E, 0x10: return UIColor(red: 0, green: 0.7, blue: 0, alpha: 1) // Flood Watch
        default:   return .systemOrange
        }
    }

    /// Fill color (same hue as stroke).
    var fillUIColor: UIColor { strokeUIColor }

    /// Fill opacity — Warning more opaque than Watch/Advisory.
    var fillOpacity: CGFloat {
        switch vtecSignificance {
        case 0x0: return 0.25  // Warning
        case 0x1: return 0.15  // Watch
        case 0x2: return 0.10  // Advisory
        default:  return 0.07
        }
    }

    /// Stroke width — Warning gets heavier border.
    var strokeWidth: CGFloat { vtecSignificance == 0x0 ? 2.5 : 1.5 }
}
