import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// The bot's own coverage statement (spec §7A) deciding in, out and unknown, the station
/// footprint still deciding for a bot that has not stated one, and the single office claim the
/// statement supports (docs/MESHWX_UI.md §3.1 I-B18, §7.4).
@Suite("Weather stated coverage")
struct WeatherStatedCoverageTests {
  typealias P = WeatherPhoneFixture
  let tables = MeshWXTables.shared

  /// The outlines are parsed lazily and a verdict that needs them reads "unknown" until they are
  /// there, so the suite loads them first — which is what the screen does on the way in.
  init() async {
    await MeshWXGeometry.shared.preload()
  }

  /// San Saba: in WX-AUS's stated zones (TXZ155) but 140 km out, past both the stated circle and
  /// the hull of the stations it reports.
  static let sanSaba = MeshWXCoordinate(latitude: 31.1552, longitude: -98.8176)
  /// Temple: inside the stated zones (TXZ158) and in the station footprint, but forecast by NWS
  /// Fort Worth rather than Austin/San Antonio.
  static let temple = MeshWXCoordinate(latitude: 31.10, longitude: -97.34)

  func coverage(_ states: [UInt16: WeatherBotState]) -> WeatherCoverage {
    WeatherCoverage.make(states: states, tables: tables, now: P.now)
  }

  /// The owner's phone with a fresh, complete list, and the bot's statement where given.
  func listening(_ statement: MeshWXCoverage?) -> [UInt16: WeatherBotState] {
    var state = P.state()
    _ = WeatherStateReducer.apply(
      MeshWXMessage(
        header: P.header(234, .digest),
        payload: .digest(MeshWXDigest(nowMinutes: P.nowMinutes - 20, feedHealth: 3, entries: []))),
      to: &state, receivedAt: P.now.addingTimeInterval(-1190))
    if let statement { state = P.stating(statement, on: state, seq: 235) }
    return [P.botID: state]
  }

  func status(_ states: [UInt16: WeatherBotState], place: WeatherPlace) -> WeatherAlertStatus {
    let items = WeatherAlertItems.make(
      states: states, place: place, geometry: MeshWXGeometry.shared, tables: tables, now: P.now)
    return WeatherAlertStatus.evaluate(
      place: place, coverage: coverage(states), states: states, items: items,
      isRadioConnected: true, sessionStartedAt: P.now.addingTimeInterval(-7200), tables: tables,
      now: P.now)
  }

  var listAsOf: WeatherAlertStatus { .clear(asOf: Date(unixMinutes: P.nowMinutes - 20)) }

  func place(_ coordinate: MeshWXCoordinate, _ label: String) -> WeatherPlace {
    P.place(coordinate, label: label)
  }

  // MARK: - In, out and unknown

  @Test
  func `the bot's own statement puts Austin inside and Dallas outside`() {
    let coverage = coverage([P.botID: P.stating(P.statement)])
    #expect(coverage.verdict(for: place(P.austin, "Austin, TX")) == .inside)
    #expect(coverage.botIDs(covering: P.austin) == [P.botID])
    #expect(coverage.verdict(for: place(P.dallas, "Dallas, TX")) == .outside)
    #expect(!coverage.contains(P.dallas))
  }

  /// The statement outranks the footprint: a zone the bot lists is covered though its stations
  /// never reach there, which is the case the hull got wrong.
  @Test
  func `a stated zone counts though the place is past the stated circle and the stations`() {
    #expect(!P.statement.circleContains(Self.sanSaba))
    let sanSaba = place(Self.sanSaba, "San Saba, TX")
    #expect(coverage([P.botID: P.state()]).verdict(for: sanSaba) == .outside, "the hull alone")
    #expect(coverage([P.botID: P.stating(P.statement)]).verdict(for: sanSaba) == .inside)
    #expect(status(listening(nil), place: sanSaba) == .outOfCoverage)
    #expect(status(listening(P.statement), place: sanSaba) == listAsOf)
  }

  /// `n` = 0 and `k` = 0: no area filter at all, so no place is outside it.
  @Test
  func `a bot that states no area filter carries everywhere its feed does`() {
    let everything = MeshWXCoverage(
      latitude: 0, longitude: 0, radiusKilometres: 0, stationCap: 14, officeIndices: [], areas: [])
    #expect(everything.hasNoAreaFilter)
    let coverage = coverage([P.botID: P.stating(everything)])
    #expect(coverage.verdict(for: place(P.dallas, "Dallas, TX")) == .inside)
    #expect(coverage.verdict(for: place(P.austin, "Austin, TX")) == .inside)
  }

  /// The whole point of the message: a list the bot had to cut means "not listed", never "not
  /// covered", so it can withhold the check but never deny the place.
  @Test
  func `a cut list can only say unknown, never outside`() {
    let dallas = place(P.dallas, "Dallas, TX")
    var zonesCut = P.statement
    zonesCut.areasCut = true
    let cut = coverage([P.botID: P.stating(zonesCut)])
    #expect(cut.verdict(for: place(P.austin, "Austin, TX")) == .inside, "a listed run still counts")
    #expect(cut.verdict(for: dallas) == .unknown)

    var officesCut = P.statement
    officesCut.officesCut = true
    #expect(coverage([P.botID: P.stating(officesCut)]).verdict(for: dallas) == .unknown)

    #expect(status(listening(zonesCut), place: dallas) == .coverageUnknown)
    #expect(status(listening(P.statement), place: dallas) == .outOfCoverage)
  }

  @Test
  func `with nothing stated the station footprint still decides, and nothing at all is unknown`() {
    let heard = coverage([P.botID: P.state()])
    #expect(heard.verdict(for: place(P.austin, "Austin, TX")) == .inside)
    #expect(heard.verdict(for: place(P.dallas, "Dallas, TX")) == .outside)

    let silent = coverage([P.botID: WeatherBotState(botID: P.botID)])
    #expect(silent.verdict(for: place(P.austin, "Austin, TX")) == .unknown)
    #expect(silent.isEmpty)
    #expect(status(listening(nil).mapValues { state in
      var stripped = state
      stripped.observations = [:]
      return stripped
    }, place: place(P.austin, "Austin, TX")) == .coverageUnknown)
  }

  /// One bot's "outside" says nothing about a place another bot carries.
  @Test
  func `one bot's outside never speaks for another bot's area`() {
    let dallasBot = P.stating(
      MeshWXCoverage(
        latitude: 32.7767, longitude: -96.7970, radiusKilometres: 50, stationCap: 0,
        officeIndices: [40], areas: []),
      on: WeatherBotState(botID: 0x0102), seq: 3)
    let both = coverage([P.botID: P.stating(P.statement), 0x0102: dallasBot])
    #expect(both.verdict(for: place(P.dallas, "Dallas, TX")) == .inside)
    #expect(both.botIDs(covering: P.dallas) == [0x0102])
    #expect(both.verdict(for: place(P.austin, "Austin, TX")) == .inside)
    #expect(both.botIDs(covering: P.austin) == [P.botID])
  }

  // MARK: - The office claim

  /// It takes the bot's own complete office list and nothing weaker: the offices seen on active
  /// warnings are the weather, not the coverage (docs/MESHWX_UI.md §3.1 I-B18).
  @Test
  func `the office claim fires only on a stated, uncut office list that omits the place's office`() {
    let temple = place(Self.temple, "Temple, TX")
    #expect(coverage([P.botID: P.stating(P.statement)]).placeOffices(for: temple) == ["FWD"])

    var austinOnly = P.statement
    austinOnly.officeIndices = [35]  // EWX alone, though the zone runs still cover Bell County.
    #expect(coverage([P.botID: P.stating(austinOnly)]).uncarriedOffice(for: temple) == "FWD")
    #expect(status(listening(austinOnly), place: temple) == .officeMayNotBeCovered(office: "FWD"))

    // The same list, cut: an office absent from it may still be carried.
    var cut = austinOnly
    cut.officesCut = true
    #expect(coverage([P.botID: P.stating(cut)]).uncarriedOffice(for: temple) == nil)
    #expect(status(listening(cut), place: temple) == listAsOf)

    // The real statement carries Fort Worth, so there is nothing to say.
    #expect(coverage([P.botID: P.stating(P.statement)]).uncarriedOffice(for: temple) == nil)
    #expect(status(listening(P.statement), place: temple) == listAsOf)

    // Nothing stated: a bot that has only been heard from is no evidence against an office.
    #expect(coverage([P.botID: P.state()]).uncarriedOffice(for: temple) == nil)
    #expect(status(listening(nil), place: temple) == listAsOf)
  }

  /// A second bot that carries the office answers for the place, so no claim is made.
  @Test
  func `an office any answering bot carries is never called uncarried`() {
    let temple = place(Self.temple, "Temple, TX")
    var austinOnly = P.statement
    austinOnly.officeIndices = [35]
    var fortWorth = P.statement
    fortWorth.officeIndices = [40]

    let both = coverage([
      P.botID: P.stating(austinOnly),
      0x0102: P.stating(fortWorth, on: WeatherBotState(botID: 0x0102), seq: 4)
    ])
    #expect(both.uncarriedOffice(for: temple) == nil)
    #expect(coverage([P.botID: P.stating(austinOnly)]).uncarriedOffice(for: temple) == "FWD")
  }
}
