import Foundation
import MC1Services
import MeshWX
import Testing

@testable import MC1

/// When a new phone fix is worth moving the place for.
@Suite("Weather location samples")
struct WeatherLocationSampleTests {
  static let now = WeatherFormattingTests.now

  func sample(latitude: Double = 30.2672, accuracy: Double = 50, after seconds: TimeInterval = 0) -> WeatherLocationSample {
    WeatherLocationSample(latitude: latitude, longitude: -97.7431, horizontalAccuracy: accuracy, timestamp: Self.now.addingTimeInterval(seconds))
  }

  @Test
  func `a survey stream's next fix a second later changes nothing`() {
    #expect(!WeatherToolModel.isMeaningfulChange(from: sample(), to: sample(latitude: 30.2673, after: 1)))
  }

  @Test
  func `a fix a minute newer replaces the place`() {
    #expect(WeatherToolModel.isMeaningfulChange(from: sample(), to: sample(after: 61)))
  }

  @Test
  func `a fix half a kilometre away replaces the place`() {
    #expect(WeatherToolModel.isMeaningfulChange(from: sample(), to: sample(latitude: 30.30, after: 5)))
  }

  @Test
  func `a much more accurate fix replaces a coarse one, a slightly better one does not`() {
    #expect(WeatherToolModel.isMeaningfulChange(from: sample(accuracy: 3000), to: sample(accuracy: 65, after: 5)))
    #expect(!WeatherToolModel.isMeaningfulChange(from: sample(accuracy: 100), to: sample(accuracy: 60, after: 5)))
    #expect(WeatherToolModel.isMeaningfulChange(from: sample(accuracy: -1), to: sample(accuracy: 60, after: 5)))
    #expect(!WeatherToolModel.isMeaningfulChange(from: sample(accuracy: 100), to: sample(accuracy: -1, after: 5)))
  }
}

/// The model's request bookkeeping and the store's visit lifetime, without a radio.
@Suite("Weather tool model")
@MainActor
struct WeatherToolModelTests {
  static let botID: UInt16 = 0x041D

  @Test
  func `a request is pending from the tap, before the service has answered`() {
    let model = WeatherToolModel()
    model.beginRequest(.digest)
    guard case .pending = model.status(for: .digest) else {
      Issue.record("expected pending, got \(model.status(for: .digest))")
      return
    }
    #expect(model.activeRequest == .digest)
    model.endRequest(.digest)
    #expect(model.activeRequest == nil)
    // No snapshot yet, so nothing can be asked: the block shows, not the old pending state.
    #expect(model.status(for: .digest) == .blocked(.noBot))
  }

  /// With a snapshot and nothing blocking, every request used to read "No weather radio to ask
  /// yet" and nothing was sent, picking a town included.
  @Test
  func `a snapshot with no block can be asked, and only no snapshot means no weather radio`() {
    let now = WeatherFormattingTests.now
    let bot = WeatherBot(
      publicKey: Data([0x1D, 0x04]) + Data(repeating: 0x55, count: 30), name: "WX-AUS", latitude: 0, longitude: 0,
      lastAdvert: nil)
    func snapshot(connected: Bool) -> WeatherScreenSnapshot {
      WeatherScreenSnapshot.make(
        WeatherScreenSnapshot.Inputs(
          states: [:], bots: [bot], preferredBotID: nil, place: nil, isRadioConnected: connected,
          firmwareSupportsWeather: true, firmwareVersion: "v1.15.0", hasWeatherChannel: true,
          session: WeatherSessionInfo(startedAt: now), now: now, calendar: WeatherFormattingTests.calendar),
        geometry: MeshWXGeometry.shared, tables: .shared)
    }
    func status(_ snapshot: WeatherScreenSnapshot?) -> WeatherRequestStatus {
      WeatherToolModel.status(for: .forecast(point: 103), snapshot: snapshot, pending: [], inFlight: [], outcomes: [:], now: now)
    }

    let ready = snapshot(connected: true)
    #expect(ready.requestBlock == nil)
    #expect(status(ready) == .idle)
    #expect(status(snapshot(connected: false)) == .blocked(.radioOffline))
    #expect(status(nil) == .blocked(.noBot))
  }

  /// Until 2026-09-21 a bot heard on the channel with no contact for it blocked every ask. A
  /// request is a datagram that names the bot by the two bytes its own packets carry, so `send`
  /// asks a stand-in (`WeatherBot.heardOnly`) — while the screen goes on calling it
  /// "Weather radio 041D", the advert being what a name needs and a DM needs.
  @Test
  func `a bot heard with no advert is asked as itself, and stays unnamed`() throws {
    let now = WeatherFormattingTests.now
    var state = WeatherBotState(botID: Self.botID)
    state.lastHeardAt = now.addingTimeInterval(-120)
    let screen = WeatherScreenSnapshot.make(
      WeatherScreenSnapshot.Inputs(
        states: [Self.botID: state], bots: [], preferredBotID: nil, place: nil, isRadioConnected: true,
        firmwareSupportsWeather: true, firmwareVersion: "v1.15.0", hasWeatherChannel: true,
        session: WeatherSessionInfo(startedAt: now), now: now, calendar: WeatherFormattingTests.calendar),
      geometry: MeshWXGeometry.shared, tables: .shared)
    let source = try #require(screen.source)
    #expect(source.bot == nil)
    #expect(source.requestBot.botID == Self.botID)
    #expect(!source.requestBot.isAnnounced)
    #expect(WeatherFormatting.botName(botID: source.botID, bot: source.bot) == "Weather radio 041D")
    #expect(WeatherToolModel.status(
      for: .digest, snapshot: screen, pending: [], inFlight: [], outcomes: [:], now: now) == .idle)
  }

  @Test
  func `a missing warning refused since its list arrived is passed over`() {
    let listed = WeatherFormattingTests.now
    let outcomes: [WeatherRequest: WeatherSettledOutcome] = [
      .warning(identity: "SV.W.EWX.42"): WeatherSettledOutcome(outcome: .notAvailable(.noData), at: listed.addingTimeInterval(60)),
      .warning(identity: "SV.W.EWX.43"): WeatherSettledOutcome(outcome: .timedOut(botWasHeard: false), at: listed.addingTimeInterval(60)),
      .warning(identity: "SV.W.EWX.44"): WeatherSettledOutcome(outcome: .notAvailable(.noData), at: listed.addingTimeInterval(-60)),
      .digest: WeatherSettledOutcome(outcome: .notAvailable(.noData), at: listed.addingTimeInterval(60))
    ]
    #expect(WeatherToolModel.notAvailableIdentities(outcomes: outcomes, since: listed)
      == [MeshWXWarningIdentity(event: 3, office: 35, etn: 42)])
  }

  @Test
  func `a second call clears only the fingerprint it recorded`() {
    let model = WeatherToolModel()
    let first = UUID()
    let second = UUID()
    model.recordFingerprint(WeatherToolModel.Fingerprint(token: first, value: 1, kind: .other), for: .digest)
    model.recordFingerprint(WeatherToolModel.Fingerprint(token: second, value: 2, kind: .other), for: .digest)
    model.clearFingerprint(for: .digest, token: first)
    #expect(model.fingerprints[.digest]?.token == second)
    model.clearFingerprint(for: .digest, token: second)
    #expect(model.fingerprints[.digest] == nil)
  }

  @Test
  func `a forecast answer with the same issue time is nothing new`() throws {
    var state = WeatherBotState(botID: Self.botID)
    state.forecasts[103] = WeatherStoredForecast(
      forecast: MeshWXForecast(pointIndex: 103, issuedMinutes: 29_000_000, firstPeriod: 0, periods: []), receivedAt: .now)
    let before = try #require(WeatherToolModel.fingerprint(.forecast(point: 103), sourceBotID: Self.botID, states: [Self.botID: state]))
    #expect(before.kind == .forecast)
    #expect(before.value == 29_000_000)
    state.forecasts[103]?.forecast.issuedMinutes = 29_000_060
    let after = WeatherToolModel.fingerprint(.forecast(point: 103), sourceBotID: Self.botID, states: [Self.botID: state])
    #expect(after?.value != before.value)
  }

  @Test
  func `alert lists and text replies have fingerprints too`() {
    var state = WeatherBotState(botID: Self.botID)
    state.digest = WeatherStoredDigest(digest: MeshWXDigest(nowMinutes: 50, feedHealth: 2, entries: []), receivedAt: .now)
    #expect(WeatherToolModel.fingerprint(.digest, sourceBotID: Self.botID, states: [Self.botID: state])?.value == 50)

    func textPrint() -> Int? {
      WeatherToolModel.fingerprint(.spaceWeather, sourceBotID: Self.botID, states: [Self.botID: state])?.value
    }
    #expect(textPrint() == nil)
    // Somebody else's reply on the same subject is not an answer to this phone.
    state.texts[3] = WeatherTextAssembly(
      subject: .spaceWeather, group: 3, total: 1, chunks: [0: "Kp 3"], firstReceivedAt: .now, lastReceivedAt: .now)
    #expect(textPrint() == nil)

    state.texts[5] = WeatherTextAssembly(
      subject: .spaceWeather, group: 5, total: 1, chunks: [0: "Kp 4"], firstReceivedAt: .now, lastReceivedAt: .now,
      request: .spaceWeather)
    let one = textPrint()
    #expect(one != nil)
    state.texts[5]?.lastReceivedAt = .now.addingTimeInterval(60)
    #expect(textPrint() == one)
    state.texts[4] = WeatherTextAssembly(
      subject: .spaceWeather, group: 4, total: 1, chunks: [0: "Kp 6"], firstReceivedAt: .now, lastReceivedAt: .now)
    #expect(textPrint() == one)
    state.texts[9] = WeatherTextAssembly(
      subject: .spaceWeather, group: 9, total: 1, chunks: [0: "Kp 5"], firstReceivedAt: .now, lastReceivedAt: .now,
      request: .spaceWeather)
    #expect(textPrint() != one)
  }

  @Test
  func `only a complete reply this phone asked for, under five minutes old, replaces the button`() {
    let now = WeatherFormattingTests.now
    let owned = WeatherTextAssembly(
      subject: .metarOrTAF, group: 7, total: 1, chunks: [0: "KAUS 150553Z"], firstReceivedAt: now, lastReceivedAt: now,
      request: .metar(station: "KAUS"))
    #expect(WeatherToolModel.isFreshOwnedReply(owned, for: .metar(station: "KAUS"), now: now.addingTimeInterval(60)))
    #expect(!WeatherToolModel.isFreshOwnedReply(owned, for: .metar(station: "KAUS"), now: now.addingTimeInterval(5 * 60)))
    #expect(!WeatherToolModel.isFreshOwnedReply(owned, for: .taf(station: "KAUS"), now: now))
    var partial = owned
    partial.total = 2
    #expect(!WeatherToolModel.isFreshOwnedReply(partial, for: .metar(station: "KAUS"), now: now))
    var overheard = owned
    overheard.request = nil
    #expect(!WeatherToolModel.isFreshOwnedReply(overheard, for: .metar(station: "KAUS"), now: now))
  }

  /// A bare `>o` comes back with the batch the bot would send now, so it can refresh a station
  /// that batch still carries and nothing else. Being in the footprint — any multi-station batch
  /// of the last day — is not enough.
  @Test
  func `a station the newest batch no longer carries is asked for by its code`() throws {
    let now = WeatherFormattingTests.now
    let nowMinutes = UInt32(now.timeIntervalSince1970 / 60)
    let place = WeatherPlace(
      kind: .current, coordinate: MeshWXCoordinate(latitude: 30.2672, longitude: -97.7431), label: "Austin, TX",
      uncertaintyKilometres: 0.5, locatedAt: now)
    var state = WeatherBotState(botID: Self.botID)
    func batch(_ seq: UInt8, _ minutes: UInt32, _ stations: [UInt16]) {
      _ = WeatherStateReducer.apply(
        MeshWXMessage(
          header: MeshWXHeader(seq: seq, bot: Self.botID, type: .observations),
          payload: .observations(MeshWXObservations(
            timestampMinutes: minutes,
            stations: stations.map { MeshWXStationObservation(stationIndex: $0, tempF: 88, sky: .few) }))),
        to: &state, receivedAt: now)
    }
    batch(1, nowMinutes - 60, [202, 860, 194])
    batch(2, nowMinutes, [202, 860])

    let states = [Self.botID: state]
    let coverage = WeatherCoverage.make(states: states, tables: .shared, now: now)
    let readings = WeatherStations.readings(states: states, coverage: coverage, place: place, tables: .shared, now: now)
    let carried = try #require(readings.first { $0.index == 202 })
    #expect(WeatherUpdatePlan.readingsRequest(for: carried) == .observations)

    let dropped = try #require(readings.first { $0.index == 194 })
    #expect(dropped.isInFootprint)
    #expect(WeatherUpdatePlan.readingsRequest(for: dropped) == .observation(station: dropped.station.icao))
  }

  /// Picking keeps the place and sends nothing: the automatic forecast request on a pick is gone
  /// (docs/MESHWX_UI.md §3.1 O-1, overturned), and Update is on the screen behind.
  @Test
  func `a pick from Places is applied and kept, and sends nothing`() {
    let model = WeatherToolModel(savedPlacesStore: WeatherPlaceSearchTests.emptyStore(#function))
    let town = WeatherSavedPlace(label: "Round Rock, TX", latitude: 30.5, longitude: -97.7, chosenAt: .now)
    model.pendingPlaceAction = .place(town)
    #expect(model.applyPendingPlaceAction(isLocationAuthorized: false) == false)
    #expect(model.searchedPlace == town.place)
    #expect(model.savedPlaces.map(\.id) == [town.id])
    #expect(model.stationToOpen == nil)
    #expect(model.pending.isEmpty)
    #expect(model.inFlight.isEmpty)
    #expect(model.pendingPlaceAction == nil)

    model.pendingPlaceAction = .currentLocation
    #expect(model.applyPendingPlaceAction(isLocationAuthorized: false) == true)
  }

  @MainActor
  final class OpenTool {
    var isOpen = true
  }

  @Test
  func `the visit's model survives while the tool is open and goes when it is left`() {
    let store = WeatherModelStore()
    let tool = OpenTool()
    let model = store.rootAppeared { tool.isOpen }
    #expect(store.isCurrent(model))

    // A shell swap: the old root goes, a new one comes, the model is the same.
    store.rootDisappeared()
    #expect(store.rootAppeared { tool.isOpen } === model)

    // A pushed detail: no root on screen, the tool still open.
    store.rootDisappeared()
    store.evaluate()
    #expect(store.model === model)

    // Back to the tool list.
    tool.isOpen = false
    store.evaluate()
    #expect(store.model == nil)
    #expect(store.rootAppeared { true } !== model)
  }

  // MARK: - One build per page (docs/MESHWX_UI.md §13)

  /// The state storm reports and rainfall ask about is one page's answer to "which state". It
  /// was one value for the whole visit, so picking Texas on one page sent `>storm TX` from every
  /// page — including one in Puerto Rico.
  @Test
  func `a state picked on one page is that page's alone`() {
    let model = WeatherToolModel()
    let dallas = "at:32.777,-96.797"
    model.setReportState("TX", forPageID: dallas)
    #expect(model.reportState(for: dallas) == "TX")
    #expect(model.reportState(for: WeatherPage.myLocationID) == nil)
    model.setReportState("PR", forPageID: WeatherPage.myLocationID)
    #expect(model.reportState(for: dallas) == "TX")
    #expect(model.reportState(for: WeatherPage.myLocationID) == "PR")
  }

  /// The swipe window: the title already names the new place while its build is still coming.
  /// A page with no build has no plan, so Update is disabled and a pull sends nothing — rather
  /// than sending the previous place's requests under this page's name.
  @Test
  func `a page with no build has no plan, no screen and no update run`() {
    let model = WeatherToolModel()
    #expect(model.screen(for: WeatherPage.myLocationID) == nil)
    #expect(model.build(for: WeatherPage.myLocationID) == nil)
    #expect(model.plan(for: WeatherPage.myLocationID).isEmpty)
    #expect(model.plan(for: "at:32.777,-96.797").isEmpty)
    #expect(!model.isUpdating(pageID: WeatherPage.myLocationID))
    #expect(model.updateRequests(pageID: WeatherPage.myLocationID).isEmpty)
    #expect(model.updateStatusText(pageID: WeatherPage.myLocationID) == nil)
    // A tap in that window starts nothing at all.
    model.update(model.plan(for: WeatherPage.myLocationID), pageID: WeatherPage.myLocationID)
    #expect(!model.isUpdating(pageID: WeatherPage.myLocationID))
  }

  /// A selection pointing at a page that is gone is a page nothing can be built for, and a
  /// spinner on every page until the next swipe. It is resolved and written back.
  @Test
  func `a page id nothing answers to leaves the pager on my location`() {
    let model = WeatherToolModel()
    model.showPage("at:32.777,-96.797")
    #expect(model.selectedPageID == WeatherPage.myLocationID)
    #expect(model.pages.map(\.id) == [WeatherPage.myLocationID])
  }
}

/// What Places finds, and what picking it keeps.
@Suite("Weather place search")
@MainActor
struct WeatherPlaceSearchTests {
  /// **An airport code opens the station screen and nothing else** (docs/MESHWX_UI.md §3.1 U-3).
  ///
  /// It used to do three things at once: push the station, save a place and add a page. KAUS
  /// produced a second page called "Austin" beside the one already there; TJSJ produced a page
  /// called "Eleanor Roosevelt", named after the town nearest the airport. An airport code is a
  /// question about a station, not a place someone asked to keep.
  @Test
  func `an airport code opens its station and creates no place`() throws {
    let index = try #require(MeshWXTables.shared.stationIndex(forICAO: "TJSJ"))
    let model = WeatherToolModel(savedPlacesStore: Self.emptyStore(#function))

    model.pendingPlaceAction = .station(index: index)
    #expect(model.applyPendingPlaceAction(isLocationAuthorized: false) == false)
    #expect(model.stationToOpen?.index == index)
    #expect(model.savedPlaces.isEmpty)
    #expect(model.pages.map(\.id) == [WeatherPage.myLocationID])
    // And it is pushed over the page the user was already on.
    #expect(model.stationToOpen?.pageID == model.selectedPageID)
  }

  /// A search by airport code still finds the station; what changed is what picking it does.
  @Test
  func `an airport code still finds its station by prefix`() throws {
    let result = try #require(WeatherPlacePickerView.stations(matchingCode: "tjsj", near: nil, tables: .shared).first)
    #expect(result.station.icao == "TJSJ")
  }

  /// Each destination is judged against the page it was opened from, not the page the pager has
  /// since landed on (docs/MESHWX_UI.md §3.1 U-18).
  @Test
  func `a tapped alert carries the page it was raised for`() {
    let model = WeatherToolModel(savedPlacesStore: Self.emptyStore(#function))
    let identity = MeshWXWarningIdentity(event: 0, office: 1, etn: 42)
    model.alertToOpen = WeatherAlertTarget(pageID: "at:30.510,-97.679", identity: identity)
    #expect(model.alertToOpen?.pageID == "at:30.510,-97.679")
    #expect(model.alertToOpen?.identity == identity)
  }

  /// A defaults suite of this test's own: the model writes through the real store now, and the
  /// user's saved places are not a fixture.
  static func emptyStore(_ name: String) -> WeatherSavedPlacesStore {
    let suite = "weather.tests.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return WeatherSavedPlacesStore(defaults: defaults)
  }

  @Test
  func `airport codes are three or four letters and digits`() {
    #expect(WeatherPlacePickerView.looksLikeStationCode("TJSJ"))
    #expect(WeatherPlacePickerView.looksLikeStationCode("7R5"))
    #expect(!WeatherPlacePickerView.looksLikeStationCode("San Juan"))
    #expect(!WeatherPlacePickerView.looksLikeStationCode("sj"))
  }

  /// A code finds its station and stops there: there is no `WeatherPlace` built from a station
  /// any more, because that is what named a saved page "Eleanor Roosevelt" after picking TJSJ
  /// (docs/MESHWX_UI.md §3.1 U-3).
  @Test
  func `a code finds its station, and the station stays a station`() throws {
    let found = WeatherPlacePickerView.stations(matchingCode: "tjsj", near: nil, tables: .shared)
    let result = try #require(found.first)
    #expect(result.station.icao == "TJSJ")
    #expect(MeshWXTables.shared.stationIndex(forICAO: result.station.icao) != nil)
  }

  @Test
  func `a town name is not searched as a code`() {
    #expect(WeatherPlacePickerView.stations(matchingCode: "Austin", near: nil, tables: .shared).isEmpty)
  }

  @Test
  func `five digits or ZIP+4 is a ZIP and never an airport code, three or four characters may be one`() {
    #expect(WeatherPlacePickerView.queryKind("78701") == .zip("78701"))
    #expect(WeatherPlacePickerView.queryKind("00901") == .zip("00901"))
    #expect(WeatherPlacePickerView.queryKind("78701-1234") == .zip("78701"))
    #expect(WeatherPlacePickerView.queryKind("KAUS") == .townOrAirportCode)
    #expect(WeatherPlacePickerView.queryKind("7R5") == .townOrAirportCode)
    #expect(WeatherPlacePickerView.queryKind("Round Rock") == .town)
    #expect(WeatherPlacePickerView.queryKind("787011") == .town)
    #expect(WeatherPlacePickerView.queryKind("78701-12") == .town)
    #expect(!WeatherPlacePickerView.looksLikeStationCode("78701"))
    #expect(WeatherPlacePickerView.stations(matchingCode: "78701", near: nil, tables: .shared).isEmpty)
  }

  @Test
  func `a ZIP shows one row, labelled as the bot labels it, that picks the ZIP's point`() throws {
    let found = WeatherPlacePickerView.results(for: "78701", near: nil, tables: .shared)
    #expect(found.places.isEmpty)
    #expect(found.stations.isEmpty)
    guard case let .found(zip) = try #require(found.zip) else {
      Issue.record("expected a ZIP row, got \(String(describing: found.zip))")
      return
    }
    #expect(zip.label == "Austin, TX 78701")
    let place = WeatherPlace.zip(zip)
    #expect(place.kind == .searched)
    #expect(place.label == "Austin, TX 78701")
    #expect(place.coordinate == MeshWXCoordinate(latitude: 30.2706, longitude: -97.7426))
  }

  @Test
  func `a ZIP+4 and a leading zero find their ZIP`() throws {
    let tables = MeshWXTables.shared
    let austin = try #require(tables.zip("78701"))
    let sanJuan = try #require(tables.zip("00901"))
    #expect(WeatherPlacePickerView.results(for: "78701-1234", near: nil, tables: tables).zip == .found(austin))
    #expect(WeatherPlacePickerView.results(for: "00901", near: nil, tables: tables).zip == .found(sanJuan))
    #expect(sanJuan.label == "San Juan, PR 00901")
  }

  @Test
  func `an unknown ZIP gets a row saying so, not an empty list`() {
    let unknown = WeatherPlacePickerView.results(for: "99999", near: nil, tables: .shared)
    #expect(unknown.zip == .unknown("99999"))
    #expect(!unknown.isEmpty)
    #expect(WeatherPlacePickerView.results(for: "20500-0001", near: nil, tables: .shared).zip == .unknown("20500"))
  }

  @Test
  func `airport codes and towns search as before`() {
    let code = WeatherPlacePickerView.results(for: "KAUS", near: nil, tables: .shared)
    #expect(code.zip == nil)
    #expect(code.stations.first?.station.icao == "KAUS")
    let town = WeatherPlacePickerView.results(for: "round rock", near: nil, tables: .shared)
    #expect(town.zip == nil)
    #expect(town.stations.isEmpty)
    #expect(town.places.first?.name == "ROUND ROCK")
  }
}

/// When the map outlines are worth loading (docs/MESHWX_UI.md §3.1 U-27).
@Suite("Weather outlines")
struct WeatherScreenBuilderGeometryTests {

  /// A warning the phone must draw itself: area runs, no polygon of its own.
  func stateWithUndrawnWarning() -> [UInt16: WeatherBotState] {
    let warning = MeshWXWarning(
      identity: MeshWXWarningIdentity(event: 3, office: 35, etn: 42), expiresMinutes: 29_000_000,
      areas: [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 100, run: 1)])
    var state = WeatherBotState(botID: 0x041D)
    state.warnings[warning.identity] = WeatherStoredWarning(warning: warning, receivedAt: Date())
    return [0x041D: state]
  }

  /// The San Juan case: a place, nothing held for it. The outlines are what say the place is
  /// outside the radio's area and name the zone and county to ask by, so without them the page
  /// asked for no alerts at all and no alert could ever arrive to load them.
  @Test
  func `a place needs the outlines even with nothing held`() {
    #expect(WeatherScreenBuilder.needsGeometry(hasPlace: true, states: [:]))
    #expect(WeatherScreenBuilder.needsGeometry(hasPlace: true, states: stateWithUndrawnWarning()))
  }

  /// No place: only a warning that must be drawn is worth 15 MB of outlines.
  @Test
  func `with no place only an undrawn warning asks for them`() {
    #expect(!WeatherScreenBuilder.needsGeometry(hasPlace: false, states: [:]))
    #expect(!WeatherScreenBuilder.needsGeometry(hasPlace: false, states: [0x041D: WeatherBotState(botID: 0x041D)]))
    #expect(WeatherScreenBuilder.needsGeometry(hasPlace: false, states: stateWithUndrawnWarning()))
  }

  /// San Juan lies in two land zones and in Atlantic marine zone AMZ712, in whatever order the
  /// outlines answer. The land zone of the place's own state is the one a radio is asked about.
  @Test
  func `a coastal place asks about its land zone, not the water`() {
    let sanJuan = ["AMZ712", "PRZ016", "PRC127", "PRZ001"]
    #expect(WeatherScreenBuilder.placeZone(from: sanJuan, stateCode: "PR", county: "PRC127") == "PRZ001")
    // No state code held yet: the county names the state.
    #expect(WeatherScreenBuilder.placeZone(from: sanJuan, stateCode: nil, county: "PRC127") == "PRZ001")
    // Nothing says which state: any zone beats no zone, and the choice is at least stable.
    #expect(WeatherScreenBuilder.placeZone(from: sanJuan, stateCode: nil, county: nil) == "AMZ712")
    #expect(WeatherScreenBuilder.placeZone(from: ["TXC453", "TXZ192"], stateCode: "TX", county: "TXC453") == "TXZ192")
    #expect(WeatherScreenBuilder.placeZone(from: ["TXC453"], stateCode: "TX", county: "TXC453") == nil)
  }
}

/// The model's revision 10 rules: which areas the next map covers, and how much of the request
/// log the radio page shows (docs/MESHWX_UI.md §17, §3.1 U-37, U-39).
@Suite("Weather tool model, revision 10")
@MainActor
struct WeatherToolModelRevision10Tests {
  func store() -> (WeatherAreaSelectionStore, String) {
    let suite = "test.weather.areaSelection.\(UUID().uuidString)"
    return (WeatherAreaSelectionStore(defaults: UserDefaults(suiteName: suite)!), suite)
  }

  /// The owner's third ask: *have a way for the user to select which areas they want to request
  /// the warnings for.* The choice is one value on the phone, saved the moment it changes —
  /// there is no Done on the picker and nothing to commit.
  @Test
  func `the area selection is saved as it changes`() throws {
    let (store, suite) = store()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let model = WeatherToolModel(areaSelectionStore: store)

    // Nothing chosen and no page built: the whole country, which is also what the store holds
    // nothing for.
    #expect(store.selection == nil)
    #expect(model.areaSelection(forPageID: WeatherPage.myLocationID) == .wholeCountry)

    model.setAreaSelection(WeatherAreaSelection(isWholeCountry: false, states: ["tx", "ok"]))
    let expected = WeatherAreaSelection(isWholeCountry: false, states: ["OK", "TX"])
    #expect(model.areaSelection(forPageID: WeatherPage.myLocationID) == expected)
    #expect(store.selection == expected)
    // Codes are one value however the picker handed them over, so one selection is one request.
    #expect(expected.request(includesAdvisories: false).wireText == ">wmap OKTX")

    // Turning the whole country back on keeps what was picked under it.
    model.setAreaSelection(WeatherAreaSelection(isWholeCountry: true, states: ["OK", "TX"]))
    #expect(model.areaSelection(forPageID: WeatherPage.myLocationID).isWholeCountry)
    #expect(model.areaSelection(forPageID: WeatherPage.myLocationID).states == ["OK", "TX"])
    #expect(store.selection?.isWholeCountry == true)
  }

  /// Before anybody chooses, the map opens on the state of the page's own place: somebody opening
  /// it from their own town wants their own state, and one state is one packet rather than eight.
  @Test
  func `with nothing chosen the default is the page's own state`() {
    #expect(WeatherAreaSelection.default(placeState: "TX")
      == WeatherAreaSelection(isWholeCountry: false, states: ["TX"]))
    #expect(WeatherAreaSelection.default(placeState: nil) == .wholeCountry)
    #expect(WeatherAreaSelection.default(placeState: "") == .wholeCountry)
  }

  /// The owner's fifth ask: *Your requests is way too long of a list.* Three rows and a way in;
  /// the log itself is untouched.
  @Test
  func `the radio page shows the newest three requests and counts the rest`() {
    let now = WeatherFormattingTests.now
    let log = (0..<7).map { offset in
      WeatherRequestLogEntry(
        id: UUID(), request: .digest, botID: 0x041D,
        sentAt: now.addingTimeInterval(-Double(offset) * 60))
    }
    let split = WeatherToolModel.requestLogSplit(log)
    #expect(WeatherToolModel.newestRequestCount == 3)
    #expect(split.newest.map(\.id) == log.prefix(3).map(\.id))
    #expect(split.total == 7)

    // A log short of the limit is the whole log, and there is nothing left to open.
    let short = WeatherToolModel.requestLogSplit(Array(log.prefix(2)))
    #expect(short.newest.count == 2)
    #expect(short.total == 2)
    let none = WeatherToolModel.requestLogSplit([])
    #expect(none.newest.isEmpty)
    #expect(none.total == 0)
    #expect(L10n.Weather.Weather.Requests.all(27) == "All requests (27)")
  }
}
