import Foundation
import Testing

@testable import MeshWX

/// The preload bundle (spec §9) and the search rules (spec §11).
///
/// The expected values are read off the kit's own `client_data` files, not off this
/// implementation: if a future bundle renumbers something, these fail loudly instead of
/// agreeing with whatever the code now does.
@Suite("MeshWX tables")
struct MeshWXTablesTests {
  let tables = MeshWXTables.shared

  @Test func bundleLoads() {
    #expect(tables.protocolVersion == 8, "protocol.json version is 8 for v5.0")
    #expect(tables.offices.count == 125)
    #expect(tables.stations.count == 2237)
    #expect(tables.states.count == 78)
    #expect(tables.points.count == 1873)
    #expect(tables.places.count == 34937)
  }

  @Test func wireIndicesResolveToTheDocumentedCodes() {
    // These three are the indices in the kit's own vectors: a warning from EWX over
    // Texas, and KAUS in the observation batch.
    #expect(tables.officeCode(35) == "EWX")
    #expect(tables.stateCode(42) == "TX")
    #expect(tables.stationICAO(202) == "KAUS")
    #expect(tables.stationICAO(860) == "KGTU")
    #expect(tables.stationICAO(976) == "KHYI")
    #expect(tables.stationIndex(forICAO: "KAUS") == 202)
    #expect(tables.stationIndex(forICAO: "kaus") == 202)
  }

  @Test func unknownIndicesReturnNilAndStillLabel() {
    #expect(tables.officeCode(250) == nil)
    #expect(tables.stationICAO(60000) == nil)
    #expect(tables.stateCode(200) == nil)
    #expect(tables.officeLabel(250) == "unknown (#250)")
    #expect(tables.stationLabel(60000) == "unknown (#60000)")
    #expect(tables.eventLabel(for: 250) == "unknown (#250)")
  }

  @Test func eventBytesResolveToVTECAndNames() {
    #expect(tables.vtec(for: 3) == "SV.W")
    #expect(tables.eventByCode["SV.W"] == 3)
    let name = tables.eventName(for: 3)
    #expect(name?.long == "Severe Thunderstorm Warning")
    #expect(name?.short == "SVR TSTM WRN")
    #expect(tables.vtec(for: 24) == "WS.W")
    #expect(tables.eventName(for: 24)?.long == "Winter Storm Warning")
  }

  @Test func severityComesFromTheSignificanceLetter() throws {
    #expect(tables.severity(for: 3) == .warning)  // SV.W
    #expect(tables.severity(for: 4) == .watch)  // SV.A
    #expect(tables.severity(for: 14) == .advisory)  // HT.Y
    // SPS has no significance letter at all and is a statement (spec §3).
    let sps = try #require(tables.eventByCode["SPS"])
    #expect(tables.severity(for: sps) == .statement)
  }

  @Test func skyCodeNamesComeFromTheBundle() {
    #expect(tables.skyNames[.broken] == "broken")
    #expect(tables.skyNames[.thunderstorm] == "thunderstorm")
    #expect(tables.skyNames.count == 16)
  }

  @Test func forecastPointsAreIndexedByWirePosition() throws {
    let point = try #require(tables.point(at: 102))
    #expect(point.name.contains("Austin"), "point 102 is \(point.name)")
    #expect(point.index == 102)
    #expect(point.office == "EWX")
    #expect(point.zone == "TXZ192")
  }

  @Test func nearestPointToAustinIsInTravis() throws {
    // Downtown Austin. The nearest bundled point is Camp Mabry (index 103), in Travis
    // county, zone TXZ192 — which is what `>f <index>` should be sent for.
    let point = try #require(tables.nearestPoint(toLat: 30.27, lon: -97.74))
    #expect(point.name.contains("Travis"), "nearest point is \(point.name)")
    #expect(point.zone == "TXZ192")
    let distance = MeshWXGeo.distanceMiles(
      fromLat: 30.27, lon: -97.74, toLat: point.lat, lon: point.lon)
    #expect(distance < 10)
  }

  @Test func stationDetailsAndSearch() throws {
    let kaus = try #require(tables.station(icao: "KAUS"))
    #expect(kaus.name == "AUSTIN-BERGSTROM INTL AIRPORT")
    #expect(kaus.state == "TX")
    #expect(abs(kaus.lat - 30.183) < 0.0005)
    // The wire index and the details table agree.
    #expect(tables.station(at: 202) == kaus)

    #expect(tables.searchStations(query: "KAU").contains { $0.icao == "KAUS" })
    #expect(tables.searchStations(query: "bergstrom").contains { $0.icao == "KAUS" })
    #expect(tables.searchStations(query: "").isEmpty)
  }

  @Test func zonesCountiesAndOfficesResolve() throws {
    let zone = try #require(tables.zone("TXZ192"))
    #expect(zone.name == "Travis")
    #expect(zone.office == "EWX")

    let county = try #require(tables.county("TXC453"))
    #expect(county.name == "Travis")
    #expect(county.state == "TX")

    let office = try #require(tables.office("EWX"))
    #expect(office.states == ["TX"])
    #expect(tables.zone("XXZ999") == nil)
    #expect(tables.county("XXC999") == nil)
  }

  @Test func placeSearchRanksByDistanceThenPopulation() {
    // Spec §11's own example: Round Rock exists in TX and AZ. Asked from Austin, the
    // one 20 miles up the road has to come first, even though ranking by population
    // alone would also get it right — so the AZ one must be present to prove the
    // search is not just filtering by state.
    let fromAustin = tables.searchPlaces(query: "round rock", nearLat: 30.27, lon: -97.74)
    let states = fromAustin.prefix(2).map(\.state)
    #expect(states == ["TX", "AZ"])
    #expect(fromAustin.first?.name == "ROUND ROCK")

    // Same query with no anchor: biggest first, which is still TX.
    let unanchored = tables.searchPlaces(query: "round rock")
    #expect(Array(unanchored.map(\.state).prefix(2)) == ["TX", "AZ"])
    #expect((unanchored.first?.population ?? 0) > 100_000)

    // Prefix, not substring: "rock" must not pull in "ROUND ROCK".
    #expect(!tables.searchPlaces(query: "ock").contains { $0.name == "ROUND ROCK" })
    #expect(tables.searchPlaces(query: "ROUND ROCK").count == 2)
    #expect(tables.searchPlaces(query: "round rock", limit: 1).count == 1)
    #expect(tables.searchPlaces(query: "   ").isEmpty)
  }

  @Test func warningAreasResolveToNamedCounties() throws {
    // The area list from the kit's severe thunderstorm vector: Hays and Travis.
    let runs = [
      MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 209, run: 1),
      MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1),
    ]
    let areas = tables.namedAreas(for: runs)
    #expect(areas.map(\.ugc) == ["TXC209", "TXC453"])
    #expect(areas.map(\.name) == ["Hays", "Travis"])
    #expect(areas.allSatisfy { $0.state == "TX" && $0.isCounty })
    #expect(areas.allSatisfy { $0.lat != nil && $0.lon != nil })
  }

  @Test func zoneRunExpandsToEveryZoneItCovers() {
    // The winter storm vector: zones 191-194 as one run.
    let areas = tables.namedAreas(for: [
      MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 191, run: 4)
    ])
    #expect(areas.map(\.ugc) == ["TXZ191", "TXZ192", "TXZ193", "TXZ194"])
    #expect(areas.map(\.name) == ["Hays", "Travis", "Bastrop", "Lee"])
  }

  @Test func areasSurviveAnUnknownUGC() {
    // A county number this bundle has no row for still yields an area, unnamed.
    let areas = tables.namedAreas(for: [
      MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 997, run: 1)
    ])
    #expect(areas.count == 1)
    #expect(areas[0].ugc == "TXC997")
    #expect(areas[0].name == nil)
    #expect(areas[0].lat == nil)
  }

  @Test func missingResourcesLoadEmptyRatherThanCrashing() {
    // A resource that did not copy must not take the app down on launch.
    let empty = MeshWXTables(resourceDirectory: URL(fileURLWithPath: "/nonexistent/meshwx"))
    #expect(empty.protocolVersion == 0)
    #expect(empty.offices.isEmpty)
    #expect(empty.officeCode(35) == nil)
    #expect(empty.officeLabel(35) == "unknown (#35)")
    #expect(empty.nearestPoint(toLat: 30.27, lon: -97.74) == nil)
    #expect(empty.searchPlaces(query: "round rock").isEmpty)
    #expect(empty.namedAreas(for: [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1)]).isEmpty)
  }

  /// Not an assertion about speed — a number for the report, and a guard that the
  /// bundle is being read at all.
  @Test func reportsBundleLoadTime() throws {
    let directory = try #require(MeshWXTables.bundledResourceDirectory)
    let started = ContinuousClock.now
    let fresh = MeshWXTables(resourceDirectory: directory)
    let milliseconds = (ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000
    print("MeshWX: eight JSON tables loaded in \(milliseconds) ms")
    #expect(fresh.places.count == 34937)
  }
}
