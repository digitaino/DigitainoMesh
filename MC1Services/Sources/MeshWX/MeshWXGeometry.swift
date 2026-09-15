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
