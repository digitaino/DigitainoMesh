import MapKit

/// Map overlay representing a route segment between two repeaters with traffic frequency data.
final class TrafficSegmentOverlay: MKPolyline {

    /// Traffic direction for this segment.
    enum SegmentDirection {
        case inbound
        case outbound
        case bidirectional
        case unspecified
    }

    private(set) var frequency: Int = 0
    private(set) var normalizedFrequency: Double = 0
    private(set) var averageSNR: Double?
    private(set) var startCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D()
    private(set) var endCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D()
    private(set) var direction: SegmentDirection = .unspecified

    /// Create a segment overlay between two coordinates with traffic metrics.
    static func line(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        frequency: Int,
        normalizedFrequency: Double,
        averageSNR: Double?,
        direction: SegmentDirection = .unspecified
    ) -> TrafficSegmentOverlay {
        var coords = [start, end]
        let overlay = TrafficSegmentOverlay(coordinates: &coords, count: 2)
        overlay.frequency = frequency
        overlay.normalizedFrequency = normalizedFrequency
        overlay.averageSNR = averageSNR
        overlay.startCoordinate = start
        overlay.endCoordinate = end
        overlay.direction = direction
        return overlay
    }
}
