import MapKit
import MC1Services

/// Map annotation representing a repeater node with aggregated traffic data.
final class TrafficBubbleAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let name: String
    let publicKey: Data
    let packetCount: Int
    let averageSNR: Double?
    let snrQuality: SNRQuality
    let lastSeen: Date
    /// Normalized 0–1 value for sizing the bubble relative to the busiest node.
    let normalizedTraffic: Double

    var title: String? { name }

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
        self.coordinate = coordinate
        self.name = name
        self.publicKey = publicKey
        self.packetCount = packetCount
        self.averageSNR = averageSNR
        self.snrQuality = snrQuality
        self.lastSeen = lastSeen
        self.normalizedTraffic = normalizedTraffic
        super.init()
    }
}
