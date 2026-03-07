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

    init(type: EndpointType, coordinate: CLLocationCoordinate2D, name: String) {
        self.endpointType = type
        self.coordinate = coordinate
        self.title = name
        super.init()
    }
}
