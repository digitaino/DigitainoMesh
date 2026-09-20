import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// Alert order, dedupe across bots, folding and the requests the alert buttons send, plus the
/// coverage and forecast-reach rules that keep a far-away answer from reading as local.
@Suite("Weather alert rules")
struct WeatherAlertRulesTests {
  typealias P = WeatherPhoneFixture
  let tables = MeshWXTables.shared

  static let svw42 = MeshWXWarningIdentity(event: 3, office: 35, etn: 42)
  static let svw43 = MeshWXWarningIdentity(event: 3, office: 35, etn: 43)

  /// A box about 13 km across centred on `latitude` over central Austin's longitude.
  func box(at latitude: Double) -> [MeshWXCoordinate] {
    [
      MeshWXCoordinate(latitude: latitude + 0.05, longitude: -97.80), MeshWXCoordinate(latitude: latitude + 0.05, longitude: -97.68),
      MeshWXCoordinate(latitude: latitude - 0.05, longitude: -97.68), MeshWXCoordinate(latitude: latitude - 0.05, longitude: -97.80)
    ]
  }

  func stored(
    event: UInt8, etn: UInt16, minutes: Int = 60, polygonAt latitude: Double? = P.austin.latitude,
    areas: [MeshWXAreaRun]? = nil, receivedAgo: TimeInterval = 0
  ) -> WeatherStoredWarning {
    WeatherStoredWarning(
      warning: MeshWXWarning(
        identity: MeshWXWarningIdentity(event: event, office: 35, etn: etn),
        expiresMinutes: UInt32((P.now.timeIntervalSince1970 + Double(minutes * 60)) / 60),
        polygon: latitude.map(box(at:)), areas: areas),
      receivedAt: P.now.addingTimeInterval(-receivedAgo))
  }

  func state(_ warnings: [WeatherStoredWarning], bot: UInt16 = P.botID) -> WeatherBotState {
    var state = WeatherBotState(botID: bot)
    for warning in warnings { state.warnings[warning.identity] = warning }
    return state
  }

  func items(
    _ states: [UInt16: WeatherBotState], place: WeatherPlace? = P.place(P.austin),
    geometry: any WeatherAreaGeometry = UnloadedGeometry()
  ) -> [WeatherAlertItem] {
    WeatherAlertItems.make(states: states, place: place, geometry: geometry, tables: tables, now: P.now)
  }

  func status(_ states: [UInt16: WeatherBotState], place: WeatherPlace) -> WeatherAlertStatus {
    let coverage = WeatherCoverage.make(states: states, tables: tables, now: P.now)
    return WeatherAlertStatus.evaluate(
      place: place, coverage: coverage, states: states, items: items(states, place: place),
      isRadioConnected: true, sessionStartedAt: P.now.addingTimeInterval(-7200), tables: tables, now: P.now)
  }

  func listOnly(_ mutate: (inout WeatherBotState) -> Void = { _ in }) -> [UInt16: WeatherBotState] {
    var state = WeatherBotState(botID: P.botID)
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: P.header(1, .digest), payload: .digest(MeshWXDigest(nowMinutes: P.nowMinutes - 20, feedHealth: 3, entries: []))),
      to: &state, receivedAt: P.now.addingTimeInterval(-1190))
    mutate(&state)
    return [P.botID: state]
  }

  let heatZone = [MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 192, run: 1)]

  // MARK: - Coverage unknown

  /// WX-AUS's list reaching a phone in Dallas, before any station batch has shown where WX-AUS
  /// reports: the list says nothing about Dallas.
  @Test
  func `a list with no station batch behind it never reads as calm`() {
    #expect(status(listOnly(), place: P.place(P.dallas, label: "Dallas, TX")) == .coverageUnknown)
    #expect(status(listOnly(), place: P.place(P.austin)) == .coverageUnknown)
  }

  @Test
  func `with coverage unknown the rows are still there`() {
    let states = listOnly { $0.warnings[Self.svw42] = self.stored(event: 3, etn: 42) }
    #expect(items(states).contains { $0.placement == .here })
    #expect(status(states, place: P.place(P.austin)) == .coverageUnknown)
  }

  // MARK: - Order

  @Test
  func `here first, then priority over placement, and what just expired last`() {
    let states = [P.botID: state([
      stored(event: 1, etn: 9, minutes: -5),                           // Tornado Warning here, expired
      stored(event: 14, etn: 5, minutes: 30, polygonAt: nil, areas: heatZone), // Heat Advisory, outlines loading
      stored(event: 1, etn: 12, polygonAt: 30.57),                     // Tornado Warning ~28 km north
      stored(event: 3, etn: 44, minutes: 90)                           // Severe Thunderstorm Warning here
    ])]
    let order = items(states).map { "\($0.identity.event).\($0.identity.etn)" }
    #expect(order == ["3.44", "1.12", "14.5", "1.9"])
  }

  @Test
  func `of two bots' copies the active one wins, then the later expiry`() throws {
    let expiredButNewer = stored(event: 3, etn: 42, minutes: -5, receivedAgo: 0)
    let active = stored(event: 3, etn: 42, minutes: 30, receivedAgo: 3600)
    let longer = stored(event: 3, etn: 42, minutes: 60, receivedAgo: 7200)

    let pair = try #require(items([0x0001: state([expiredButNewer], bot: 0x0001), 0x0002: state([active], bot: 0x0002)]).first)
    #expect(pair.kind == .active)
    #expect(pair.expiresAt == active.expiresAt)
    #expect(pair.botIDs == [0x0001, 0x0002])

    let three = items([
      0x0001: state([expiredButNewer], bot: 0x0001), 0x0002: state([active], bot: 0x0002), 0x0003: state([longer], bot: 0x0003)
    ])
    #expect(three.count == 1)
    #expect(three.first?.expiresAt == longer.expiresAt)
  }

  @Test
  func `an upgrade marker stands in only when no bot holds the warning`() {
    let copy = stored(event: 3, etn: 42)
    let marker = WeatherPendingUpgrade(warning: copy.warning, cancelledAt: P.now.addingTimeInterval(-600))
    for (markerBot, warningBot) in [(UInt16(0x0001), UInt16(0xFFFE)), (0xFFFE, 0x0001)] {
      var markerState = WeatherBotState(botID: markerBot)
      markerState.pendingUpgrades[Self.svw42] = marker
      let listed = items([markerBot: markerState, warningBot: state([copy], bot: warningBot)])
      #expect(listed.count == 1)
      #expect(listed.first?.kind == .active)
    }

    var early = WeatherBotState(botID: 0x0001)
    early.pendingUpgrades[Self.svw42] = marker
    var late = WeatherBotState(botID: 0x0002)
    late.pendingUpgrades[Self.svw42] = WeatherPendingUpgrade(warning: copy.warning, cancelledAt: P.now.addingTimeInterval(-60))
    let markers = items([0x0001: early, 0x0002: late])
    #expect(markers.first?.kind == .upgradedAwaitingReplacement(cancelledAt: P.now.addingTimeInterval(-60)))
    #expect(markers.first?.botIDs == [0x0001, 0x0002])
  }

  // MARK: - Folding

  @Test
  func `storm warnings and unfinished upgrades are never folded, anything else past two is`() throws {
    let tornadoes = items([P.botID: state([1, 2, 3].map { stored(event: 1, etn: $0) })])
    #expect(WeatherAlertFolding.fold(tornadoes, tables: tables).rows.count == 3)

    let storms = items([P.botID: state([1, 2, 3].map { stored(event: 3, etn: $0) })])
    let foldedStorms = WeatherAlertFolding.fold(storms, tables: tables)
    #expect(foldedStorms.rows.count == 3)
    #expect(foldedStorms.folded == 0)

    let heat = items([P.botID: state([1, 2, 3].map { stored(event: 14, etn: $0) })])
    let foldedHeat = WeatherAlertFolding.fold(heat, tables: tables)
    #expect(foldedHeat.rows.count == 2)
    #expect(foldedHeat.folded == 1)

    let mixed = items([P.botID: state([
      stored(event: 14, etn: 1), stored(event: 14, etn: 2), stored(event: 25, etn: 3), stored(event: 1, etn: 4, polygonAt: 30.57)
    ])])
    let foldedMixed = WeatherAlertFolding.fold(mixed, tables: tables)
    #expect(foldedMixed.rows.map(\.identity.etn) == [3, 1, 4], "the near Tornado Warning stays, in its place")
    #expect(foldedMixed.folded == 1)

    var upgraded = state([1, 2].map { stored(event: 14, etn: $0) })
    let advisory = stored(event: 14, etn: 9, minutes: 120)
    upgraded.pendingUpgrades[advisory.identity] = WeatherPendingUpgrade(warning: advisory.warning, cancelledAt: P.now)
    let foldedUpgrade = WeatherAlertFolding.fold(items([P.botID: upgraded]), tables: tables)
    #expect(foldedUpgrade.rows.contains { $0.identity.etn == 9 })
    #expect(foldedUpgrade.folded == 0)
  }

  // MARK: - Requests

  func missedMessages(_ source: WeatherBotState, county: String?, office: String? = "EWX") -> WeatherRequest {
    WeatherAlertRequests.missedMessages(source: source, placeCountyUGC: county, placeOffice: office, tables: tables)
  }

  @Test
  func `missed messages ask for the list, one missing warning, or the county under an upgrade`() {
    var gap = WeatherBotState(botID: P.botID)
    gap.needsDigest = true
    #expect(missedMessages(gap, county: "TXC453") == .digest)

    var one = gap
    one.missingFromDigest = [Self.svw42]
    #expect(missedMessages(one, county: "TXC453") == .warning(identity: "SV.W.EWX.42"))

    // `>w <county>` would miss zone-coded warnings and stop at six: one identity per tap instead.
    var several = one
    several.missingFromDigest = [Self.svw43, Self.svw42]
    #expect(missedMessages(several, county: "TXC453") == .warning(identity: "SV.W.EWX.42"))
    #expect(missedMessages(several, county: nil) == .warning(identity: "SV.W.EWX.42"))

    // Upgrades are storm-based warnings, which carry county codes.
    var upgraded = one
    let hays = MeshWXWarning(identity: Self.svw43, expiresMinutes: P.nowMinutes + 30,
                             areas: [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 209, run: 1)])
    upgraded.pendingUpgrades[Self.svw43] = WeatherPendingUpgrade(warning: hays, cancelledAt: P.now)
    #expect(missedMessages(upgraded, county: "TXC453") == .warningsTouching(ugc: "TXC453"))
    #expect(missedMessages(upgraded, county: nil) == .warningsTouching(ugc: "TXC209"))

    var unplacedUpgrade = WeatherBotState(botID: P.botID)
    unplacedUpgrade.pendingUpgrades[Self.svw43] = WeatherPendingUpgrade(
      warning: MeshWXWarning(identity: Self.svw43, expiresMinutes: P.nowMinutes + 30), cancelledAt: P.now)
    #expect(missedMessages(unplacedUpgrade, county: nil) == .activeWarnings)
  }

  @Test
  func `missing warnings are asked for one per tap, the most important first`() throws {
    let fortWorth = try #require(tables.offices.firstIndex(of: "FWD").flatMap { UInt8(exactly: $0) })
    let heat = MeshWXWarningIdentity(event: 14, office: 35, etn: 5)
    let tornadoFortWorth = MeshWXWarningIdentity(event: 1, office: fortWorth, etn: 20)
    let tornadoAustin = MeshWXWarningIdentity(event: 1, office: 35, etn: 30)
    func ask(_ state: WeatherBotState, office: String?, refused: Set<MeshWXWarningIdentity> = []) -> WeatherRequest? {
      WeatherAlertRequests.missingWarnings(source: state, placeOffice: office, notAvailable: refused, tables: tables)
    }

    var state = WeatherBotState(botID: P.botID)
    #expect(ask(state, office: "EWX") == nil)
    state.missingFromDigest = [heat, tornadoFortWorth, tornadoAustin]
    // Tornado warnings before the heat advisory; of two, the place's own office's.
    #expect(ask(state, office: "EWX") == .warning(identity: "TO.W.EWX.30"))
    #expect(ask(state, office: "FWD") == .warning(identity: "TO.W.FWD.20"))
    #expect(ask(state, office: nil) == .warning(identity: "TO.W.EWX.30"))

    // What the bot said it lacks is passed over; once all have been, a new list.
    #expect(ask(state, office: "EWX", refused: [tornadoAustin]) == .warning(identity: "TO.W.FWD.20"))
    #expect(ask(state, office: "EWX", refused: [tornadoAustin, tornadoFortWorth]) == .warning(identity: "HT.Y.EWX.5"))
    #expect(ask(state, office: "EWX", refused: [tornadoAustin, tornadoFortWorth, heat]) == .digest)
    #expect(missedMessages(state, county: "TXC453") == .warning(identity: "TO.W.EWX.30"))

    // Nothing the bundle can spell: the whole list.
    state.missingFromDigest = [MeshWXWarningIdentity(event: 250, office: 35, etn: 1)]
    #expect(ask(state, office: "EWX") == .activeWarnings)
  }

  @Test
  func `identities render as the bot spells them and read back`() {
    #expect(WeatherAlertRequests.identityString(Self.svw42, tables: tables) == "SV.W.EWX.42")
    #expect(WeatherAlertRequests.identity(from: "sv.w.ewx.42", tables: tables) == Self.svw42)
    #expect(WeatherAlertRequests.identity(from: "SV.W.EWX", tables: tables) == nil)
    #expect(WeatherAlertRequests.identity(from: "ZZ.W.EWX.42", tables: tables) == nil)
    #expect(WeatherAlertRequests.identity(from: "SV.W.QQQ.42", tables: tables) == nil)
    #expect(WeatherAlertRequests.identityString(MeshWXWarningIdentity(event: 250, office: 35, etn: 1), tables: tables) == nil)
  }

  // MARK: - Ported from the app's copy tests

  @Test
  func `a near alert carries its distance and direction, a checking one is still a row`() throws {
    let near = try #require(items([P.botID: state([stored(event: 3, etn: 21, polygonAt: 30.57)])]).first)
    guard case let .near(kilometres, direction) = near.placement else {
      Issue.record("expected near, got \(near.placement)")
      return
    }
    #expect(kilometres > 20 && kilometres < 35)
    #expect(direction == .north)

    let checking = try #require(items([P.botID: state([stored(event: 14, etn: 1, polygonAt: nil, areas: heatZone)])]).first)
    #expect(checking.placement == .checking)
    #expect(checking.placement.isCardRow)
  }

  @Test
  func `a day row keeps both temperatures and says when the rain is at night`() throws {
    let calendar = P.calendar
    let issued = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 5)))
    let nine = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9)))
    let forecast = MeshWXForecast(
      pointIndex: 1, issuedMinutes: UInt32(issued.timeIntervalSince1970 / 60), firstPeriod: 0,
      periods: [MeshWXForecastPeriod(highF: 90, popPercent: 10, windy: true), MeshWXForecastPeriod(lowF: 70, popPercent: 70, thunder: true)])
    let row = try #require(WeatherForecastRows.rows(for: forecast, now: nine, calendar: calendar).first)
    #expect(row.highF == 90 && row.lowF == 70)
    #expect(row.popPercent == 70 && row.popIsNight)
    #expect(row.thunder && row.windy)
  }

  // MARK: - Forecast reach

  /// Pago Pago, American Samoa. The office PPG is one of the nine `pfm_points.json` version 1 had
  /// no point at all for, and version 2 filled six of them in; the Pacific territories are still
  /// thousands of kilometres from the nearest point, which is what this test needs.
  static let pagoPago = MeshWXCoordinate(latitude: -14.2756, longitude: -170.7020)

  /// Spec revision 10, §1.3, and the case the whole ask exists for. The card used to be
  /// `.noPointNearby` with **no ask at all** — "No forecast point near Albuquerque" — which is
  /// what the owner saw as "forecast works in chat but not in the app". A place with a coordinate
  /// always has something to ask for now.
  @Test
  func `a place with no bundled point in reach is still asked about, by coordinate`() throws {
    let place = P.place(Self.pagoPago, label: "Pago Pago, AS")
    let nearest = tables.nearestPoint(toLat: Self.pagoPago.latitude, lon: Self.pagoPago.longitude)
    try #require(nearest == nil || MeshWXGeo.distanceKilometres(
      fromLat: Self.pagoPago.latitude, lon: Self.pagoPago.longitude,
      toLat: nearest!.lat, lon: nearest!.lon) > WeatherForecastCard.pointReachKilometres)

    guard case let .missing(point, kilometres) = WeatherForecastCard.make(
      states: [:], place: place, tables: tables, now: P.now, calendar: P.calendar) else {
      Issue.record("expected an empty card with an ask")
      return
    }
    #expect(point == nil, "no bundled point stands for the place")
    #expect(kilometres == nil)
  }

  /// The cutoff's derivation, re-measured on a fixed sample of the bundle: about three places in
  /// a thousand with any point in their region lie beyond it.
  ///
  /// It was about one in a hundred when 115 km was chosen, and `pfm_points.json` version 2 is why
  /// it is not any more: eighty-five points were appended for the nine offices the first cut had
  /// none for (spec revision 10, §1.3). Over the whole bundle the distance from a place to its
  /// nearest point is now 22.5 km at the median, 62.6 km at p95 and 90.2 km at p99, with 109 of
  /// 34,909 places beyond 115 km — so the cutoff has quietly moved from p99 to about p99.7.
  ///
  /// It is left where it is on purpose. The number this rule decides is not "is there a point"
  /// but "is that point's forecast this place's weather", and the answer to that did not change
  /// when the bundle grew. A place beyond it is no longer left with nothing either: since
  /// revision 10 it is asked about by coordinate.
  @Test
  func `the reach cutoff leaves about three places in a thousand without a point`() throws {
    var measured = 0
    var beyond = 0
    for place in stride(from: 0, to: tables.places.count, by: 25).map({ tables.places[$0] }) {
      guard let point = tables.nearestPoint(toLat: place.lat, lon: place.lon) else { continue }
      let kilometres = MeshWXGeo.distanceKilometres(fromLat: place.lat, lon: place.lon, toLat: point.lat, lon: point.lon)
      guard kilometres <= 1000 else { continue }
      measured += 1
      if kilometres > WeatherForecastCard.pointReachKilometres { beyond += 1 }
    }
    try #require(measured > 1000)
    let share = Double(beyond) / Double(measured)
    #expect(share > 0.0005 && share < 0.01, "\(beyond) of \(measured) beyond \(WeatherForecastCard.pointReachKilometres) km")
  }
}
