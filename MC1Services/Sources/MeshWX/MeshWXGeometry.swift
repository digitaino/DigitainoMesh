import Foundation
import OSLog
import Synchronization

/// Zone and county outlines, keyed by UGC code (spec §9, `zones.geojson` and
/// `counties.geojson`).
///
/// A warning either carries a polygon or names areas. Storm-based products (tornado,
/// severe thunderstorm, flash flood) carry the polygon and the area list is just the
/// counties under it; zone-based products (winter, heat, wind, fire) carry the list
/// alone, and without these outlines the only thing an app can draw for them is a pin in
/// the middle of a county. Hence the 15 MB.
///
/// **Not every code has a ring.** The bundle is a cut in time and the UGC tables grow,
/// so ``rings(for:)`` returning nil is a normal outcome, not a failure: fall back to the
/// centroid that `zones.json` / `counties.json` carry (spec §9).
///
/// Loading is lazy and per-file, because the two files together take roughly half a
/// second to parse and an app that never shows a zone-based warning should never pay for
/// it. Call ``preload()`` early — from a background task at launch, or when the user
/// opens the weather screen — so the first warning does not land on a cold cache.
public final class MeshWXGeometry: Sendable {
  private static let log = Logger(subsystem: "com.mc1", category: "MeshWX")

  /// Rings of one area, outer only. A Polygon yields one; a MultiPolygon yields one per
  /// part, so an island county draws as several closed shapes.
  public typealias Rings = [[MeshWXCoordinate]]

  /// The app-wide geometry, reading the bundled GeoJSON.
  public static let shared = MeshWXGeometry()

  private let resourceDirectory: URL?
  /// One cache per file. `nil` means "not read yet"; an empty dictionary means the file
  /// was read and had nothing usable, so a failed load is never retried in a loop.
  private let caches = Mutex<Caches>(Caches())

  private struct Caches {
    var zones: [String: Rings]?
    var counties: [String: Rings]?
    var zoneBoxes: [String: Box]?
    var countyBoxes: [String: Box]?
  }

  public convenience init() {
    self.init(resourceDirectory: MeshWXTables.bundledResourceDirectory)
  }

  public init(resourceDirectory: URL?) {
    self.resourceDirectory = resourceDirectory
  }

  // MARK: - Lookup

  /// Outer rings for a UGC code (`"TXC453"`, `"TXZ192"`), or nil when the bundle has no
  /// outline for it.
  ///
  /// Holes are dropped. A county with a lake in it is drawn filled: at the zoom a
  /// warning map uses, a hole is a few pixels, and carrying holes would double the
  /// memory and force every consumer to handle even-odd fill rules.
  ///
  /// The first call for each file parses it (a few hundred milliseconds) on the calling
  /// thread — use ``preload()`` to keep that off a user interaction.
  public func rings(for ugc: String) -> Rings? {
    let code = ugc.uppercased()
    guard code.count >= 3 else { return nil }
    let kind = Array(code)[2]
    switch kind {
    case "C": return counties()[code]
    case "Z": return zones()[code]
    default: return nil
    }
  }

  /// Outer rings for an area already resolved to a name by `MeshWXTables`.
  public func rings(for area: MeshWXNamedArea) -> Rings? {
    rings(for: area.ugc)
  }

  // MARK: - Containment

  /// A latitude/longitude box around every ring of one area.
  ///
  /// Asking "which county am I in" against 8,600 outlines is a ray cast per vertex; asking
  /// it against 8,600 boxes first leaves two or three outlines to cast against, which is
  /// what makes the lookup cheap enough to run whenever the place changes.
  public struct Box: Sendable, Hashable {
    public var minLatitude: Double
    public var maxLatitude: Double
    public var minLongitude: Double
    public var maxLongitude: Double

    public init?(_ rings: Rings) {
      var first = true
      var minLatitude = 0.0, maxLatitude = 0.0, minLongitude = 0.0, maxLongitude = 0.0
      for ring in rings {
        for vertex in ring {
          if first {
            minLatitude = vertex.latitude; maxLatitude = vertex.latitude
            minLongitude = vertex.longitude; maxLongitude = vertex.longitude
            first = false
          } else {
            minLatitude = min(minLatitude, vertex.latitude)
            maxLatitude = max(maxLatitude, vertex.latitude)
            minLongitude = min(minLongitude, vertex.longitude)
            maxLongitude = max(maxLongitude, vertex.longitude)
          }
        }
      }
      guard !first else { return nil }
      self.minLatitude = minLatitude
      self.maxLatitude = maxLatitude
      self.minLongitude = minLongitude
      self.maxLongitude = maxLongitude
    }

    public func contains(_ point: MeshWXCoordinate) -> Bool {
      point.latitude >= minLatitude && point.latitude <= maxLatitude
        && point.longitude >= minLongitude && point.longitude <= maxLongitude
    }
  }

  /// Whether a ring contains a point, by ray casting in latitude/longitude.
  ///
  /// Planar on purpose: warning polygons and county outlines are tens of kilometres across,
  /// where the curvature error is metres — far inside the 0.001° resolution a warning
  /// polygon is sent at. A ring may repeat its first vertex or not; the duplicate edge has
  /// zero height and never crosses the ray. A point exactly on an edge may land either side,
  /// which is why callers that make safety claims must also measure distance to the edge.
  public static func ring(_ ring: [MeshWXCoordinate], contains point: MeshWXCoordinate) -> Bool {
    guard ring.count >= 3 else { return false }
    var inside = false
    var previous = ring[ring.count - 1]
    for vertex in ring {
      if (vertex.latitude > point.latitude) != (previous.latitude > point.latitude) {
        let fraction = (point.latitude - vertex.latitude) / (previous.latitude - vertex.latitude)
        let crossing = vertex.longitude + fraction * (previous.longitude - vertex.longitude)
        if point.longitude < crossing { inside.toggle() }
      }
      previous = vertex
    }
    return inside
  }

  /// Whether the outline of a UGC code contains a point, or nil when the bundle has no
  /// outline for that code — "no outline" is not "outside", and callers must not treat it
  /// as such.
  public func contains(_ point: MeshWXCoordinate, ugc: String) -> Bool? {
    guard let rings = rings(for: ugc) else { return nil }
    return rings.contains { Self.ring($0, contains: point) }
  }

  /// Every county and zone whose outline contains a point, sorted: normally one county and
  /// one land zone, occasionally more where fire-weather or marine zones overlap.
  ///
  /// Parses both GeoJSON files on first use (see ``preload()``).
  public func areaCodes(containing point: MeshWXCoordinate) -> [String] {
    let counties = counties()
    let zones = zones()
    var hits: [String] = []
    for (code, box) in boxes(\.countyBoxes, from: counties) where box.contains(point) {
      if counties[code]?.contains(where: { Self.ring($0, contains: point) }) == true {
        hits.append(code)
      }
    }
    for (code, box) in boxes(\.zoneBoxes, from: zones) where box.contains(point) {
      if zones[code]?.contains(where: { Self.ring($0, contains: point) }) == true {
        hits.append(code)
      }
    }
    return hits.sorted()
  }

  /// Distance in kilometres from a point to the nearest edge of a ring, 0 when inside.
  ///
  /// An equirectangular projection around the point: within the tens of kilometres a "near"
  /// alert or a location's uncertainty radius spans, its error is well under the 0.001° a
  /// warning polygon is sent at. A two-point ring is a line; a one-point ring is a point.
  public static func distanceKilometres(from point: MeshWXCoordinate, to ring: [MeshWXCoordinate]) -> Double {
    guard let first = ring.first else { return .infinity }
    if ring.count >= 3, Self.ring(ring, contains: point) { return 0 }
    let kilometresPerDegreeLatitude = 111.195
    let kilometresPerDegreeLongitude = kilometresPerDegreeLatitude * cos(point.latitude * .pi / 180)
    func projected(_ vertex: MeshWXCoordinate) -> (x: Double, y: Double) {
      ((vertex.longitude - point.longitude) * kilometresPerDegreeLongitude,
       (vertex.latitude - point.latitude) * kilometresPerDegreeLatitude)
    }
    guard ring.count >= 2 else {
      let only = projected(first)
      return (only.x * only.x + only.y * only.y).squareRoot()
    }
    var nearest = Double.infinity
    var previous = projected(ring[ring.count - 1])
    for vertex in ring {
      let current = projected(vertex)
      let dx = current.x - previous.x
      let dy = current.y - previous.y
      let lengthSquared = dx * dx + dy * dy
      let fraction = lengthSquared > 0
        ? max(0, min(1, -(previous.x * dx + previous.y * dy) / lengthSquared))
        : 0
      let closestX = previous.x + fraction * dx
      let closestY = previous.y + fraction * dy
      nearest = min(nearest, (closestX * closestX + closestY * closestY).squareRoot())
      previous = current
    }
    return nearest
  }

  /// Distance from a point to a UGC area's outline, 0 inside, or nil when the bundle has no
  /// outline for the code — "no outline" is not "far away".
  public func distanceKilometres(from point: MeshWXCoordinate, toArea ugc: String) -> Double? {
    guard let rings = rings(for: ugc), !rings.isEmpty else { return nil }
    return rings.map { Self.distanceKilometres(from: point, to: $0) }.min()
  }

  /// Every county and zone whose outline contains a point or passes within a radius of it:
  /// the areas a location with that much uncertainty might be in.
  public func areaCodes(near point: MeshWXCoordinate, withinKilometres radius: Double) -> [String] {
    let counties = counties()
    let zones = zones()
    let latitudePad = radius / 111.195
    let longitudePad = radius / max(1, 111.195 * cos(point.latitude * .pi / 180))
    func candidates(_ rings: [String: Rings], _ boxes: [String: Box]) -> [String] {
      boxes.compactMap { code, box in
        guard point.latitude >= box.minLatitude - latitudePad,
              point.latitude <= box.maxLatitude + latitudePad,
              point.longitude >= box.minLongitude - longitudePad,
              point.longitude <= box.maxLongitude + longitudePad,
              let areaRings = rings[code],
              areaRings.contains(where: { Self.distanceKilometres(from: point, to: $0) <= radius })
        else { return nil }
        return code
      }
    }
    return (candidates(counties, boxes(\.countyBoxes, from: counties))
      + candidates(zones, boxes(\.zoneBoxes, from: zones))).sorted()
  }

  private func boxes(
    _ keyPath: WritableKeyPath<Caches, [String: Box]?>, from rings: [String: Rings]
  ) -> [String: Box] {
    if let existing = caches.withLock({ $0[keyPath: keyPath] }) { return existing }
    let computed = rings.compactMapValues(Box.init)
    return caches.withLock { caches in
      if let existing = caches[keyPath: keyPath] { return existing }
      caches[keyPath: keyPath] = computed
      return computed
    }
  }

  /// Whether each file has been read yet, for a "preparing map" indicator.
  public var isZoneFileLoaded: Bool { caches.withLock { $0.zones != nil } }
  public var isCountyFileLoaded: Bool { caches.withLock { $0.counties != nil } }

  /// Parse both files off the caller's actor, in parallel.
  ///
  /// `withTaskGroup` child tasks run on the concurrent executor whatever the caller's
  /// isolation, so this stays off the main actor even when a view calls it in `.task`.
  public func preload() async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { _ = self.zones() }
      group.addTask { _ = self.counties() }
    }
  }

  // MARK: - Lazy per-file loading

  private func zones() -> [String: Rings] {
    cached(\.zones, file: "zones.geojson")
  }

  private func counties() -> [String: Rings] {
    cached(\.counties, file: "counties.geojson")
  }

  /// Read-check under the lock, parse *outside* it, then publish.
  ///
  /// Parsing inside the lock would block every other caller — including the main thread
  /// asking for a county while a background preload chews through the zones — for the
  /// whole parse. The cost of letting go is that two simultaneous cold callers can parse
  /// the same file twice; they produce identical dictionaries, the first one published
  /// wins, and it only ever happens on the very first access.
  private func cached(
    _ keyPath: WritableKeyPath<Caches, [String: Rings]?>, file: String
  ) -> [String: Rings] {
    if let loaded = caches.withLock({ $0[keyPath: keyPath] }) { return loaded }
    let parsed = Self.parse(file: file, in: resourceDirectory)
    return caches.withLock { caches in
      if let existing = caches[keyPath: keyPath] { return existing }
      caches[keyPath: keyPath] = parsed
      return parsed
    }
  }

  private static func parse(file: String, in directory: URL?) -> [String: Rings] {
    guard let directory else {
      log.warning("MeshWX resources missing from the bundle; \(file) not loaded")
      return [:]
    }
    let url = directory.appendingPathComponent(file, isDirectory: false)
    let started = ContinuousClock.now
    let collection: FeatureCollection
    do {
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      collection = try JSONDecoder().decode(FeatureCollection.self, from: data)
    } catch {
      log.warning("MeshWX geometry \(file) failed to load: \(error.localizedDescription)")
      return [:]
    }

    var result: [String: Rings] = [:]
    result.reserveCapacity(collection.features.count)
    for feature in collection.features {
      guard let code = feature.properties.code?.uppercased(), !feature.geometry.rings.isEmpty
      else { continue }
      // A handful of zones (74 in the 2026-09 cut) appear as two features; appending
      // rather than assigning keeps both halves instead of drawing only the last one.
      result[code, default: []].append(contentsOf: feature.geometry.rings)
    }
    let elapsed = started.duration(to: .now)
    log.info(
      "MeshWX geometry \(file) loaded: \(result.count) codes in \(elapsed.milliseconds) ms")
    return result
  }

  // MARK: - GeoJSON shapes
  //
  // GeoJSON is lon-first; everything else in this module is lat-first, so the swap
  // happens once here, at the boundary, rather than at every call site.

  private struct FeatureCollection: Decodable {
    let features: [Feature]
  }

  private struct Feature: Decodable {
    let properties: Properties
    let geometry: Geometry
  }

  private struct Properties: Decodable {
    /// `zones.geojson` carries only this; `counties.geojson` also carries name and
    /// state, which `counties.json` already has, so they are not decoded.
    let code: String?
  }

  /// The outer rings of one feature, converted on the spot.
  ///
  /// The `[[[Double]]]` tree the decoder builds is the expensive part of these files —
  /// tens of megabytes of boxed arrays — so it is turned into coordinates inside this
  /// initializer and released with the decode, never stored.
  private struct Geometry: Decodable {
    let rings: [[MeshWXCoordinate]]

    private enum CodingKeys: String, CodingKey {
      case type, coordinates
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      switch try container.decode(String.self, forKey: .type) {
      case "MultiPolygon":
        let polygons = try container.decode([[[[Double]]]].self, forKey: .coordinates)
        // Index 0 of each polygon is its outer ring; the rest are holes.
        rings = polygons.compactMap { $0.first.map(Geometry.ring) }
      case "Polygon":
        let polygon = try container.decode([[[Double]]].self, forKey: .coordinates)
        rings = polygon.first.map { [Geometry.ring($0)] } ?? []
      default:
        // Point, LineString and friends have no area to fill.
        rings = []
      }
    }

    private static func ring(_ positions: [[Double]]) -> [MeshWXCoordinate] {
      positions.compactMap { position in
        guard position.count >= 2 else { return nil }
        return MeshWXCoordinate(latitude: position[1], longitude: position[0])
      }
    }
  }
}

extension Duration {
  /// Whole milliseconds, for a log line.
  fileprivate var milliseconds: Int {
    Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
  }
}
