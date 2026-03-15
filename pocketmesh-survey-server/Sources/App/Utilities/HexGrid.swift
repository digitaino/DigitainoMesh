import Foundation

/// Flat-top hexagonal grid utilities for spatial bucketing of coordinates.
/// Server-side port of the iOS HexGrid — identical math, no CoreLocation dependency.
///
/// All methods accept a `referenceLatitude` to correct for Mercator distortion:
/// 1° of longitude is shorter than 1° of latitude away from the equator.
/// By scaling longitude by `cos(referenceLatitude)`, hex cells appear as regular
/// hexagons on the map rather than stretched along the east-west axis.
enum HexGrid {

    /// Hex size in degrees of latitude (center to vertex).
    /// Produces ~100m flat-to-flat cells at mid-latitudes.
    static let size: Double = 0.0005

    /// Axial hex coordinate pair.
    struct AxialCoord: Hashable {
        let q: Int
        let r: Int

        /// String key suitable for dictionary bucketing.
        var key: String { "\(q)_\(r)" }
    }

    // MARK: - Coordinate Conversion

    /// Convert a lat/lon to the axial hex coordinate of the containing hex cell.
    static func axialFromLatLon(latitude: Double, longitude: Double, referenceLatitude: Double = 30.0) -> AxialCoord {
        let lonScale = cos(referenceLatitude * .pi / 180.0)
        let scaledLon = longitude * lonScale

        let q = (2.0 / 3.0 * scaledLon) / size
        let r = (-1.0 / 3.0 * scaledLon + sqrt(3.0) / 3.0 * latitude) / size

        let s = -q - r
        return cubeRound(q: q, r: r, s: s)
    }

    /// Convert axial hex coordinate back to the center lat/lon.
    static func centerLatLon(from coord: AxialCoord, referenceLatitude: Double = 30.0) -> (latitude: Double, longitude: Double) {
        let lonScale = cos(referenceLatitude * .pi / 180.0)
        let scaledLon = size * 3.0 / 2.0 * Double(coord.q)
        let latitude = size * sqrt(3.0) * (Double(coord.r) + Double(coord.q) / 2.0)
        let longitude = scaledLon / lonScale
        return (latitude: latitude, longitude: longitude)
    }

    /// Generate the 6 vertices of a flat-top hex at the given axial coordinate.
    static func vertices(for coord: AxialCoord, referenceLatitude: Double = 30.0) -> [(latitude: Double, longitude: Double)] {
        let lonScale = cos(referenceLatitude * .pi / 180.0)
        let center = centerLatLon(from: coord, referenceLatitude: referenceLatitude)

        return (0..<6).map { i in
            let angleDeg = 60.0 * Double(i)
            let angleRad = angleDeg * .pi / 180.0
            let vLat = center.latitude + size * sin(angleRad)
            let vLon = center.longitude + (size * cos(angleRad)) / lonScale
            return (latitude: vLat, longitude: vLon)
        }
    }

    // MARK: - Cube Rounding

    private static func cubeRound(q: Double, r: Double, s: Double) -> AxialCoord {
        var rq = q.rounded()
        var rr = r.rounded()
        let rs = s.rounded()

        let dq = abs(rq - q)
        let dr = abs(rr - r)
        let ds = abs(rs - s)

        if dq > dr && dq > ds {
            rq = -rr - rs
        } else if dr > ds {
            rr = -rq - rs
        }

        return AxialCoord(q: Int(rq), r: Int(rr))
    }
}
