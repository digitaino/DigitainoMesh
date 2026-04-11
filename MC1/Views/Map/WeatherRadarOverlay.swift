import MapKit

/// Custom MKOverlay for rendering a 16x16 MeshWX radar reflectivity grid on the map.
final class WeatherRadarOverlay: NSObject, MKOverlay {

    let regionID: UInt8
    let grid: [UInt8] // 256 elements (16x16), values 0x0-0xE
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    /// Unique ID for identity-based change detection.
    let overlayID: UUID

    /// Creates a radar overlay from a decoded MeshWX radar frame.
    static func make(from frame: MeshWXRadarFrame) -> WeatherRadarOverlay? {
        guard let region = MeshWXRegion.all[frame.regionID] else { return nil }
        // Skip empty grids
        guard !frame.isEmpty else { return nil }

        let center = CLLocationCoordinate2D(
            latitude: region.centerLatitude,
            longitude: region.centerLongitude
        )

        // Build bounding rect from region definition
        let topLeft = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.north,
            longitude: region.west
        ))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.south,
            longitude: region.east
        ))
        let rect = MKMapRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )

        return WeatherRadarOverlay(
            regionID: frame.regionID,
            grid: frame.grid,
            coordinate: center,
            boundingMapRect: rect,
            overlayID: UUID()
        )
    }

    private init(regionID: UInt8, grid: [UInt8], coordinate: CLLocationCoordinate2D,
                 boundingMapRect: MKMapRect, overlayID: UUID) {
        self.regionID = regionID
        self.grid = grid
        self.coordinate = coordinate
        self.boundingMapRect = boundingMapRect
        self.overlayID = overlayID
        super.init()
    }
}
