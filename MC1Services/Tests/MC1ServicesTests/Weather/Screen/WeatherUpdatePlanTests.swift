import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// What one tap on Update asks for, branch by branch (docs/MESHWX_UI.md §11).
@Suite("Weather update plan")
struct WeatherUpdatePlanTests {
  typealias P = WeatherPhoneFixture

  let wxAus = WeatherBot(
    publicKey: Data([0x1D, 0x04]) + Data(repeating: 0x55, count: 30),
    name: "WX-AUS", latitude: 0, longitude: 0, lastAdvert: nil)

  func snapshot(_ state: WeatherBotState, place: WeatherPlace?, now: Date) -> WeatherScreenSnapshot {
    WeatherScreenSnapshot.make(
      WeatherScreenSnapshot.Inputs(
        states: [P.botID: state], bots: [wxAus], preferredBotID: nil, place: place,
        isRadioConnected: true, firmwareSupportsWeather: true, firmwareVersion: "v1.15.0",
        hasWeatherChannel: true, session: WeatherSessionInfo(startedAt: now.addingTimeInterval(-3600)),
        now: now, calendar: P.calendar),
      geometry: MeshWXGeometry.shared, tables: .shared)
  }

  /// - Parameter askedCoverage: the coverage step has its own tests below, so everything else is
  ///   read with it already asked rather than repeating one more step in every expectation.
  func plan(
    _ state: WeatherBotState,
    place: WeatherPlace? = WeatherPhoneFixture.place(WeatherPhoneFixture.austin),
    county: String? = nil,
    zone: String? = nil,
    nearbyStation: String? = nil,
    askedCoverage: Bool = true,
    now: Date = WeatherPhoneFixture.now
  ) -> WeatherUpdatePlan {
    WeatherUpdatePlan.make(
      snapshot: snapshot(state, place: place, now: now), sourceState: state,
      placeCountyUGC: county, placeZoneUGC: zone,
      nearbyStation: nearbyStation.flatMap { Self.nearby($0, to: place?.coordinate) },
      coverageAlreadyAsked: askedCoverage, tables: .shared, now: now)
  }

  /// A bundled station as the screen builder hands it over: its distance from the place.
  static func nearby(_ icao: String, to coordinate: MeshWXCoordinate?) -> WeatherNearbyStation? {
    guard let coordinate, let station = MeshWXTables.shared.station(icao: icao) else { return nil }
    return WeatherNearbyStation(
      icao: icao, name: station.name,
      kilometres: MeshWXGeo.distanceKilometres(
        fromLat: coordinate.latitude, lon: coordinate.longitude, toLat: station.lat, lon: station.lon))
  }

  /// A list built `minutesAgo` before now and received then too, unless `receivedAt` says
  /// otherwise.
  func withDigest(
    _ state: WeatherBotState, builtMinutesAgo: UInt32, receivedAt: Date? = nil,
    entries: [MeshWXDigest.Entry] = []
  ) -> WeatherBotState {
    var state = state
    _ = WeatherStateReducer.apply(
      MeshWXMessage(
        header: P.header(234, .digest),
        payload: .digest(MeshWXDigest(
          nowMinutes: P.nowMinutes - builtMinutesAgo, feedHealth: 3, entries: entries))),
      to: &state,
      receivedAt: receivedAt ?? P.now.addingTimeInterval(-Double(builtMinutesAgo) * 60))
    return state
  }

  // MARK: - Alerts

  @Test
  func `with no list held the plan asks for one`() {
    let plan = plan(P.state())
    #expect(plan.steps.first?.item == .alerts)
    #expect(plan.steps.first?.request == .digest)
    #expect(plan.currentAsOf == nil)
  }

  @Test
  func `a list inside its three-hour cadence is not asked for again`() {
    let plan = plan(withDigest(P.state(), builtMinutesAgo: 20))
    #expect(!plan.items.contains(.alerts))
  }

  @Test
  func `a list older than three hours and a quarter is asked for again`() {
    #expect(plan(withDigest(P.state(), builtMinutesAgo: 194)).items.contains(.alerts) == false)
    let old = plan(withDigest(P.state(), builtMinutesAgo: 200))
    #expect(old.steps.map(\.request) == [.digest])
  }

  /// Airtime etiquette (spec §13): the channel delivered it a minute ago, so the bot would only
  /// rebuild the same answer. Not current either, so nothing claims it is.
  @Test
  func `an old list the channel delivered a minute ago is held back, not called current`() {
    let plan = plan(withDigest(P.state(), builtMinutesAgo: 200, receivedAt: P.now.addingTimeInterval(-60)))
    #expect(plan.isEmpty)
    #expect(plan.justReceived == [.alerts])
    #expect(plan.currentAsOf == nil)
  }

  /// A gap says what was missed came *after* whatever was received, so the five-minute rule
  /// never holds the request back (§3.1 R-3).
  @Test
  func `a gap asks for a list however fresh the held one is`() {
    var state = withDigest(P.state(), builtMinutesAgo: 20, receivedAt: P.now.addingTimeInterval(-30))
    state.needsDigest = true
    let plan = plan(state)
    #expect(plan.steps.map(\.request) == [.digest])
    #expect(plan.justReceived.isEmpty)
  }

  @Test
  func `a warning the list named that never arrived is asked for by identity`() throws {
    let identity = MeshWXWarningIdentity(event: 14, office: 35, etn: 3)
    var state = withDigest(P.state(), builtMinutesAgo: 20)
    state.missingFromDigest = [identity]
    let text = try #require(WeatherAlertRequests.identityString(identity, tables: .shared))
    #expect(plan(state).steps.map(\.request) == [.warning(identity: text)])
  }

  // MARK: - Outside the bot's area

  @Test
  func `outside the area the place's zone and county are asked for by name`() {
    let plan = plan(
      P.state(), place: P.place(P.dallas, label: "Dallas, TX"),
      county: "TXC113", zone: "TXZ103", nearbyStation: "KDAL")
    #expect(plan.steps.map(\.item) == [.alerts, .areaAlerts, .areaAlerts, .readings, .forecast])
    #expect(plan.steps[1].request == .warningsTouching(ugc: "TXZ103"))
    #expect(plan.steps[2].request == .warningsTouching(ugc: "TXC113"))
    #expect(plan.steps[3].request == .observation(station: "KDAL"))
  }

  @Test
  func `inside the area nothing is asked by county`() {
    let plan = plan(withDigest(P.state(), builtMinutesAgo: 20), county: "TXC453", zone: "TXZ192")
    #expect(!plan.items.contains(.areaAlerts))
  }

  // MARK: - Readings

  @Test
  func `a reading inside the hour is left alone`() {
    #expect(!plan(P.state()).items.contains(.readings))
  }

  @Test
  func `a missed hourly batch asks for the batch the bot would send now`() {
    let plan = plan(P.state(observationsAgo: 75 * 60))
    #expect(plan.steps.map(\.request).contains(.observations))
  }

  /// A station the bot has dropped from its batch, or one held from somebody's single-station
  /// answer, cannot be refreshed by a bare `>o`.
  @Test
  func `a station outside the newest batch is asked for by its code`() throws {
    let station = try #require(MeshWXTables.shared.station(at: 194))
    var state = WeatherBotState(botID: P.botID)
    _ = WeatherStateReducer.apply(
      MeshWXMessage(
        header: P.header(230, .observations),
        payload: .observations(MeshWXObservations(
          timestampMinutes: P.nowMinutes - 75,
          stations: [MeshWXStationObservation(stationIndex: 194, tempF: 88, sky: .few)]))),
      to: &state, receivedAt: P.now.addingTimeInterval(-75 * 60))
    let plan = plan(state)
    #expect(plan.steps.map(\.request).contains(.observation(station: station.icao)))
  }

  @Test
  func `stale readings the channel delivered a minute ago are held back`() {
    var state = P.state(observationsAgo: 75 * 60)
    for (index, stored) in state.observations {
      var fresh = stored
      fresh.receivedAt = P.now.addingTimeInterval(-60)
      state.observations[index] = fresh
    }
    let plan = plan(state)
    #expect(!plan.items.contains(.readings))
    #expect(plan.justReceived.contains(.readings))
  }

  @Test
  func `with nothing held at all the batch is asked for`() {
    var state = WeatherBotState(botID: P.botID)
    state.lastHeardAt = P.now
    let plan = plan(state)
    #expect(plan.steps.map(\.request) == [.digest, .observations, .forecast(point: 103)])
  }

  // MARK: - A reading from 25 to 40 km (docs/MESHWX_UI.md §3.1 U-2a)

  /// Wimberley, TX as saved on Rafael's phone. Its nearest station, San Marcos (KHYI), is 25.5 km
  /// away: half a kilometre past the "weather here" threshold.
  static let wimberley = MeshWXCoordinate(latitude: 29.9974, longitude: -98.0986)

  /// One KHYI reading, `minutesAgo` old, in a batch with one other station.
  func sanMarcos(minutesAgo: Double) -> WeatherBotState {
    var state = WeatherBotState(botID: P.botID)
    let khyi = MeshWXTables.shared.stationIndex(forICAO: "KHYI")!
    let kaus = MeshWXTables.shared.stationIndex(forICAO: "KAUS")!
    _ = WeatherStateReducer.apply(
      MeshWXMessage(header: P.header(230, .observations), payload: .observations(MeshWXObservations(
        timestampMinutes: UInt32((P.now.timeIntervalSince1970 - minutesAgo * 60) / 60),
        stations: [
          MeshWXStationObservation(stationIndex: khyi, tempF: 79, sky: .few, windMph: 4),
          MeshWXStationObservation(stationIndex: kaus, tempF: 78, sky: .few, windMph: 3),
        ]))),
      to: &state, receivedAt: P.now.addingTimeInterval(-minutesAgo * 60))
    return state
  }

  /// The field report: the answer came back and the page threw it away, while Update called
  /// everything current. Now the page shows it under San Marcos' name, and Update agrees.
  @Test
  func `a fresh reading 25.5 km off is shown attributed, and Update has nothing to ask`() throws {
    let place = P.place(Self.wimberley, kind: .searched, label: "Wimberley, TX")
    let state = sanMarcos(minutesAgo: 20)
    let nearby = try #require(Self.nearby("KHYI", to: Self.wimberley))
    #expect(nearby.kilometres > WeatherConditions.goodReadingKilometres)
    #expect(nearby.kilometres < WeatherConditions.labelledReadingKilometres)

    let snap = snapshot(state, place: place, now: P.now)
    let conditions = WeatherConditions.make(primary: snap.primaryStation, nearbyStation: nearby)
    guard case let .nearby(reading, nearer) = conditions else {
      Issue.record("expected an attributed reading, got \(conditions)")
      return
    }
    #expect(reading.station.icao == "KHYI")
    #expect(nearer == nil)

    let plan = plan(state, place: place, nearbyStation: "KHYI")
    #expect(!plan.items.contains(.readings))
  }

  /// Past an hourly batch it is asked for again, exactly as a reading here would be.
  @Test
  func `an attributed reading that missed its batch is asked for again`() {
    let place = P.place(Self.wimberley, kind: .searched, label: "Wimberley, TX")
    let plan = plan(sanMarcos(minutesAgo: 80), place: place, nearbyStation: "KHYI")
    let readings = plan.steps.filter { $0.item == .readings }.map(\.request)
    #expect(readings.count == 1)
    #expect(readings.first == .observations || readings.first == .observation(station: "KHYI"))
  }

  /// A place whose every station is beyond 40 km: asking would bring back a reading the page will
  /// not show, so the page says so and Update spends nothing.
  @Test
  func `with no station within 40 km the plan asks for no reading`() throws {
    // Dallas, holding only the Austin-area fixture readings, 290 km away, and no bundled station
    // offered: the verdict is no station, and the plan agrees.
    let place = P.place(P.dallas, kind: .searched, label: "Dallas, TX")
    let snap = snapshot(P.state(), place: place, now: P.now)
    let conditions = WeatherConditions.make(primary: snap.primaryStation, nearbyStation: nil)
    if case .noStation = conditions {} else { Issue.record("expected no station, got \(conditions)") }
    #expect(!plan(P.state(), place: place).items.contains(.readings))
  }

  // MARK: - Forecast

  @Test
  func `a forecast issued over twelve hours ago is asked for again`() {
    var state = withDigest(P.state(), builtMinutesAgo: 20)
    state.forecasts[103] = WeatherStoredForecast(
      forecast: P.dailyForecast(point: 103, issuedMinutes: P.nowMinutes - 13 * 60, temps: [(90, 70)]),
      receivedAt: P.now.addingTimeInterval(-13 * 3600), requestedHere: true)
    #expect(plan(state).steps.map(\.request) == [.forecast(point: 103)])
  }

  @Test
  func `a forecast the channel delivered a minute ago is held back`() {
    var state = withDigest(P.state(), builtMinutesAgo: 20)
    state.forecasts[103] = WeatherStoredForecast(
      forecast: P.dailyForecast(point: 103, issuedMinutes: P.nowMinutes - 13 * 60, temps: [(90, 70)]),
      receivedAt: P.now.addingTimeInterval(-60), requestedHere: true)
    let plan = plan(state)
    #expect(plan.isEmpty)
    #expect(plan.justReceived == [.forecast])
  }

  @Test
  func `nothing held for the place's point asks for it`() {
    var state = withDigest(P.state(), builtMinutesAgo: 20)
    state.forecasts = [:]
    #expect(plan(state).steps.map(\.request) == [.forecast(point: 103)])
  }

  // MARK: - Coverage

  /// §14 Q4: without the bot's statement the phone cannot tell "outside the area" from "nothing
  /// said yet", so it withholds both the check and the out-of-area requests — for up to three
  /// hours, until the next broadcast. One packet buys the difference, and it goes last: the
  /// weather is what the airtime is for.
  @Test
  func `a bot that has stated nothing is asked what it covers, last`() {
    var state = WeatherBotState(botID: P.botID)
    state.lastHeardAt = P.now
    let plan = plan(state, askedCoverage: false)
    #expect(plan.steps.map(\.item) == [.alerts, .readings, .forecast, .coverage])
    #expect(plan.steps.last?.request == .coverage)
  }

  /// A statement does not go stale — it describes the bot, not an hour (§6) — so one already
  /// held is never asked for again.
  @Test
  func `a statement already held is never asked for again`() {
    #expect(!plan(P.stating(P.statement), askedCoverage: false).items.contains(.coverage))
  }

  /// One packet: a bot that did not answer must not be asked again on every tap.
  @Test
  func `asking once is enough for the visit`() {
    #expect(!plan(P.state()).items.contains(.coverage))
  }

  /// "Everything is current" is a claim about the weather held. A statement carries no time, and
  /// a plan with something to send never makes the claim anyway.
  @Test
  func `a planned coverage step is not something current`() {
    let plan = plan(withDigest(P.state(), builtMinutesAgo: 20), askedCoverage: false)
    #expect(plan.steps.map(\.request) == [.coverage])
    #expect(plan.currentAsOf == nil)
  }

  // MARK: - Nothing to ask for

  /// "Everything is current" is true only as of the oldest thing it was checked against — here
  /// the forecast, issued three and a half hours ago.
  @Test
  func `with everything current the plan is empty and names the oldest content time`() {
    let state = withDigest(P.state(), builtMinutesAgo: 20)
    let plan = plan(state)
    #expect(plan.isEmpty)
    #expect(plan.justReceived.isEmpty)
    #expect(plan.currentAsOf == Date(unixMinutes: P.nowMinutes - 208))
  }

  @Test
  func `with no place only the alert list is planned`() {
    let plan = plan(P.state(), place: nil)
    #expect(plan.steps.map(\.item) == [.alerts])
  }

  @Test
  func `the order is always alerts, then readings, then forecast`() {
    var state = WeatherBotState(botID: P.botID)
    state.lastHeardAt = P.now
    #expect(plan(state).steps.map(\.item) == [.alerts, .readings, .forecast])
  }
}

@Suite("Weather saved places")
struct WeatherSavedPlacesTests {
  let now = WeatherPhoneFixture.now

  func saved(_ label: String, lat: Double = 30.5, lon: Double = -97.7, minutesAgo: Double = 0) -> WeatherSavedPlace {
    WeatherSavedPlace(
      label: label, latitude: lat, longitude: lon,
      chosenAt: now.addingTimeInterval(-minutesAgo * 60))
  }

  @Test
  func `the newest choice leads the list`() {
    let list = WeatherSavedPlaces.remember(
      saved("Austin, TX", lat: 30.27, lon: -97.74),
      in: [saved("Round Rock, TX", minutesAgo: 10)])
    #expect(list.map(\.label) == ["Austin, TX", "Round Rock, TX"])
  }

  /// **Picking a place already on the list does not move it** (docs/MESHWX_UI.md §3.1 U-4).
  ///
  /// The list is the pager's order, and the user drags it into the order they want. Sliding the
  /// row they just tapped to the front rewrites that order under their finger and renumbers every
  /// dot; a second tap would put it back. Picking is "show me this", not "reorder these".
  @Test
  func `picking a saved place again keeps its place in the order`() {
    let old = saved("Round Rock, TX", minutesAgo: 60)
    var list = [saved("Austin, TX", lat: 30.27, lon: -97.74, minutesAgo: 10), old]
    var again = old
    again.chosenAt = now
    list = WeatherSavedPlaces.remember(again, in: list)
    #expect(list.count == 2)
    #expect(list.map(\.label) == ["Austin, TX", "Round Rock, TX"])
    #expect(list[1].chosenAt == now)
  }

  /// A ZIP, a station and a town are told apart by what they are, not by their label: two ZIPs
  /// of one town are two rows, and the same station found twice is one.
  @Test
  func `identity comes from the ZIP, the station, or the point`() {
    let zip = WeatherSavedPlace(
      label: "Austin, TX 78701", latitude: 30.27, longitude: -97.74, zipCode: "78701", chosenAt: now)
    let otherZip = WeatherSavedPlace(
      label: "Austin, TX 78702", latitude: 30.26, longitude: -97.71, zipCode: "78702", chosenAt: now)
    let station = WeatherSavedPlace(
      label: "Austin, TX", latitude: 30.32, longitude: -97.76,
      searchedAs: .airportCode, stationIndex: 194, chosenAt: now)
    #expect(zip.id != otherZip.id)
    #expect(station.id == "station:194")
    #expect(saved("Austin, TX", lat: 30.2672, lon: -97.7431).id == saved("Austin", lat: 30.2674, lon: -97.7429).id)
  }

  @Test
  func `the list stops at a dozen, dropping the oldest`() {
    var list: [WeatherSavedPlace] = []
    for index in 0..<15 {
      list = WeatherSavedPlaces.remember(
        saved("Place \(index)", lat: 30 + Double(index) / 10, minutesAgo: Double(15 - index)), in: list)
    }
    #expect(list.count == WeatherSavedPlaces.limit)
    #expect(list.first?.label == "Place 14")
    #expect(!list.contains { $0.label == "Place 0" })
  }

  @Test
  func `removing takes the row out and leaves the rest in order`() {
    let list = [saved("Austin, TX", lat: 30.27, lon: -97.74), saved("Round Rock, TX", minutesAgo: 10)]
    let left = WeatherSavedPlaces.removing(list[0].id, from: list)
    #expect(left.map(\.label) == ["Round Rock, TX"])
  }

  @Test
  func `a saved place answers as a searched place with a town's radius`() {
    let place = saved("Round Rock, TX").place
    #expect(place.kind == .searched)
    #expect(place.uncertaintyKilometres == 5)
    #expect(WeatherSavedPlace.from(place, at: now).label == "Round Rock, TX")
  }

  /// A drag is written back by **id**, so it can be applied to a list that has since grown: a
  /// place the sheet never saw keeps its own place at the end rather than being dropped by an
  /// index that no longer means what it meant.
  @Test
  func `a reorder by ids keeps a place the drag never saw`() {
    let austin = saved("Austin, TX", lat: 30.27, lon: -97.74)
    let roundRock = saved("Round Rock, TX")
    let llano = saved("Llano, TX", lat: 30.75, lon: -98.68)
    let ordered = WeatherSavedPlaces.ordering(
      ids: [roundRock.id, austin.id], in: [austin, roundRock, llano])
    #expect(ordered.map(\.label) == ["Round Rock, TX", "Austin, TX", "Llano, TX"])
  }

  @Test
  func `an id nothing answers to is ignored rather than dropping a row`() {
    let austin = saved("Austin, TX", lat: 30.27, lon: -97.74)
    let ordered = WeatherSavedPlaces.ordering(ids: ["at:0.000,0.000", austin.id], in: [austin])
    #expect(ordered.map(\.label) == ["Austin, TX"])
  }
}

/// **The saved list is never written from a copy of itself** (docs/MESHWX_UI.md §3.1 U-1).
///
/// On a real phone, four saved places became one, renamed to an airport's town and moved to its
/// coordinates. The model's in-memory list is empty until it has read the store, and a pick in
/// that window wrote a one-place list over everything that was there. Every edit now goes to the
/// list the store holds, and a write that would drop a place nobody asked to drop is refused.
@Suite("Weather saved places store")
struct WeatherSavedPlacesStoreTests {
  let now = WeatherPhoneFixture.now

  func store(_ name: String = #function) -> WeatherSavedPlacesStore {
    let defaults = UserDefaults(suiteName: "weather.savedPlaces.\(name)")!
    defaults.removePersistentDomain(forName: "weather.savedPlaces.\(name)")
    return WeatherSavedPlacesStore(defaults: defaults)
  }

  func saved(_ label: String, lat: Double, lon: Double = -97.7, isWatched: Bool = false) -> WeatherSavedPlace {
    WeatherSavedPlace(
      label: label, latitude: lat, longitude: lon, chosenAt: now, isWatched: isWatched)
  }

  /// The failure as it happened: four places in the store, a pick made against an empty list.
  @Test
  func `a pick made before the list was loaded cannot drop the stored places`() {
    let store = store()
    let stored = [
      saved("Austin, TX", lat: 30.27), saved("Round Rock, TX", lat: 30.51),
      saved("Llano, TX", lat: 30.75), saved("San Juan, PR", lat: 18.47, lon: -66.11),
    ]
    store.places = stored
    // The screen's own list is still empty — it has not read the store yet. Its pick is described
    // rather than computed, so it lands on the four places that are really there.
    let after = store.apply(.remember(saved("Georgetown, TX", lat: 30.63)))
    #expect(after.count == 5)
    #expect(Set(after.map(\.id)).isSuperset(of: Set(stored.map(\.id))))
    #expect(store.places.count == 5)
  }

  @Test
  func `only a removal may take a row out`() {
    let store = store()
    store.places = [saved("Austin, TX", lat: 30.27), saved("Llano, TX", lat: 30.75)]
    let ids = store.places.map(\.id)
    let after = store.apply(.remove(id: ids[0]))
    #expect(after.map(\.id) == [ids[1]])
  }

  /// A bell adds and removes no row, and neither does a drag.
  @Test
  func `a bell and a drag leave every place where it is`() {
    let store = store()
    store.places = [saved("Austin, TX", lat: 30.27), saved("Llano, TX", lat: 30.75)]
    let ids = store.places.map(\.id)
    #expect(store.apply(.watch(true, id: ids[1])).count == 2)
    #expect(store.watched.map(\.id) == [ids[1]])
    #expect(store.apply(.reorder(ids: [ids[1], ids[0]])).map(\.id) == [ids[1], ids[0]])
  }

  /// The ceiling is the one thing besides a removal that may shorten the list, and only while
  /// adding: twelve places plus a new one is twelve, not thirteen and not one.
  @Test
  func `the ceiling may still push the oldest unwatched row off when a place is added`() {
    let store = store()
    store.places = (0..<12).map { saved("Place \($0)", lat: 30 + Double($0) / 10) }
    let after = store.apply(.remember(saved("Georgetown, TX", lat: 32.5)))
    #expect(after.count == WeatherSavedPlaces.limit)
    #expect(after.first?.label == "Georgetown, TX")
  }

  /// Nothing else may: a hand-rolled shorter list is refused outright.
  @Test
  func `a write that drops places nobody asked to drop is refused`() {
    let store = store()
    let stored = [saved("Austin, TX", lat: 30.27), saved("Llano, TX", lat: 30.75)]
    store.places = stored
    // `ordering` never drops, so ask it to keep only one and check the guard, not the rule.
    let dropped = WeatherSavedPlaces.dropped([stored[0]], from: stored)
    #expect(dropped == [stored[1].id])
    #expect(WeatherSavedPlaces.dropped(stored, from: stored).isEmpty)
  }
}

@Suite("Weather readings for another place")
struct WeatherNearestReadingTests {
  typealias P = WeatherPhoneFixture

  @Test
  func `a saved place shows the nearest reading that carries a temperature`() throws {
    let readings = WeatherStations.readings(
      states: [P.botID: P.state()],
      coverage: WeatherCoverage.make(states: [P.botID: P.state()], tables: .shared, now: P.now),
      place: P.place(P.dallas, label: "Dallas, TX"), tables: .shared, now: P.now)
    let near = try #require(WeatherStations.nearestReading(in: readings, to: P.austin))
    #expect(near.reading.station.icao == "KATT")
    #expect(near.kilometres < 10)
  }

  @Test
  func `nothing within reach is nothing held`() {
    let readings = WeatherStations.readings(
      states: [P.botID: P.state()],
      coverage: WeatherCoverage.make(states: [P.botID: P.state()], tables: .shared, now: P.now),
      place: P.place(P.austin), tables: .shared, now: P.now)
    #expect(WeatherStations.nearestReading(in: readings, to: P.dallas) == nil)
  }
}

/// A place the bot's own statement genuinely excludes, and one it only fails to mention
/// (docs/MESHWX_UI.md §6, §11.1).
@Suite("Weather update plan and stated coverage")
struct WeatherUpdatePlanCoverageTests {
  typealias P = WeatherPhoneFixture

  let wxAus = WeatherBot(
    publicKey: Data([0x1D, 0x04]) + Data(repeating: 0x55, count: 30),
    name: "WX-AUS", latitude: 0, longitude: 0, lastAdvert: nil)

  /// A stated zone list is read against the place's own UGCs, and a place with none cannot be
  /// placed — which is unknown, not outside. The outlines are parsed lazily, so the suite loads
  /// them first, as the screen does on the way in.
  init() async {
    await MeshWXGeometry.shared.preload()
  }

  func plan(_ state: WeatherBotState) -> WeatherUpdatePlan {
    let place = P.place(P.dallas, label: "Dallas, TX")
    let snapshot = WeatherScreenSnapshot.make(
      WeatherScreenSnapshot.Inputs(
        states: [P.botID: state], bots: [wxAus], preferredBotID: nil, place: place,
        isRadioConnected: true, firmwareSupportsWeather: true, firmwareVersion: "v1.15.0",
        hasWeatherChannel: true, session: WeatherSessionInfo(startedAt: P.now.addingTimeInterval(-3600)),
        now: P.now, calendar: P.calendar),
      geometry: MeshWXGeometry.shared, tables: .shared)
    return WeatherUpdatePlan.make(
      snapshot: snapshot, sourceState: state, placeCountyUGC: "TXC113", placeZoneUGC: "TXZ103",
      nearbyStation: WeatherUpdatePlanTests.nearby("KDAL", to: P.dallas), tables: .shared, now: P.now)
  }

  @Test
  func `a complete statement that excludes the place asks by its zone and county`() {
    let plan = plan(P.stating(P.statement))
    #expect(plan.steps.filter { $0.item == .areaAlerts }.map(\.request)
      == [.warningsTouching(ugc: "TXZ103"), .warningsTouching(ugc: "TXC113")])
  }

  /// A zone list the bot had to cut says "not listed", never "not covered" (spec §7A). Unknown
  /// spends no airtime: two nationwide requests for a place that is very likely inside the area
  /// is exactly what "no bot says inside" used to buy.
  @Test
  func `a cut zone list is unknown and asks for nothing by area`() {
    var cut = P.statement
    cut.areasCut = true
    let plan = plan(P.stating(cut))
    #expect(!plan.items.contains(.areaAlerts))
    // The rest of the plan is unaffected: the list, the readings and the forecast still stand.
    #expect(plan.items == [.alerts, .readings, .forecast])
  }

  @Test
  func `a bot that has stated nothing and reported nothing asks for nothing by area`() {
    var bare = WeatherBotState(botID: P.botID)
    bare.lastHeardAt = P.now
    #expect(!plan(bare).items.contains(.areaAlerts))
  }
}

/// Spec revision 10, §1.3: the forecast card and the Update plan for a place the bundle has no
/// point for, and for a forecast the bot chose the point for.
@Suite("Weather forecast by coordinate")
struct WeatherForecastAtTests {
  typealias P = WeatherPhoneFixture
  let tables = MeshWXTables.shared

  /// Pago Pago, American Samoa: the office PPG is one of the nine the first cut of
  /// `pfm_points.json` had no point at all for, and the Pacific territories are still thousands
  /// of kilometres from the nearest one.
  static let pagoPago = MeshWXCoordinate(latitude: -14.2756, longitude: -170.7020)
  static let santaFe = MeshWXCoordinate(latitude: 35.687, longitude: -105.938)

  private func plan(_ state: WeatherBotState, place: WeatherPlace) -> WeatherUpdatePlan {
    let snapshot = WeatherScreenSnapshot.make(
      WeatherScreenSnapshot.Inputs(
        states: [P.botID: state],
        bots: [WeatherBot(
          publicKey: Data([0x1D, 0x04]) + Data(repeating: 0x55, count: 30),
          name: "WX-AUS", latitude: 0, longitude: 0, lastAdvert: nil)],
        preferredBotID: nil, place: place, isRadioConnected: true, firmwareSupportsWeather: true,
        firmwareVersion: "v1.15.0", hasWeatherChannel: true,
        session: WeatherSessionInfo(startedAt: P.now.addingTimeInterval(-3600)),
        now: P.now, calendar: P.calendar),
      geometry: MeshWXGeometry.shared, tables: tables)
    return WeatherUpdatePlan.make(
      snapshot: snapshot, sourceState: state, coverageAlreadyAsked: true, tables: tables,
      now: P.now)
  }

  /// The empty card with no point to name still asks — by coordinate. Before revision 10 it was
  /// `.noPointNearby` and asked for nothing at all, which is what the owner saw as "forecast
  /// works in chat but not in the app".
  @Test
  func `a place with no bundled point in reach is asked about by coordinate`() {
    let place = P.place(Self.pagoPago, label: "Pago Pago, AS")
    var state = P.state()
    state.forecasts = [:]
    let plan = plan(state, place: place)
    #expect(plan.steps.map(\.request).contains(
      .forecastAt(latitude: Self.pagoPago.latitude, longitude: Self.pagoPago.longitude)))
    #expect(plan.items.contains(.forecast))
  }

  /// A held forecast under a coordinate within 25 km of the place **is** that place's forecast,
  /// labelled as a point the bot chose — this page cannot name the point, because the bundle has
  /// none there.
  @Test
  func `a coordinate forecast within twenty-five kilometres is the place's forecast`() throws {
    var state = WeatherBotState(botID: P.botID)
    let key = WeatherRequest.coordinateKey(
      latitude: Self.pagoPago.latitude, longitude: Self.pagoPago.longitude)
    state.unbundledForecasts[key] = WeatherStoredForecast(
      forecast: P.dailyForecast(point: 0xFFFF, issuedMinutes: P.nowMinutes - 60, temps: [(88, 74)]),
      receivedAt: P.now, requestLabel: key, requestedHere: true)

    guard case let .forecast(summary) = WeatherForecastCard.make(
      states: [P.botID: state], place: P.place(Self.pagoPago, label: "Pago Pago, AS"),
      tables: tables, now: P.now, calendar: P.calendar)
    else {
      Issue.record("expected the held coordinate forecast to be the place's")
      return
    }
    #expect(summary.point == nil, "the bundle has no point to name")
    #expect(summary.isOwn)
    #expect(summary.rows.first?.highF == 88)
    guard case let .botChosenPoint(kilometres) = summary.source else {
      Issue.record("expected the bot's own choice of point")
      return
    }
    #expect(kilometres < 1)
  }

  /// Twenty-five kilometres, and no further: what is held under a coordinate is a forecast for a
  /// point nobody here can see, somewhere near it.
  @Test
  func `a coordinate forecast further than twenty-five kilometres is not the place's`() {
    var state = WeatherBotState(botID: P.botID)
    // Half a degree of latitude is about 55 km.
    let key = WeatherRequest.coordinateKey(
      latitude: Self.pagoPago.latitude + 0.5, longitude: Self.pagoPago.longitude)
    state.unbundledForecasts[key] = WeatherStoredForecast(
      forecast: P.dailyForecast(point: 0xFFFF, issuedMinutes: P.nowMinutes - 60, temps: [(88, 74)]),
      receivedAt: P.now, requestedHere: true)
    guard case let .missing(point, _) = WeatherForecastCard.make(
      states: [P.botID: state], place: P.place(Self.pagoPago, label: "Pago Pago, AS"),
      tables: tables, now: P.now, calendar: P.calendar)
    else {
      Issue.record("expected an empty card")
      return
    }
    #expect(point == nil)
  }

  /// The one slot for an answer nobody here asked for is never a place's forecast: its key is
  /// deliberately not a coordinate, so nothing can mistake it for one.
  @Test
  func `the slot for somebody else's question is never shown as a place's forecast`() {
    var state = WeatherBotState(botID: P.botID)
    state.unbundledForecasts[WeatherBotState.unbundledAskKey] = WeatherStoredForecast(
      forecast: P.dailyForecast(point: 0xFFFF, issuedMinutes: P.nowMinutes - 60, temps: [(88, 74)]),
      receivedAt: P.now)
    guard case .missing = WeatherForecastCard.make(
      states: [P.botID: state], place: P.place(Self.pagoPago, label: "Pago Pago, AS"),
      tables: tables, now: P.now, calendar: P.calendar)
    else {
      Issue.record("expected an empty card")
      return
    }
    #expect(WeatherForecastCard.coordinate(fromKey: WeatherBotState.unbundledAskKey) == nil)
    #expect(WeatherForecastCard.coordinate(fromKey: "35.687,-105.938")
      == MeshWXCoordinate(latitude: 35.687, longitude: -105.938))
  }

  /// A stale forecast the bot chose the point for is refreshed the way it was fetched. Asking
  /// `>f <nearest bundled index>` instead would come back with another place's forecast, which is
  /// exactly what the bundle's gaps used to produce.
  @Test
  func `a stale coordinate forecast is refreshed by coordinate, not by index`() {
    var state = P.state()
    state.forecasts = [:]
    let place = P.place(Self.pagoPago, label: "Pago Pago, AS")
    let key = WeatherRequest.coordinateKey(
      latitude: Self.pagoPago.latitude, longitude: Self.pagoPago.longitude)
    state.unbundledForecasts[key] = WeatherStoredForecast(
      forecast: P.dailyForecast(point: 0xFFFF, issuedMinutes: P.nowMinutes - 13 * 60, temps: [(88, 74)]),
      receivedAt: P.now.addingTimeInterval(-3600), requestedHere: true)
    let plan = plan(state, place: place)
    #expect(plan.steps.map(\.request).contains(
      .forecastAt(latitude: Self.pagoPago.latitude, longitude: Self.pagoPago.longitude)))
    #expect(!plan.steps.contains { if case .forecast = $0.request { true } else { false } })
  }

  /// A place the bundle does have a point for is unchanged: `>f <index>` as before.
  @Test
  func `a place with a bundled point still asks by index`() {
    var state = P.state()
    state.forecasts = [:]
    let plan = plan(state, place: P.place(P.austin))
    #expect(plan.steps.map(\.request).contains(.forecast(point: 103)))
  }
}
