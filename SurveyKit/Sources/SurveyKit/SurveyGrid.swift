import CH3
import Foundation

/// A single H3 cell index. The canonical spatial identity for all survey data.
///
/// The raw value is the standard 64-bit H3 index; the resolution is encoded inside it,
/// so a cell at res 8 and a cell at res 10 are always distinct values. JSON encoding
/// uses the standard lowercase hex string form (e.g. `"8a44e0605d97fff"`) to match the
/// server API and h3-pg.
public struct H3Cell: Hashable, Sendable {
    public let rawValue: UInt64

    /// Wraps a raw index, returning nil if it is not a valid H3 cell.
    public init?(rawValue: UInt64) {
        guard isValidCell(rawValue) == 1 else { return nil }
        self.rawValue = rawValue
    }

    /// Parses the canonical hex-string form (as used on the wire and in the database).
    public init?(string: String) {
        var index: H3Index = 0
        guard stringToH3(string, &index) == 0, isValidCell(index) == 1 else { return nil }
        self.rawValue = index
    }

    /// Internal fast path for indexes we just obtained from the C library.
    init(trusted: UInt64) {
        self.rawValue = trusted
    }

    /// Canonical lowercase hex-string form, e.g. `"8a44e0605d97fff"`.
    public var stringValue: String {
        var buffer = [CChar](repeating: 0, count: 17)
        h3ToString(rawValue, &buffer, buffer.count)
        return String(cString: buffer)
    }

    /// The resolution (0...15) encoded in this index.
    public var resolution: Int {
        Int(getResolution(rawValue))
    }
}

extension H3Cell: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let cell = H3Cell(string: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid H3 cell index: \(string)"
            )
        }
        self = cell
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

extension H3Cell: CustomStringConvertible {
    public var description: String { stringValue }
}

/// A geographic coordinate in degrees. SurveyKit's dependency-free stand-in for
/// CLLocationCoordinate2D so the same code runs on Linux (server) and Apple platforms.
public struct GeoCoordinate: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// The one place in the system that knows how coordinates become hexagons.
///
/// Wraps the vendored uber/h3 C library with a small typed API. Everything the survey
/// system needs — bucketing, parents for speed-adaptive coarsening, boundaries for
/// rendering — goes through here on both the app and the server.
public enum SurveyGrid {

    /// The resolution at which samples are recorded and stored (server contract).
    /// ~66 m average edge, ~115 m across — the v2 pipeline and h3-pg indexes assume it.
    public static let baseResolution = 10

    /// The coarsest resolution the system serves or samples at (~800 m across).
    public static let coarsestResolution = 8

    /// Returns the cell containing a coordinate at the given resolution.
    /// Returns nil only for out-of-range coordinates or resolutions.
    public static func cell(
        containing coordinate: GeoCoordinate,
        resolution: Int = baseResolution
    ) -> H3Cell? {
        guard (0...15).contains(resolution),
              coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              abs(coordinate.latitude) <= 90, abs(coordinate.longitude) <= 180
        else { return nil }
        var latLng = LatLng(
            lat: degsToRads(coordinate.latitude),
            lng: degsToRads(coordinate.longitude)
        )
        var index: H3Index = 0
        guard latLngToCell(&latLng, Int32(resolution), &index) == 0 else { return nil }
        return H3Cell(trusted: index)
    }

    /// The center of a cell in degrees.
    public static func center(of cell: H3Cell) -> GeoCoordinate {
        var latLng = LatLng(lat: 0, lng: 0)
        cellToLatLng(cell.rawValue, &latLng)
        return GeoCoordinate(
            latitude: radsToDegs(latLng.lat),
            longitude: radsToDegs(latLng.lng)
        )
    }

    /// The boundary vertices of a cell in degrees (5–10 vertices; hexagons have 6,
    /// the twelve pentagon cells worldwide have 5, distorted cells can have more).
    public static func boundary(of cell: H3Cell) -> [GeoCoordinate] {
        var boundary = CellBoundary()
        guard cellToBoundary(cell.rawValue, &boundary) == 0 else { return [] }
        let count = Int(boundary.numVerts)
        return withUnsafeBytes(of: boundary.verts) { raw in
            let verts = raw.bindMemory(to: LatLng.self)
            return (0..<count).map { i in
                GeoCoordinate(
                    latitude: radsToDegs(verts[i].lat),
                    longitude: radsToDegs(verts[i].lng)
                )
            }
        }
    }

    /// The parent of a cell at a coarser resolution. Returns the cell itself when
    /// `resolution` equals the cell's resolution; nil when asked to refine (finer res).
    public static func parent(of cell: H3Cell, resolution: Int) -> H3Cell? {
        guard resolution <= cell.resolution, resolution >= 0 else { return nil }
        var parent: H3Index = 0
        guard cellToParent(cell.rawValue, Int32(resolution), &parent) == 0 else { return nil }
        return H3Cell(trusted: parent)
    }

    /// Average edge length in meters for a resolution (for UI copy like "~115 m cells").
    public static func averageEdgeMeters(resolution: Int) -> Double {
        var meters: Double = 0
        guard getHexagonEdgeLengthAvgM(Int32(resolution), &meters) == 0 else { return 0 }
        return meters
    }
}
