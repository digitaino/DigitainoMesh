import MapKit

/// MKAnnotation wrapper for TrafficBubbleAnnotation to display on MKMapView
final class TrafficAnnotation: NSObject, MKAnnotation {
    let bubble: TrafficBubbleAnnotation

    var coordinate: CLLocationCoordinate2D { bubble.coordinate }
    var title: String? { bubble.name }
    var subtitle: String? { "\(bubble.packetCount) packets" }

    init(bubble: TrafficBubbleAnnotation) {
        self.bubble = bubble
        super.init()
    }
}

extension TrafficAnnotation {
    override var hash: Int {
        bubble.publicKey.hashValue
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TrafficAnnotation else { return false }
        return bubble.publicKey == other.bubble.publicKey
    }
}
