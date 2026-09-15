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

/// Containment: which outline holds a point, and whether a warning polygon does.
@Suite("MeshWX geometry containment")
struct MeshWXGeometryContainmentTests {
  let geometry = MeshWXGeometry.shared

  /// The kit's severe thunderstorm polygon (SV.W.EWX.42), as the decoder reconstructs it.
  let stormPolygon = [
    MeshWXCoordinate(latitude: 30.52, longitude: -97.98),
    MeshWXCoordinate(latitude: 30.61, longitude: -97.62),
    MeshWXCoordinate(latitude: 30.38, longitude: -97.41),
    MeshWXCoordinate(latitude: 30.15, longitude: -97.5),
    MeshWXCoordinate(latitude: 30.09, longitude: -97.85),
    MeshWXCoordinate(latitude: 30.28, longitude: -98.04)
  ]

  @Test func aPolygonContainsItsInteriorAndNotTheOutside() {
    #expect(MeshWXGeometry.ring(stormPolygon, contains: MeshWXCoordinate(latitude: 30.35, longitude: -97.70)))
    #expect(!MeshWXGeometry.ring(stormPolygon, contains: MeshWXCoordinate(latitude: 30.00, longitude: -97.00)))
    // Just past the eastern vertex, where a bounding box would still say yes.
    #expect(!MeshWXGeometry.ring(stormPolygon, contains: MeshWXCoordinate(latitude: 30.58, longitude: -97.45)))
  }

  @Test func aClosedRingAnswersTheSameAsAnOpenOne() {
    let closed = stormPolygon + [stormPolygon[0]]
    let inside = MeshWXCoordinate(latitude: 30.35, longitude: -97.70)
    let outside = MeshWXCoordinate(latitude: 30.00, longitude: -97.00)
    #expect(MeshWXGeometry.ring(closed, contains: inside))
    #expect(!MeshWXGeometry.ring(closed, contains: outside))
  }

  @Test func degenerateRingsContainNothing() {
    let point = MeshWXCoordinate(latitude: 30.35, longitude: -97.70)
    #expect(!MeshWXGeometry.ring([], contains: point))
    #expect(!MeshWXGeometry.ring(Array(stormPolygon.prefix(2)), contains: point))
  }

  /// Expected codes come from an independent Python ray cast over the same GeoJSON files.
  @Test func downtownAustinIsInTravisCountyAndZone() {
    let codes = geometry.areaCodes(containing: MeshWXCoordinate(latitude: 30.2672, longitude: -97.7431))
    #expect(codes == ["TXC453", "TXZ192"])
  }

  @Test func roundRockIsInWilliamsonCounty() {
    let codes = geometry.areaCodes(containing: MeshWXCoordinate(latitude: 30.5083, longitude: -97.6789))
    #expect(codes == ["TXC491", "TXZ173"])
  }

  @Test func openWaterIsInAMarineZoneAndNoCounty() {
    let codes = geometry.areaCodes(containing: MeshWXCoordinate(latitude: 28.5, longitude: -94.5))
    #expect(codes == ["GMZ375"])
  }

  @Test func containmentByCodeDistinguishesOutsideFromNoOutline() {
    let austin = MeshWXCoordinate(latitude: 30.2672, longitude: -97.7431)
    #expect(geometry.contains(austin, ugc: "TXC453") == true)
    #expect(geometry.contains(austin, ugc: "TXC491") == false)
    // No outline is not "outside": the caller must not claim the area misses the point.
    #expect(geometry.contains(austin, ugc: "TXC997") == nil)
  }
}

/// How far a point is from an outline, and which areas an uncertain location might be in.
@Suite("MeshWX geometry distance")
struct MeshWXGeometryDistanceTests {
  let geometry = MeshWXGeometry.shared

  let stormPolygon = [
    MeshWXCoordinate(latitude: 30.52, longitude: -97.98),
    MeshWXCoordinate(latitude: 30.61, longitude: -97.62),
    MeshWXCoordinate(latitude: 30.38, longitude: -97.41),
    MeshWXCoordinate(latitude: 30.15, longitude: -97.5),
    MeshWXCoordinate(latitude: 30.09, longitude: -97.85),
    MeshWXCoordinate(latitude: 30.28, longitude: -98.04)
  ]

  @Test func insideIsZero() {
    #expect(MeshWXGeometry.distanceKilometres(from: MeshWXCoordinate(latitude: 30.35, longitude: -97.7), to: stormPolygon) == 0)
  }

  @Test func eastOfTheEasternVertexIsAboutTenKilometres() {
    // 0.1° of longitude at 30.38°N is 9.59 km, and the eastern vertex is the nearest point.
    let distance = MeshWXGeometry.distanceKilometres(from: MeshWXCoordinate(latitude: 30.38, longitude: -97.31), to: stormPolygon)
    #expect(distance > 9.3 && distance < 9.7, "got \(distance)")
  }

  @Test func theNearestPointCanBeOnAnEdge() {
    // Due south of the middle of the southern edge (30.15,-97.5)–(30.09,-97.85).
    let distance = MeshWXGeometry.distanceKilometres(from: MeshWXCoordinate(latitude: 30.0, longitude: -97.675), to: stormPolygon)
    #expect(distance > 12 && distance < 13.5, "got \(distance)")
  }

  @Test func noOutlineIsNotFarAway() {
    let austin = MeshWXCoordinate(latitude: 30.2672, longitude: -97.7431)
    #expect(geometry.distanceKilometres(from: austin, toArea: "TXC997") == nil)
    #expect(geometry.distanceKilometres(from: austin, toArea: "TXC453") == 0)
    let bexar = geometry.distanceKilometres(from: austin, toArea: "TXC029") ?? 0
    #expect(bexar > 60, "Bexar county is a long way from downtown Austin, got \(bexar)")
  }

  @Test func anUncertainLocationMayBeInTheNeighbouringCounties() {
    let austin = MeshWXCoordinate(latitude: 30.2672, longitude: -97.7431)
    let tight = geometry.areaCodes(near: austin, withinKilometres: 1)
    #expect(tight == ["TXC453", "TXZ192"])
    let loose = geometry.areaCodes(near: austin, withinKilometres: 35)
    #expect(loose.contains("TXC453"))
    #expect(loose.contains("TXC491"), "Williamson county is north of Austin")
    #expect(loose.contains("TXC209"), "Hays county is south-west of Austin")
    #expect(!loose.contains("TXC029"), "Bexar county is not within 35 km")
  }
}
