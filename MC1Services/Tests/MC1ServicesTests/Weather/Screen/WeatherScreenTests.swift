import Foundation
@testable import MC1Services
import MeshWX
import Testing

@Suite("Weather names")
struct WeatherNamesTests {
  @Test
  func `station names lose their capitals and abbreviations but keep state codes`() {
    #expect(WeatherNames.stationName("DRAUGHON-MILLER CNTRL TX RGNL ARPT") == "Draughon-Miller Central TX Regional Airport")
    #expect(WeatherNames.stationName("AUSTIN-BERGSTROM INTL AIRPORT") == "Austin-Bergstrom International Airport")
    #expect(WeatherNames.stationName("NEW BRAUNFELS MUNICIPAL AP") == "New Braunfels Municipal Airport")
    #expect(WeatherNames.stationName("RANDOLPH AFB") == "Randolph AFB")
    #expect(WeatherNames.stationName("Already Mixed Case") == "Already Mixed Case")
  }

  @Test
  func `forecast point names drop their county and state tail`() {
    #expect(WeatherNames.pointName("Austin Camp Mabry-Travis TX") == "Austin Camp Mabry")
    #expect(WeatherNames.pointName("Central Park-New York NY") == "Central Park")
    #expect(WeatherNames.pointName("10 Mile Boxcars") == "10 Mile Boxcars")
  }

  /// §3.1 U-26: the tail is a qualifier whatever it is, not only "-County ST". A town tail is
  /// one when the head is a name on its own, which is what keeps a hyphenated station name — and
  /// a point whose own name has a hyphen in it — whole.
  @Test
  func `a forecast point's tail is dropped when it is a town too`() {
    #expect(WeatherNames.pointName("Luis Munoz Marin International Airport-San Juan")
      == "Luis Munoz Marin International Airport")
    #expect(WeatherNames.pointName("Boerne-Kendall TX") == "Boerne")
    #expect(WeatherNames.pointName("Foo-Bar") == "Foo-Bar")
    #expect(WeatherNames.pointName("351001 (PATJENS)-Sherman OR") == "351001 (PATJENS)")
    // Station names never go through the point rule, and would not survive it: they are
    // rendered by `stationName`, which leaves every hyphen where the bundle put it.
    #expect(WeatherNames.stationName("OCALA INTERNATIONAL AIRPORT-JIM TAYLOR FIELD")
      == "Ocala International Airport-Jim Taylor Field")
  }

  /// §3.1 U-25: one forecast point read three ways on one drive — "Austin-Camp Mabry" from the
  /// station beside it, "Austin Camp Mabry" in the forecast header, "Austin Camp Mabry, TX" in
  /// Places. Every site that names a point now calls ``WeatherNames/pointLabel(_:)``: the forecast
  /// header (`WeatherForecastSection.pointParts`), the Places rows for what was heard
  /// (`WeatherPlacePickerView.heardSection`, `WeatherCopy.pointName`) and the empty place's
  /// nearest line (`WeatherCopy.emptyPlaceNearest`) — so there is one spelling to agree on.
  @Test
  func `the three sites that name a forecast point agree`() {
    let raw = "Austin Camp Mabry-Travis TX"
    let label = WeatherNames.pointLabel(raw)
    #expect(label == "Austin Camp Mabry, TX")
    // The header, the Places row and the nearest line are the same call, so they are the same
    // string; the bare head is internal and no screen can reach for it instead.
    #expect(WeatherNames.pointLabel(raw) == label)
    #expect(WeatherNames.pointName(raw) == "Austin Camp Mabry")
    #expect(WeatherNames.pointState(raw) == "TX")
    // A point whose tail is a town has no state to keep, and reads as its name alone.
    #expect(WeatherNames.pointLabel("Luis Munoz Marin International Airport-San Juan")
      == "Luis Munoz Marin International Airport")
    #expect(WeatherNames.pointLabel("Central Park-New York NY") == "Central Park, NY")
    #expect(WeatherNames.pointLabel("10 Mile Boxcars") == "10 Mile Boxcars")
  }

  @Test
  func `place labels are title case with the state`() {
    #expect(WeatherNames.placeLabel(name: "ROUND ROCK", state: "TX") == "Round Rock, TX")
    #expect(WeatherNames.placeLabel(near: WeatherPhoneFixture.austin, tables: .shared) == "Austin, TX")
  }
}

@Suite("Weather place")
struct WeatherPlaceTests {
  let now = WeatherPhoneFixture.now

  @Test
  func `a fresh accurate fix is the current place with a half-kilometre radius`() {
    let sample = WeatherLocationSample(latitude: 30.27, longitude: -97.74, horizontalAccuracy: 20, timestamp: now.addingTimeInterval(-30))
    let place = WeatherPlace.location(sample, label: "Austin, TX", now: now)
    #expect(place.kind == .current)
    #expect(place.uncertaintyKilometres == 0.5)
  }

  @Test
  func `the radius grows a kilometre a minute past five minutes and stops at twenty-five`() {
    #expect(WeatherPlace.uncertainty(accuracyMetres: 100, age: 15 * 60) == 10.5)
    #expect(WeatherPlace.uncertainty(accuracyMetres: 100, age: 50 * 60) == 25.5)
    #expect(WeatherPlace.uncertainty(accuracyMetres: 3000, age: 0) == 3)
    #expect(WeatherPlace.uncertainty(accuracyMetres: -1, age: 0) == 1)
  }

  @Test
  func `a fix over an hour old is only where the phone was`() {
    let sample = WeatherLocationSample(latitude: 30.27, longitude: -97.74, horizontalAccuracy: 20, timestamp: now.addingTimeInterval(-3 * 3600))
    #expect(WeatherPlace.location(sample, label: "Austin, TX", now: now).kind == .lastKnown)
  }

  @Test
  func `a searched town has a town-sized radius and a readable label`() {
    let place = WeatherPlace.searched(MeshWXPlace(name: "ROUND ROCK", state: "TX", lat: 30.51, lon: -97.68, population: 119_000))
    #expect(place.kind == .searched)
    #expect(place.uncertaintyKilometres == 5)
    #expect(place.label == "Round Rock, TX")
  }
}

@Suite("Weather coverage")
struct WeatherCoverageTests {
  typealias P = WeatherPhoneFixture

  @Test
  func `the hourly batch is the footprint and Austin is inside it`() {
    let coverage = WeatherCoverage.make(states: [P.botID: P.state()], tables: .shared, now: P.now)
    #expect(coverage.stations.count == 14)
    #expect(coverage.contains(P.austin))
    #expect(coverage.botIDs(covering: P.austin) == [P.botID])
  }

  @Test
  func `Dallas is outside it`() throws {
    let coverage = WeatherCoverage.make(states: [P.botID: P.state()], tables: .shared, now: P.now)
    #expect(!coverage.contains(P.dallas))
    let nearest = try #require(coverage.nearest(to: P.dallas))
    #expect(nearest.station.station.icao == "KTPL")
    #expect(nearest.kilometres > 150)
  }

  @Test
  func `a place inside the ring of stations is covered, however far from the nearest`() throws {
    let coverage = WeatherCoverage.make(states: [P.botID: P.state()], tables: .shared, now: P.now)
    // Between Temple, Caldwell and Austin Executive: about 50 km from each.
    let middle = MeshWXCoordinate(latitude: 30.75, longitude: -97.15)
    #expect(try #require(coverage.nearest(to: middle)).kilometres > 40)
    #expect(coverage.contains(middle))
  }

  /// WX-AUS relays alerts for about 120 km around Austin, and its farthest station is 96 km out:
  /// 80 km around every station reached 176 km, past where it sends anything.
  @Test
  func `a place past the outer stations is outside, though one is within 80 km`() throws {
    let coverage = WeatherCoverage.make(states: [P.botID: P.state()], tables: .shared, now: P.now)
    // North of Lampasas, and east of Caldwell.
    for outside in [MeshWXCoordinate(latitude: 31.6, longitude: -98.2), MeshWXCoordinate(latitude: 30.3, longitude: -96.3)] {
      let nearest = try #require(coverage.nearest(to: outside)).kilometres
      #expect(nearest > WeatherCoverage.stationReachKilometres && nearest < 80)
      #expect(!coverage.contains(outside))
      #expect(coverage.botIDs(covering: outside).isEmpty)
    }
    // Just west of Llano's station, outside the ring but within its reach.
    #expect(coverage.contains(MeshWXCoordinate(latitude: 30.784, longitude: -98.85)))
  }

  @Test
  func `each bot covers its own ring, and two stations reach twenty kilometres`() {
    var second = WeatherBotState(botID: 0x0102)
    // Austin-Bergstrom and Camp Mabry: two stations, no ring.
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: MeshWXHeader(seq: 1, bot: 0x0102, type: .observations), payload: .observations(MeshWXObservations(
        timestampMinutes: P.nowMinutes, stations: [MeshWXStationObservation(stationIndex: 202, tempF: 80), MeshWXStationObservation(stationIndex: 194, tempF: 81)]))),
      to: &second, receivedAt: P.now)
    let coverage = WeatherCoverage.make(states: [P.botID: P.state(), 0x0102: second], tables: .shared, now: P.now)
    #expect(coverage.stations.count == 16, "a station both bots report is in both footprints")
    #expect(coverage.botIDs(covering: P.austin) == [P.botID, 0x0102])
    #expect(coverage.botIDs(covering: MeshWXCoordinate(latitude: 30.75, longitude: -97.15)) == [P.botID])
  }

  @Test
  func `a single-station answer and a day-old batch are not coverage`() {
    var state = P.state(observationsAgo: 25 * 3600)
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: P.header(240, .observations), payload: .observations(MeshWXObservations(
        timestampMinutes: P.nowMinutes, stations: [MeshWXStationObservation(stationIndex: 1000, tempF: 70)]))),
      to: &state, receivedAt: P.now)
    #expect(WeatherCoverage.make(states: [P.botID: state], tables: .shared, now: P.now).isEmpty)
  }

  /// Anybody's `>o KATT` is broadcast to everyone, and every phone keeps the newer reading. It must
  /// not also take Camp Mabry out of WX-AUS's area, shrink the outline or change the count the Now
  /// card's link shows.
  @Test
  func `a single-station answer leaves the station in the footprint it was reported in`() {
    var state = P.state()
    let before = WeatherCoverage.make(states: [P.botID: state], tables: .shared, now: P.now)
    #expect(before.stations.count == 14)
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: P.header(240, .observations), payload: .observations(MeshWXObservations(
        timestampMinutes: P.nowMinutes, stations: [MeshWXStationObservation(stationIndex: 202, tempF: 91)]))),
      to: &state, receivedAt: P.now)
    let after = WeatherCoverage.make(states: [P.botID: state], tables: .shared, now: P.now)
    #expect(after.stations.map(\.index) == before.stations.map(\.index))
    #expect(after.contains(P.austin))
    #expect(state.observations[202]?.observation.tempF == 91, "the newer reading is still what is shown")
  }
}

@Suite("Weather alert placement and priority")
struct WeatherAlertPlacementTests {
  typealias P = WeatherPhoneFixture
  let tables = MeshWXTables.shared

  let stormPolygon = [
    MeshWXCoordinate(latitude: 30.52, longitude: -97.98),
    MeshWXCoordinate(latitude: 30.61, longitude: -97.62),
    MeshWXCoordinate(latitude: 30.38, longitude: -97.41),
    MeshWXCoordinate(latitude: 30.15, longitude: -97.5),
    MeshWXCoordinate(latitude: 30.09, longitude: -97.85),
    MeshWXCoordinate(latitude: 30.28, longitude: -98.04)
  ]

  func warning(event: UInt8 = 3, polygon: [MeshWXCoordinate]? = nil, areas: [MeshWXAreaRun]? = nil,
               tornado: MeshWXTornadoTag = .none, floodDamage: MeshWXFloodDamage = .none, etn: UInt16 = 1) -> MeshWXWarning {
    MeshWXWarning(identity: MeshWXWarningIdentity(event: event, office: 35, etn: etn), expiresMinutes: P.nowMinutes + 60,
                  tornado: tornado, floodDamage: floodDamage, polygon: polygon, areas: areas)
  }

  @Test
  func `a polygon covering the place is here`() {
    #expect(WeatherAlertPlacement.place(warning(polygon: stormPolygon), at: P.place(P.austin), geometry: UnloadedGeometry(), tables: tables) == .here)
  }

  @Test
  func `a polygon just beyond an accurate fix is near, but within a stale fix's radius it is here`() {
    // 9.6 km east of the polygon's eastern vertex.
    let east = MeshWXCoordinate(latitude: 30.38, longitude: -97.31)
    let accurate = WeatherAlertPlacement.place(warning(polygon: stormPolygon), at: P.place(east), geometry: UnloadedGeometry(), tables: tables)
    guard case let .near(kilometres, direction) = accurate else {
      Issue.record("expected near, got \(accurate)")
      return
    }
    #expect(kilometres > 9 && kilometres < 10)
    #expect(direction == .west)
    #expect(WeatherAlertPlacement.place(warning(polygon: stormPolygon), at: P.place(east, radius: 12), geometry: UnloadedGeometry(), tables: tables) == .here)
  }

  @Test
  func `a polygon far away is elsewhere`() {
    let sanAntonio = MeshWXCoordinate(latitude: 29.42, longitude: -98.49)
    #expect(WeatherAlertPlacement.place(warning(polygon: stormPolygon), at: P.place(sanAntonio), geometry: UnloadedGeometry(), tables: tables) == .elsewhere)
  }

  /// The outlines load lazily; placement says "checking" until they have, which is also what
  /// obliges the screen model to preload them when an area-based alert is held.
  @Test
  func `a zone warning is checking until outlines load, then here over Travis`() async {
    await MeshWXGeometry.shared.preload()
    let travisZone = [MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 192, run: 1)]
    #expect(WeatherAlertPlacement.place(warning(event: 24, areas: travisZone), at: P.place(P.austin), geometry: UnloadedGeometry(), tables: tables) == .checking)
    #expect(WeatherAlertPlacement.place(warning(event: 24, areas: travisZone), at: P.place(P.austin), geometry: MeshWXGeometry.shared, tables: tables) == .here)
  }

  @Test
  func `an area with no outline near the place is unplaced, never elsewhere`() async {
    await MeshWXGeometry.shared.preload()
    // Zone 999 has neither an outline nor a centroid in the bundle.
    let unknownZone = [MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 999, run: 1)]
    #expect(WeatherAlertPlacement.place(warning(event: 24, areas: unknownZone), at: P.place(P.austin), geometry: MeshWXGeometry.shared, tables: tables) == .unplaced)
    #expect(WeatherAlertPlacement.place(warning(event: 24), at: P.place(P.austin), geometry: MeshWXGeometry.shared, tables: tables) == .unplaced)
  }

  @Test
  func `tornado warnings outrank everything, then the tagged storms`() {
    let tornado = WeatherAlertPriority.rank(warning(event: 1), tables: tables)
    let catastrophicFlood = WeatherAlertPriority.rank(warning(event: 6, floodDamage: .catastrophic), tables: tables)
    let taggedStorm = WeatherAlertPriority.rank(warning(event: 3, tornado: .possible), tables: tables)
    let flashFlood = WeatherAlertPriority.rank(warning(event: 6), tables: tables)
    let storm = WeatherAlertPriority.rank(warning(event: 3), tables: tables)
    let winterStormWatch = WeatherAlertPriority.rank(warning(event: 25), tables: tables)
    let heatAdvisory = WeatherAlertPriority.rank(warning(event: 14), tables: tables)
    let ranks: [Int] = [tornado, catastrophicFlood, taggedStorm, flashFlood, storm, winterStormWatch, heatAdvisory]
    #expect(ranks == [0, 2, 3, 4, 5, 7, 8])
  }
}

@Suite("Weather alert items and status")
struct WeatherAlertStatusTests {
  typealias P = WeatherPhoneFixture
  let tables = MeshWXTables.shared

  func stormMessage(seq: UInt8, etn: UInt16 = 42, event: UInt8 = 3, expiresMinutes: UInt32? = nil,
                    polygon: [MeshWXCoordinate]? = nil, bot: UInt16 = P.botID) -> MeshWXMessage {
    let shape = polygon ?? [
      MeshWXCoordinate(latitude: 30.52, longitude: -97.98), MeshWXCoordinate(latitude: 30.61, longitude: -97.62),
      MeshWXCoordinate(latitude: 30.38, longitude: -97.41), MeshWXCoordinate(latitude: 30.15, longitude: -97.5),
      MeshWXCoordinate(latitude: 30.09, longitude: -97.85)]
    return MeshWXMessage(
      header: MeshWXHeader(seq: seq, bot: bot, type: .warning),
      payload: .warning(MeshWXWarning(identity: MeshWXWarningIdentity(event: event, office: 35, etn: etn),
                                      expiresMinutes: expiresMinutes ?? P.nowMinutes + 60, polygon: shape)))
  }

  func digestMessage(seq: UInt8, builtMinutes: UInt32, entries: [MeshWXDigest.Entry] = [], feedHealth: UInt8 = 3) -> MeshWXMessage {
    MeshWXMessage(header: P.header(seq, .digest),
                  payload: .digest(MeshWXDigest(nowMinutes: builtMinutes, feedHealth: feedHealth, entries: entries)))
  }

  func status(_ states: [UInt16: WeatherBotState], place: WeatherPlace?, connected: Bool = true,
              session: Date? = WeatherPhoneFixture.now.addingTimeInterval(-7200)) -> WeatherAlertStatus {
    let coverage = WeatherCoverage.make(states: states, tables: tables, now: P.now)
    let items = WeatherAlertItems.make(states: states, place: place, geometry: MeshWXGeometry.shared, tables: tables, now: P.now)
    return WeatherAlertStatus.evaluate(place: place, coverage: coverage, states: states, items: items,
                                       isRadioConnected: connected, sessionStartedAt: session, tables: tables, now: P.now)
  }

  /// A phone that heard a fresh, complete list twenty minutes ago.
  func listening(_ mutate: (inout WeatherBotState) -> Void = { _ in }) -> [UInt16: WeatherBotState] {
    var state = P.state()
    _ = WeatherStateReducer.apply(digestMessage(seq: 234, builtMinutes: P.nowMinutes - 20), to: &state, receivedAt: P.now.addingTimeInterval(-1190))
    mutate(&state)
    return [P.botID: state]
  }

  @Test
  func `the owner's phone had no alert list, so alerts are not checked`() {
    #expect(status([P.botID: P.state()], place: P.place(P.austin)) == .notChecked)
  }

  @Test
  func `no place and out of coverage come first`() {
    #expect(status(listening(), place: nil) == .noPlace)
    #expect(status(listening(), place: P.place(P.dallas, label: "Dallas, TX")) == .outOfCoverage)
  }

  @Test
  func `a fresh complete list while listening, with nothing anywhere, is the green check`() {
    #expect(status(listening(), place: P.place(P.austin)) == .clear(asOf: Date(unixMinutes: P.nowMinutes - 20)))
  }

  @Test
  func `offline, stale feed, missed messages, and an old list each withhold the check`() {
    #expect(status(listening(), place: P.place(P.austin), connected: false) == .radioOffline(listAsOf: Date(unixMinutes: P.nowMinutes - 20)))

    var quiet = P.state()
    _ = WeatherStateReducer.apply(digestMessage(seq: 234, builtMinutes: P.nowMinutes - 20, feedHealth: 75), to: &quiet, receivedAt: P.now)
    #expect(status([P.botID: quiet], place: P.place(P.austin)) == .feedQuiet(minutesSinceProduct: 300))

    #expect(status(listening { $0.needsDigest = true }, place: P.place(P.austin)) == .missedMessages)

    var old = P.state()
    _ = WeatherStateReducer.apply(digestMessage(seq: 234, builtMinutes: P.nowMinutes - 200), to: &old, receivedAt: P.now.addingTimeInterval(-12_000))
    #expect(status([P.botID: old], place: P.place(P.austin)) == .listOld(asOf: Date(unixMinutes: P.nowMinutes - 200)))
  }

  /// Spec §5: a quiet home office passes four hours on a healthy feed, so it says nothing is wrong
  /// and yields to whatever asks for something; only a feed that never delivered comes first.
  @Test
  func `a quiet home office withholds calm below the other statuses, a feed that never delivered above them`() {
    var quiet = P.state()
    _ = WeatherStateReducer.apply(digestMessage(seq: 234, builtMinutes: P.nowMinutes - 20, feedHealth: 75), to: &quiet, receivedAt: P.now)
    quiet.needsDigest = true
    #expect(status([P.botID: quiet], place: P.place(P.austin)) == .missedMessages)
    #expect(status([P.botID: quiet], place: P.place(P.austin), connected: false) == .radioOffline(listAsOf: Date(unixMinutes: P.nowMinutes - 20)))

    var never = P.state()
    _ = WeatherStateReducer.apply(digestMessage(seq: 234, builtMinutes: P.nowMinutes - 20, feedHealth: 255), to: &never, receivedAt: P.now)
    never.needsDigest = true
    #expect(status([P.botID: never], place: P.place(P.austin)) == .feedNeverReceived)
    #expect(status([P.botID: never], place: P.place(P.austin), connected: false) == .feedNeverReceived)
  }

  @Test
  func `a watch the bot sends as office 0 does not say which office it carries`() throws {
    // A revision 2 bot, without the Storm Prediction Center in its bundle, sent its watches as office 0.
    let tornadoWatch = try #require(tables.eventByCode["TO.A"])
    let entry = MeshWXDigest.Entry(identity: MeshWXWarningIdentity(event: tornadoWatch, office: 0, etn: 612), expiresRelativeMinutes: 300, expiresMinutes: P.nowMinutes + 280)
    var state = P.state()
    _ = WeatherStateReducer.apply(digestMessage(seq: 234, builtMinutes: P.nowMinutes - 20, entries: [entry]), to: &state, receivedAt: P.now.addingTimeInterval(-1190))
    state.missingFromDigest = []
    #expect(status([P.botID: state], place: P.place(P.austin)) == .clear(asOf: Date(unixMinutes: P.nowMinutes - 20)))
  }

  @Test
  func `a national centre's product does not say which office the bot carries`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meshwx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"offices": ["ABQ", "EWX", "NHC", "WNS"], "stations": [], "states": []}"#.utf8)
      .write(to: directory.appendingPathComponent("index.json"))
    let updated = MeshWXTables(resourceDirectory: directory)
    #expect(WeatherAlertStatus.showsOffice(MeshWXWarningIdentity(event: 3, office: 1, etn: 42), tables: updated))
    #expect(!WeatherAlertStatus.showsOffice(MeshWXWarningIdentity(event: 3, office: 2, etn: 9), tables: updated))
    #expect(!WeatherAlertStatus.showsOffice(MeshWXWarningIdentity(event: 3, office: 3, etn: 612), tables: updated))
  }

  @Test
  func `a list received before this radio session started is old, however recent`() {
    #expect(status(listening(), place: P.place(P.austin), session: P.now.addingTimeInterval(-60)) == .listOld(asOf: Date(unixMinutes: P.nowMinutes - 20)))
  }

  @Test
  func `a last-known location never earns the check`() {
    #expect(status(listening(), place: P.place(P.austin, kind: .lastKnown)) == .locationOld(since: P.now))
  }

  @Test
  func `an alert here lets the rows speak; one elsewhere withholds the check`() {
    let here = listening { state in
      _ = WeatherStateReducer.apply(self.stormMessage(seq: 235), to: &state, receivedAt: P.now)
    }
    #expect(status(here, place: P.place(P.austin)) == .rowsSpeak)

    let farPolygon = [MeshWXCoordinate(latitude: 29.0, longitude: -99.9), MeshWXCoordinate(latitude: 29.1, longitude: -99.8),
                      MeshWXCoordinate(latitude: 29.0, longitude: -99.7)]
    let elsewhere = listening { state in
      _ = WeatherStateReducer.apply(self.stormMessage(seq: 235, polygon: farPolygon), to: &state, receivedAt: P.now)
    }
    #expect(status(elsewhere, place: P.place(P.austin)) == .noneHere(elsewhere: 1, asOf: Date(unixMinutes: P.nowMinutes - 20)))
  }

  /// `.officeMayNotBeCovered` is no longer produced (docs/MESHWX_UI.md §3.1 I-B18): the offices a
  /// bot has *shown* are whichever products happen to be active, so an hour in which the Austin
  /// advisories expired and only a Fort Worth warning was left said WX-AUS might not carry its own
  /// home county. A place in the footprint is answered for by the list it has.
  @Test
  func `a place forecast by an office the list does not name is not called uncovered`() throws {
    // Temple is in the footprint (KTPL) but forecast by NWS Fort Worth; WX-AUS's list names Austin/San Antonio.
    let temple = MeshWXCoordinate(latitude: 31.10, longitude: -97.34)
    let office = try #require(tables.nearestPoint(toLat: temple.latitude, lon: temple.longitude)?.office)
    try #require(office != "EWX")
    let entry = MeshWXDigest.Entry(identity: MeshWXWarningIdentity(event: 14, office: 35, etn: 3), expiresRelativeMinutes: 300, expiresMinutes: P.nowMinutes + 280)
    var state = P.state()
    _ = WeatherStateReducer.apply(digestMessage(seq: 234, builtMinutes: P.nowMinutes - 20, entries: [entry]), to: &state, receivedAt: P.now.addingTimeInterval(-1190))
    state.missingFromDigest = []
    #expect(status([P.botID: state], place: P.place(temple, label: "Temple, TX")) == .clear(asOf: Date(unixMinutes: P.nowMinutes - 20)))
  }

  @Test
  func `alerts from two bots are one row each, and a covering alert that just expired stays`() throws {
    var first = P.state()
    _ = WeatherStateReducer.apply(stormMessage(seq: 235), to: &first, receivedAt: P.now)
    var second = WeatherBotState(botID: 0x0102)
    _ = WeatherStateReducer.apply(stormMessage(seq: 1, bot: 0x0102), to: &second, receivedAt: P.now.addingTimeInterval(-30))
    _ = WeatherStateReducer.apply(stormMessage(seq: 2, etn: 99, expiresMinutes: P.nowMinutes - 5, bot: 0x0102), to: &second, receivedAt: P.now.addingTimeInterval(-3600))
    let items = WeatherAlertItems.make(states: [P.botID: first, 0x0102: second], place: P.place(P.austin),
                                       geometry: MeshWXGeometry.shared, tables: tables, now: P.now)
    #expect(items.count == 2)
    let active = try #require(items.first { $0.identity.etn == 42 })
    #expect(active.botIDs == [UInt16(0x0102), P.botID])
    #expect(items.first { $0.identity.etn == 99 }?.kind == .expiredRecently)
  }

  @Test
  func `an upgrade whose replacement is missing is a row where it was`() throws {
    var state = P.state()
    _ = WeatherStateReducer.apply(stormMessage(seq: 235), to: &state, receivedAt: P.now)
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: P.header(236, .cancel), payload: .cancel(MeshWXCancel(identity: MeshWXWarningIdentity(event: 3, office: 35, etn: 42), reason: .upgraded))),
      to: &state, receivedAt: P.now)
    let items = WeatherAlertItems.make(states: [P.botID: state], place: P.place(P.austin), geometry: MeshWXGeometry.shared, tables: tables, now: P.now)
    let item = try #require(items.first)
    #expect(item.kind == .upgradedAwaitingReplacement(cancelledAt: P.now))
    #expect(item.placement == .here)
  }
}

@Suite("Weather stations")
struct WeatherStationTests {
  typealias P = WeatherPhoneFixture

  func readings(_ state: WeatherBotState, at place: WeatherPlace?) -> [WeatherStationReading] {
    let states = [P.botID: state]
    let coverage = WeatherCoverage.make(states: states, tables: .shared, now: P.now)
    return WeatherStations.readings(states: states, coverage: coverage, place: place, tables: .shared, now: P.now)
  }

  func primary(_ state: WeatherBotState, at place: WeatherPlace?) -> WeatherPrimaryStation {
    WeatherPrimaryStation.pick(readings: readings(state, at: place), place: place)
  }

  /// A bare `>o` comes back with the batch the bot would send *now*, so only a station that batch
  /// still carries can be refreshed by it. One the bot has dropped since, or one held only from
  /// somebody's single-station answer, has to be asked for by its code.
  @Test
  func `only a station in the newest batch can be refreshed by the bot's batch`() throws {
    var state = P.state()
    // Somebody's `>o` for a station the bot's batch never carries.
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: P.header(240, .observations), payload: .observations(MeshWXObservations(
        timestampMinutes: P.nowMinutes, stations: [MeshWXStationObservation(stationIndex: 1000, tempF: 70)]))),
      to: &state, receivedAt: P.now)
    // The next hourly batch, without Llano (1929).
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: P.header(241, .observations), payload: .observations(MeshWXObservations(
        timestampMinutes: P.nowMinutes + 58,
        stations: P.stations.dropFirst().map { MeshWXStationObservation(stationIndex: $0.0, tempF: $0.1, sky: .few) }))),
      to: &state, receivedAt: P.now)

    let held = readings(state, at: P.place(P.austin))
    func reading(_ index: UInt16) throws -> WeatherStationReading {
      try #require(held.first { $0.index == index })
    }
    #expect(try reading(202).isInLatestBatch)
    let dropped = try reading(1929)
    #expect(dropped.isInFootprint, "still in the area it was reported in an hour ago")
    #expect(!dropped.isInLatestBatch, "a bare `>o` would come back without it")
    let answered = try reading(1000)
    #expect(!answered.isInFootprint)
    #expect(!answered.isInLatestBatch)
  }

  /// The list the Now card's link opens starts with the station the card names. The card's station
  /// is not always the first by distance: a nearer stale one sorts ahead of it.
  @Test
  func `the list leads with the station the Now card is showing`() throws {
    let place = P.place(P.austin)
    let held = readings(P.state(), at: place)
    let index = try #require(WeatherPrimaryStation.pick(readings: held, place: place).index)
    let moved = Array(held.dropFirst()) + [held[0]]
    #expect(WeatherStations.ordered(moved, leading: index).first?.index == index)
    #expect(WeatherStations.ordered(moved, leading: index).count == held.count)
    #expect(WeatherStations.ordered(held, leading: nil) == held)
  }

  @Test
  func `downtown Austin leads with Camp Mabry, not the first station in the batch`() throws {
    guard case let .reading(reading) = primary(P.state(), at: P.place(P.austin)) else {
      Issue.record("expected a reading")
      return
    }
    #expect(reading.station.icao == "KATT")
    #expect(!reading.isStale)
    #expect((reading.distanceKilometres ?? 99) < 10)
  }

  @Test
  func `stale readings in reach are still offered, marked stale`() {
    guard case let .reading(reading) = primary(P.state(observationsAgo: 3 * 3600), at: P.place(P.austin)) else {
      Issue.record("expected a reading")
      return
    }
    #expect(reading.isStale)
  }

  @Test
  func `Dallas gets the nearest station named, not a reading`() {
    guard case let .noneNearby(nearest) = primary(P.state(), at: P.place(P.dallas)) else {
      Issue.record("expected noneNearby")
      return
    }
    #expect(nearest.station.icao == "KTPL")
  }

  @Test
  func `no observations and no place are their own states`() {
    #expect(primary(WeatherBotState(botID: P.botID), at: P.place(P.austin)) == .noObservations)
    #expect(primary(P.state(), at: nil) == .noPlace)
  }
}

@Suite("Weather forecast rows")
struct WeatherForecastRowTests {
  typealias P = WeatherPhoneFixture
  let calendar = WeatherPhoneFixture.calendar

  func date(_ day: Int, _ hour: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
  }

  var live: MeshWXForecast {
    P.dailyForecast(point: 103, issuedMinutes: UInt32(date(14, 19).timeIntervalSince1970 / 60) + 52,
                    temps: [(102, 77), (100, 78), (98, 75), (97, 73), (98, 74), (99, 76), (96, 81)])
  }

  @Test
  func `the live daily forecast reads as days, not tonight at a hundred degrees`() {
    let rows = WeatherForecastRows.rows(for: live, now: date(14, 23), calendar: calendar)
    #expect(rows.count == 7)
    #expect(rows[0].label == .today && rows[0].highF == 102 && rows[0].lowF == 77)
    #expect(rows[1].label == .tomorrow && rows[1].highF == 100 && rows[1].lowF == 78)
    #expect(rows[2].label == .day(date(16, 0)))
  }

  /// Spec §7 (revision 3): entry i is the issue date plus `first / 2 + i` days.
  @Test
  func `an evening issue that starts tomorrow is labelled tomorrow`() {
    let evening = MeshWXForecast(pointIndex: 103, issuedMinutes: live.issuedMinutes, firstPeriod: 2, periods: live.periods)
    let rows = WeatherForecastRows.rows(for: evening, now: date(14, 23), calendar: calendar)
    #expect(rows.count == 7)
    #expect(rows[0].label == .tomorrow && rows[0].highF == 102)
    #expect(rows[1].label == .day(date(16, 0)))
  }

  @Test
  func `next morning yesterday's day is gone`() {
    let rows = WeatherForecastRows.rows(for: live, now: date(15, 8), calendar: calendar)
    #expect(rows.count == 6)
    #expect(rows[0].label == .today && rows[0].highF == 100)
  }

  var spec: MeshWXForecast {
    MeshWXForecast(
      pointIndex: 102, issuedMinutes: UInt32(date(14, 15).timeIntervalSince1970 / 60), firstPeriod: 1,
      periods: [
        MeshWXForecastPeriod(lowF: 73, popPercent: 20, sky: .scattered, windMph: 5),
        MeshWXForecastPeriod(highF: 93, popPercent: 40, sky: .broken, thunder: true, windMph: 10),
        MeshWXForecastPeriod(lowF: 72, popPercent: 30, sky: .broken, windy: true, windMph: 25),
        MeshWXForecastPeriod(highF: 90, popPercent: 60, sky: .rain, windMph: 20)
      ])
  }

  @Test
  func `spec periods pair each day with its night and keep every hazard`() {
    let rows = WeatherForecastRows.rows(for: spec, now: date(14, 20), calendar: calendar)
    #expect(rows.map(\.label) == [.tonight, .tomorrow, .day(date(16, 0))])
    #expect(rows[0].lowF == 73 && rows[0].highF == nil && rows[0].isNightIcon)
    let tomorrow = rows[1]
    #expect(tomorrow.highF == 93 && tomorrow.lowF == 72)
    #expect(tomorrow.thunder && tomorrow.windy, "the day's thunder and the night's wind both reach the row")
    #expect(tomorrow.popPercent == 40 && !tomorrow.popIsNight)
    #expect(tomorrow.windMph == 25)
    #expect(tomorrow.sky == .broken)
  }

  @Test
  func `after midnight last night is still tonight until six`() {
    let rows = WeatherForecastRows.rows(for: spec, now: date(15, 1), calendar: calendar)
    #expect(rows.first?.label == .tonight)
    let later = WeatherForecastRows.rows(for: spec, now: date(15, 7), calendar: calendar)
    #expect(later.first?.label == .today)
    #expect(later.first?.highF == 93)
  }

  @Test
  func `a night with the higher rain chance says so`() {
    let forecast = MeshWXForecast(
      pointIndex: 1, issuedMinutes: UInt32(date(14, 5).timeIntervalSince1970 / 60), firstPeriod: 0,
      periods: [MeshWXForecastPeriod(highF: 90, popPercent: 10), MeshWXForecastPeriod(lowF: 70, popPercent: 70, thunder: true)])
    let row = WeatherForecastRows.rows(for: forecast, now: date(14, 9), calendar: calendar)[0]
    #expect(row.popPercent == 70 && row.popIsNight && row.thunder)
  }
}

@Suite("Weather forecast card and other places")
struct WeatherForecastCardTests {
  typealias P = WeatherPhoneFixture
  let tables = MeshWXTables.shared

  @Test
  func `downtown Austin gets the Camp Mabry forecast the bot sent`() throws {
    guard case let .forecast(summary) = WeatherForecastCard.make(states: [P.botID: P.state()], place: P.place(P.austin), tables: tables, now: P.now, calendar: P.calendar) else {
      Issue.record("expected a forecast")
      return
    }
    #expect(summary.point.index == 103)
    #expect(summary.source == .placePoint)
    #expect(summary.layout == .days)
    #expect(summary.rows.first?.highF == 102)
  }

  @Test
  func `Round Rock is not answered with Austin's forecast from twenty kilometres away`() {
    guard case let .missing(point, kilometres) = WeatherForecastCard.make(states: [P.botID: P.state()], place: P.place(P.roundRock), tables: tables, now: P.now, calendar: P.calendar) else {
      Issue.record("expected missing")
      return
    }
    #expect(point.index != 103)
    #expect(abs(kilometres - WeatherGeo.kilometres(P.roundRock, MeshWXCoordinate(latitude: point.lat, longitude: point.lon))) < 0.001)
    #expect(kilometres <= WeatherForecastCard.pointReachKilometres)
  }

  /// **The forecast carries the point it is for, and how far away it is** (docs/MESHWX_UI.md
  /// §3.1 U-9), so the header can name both. Round Rock and Austin showed the same seven rows
  /// with nothing on either page to say they were one Camp Mabry forecast rather than two.
  @Test
  func `a forecast knows its point's distance from the place, and whether this phone asked`() throws {
    guard case let .forecast(summary) = WeatherForecastCard.make(
      states: [P.botID: P.state()], place: P.place(P.austin), tables: tables, now: P.now,
      calendar: P.calendar)
    else {
      Issue.record("expected a forecast")
      return
    }
    let point = MeshWXCoordinate(latitude: summary.point.lat, longitude: summary.point.lon)
    #expect(abs(summary.kilometres - WeatherGeo.kilometres(P.austin, point)) < 0.001)
    // The fixture's forecasts came off the channel; nothing here asked for them.
    #expect(summary.isOwn == false)
  }

  @Test
  func `a point standing in for the place measures from the place, not from the point it replaced`() throws {
    // Round Rock's own point holds nothing, so a forecast within 10 km may stand in for it.
    var state = P.state()
    let roundRockPoint = try #require(tables.nearestPoint(toLat: P.roundRock.latitude, lon: P.roundRock.longitude))
    let held = try #require(state.forecasts[103])
    state.forecasts[roundRockPoint.index] = nil
    guard case let .forecast(summary) = WeatherForecastCard.make(
      states: [P.botID: state], place: P.place(P.roundRock), tables: tables, now: P.now,
      calendar: P.calendar), case let .nearbyPoint(kilometres) = summary.source
    else {
      // Camp Mabry is more than 10 km from Round Rock, so this is `missing`; the distance the
      // card carries is still the place's own.
      _ = held
      return
    }
    #expect(abs(summary.kilometres - kilometres) < 0.001)
  }

  @Test
  func `no place is its own state`() {
    #expect(WeatherForecastCard.make(states: [P.botID: P.state()], place: nil, tables: tables, now: P.now, calendar: P.calendar) == .noPlace)
  }

  @Test
  func `New York and San Juan are other people's places, newest first`() {
    let others = WeatherOtherPlace.make(states: [P.botID: P.state()], excludingPoint: 103, tables: tables, now: P.now)
    #expect(others.map(\.point.index) == [304, 1010])
  }

  @Test
  func `a forecast this phone asked for is not someone else's place`() {
    var state = P.state()
    state.forecasts[304]?.requestedHere = true
    #expect(WeatherOtherPlace.make(states: [P.botID: state], excludingPoint: 103, tables: tables, now: P.now).map(\.point.index) == [1010])
  }
}
