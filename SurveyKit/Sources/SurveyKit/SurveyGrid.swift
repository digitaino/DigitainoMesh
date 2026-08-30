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

  /// Canonical lowercase hex-string form, e.g. `"8944e0605d7ffff"`.
  public var stringValue: String {
    var buffer = [CChar](repeating: 0, count: 17)
    h3ToString(rawValue, &buffer, buffer.count)
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
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
  public var description: String {
    stringValue
  }
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
  /// The resolution at which samples are recorded and stored (the wire v3 store
  /// contract — docs/SIGNAL_MAPPER_V2.md): ~200 m average edge, ~350 m across.
  public static let baseResolution = 9

  /// The coarsest resolution the system samples at (~2.4 km cells, highway tier).
  public static let coarsestResolution = 7

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

  // MARK: - Spherical geometry

  /// Mean Earth radius in meters. H3 is defined on the same authalic sphere, so cell
  /// centres and the two helpers below agree to far better than a res-9 cell width —
  /// which is the only precision anything in this package needs.
  public static let earthRadiusMeters = 6_371_007.2

  /// Great-circle distance between two coordinates, in meters.
  ///
  /// Haversine on the sphere above. Deliberately not `CLLocation.distance(from:)`: this
  /// package runs on Linux too, and the difference over the few kilometers any caller
  /// measures is centimeters.
  public static func distanceMeters(from origin: GeoCoordinate, to destination: GeoCoordinate) -> Double {
    let lat1 = degsToRads(origin.latitude)
    let lat2 = degsToRads(destination.latitude)
    let deltaLat = lat2 - lat1
    let deltaLng = degsToRads(destination.longitude - origin.longitude)

    let a = sin(deltaLat / 2) * sin(deltaLat / 2)
      + cos(lat1) * cos(lat2) * sin(deltaLng / 2) * sin(deltaLng / 2)
    return 2 * earthRadiusMeters * atan2(sqrt(a), sqrt(max(0, 1 - a)))
  }

  /// The coordinate `distanceMeters` away from `origin` along `bearingRadians`
  /// (0 = north, increasing clockwise).
  ///
  /// The inverse of ``distanceMeters(from:to:)``, used wherever a point has to be
  /// displaced by a known amount in a known direction.
  public static func coordinate(
    from origin: GeoCoordinate,
    bearingRadians: Double,
    distanceMeters: Double
  ) -> GeoCoordinate {
    let angular = distanceMeters / earthRadiusMeters
    let lat1 = degsToRads(origin.latitude)
    let lng1 = degsToRads(origin.longitude)

    let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearingRadians))
    let lng2 = lng1 + atan2(
      sin(bearingRadians) * sin(angular) * cos(lat1),
      cos(angular) - sin(lat1) * sin(lat2)
    )

    // Normalized back into (-180, 180] so a disc straddling the antimeridian still
    // produces coordinates the rest of the system accepts.
    var longitude = radsToDegs(lng2).truncatingRemainder(dividingBy: 360)
    if longitude > 180 { longitude -= 360 }
    if longitude <= -180 { longitude += 360 }
    return GeoCoordinate(latitude: radsToDegs(lat2), longitude: longitude)
  }

  /// Every cell whose *centre* lies within `radiusMeters` of `center`.
  ///
  /// Centre-membership rather than any-overlap: it is the cheap, symmetric definition —
  /// a cell is in the disc exactly when ``distanceMeters(from:to:)`` from the disc's
  /// centre to ``center(of:)`` is inside the radius — so a caller can test one cell with
  /// that comparison and get the same answer this enumeration gives.
  ///
  /// Returns an empty array for a non-positive radius or an unmappable centre.
  public static func cells(
    within radiusMeters: Double,
    of center: GeoCoordinate,
    resolution: Int = baseResolution
  ) -> [H3Cell] {
    guard radiusMeters > 0, let origin = cell(containing: center, resolution: resolution) else {
      return []
    }

    // Centres of neighbouring cells sit about `edge * sqrt(3)` apart; dividing by a
    // smaller number over-covers, which is the safe direction — the distance filter
    // below discards anything the ring count reached too far for.
    let edge = averageEdgeMeters(resolution: resolution)
    guard edge > 0 else { return [] }
    let rings = Int((radiusMeters / (edge * 1.5)).rounded(.up)) + 1

    var size: Int64 = 0
    guard maxGridDiskSize(Int32(rings), &size) == 0, size > 0, size < 1_000_000 else { return [] }

    var indexes = [H3Index](repeating: 0, count: Int(size))
    guard gridDisk(origin.rawValue, Int32(rings), &indexes) == 0 else { return [] }

    // gridDisk leaves 0 in the slots it could not fill (the disk around a pentagon is
    // smaller than the maximum), so invalid entries are dropped rather than trusted.
    return indexes.compactMap { H3Cell(rawValue: $0) }
      .filter { distanceMeters(from: center, to: self.center(of: $0)) <= radiusMeters }
  }
}
