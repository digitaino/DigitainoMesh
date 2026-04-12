import MapKit

/// Custom MKOverlay for rendering a MeshWX radar reflectivity grid on the map.
/// Supports 16×16 (legacy 0x10), 32×32, and 64×64 (0x11) grids.
final class WeatherRadarOverlay: NSObject, MKOverlay {

    let regionID: UInt8
    let gridSize: Int   // 16, 32, or 64
    let grid: [UInt8]   // gridSize × gridSize elements, values 0x0–0xE
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    /// Unique ID for identity-based change detection.
    let overlayID: UUID

    /// Creates a radar overlay from a decoded MeshWX radar frame.
    static func make(from frame: MeshWXRadarFrame) -> WeatherRadarOverlay? {
        guard let region = MeshWXRegion.all[frame.regionID] else { return nil }
        guard !frame.isEmpty else { return nil }

        let center = CLLocationCoordinate2D(
            latitude: region.centerLatitude,
            longitude: region.centerLongitude
        )

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
            gridSize: frame.gridSize,
            grid: frame.grid,
            coordinate: center,
            boundingMapRect: rect,
            overlayID: UUID()
        )
    }

    private init(regionID: UInt8, gridSize: Int, grid: [UInt8],
                 coordinate: CLLocationCoordinate2D,
                 boundingMapRect: MKMapRect, overlayID: UUID) {
        self.regionID = regionID
        self.gridSize = gridSize
        self.grid = grid
        self.coordinate = coordinate
        self.boundingMapRect = boundingMapRect
        self.overlayID = overlayID
        super.init()
    }
}
