import CoreLocation

/// Traffic direction for a route segment.
enum SegmentDirection: Hashable {
    case inbound
    case outbound
    case bidirectional
    case unspecified
}

/// Plain data model representing a route segment between two repeaters with traffic metrics.
/// Used by both the traffic heatmap and contact route map SwiftUI Map views.
struct TrafficSegmentData: Identifiable, Hashable {
    let id: String  // derived from endpoint keys + direction
    let startCoordinate: CLLocationCoordinate2D
    let endCoordinate: CLLocationCoordinate2D
    let frequency: Int
    let normalizedFrequency: Double
    let averageSNR: Double?
    let direction: SegmentDirection

    var coordinates: [CLLocationCoordinate2D] {
        [startCoordinate, endCoordinate]
    }

    // Hashable conformance using id
    static func == (lhs: TrafficSegmentData, rhs: TrafficSegmentData) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
