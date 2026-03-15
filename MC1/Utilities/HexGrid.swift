import CoreLocation
import Foundation

/// Flat-top hexagonal grid utilities for spatial bucketing of coordinates.
/// Used by both SignalSurveyViewModel (map rendering) and SurveyExportService (JSON export).
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
    /// - Parameters:
    ///   - latitude: Point latitude in degrees
    ///   - longitude: Point longitude in degrees
    ///   - referenceLatitude: Latitude used for Mercator correction (typically the center of the survey area)
    static func axialFromLatLon(latitude: Double, longitude: Double, referenceLatitude: Double = 30.0) -> AxialCoord {
        let lonScale = cos(referenceLatitude * .pi / 180.0)
        let scaledLon = longitude * lonScale

        // Fractional axial coordinates (flat-top hex)
        let q = (2.0 / 3.0 * scaledLon) / size
        let r = (-1.0 / 3.0 * scaledLon + sqrt(3.0) / 3.0 * latitude) / size

        // Convert to cube coordinates for rounding
        let s = -q - r
        return cubeRound(q: q, r: r, s: s)
    }

    /// Convert axial hex coordinate back to the center lat/lon.
    /// - Parameter referenceLatitude: Must match the value used in `axialFromLatLon`.
    static func centerLatLon(from coord: AxialCoord, referenceLatitude: Double = 30.0) -> (latitude: Double, longitude: Double) {
        let lonScale = cos(referenceLatitude * .pi / 180.0)
        let scaledLon = size * 3.0 / 2.0 * Double(coord.q)
        let latitude = size * sqrt(3.0) * (Double(coord.r) + Double(coord.q) / 2.0)
        let longitude = scaledLon / lonScale
        return (latitude: latitude, longitude: longitude)
    }

    /// Generate the 6 vertices of a flat-top hex at the given axial coordinate.
    /// - Parameter referenceLatitude: Must match the value used in `axialFromLatLon`.
    static func vertices(for coord: AxialCoord, referenceLatitude: Double = 30.0) -> [CLLocationCoordinate2D] {
        let lonScale = cos(referenceLatitude * .pi / 180.0)
        let center = centerLatLon(from: coord, referenceLatitude: referenceLatitude)

        return (0..<6).map { i in
            let angleDeg = 60.0 * Double(i)
            let angleRad = angleDeg * .pi / 180.0
            // Vertex offset in the corrected space, then unscale longitude
            let vLat = center.latitude + size * sin(angleRad)
            let vLon = center.longitude + (size * cos(angleRad)) / lonScale
            return CLLocationCoordinate2D(latitude: vLat, longitude: vLon)
        }
    }

    /// Generate the 6 vertices of a flat-top hex centered on actual geographic coordinates.
    /// Use this when you have real lat/lon (e.g., from server data) instead of computing from axial coords.
    static func vertices(centerLatitude: Double, centerLongitude: Double, referenceLatitude: Double = 30.0) -> [CLLocationCoordinate2D] {
        let lonScale = cos(referenceLatitude * .pi / 180.0)

        return (0..<6).map { i in
            let angleDeg = 60.0 * Double(i)
            let angleRad = angleDeg * .pi / 180.0
            let vLat = centerLatitude + size * sin(angleRad)
            let vLon = centerLongitude + (size * cos(angleRad)) / lonScale
            return CLLocationCoordinate2D(latitude: vLat, longitude: vLon)
        }
    }

    // MARK: - Fixed Reference Latitude

    /// Returns a predetermined reference latitude for the given latitude,
    /// ensuring all clients produce identical hex grids at the same location.
    ///
    /// Rounds to the nearest 10° band (e.g. 32.7° → 30°, -7.3° → -10°).
    /// This means the grid Mercator correction is slightly imprecise
    /// (off by up to 5° of latitude), but the cells are globally consistent.
    static func fixedReferenceLatitude(for latitude: Double) -> Double {
        (latitude / 10.0).rounded() * 10.0
    }

    // MARK: - Cube Rounding

    /// Round fractional cube coordinates to the nearest hex center.
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
