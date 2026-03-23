import MapKit

// MARK: - Route Selection Polygon

/// MKPolygon subclass for the user-drawn survey area boundary.
final class RouteSelectionPolygonOverlay: MKPolygon {
    /// Creates a polygon overlay from an array of coordinates.
    static func make(from coordinates: [CLLocationCoordinate2D]) -> RouteSelectionPolygonOverlay {
        var coords = coordinates
        return RouteSelectionPolygonOverlay(coordinates: &coords, count: coords.count)
    }
}

// MARK: - Route Path Polyline

/// MKPolyline subclass connecting waypoints in route order.
final class RoutePathPolyline: MKPolyline {
    static func make(from coordinates: [CLLocationCoordinate2D]) -> RoutePathPolyline {
        var coords = coordinates
        return RoutePathPolyline(coordinates: &coords, count: coords.count)
    }
}

// MARK: - Drawing Vertex Annotation

/// Annotation for a polygon corner point during drawing mode.
final class RouteDrawingVertexAnnotation: NSObject, MKAnnotation {
    let index: Int
    let coordinate: CLLocationCoordinate2D
    let isFirst: Bool

    init(index: Int, coordinate: CLLocationCoordinate2D, isFirst: Bool = false) {
        self.index = index
        self.coordinate = coordinate
        self.isFirst = isFirst
    }
}

// MARK: - Drawing Edge Polyline

/// MKPolyline for edges between polygon drawing vertices.
final class RouteDrawingEdgePolyline: MKPolyline {
    static func make(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> RouteDrawingEdgePolyline {
        var coords = [from, to]
        return RouteDrawingEdgePolyline(coordinates: &coords, count: 2)
    }
}

// MARK: - Route Waypoint Annotation

/// Annotation for a numbered waypoint in the planned route.
final class RouteWaypointAnnotation: NSObject, MKAnnotation {
    let waypointIndex: Int
    let coordinate: CLLocationCoordinate2D
    var status: RoutePlanner.Waypoint.Status

    init(waypointIndex: Int, coordinate: CLLocationCoordinate2D, status: RoutePlanner.Waypoint.Status) {
        self.waypointIndex = waypointIndex
        self.coordinate = coordinate
        self.status = status
    }
}
