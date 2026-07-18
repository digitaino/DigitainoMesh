import Foundation

/// The v1 flat-top axial hex grid — **legacy, read-only**.
///
/// Kept solely to render/export sessions recorded before the H3 migration and to keep
/// the v1 upload path decodable during the transition. New code buckets with
/// `SurveyGrid`. This is the single implementation; the former copies in
/// `MC1/Utilities/HexGrid.swift` and the server's `Utilities/HexGrid.swift` delegate
/// here or are deleted.
public enum LegacyAxialGrid {

    /// Hex size in degrees of latitude (center to vertex). ~100 m cells.
    public static let size: Double = 0.0005

    public struct AxialCoord: Hashable, Sendable {
        public let q: Int
        public let r: Int

        public init(q: Int, r: Int) {
            self.q = q
            self.r = r
        }

        public var key: String { "\(q)_\(r)" }
    }

    /// Rounds to the nearest 10° band so all clients derive identical grids.
    public static func fixedReferenceLatitude(for latitude: Double) -> Double {
        (latitude / 10.0).rounded() * 10.0
    }

    public static func axial(
        latitude: Double,
        longitude: Double,
        referenceLatitude: Double
    ) -> AxialCoord {
        let lonScale = cos(referenceLatitude * .pi / 180.0)
        let scaledLon = longitude * lonScale
        let q = (2.0 / 3.0 * scaledLon) / size
        let r = (-1.0 / 3.0 * scaledLon + sqrt(3.0) / 3.0 * latitude) / size
        return cubeRound(q: q, r: r, s: -q - r)
    }

    public static func center(
        of coord: AxialCoord,
        referenceLatitude: Double
    ) -> GeoCoordinate {
        let lonScale = cos(referenceLatitude * .pi / 180.0)
        let scaledLon = size * 3.0 / 2.0 * Double(coord.q)
        let latitude = size * sqrt(3.0) * (Double(coord.r) + Double(coord.q) / 2.0)
        return GeoCoordinate(latitude: latitude, longitude: scaledLon / lonScale)
    }

    public static func vertices(
        for coord: AxialCoord,
        referenceLatitude: Double
    ) -> [GeoCoordinate] {
        let center = center(of: coord, referenceLatitude: referenceLatitude)
        return vertices(
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            referenceLatitude: referenceLatitude
        )
    }

    public static func vertices(
        centerLatitude: Double,
        centerLongitude: Double,
        referenceLatitude: Double
    ) -> [GeoCoordinate] {
        let lonScale = cos(referenceLatitude * .pi / 180.0)
        return (0..<6).map { i in
            let angle = 60.0 * Double(i) * .pi / 180.0
            return GeoCoordinate(
                latitude: centerLatitude + size * sin(angle),
                longitude: centerLongitude + (size * cos(angle)) / lonScale
            )
        }
    }

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
