import Foundation
import Testing

@testable import MeshWX

/// The bundled zone and county outlines (spec §9).
@Suite("MeshWX geometry")
struct MeshWXGeometryTests {
  let geometry = MeshWXGeometry.shared

  @Test func countyRingsCoverTheCounty() throws {
    // Travis county, TX: the same county the kit's severe thunderstorm vector names.
    let rings = try #require(geometry.rings(for: "TXC453"))
    #expect(!rings.isEmpty)
    let ring = try #require(rings.first)
    #expect(ring.count > 3, "a fillable ring needs more than three points, got \(ring.count)")

    // The outline must actually be around Austin, not around whatever feature happened
    // to be first in the file: check the box it spans, since any single vertex sits on
    // an edge rather than near the centre.
    let box = BoundingBox(ring)
    #expect(box.contains(latitude: 30.3, longitude: -97.8), "Travis box is \(box)")
    #expect(abs(box.centreLatitude - 30.3) < 0.2)
    #expect(abs(box.centreLongitude - (-97.8)) < 0.2)
  }

  @Test func zoneRingsExist() throws {
    let rings = try #require(geometry.rings(for: "TXZ192"))
    let ring = try #require(rings.first)
    #expect(ring.count > 3)
    let box = BoundingBox(ring)
    #expect(box.contains(latitude: 30.3, longitude: -97.8))
  }

  @Test func lookupIsCaseInsensitiveAndKindAware() {
    #expect(geometry.rings(for: "txc453") != nil)
    // The third character picks the file; anything else is not a UGC.
    #expect(geometry.rings(for: "TXQ453") == nil)
    #expect(geometry.rings(for: "TX") == nil)
    #expect(geometry.rings(for: "") == nil)
  }

  @Test func unknownCodesReturnNilSoTheAppFallsBackToTheCentroid() {
    // Spec §9: bundling the polygons is not a promise every code has one.
    #expect(geometry.rings(for: "TXC997") == nil)
    #expect(geometry.rings(for: "ZZZ001") == nil)
  }

  @Test func namedAreasResolveToRings() throws {
    let areas = MeshWXTables.shared.namedAreas(for: [
      MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1)
    ])
    let area = try #require(areas.first)
    #expect(geometry.rings(for: area) != nil)
  }

  @Test func missingResourcesYieldNoRingsRatherThanCrashing() {
    let empty = MeshWXGeometry(resourceDirectory: URL(fileURLWithPath: "/nonexistent/meshwx"))
    #expect(empty.rings(for: "TXC453") == nil)
    // A failed read still counts as loaded, so it is not retried on every lookup.
    #expect(empty.isCountyFileLoaded)
  }

  /// Numbers for the report, and proof that `preload()` warms both caches.
  @Test func reportsGeoJSONLoadTimes() async {
    let fresh = MeshWXGeometry()
    #expect(!fresh.isZoneFileLoaded)
    #expect(!fresh.isCountyFileLoaded)

    let counties = MeshWXGeometry()
    var started = ContinuousClock.now
    _ = counties.rings(for: "TXC453")
    print("MeshWX: counties.geojson first load \(Self.milliseconds(since: started)) ms")

    let zones = MeshWXGeometry()
    started = ContinuousClock.now
    _ = zones.rings(for: "TXZ192")
    print("MeshWX: zones.geojson first load \(Self.milliseconds(since: started)) ms")

    started = ContinuousClock.now
    await fresh.preload()
    print("MeshWX: preload() of both files \(Self.milliseconds(since: started)) ms")
    #expect(fresh.isZoneFileLoaded)
    #expect(fresh.isCountyFileLoaded)

    // Warm lookups must not re-read anything.
    started = ContinuousClock.now
    #expect(fresh.rings(for: "TXC453") != nil)
    #expect(Self.milliseconds(since: started) < 50)
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    Int((ContinuousClock.now - start).components.attoseconds / 1_000_000_000_000_000)
  }

  /// The box a ring spans, so a test can assert *where* an outline is without depending
  /// on which vertex the source file happens to start at.
  private struct BoundingBox: CustomStringConvertible {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    init(_ ring: [MeshWXCoordinate]) {
      minLatitude = ring.map(\.latitude).min() ?? 0
      maxLatitude = ring.map(\.latitude).max() ?? 0
      minLongitude = ring.map(\.longitude).min() ?? 0
      maxLongitude = ring.map(\.longitude).max() ?? 0
    }

    var centreLatitude: Double { (minLatitude + maxLatitude) / 2 }
    var centreLongitude: Double { (minLongitude + maxLongitude) / 2 }

    func contains(latitude: Double, longitude: Double) -> Bool {
      (minLatitude...maxLatitude).contains(latitude)
        && (minLongitude...maxLongitude).contains(longitude)
    }

    var description: String {
      "lat \(minLatitude)…\(maxLatitude), lon \(minLongitude)…\(maxLongitude)"
    }
  }
}
