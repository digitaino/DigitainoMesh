import MapKit

/// Annotation for sender or receiver endpoint on the message route map.
/// Distinct from `RepeaterAnnotation` to allow different pin styling.
final class RouteEndpointAnnotation: NSObject, MKAnnotation {

    enum EndpointType {
        case sender
        case receiver
    }

    let endpointType: EndpointType
    let coordinate: CLLocationCoordinate2D
    let title: String?
    /// Position in the overall route sequence (0 for sender, last for receiver)
    let routeIndex: Int

    init(type: EndpointType, coordinate: CLLocationCoordinate2D, name: String, routeIndex: Int = 0) {
        self.endpointType = type
        self.coordinate = coordinate
        self.title = name
        self.routeIndex = routeIndex
        super.init()
    }
}
