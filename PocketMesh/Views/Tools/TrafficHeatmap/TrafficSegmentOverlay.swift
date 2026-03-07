import MapKit

/// Map overlay representing a route segment between two repeaters with traffic frequency data.
final class TrafficSegmentOverlay: MKPolyline {
    private(set) var frequency: Int = 0
    private(set) var normalizedFrequency: Double = 0
    private(set) var averageSNR: Double?

    /// Create a segment overlay between two coordinates with traffic metrics.
    static func line(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        frequency: Int,
        normalizedFrequency: Double,
        averageSNR: Double?
    ) -> TrafficSegmentOverlay {
        var coords = [start, end]
        let overlay = TrafficSegmentOverlay(coordinates: &coords, count: 2)
        overlay.frequency = frequency
        overlay.normalizedFrequency = normalizedFrequency
        overlay.averageSNR = averageSNR
        return overlay
    }
}
