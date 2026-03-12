import CoreLocation
import MC1Services

/// Plain data model representing a repeater node with aggregated traffic data.
/// Used by both the traffic heatmap and contact route map SwiftUI Map views.
struct TrafficBubbleAnnotation: Identifiable {
    let id: Data  // publicKey serves as identity
    let coordinate: CLLocationCoordinate2D
    let name: String
    let publicKey: Data
    let packetCount: Int
    let averageSNR: Double?
    let snrQuality: SNRQuality
    let lastSeen: Date
    /// Normalized 0–1 value for sizing the bubble relative to the busiest node.
    let normalizedTraffic: Double

    init(
        coordinate: CLLocationCoordinate2D,
        name: String,
        publicKey: Data,
        packetCount: Int,
        averageSNR: Double?,
        snrQuality: SNRQuality,
        lastSeen: Date,
        normalizedTraffic: Double
    ) {
        self.id = publicKey
        self.coordinate = coordinate
        self.name = name
        self.publicKey = publicKey
        self.packetCount = packetCount
        self.averageSNR = averageSNR
        self.snrQuality = snrQuality
        self.lastSeen = lastSeen
        self.normalizedTraffic = normalizedTraffic
    }
}
