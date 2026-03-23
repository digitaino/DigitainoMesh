import CoreLocation

/// Generates efficient survey routes through hex grid cells using a boustrophedon (lawnmower) sweep pattern.
enum RoutePlanner {

    /// A waypoint in a planned survey route.
    struct Waypoint: Identifiable, Equatable {
        let id: Int
        let hexCoord: HexGrid.AxialCoord
        let center: CLLocationCoordinate2D
        var status: Status

        enum Status: Equatable {
            case pending
            case current
            case completed
            case skipped
        }

        static func == (lhs: Waypoint, rhs: Waypoint) -> Bool {
            lhs.id == rhs.id
                && lhs.hexCoord == rhs.hexCoord
                && lhs.status == rhs.status
                && lhs.center.latitude == rhs.center.latitude
                && lhs.center.longitude == rhs.center.longitude
        }
    }

    /// A planned survey route: the original polygon, ordered waypoints, and metadata.
    struct Route {
        let polygon: [CLLocationCoordinate2D]
        var waypoints: [Waypoint]
        let referenceLatitude: Double
        let excludedSurveyedCells: Bool

        var currentWaypointIndex: Int? {
            waypoints.firstIndex(where: { $0.status == .current })
        }

        var completedCount: Int {
            waypoints.filter { $0.status == .completed }.count
        }

        var remainingCount: Int {
            waypoints.filter { $0.status == .pending || $0.status == .current }.count
        }
    }

    /// Generate an ordered route through all hex cells inside the given polygon.
    ///
    /// - Parameters:
    ///   - polygon: The polygon vertices defining the survey area.
    ///   - excludeCoordKeys: Set of hex coord keys (e.g., "5_12") to skip (already surveyed).
    /// - Returns: A `Route` with waypoints in boustrophedon order, or nil if no cells found.
    static func generateRoute(
        polygon: [CLLocationCoordinate2D],
        excludeCoordKeys: Set<String> = []
    ) -> Route? {
        guard polygon.count >= 3 else { return nil }

        // Determine reference latitude from polygon centroid
        let centroidLat = polygon.map(\.latitude).reduce(0, +) / Double(polygon.count)
        let referenceLatitude = HexGrid.fixedReferenceLatitude(for: centroidLat)

        // Convert polygon to tuple array for HexGrid
        let vertices = polygon.map { (latitude: $0.latitude, longitude: $0.longitude) }

        // Enumerate cells inside polygon
        var cells = HexGrid.cellsInPolygon(vertices: vertices, referenceLatitude: referenceLatitude)

        // Subtract already-surveyed cells
        if !excludeCoordKeys.isEmpty {
            cells = cells.filter { !excludeCoordKeys.contains($0.key) }
        }

        guard !cells.isEmpty else { return nil }

        // Boustrophedon ordering: group by r (hex row), alternate sweep direction
        let grouped = Dictionary(grouping: cells) { $0.r }
        let sortedRows = grouped.keys.sorted()

        var ordered: [HexGrid.AxialCoord] = []
        for (index, r) in sortedRows.enumerated() {
            let rowCells = grouped[r]!
            if index.isMultiple(of: 2) {
                // Even rows: left-to-right (ascending q)
                ordered.append(contentsOf: rowCells.sorted { $0.q < $1.q })
            } else {
                // Odd rows: right-to-left (descending q)
                ordered.append(contentsOf: rowCells.sorted { $0.q > $1.q })
            }
        }

        // Convert to waypoints
        let waypoints = ordered.enumerated().map { index, coord in
            let center = HexGrid.centerLatLon(from: coord, referenceLatitude: referenceLatitude)
            return Waypoint(
                id: index,
                hexCoord: coord,
                center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
                status: index == 0 ? .current : .pending
            )
        }

        return Route(
            polygon: polygon,
            waypoints: waypoints,
            referenceLatitude: referenceLatitude,
            excludedSurveyedCells: !excludeCoordKeys.isEmpty
        )
    }

    /// Compute the bearing (in degrees, 0=north, clockwise) from one coordinate to another.
    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Compute the distance in meters between two coordinates.
    static func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let loc2 = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return loc1.distance(from: loc2)
    }

    /// Format a distance as a human-readable string.
    static func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters))m"
        } else {
            return String(format: "%.1f km", meters / 1000)
        }
    }
}
