import Foundation
@testable import MC1Services
import MeshCore
import MeshWX
import Testing

/// Phase 2 (18 October 2026, spec §10.8): several cities' bots on one `#meshwx`. A bot is two
/// self-asserted bytes on the wire until signing (wire revision 14), meshes are bridged so a phone
/// hears two bots and then loses one, and people travel. These are the scenarios the review found,
/// end to end through the service, the screen rules and the notifier. The web client's
/// `WeatherMultiBotTests` runs the same ones.
@Suite("Weather with several bots")
struct WeatherMultiBotTests {
  typealias F = WeatherFixture
  typealias P = WeatherPhoneFixture

  static func key(_ first: UInt8, _ second: UInt8, _ fill: UInt8) -> Data {
    Data([first, second]) + Data(repeating: fill, count: 30)
  }

  /// WX-AUS as the owner's radio holds it: key 1D 04, so `bot` 0x041D.
  static let aus: UInt16 = 0x041D
  static let wxAus = WeatherBot(publicKey: key(0x1D, 0x04, 0x55), name: "WX-AUS", latitude: 0, longitude: 0, lastAdvert: nil)
  /// WX-SAT: key 2B 11, so `bot` 0x112B.
  static let sat: UInt16 = 0x112B
  static let wxSat = WeatherBot(publicKey: key(0x2B, 0x11, 0x66), name: "WX-SAT", latitude: 0, longitude: 0, lastAdvert: nil)
  /// An id nobody announced, sending under it.
  static let spoof: UInt16 = 0xBEEF

  /// 120 km around San Antonio, with its office; neither list cut.
  static let sanAntonioCoverage = MeshWXCoverage(
    latitude: 29.4241, longitude: -98.4936, radiusKilometres: 120, stationCap: 12, officeIndices: [35],
    areas: [MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 200, run: 4)])
  /// `n` = 0 and `k` = 0: no area filter at all, the cheapest statement there is to forge.
  static let everything = MeshWXCoverage(
    latitude: 0, longitude: 0, radiusKilometres: 0, stationCap: 0, officeIndices: [], areas: [])

  static func place(_ label: String, _ latitude: Double, _ longitude: Double) -> WeatherPlace {
    WeatherPlace(
      kind: .searched, coordinate: MeshWXCoordinate(latitude: latitude, longitude: longitude), label: label,
      uncertaintyKilometres: 5)
  }

  static let austin = place("Austin, TX", 30.2672, -97.7431)
  static let sanAntonio = place("San Antonio, TX", 29.4241, -98.4936)
  static let newBraunfels = place("New Braunfels, TX", 29.703, -98.1245)

  /// A Flash Flood Warning's polygon over San Marcos, Hays County: inside both bots' circles.
  static let haysPolygon = [
    MeshWXCoordinate(latitude: 29.95, longitude: -98.0), MeshWXCoordinate(latitude: 29.95, longitude: -97.85),
    MeshWXCoordinate(latitude: 29.82, longitude: -97.85), MeshWXCoordinate(latitude: 29.82, longitude: -98.0)
  ]
  static var ffw: MeshWXWarningIdentity {
    MeshWXWarningIdentity(event: MeshWXTables.shared.eventByCode["FF.W"] ?? 0, office: 35, etn: 77)
  }

  private struct NoOutlines: WeatherAreaGeometry {
    var isLoaded: Bool { false }
    func distanceKilometres(from point: MeshWXCoordinate, toArea ugc: String) -> Double? { nil }
    func centre(ofArea ugc: String) -> MeshWXCoordinate? { nil }
  }

  func service(clock: WeatherTestClock, transport: FakeWeatherTransport = FakeWeatherTransport()) -> WeatherService {
    WeatherService(transport: transport, store: InMemoryWeatherStateStore(), now: { clock.now }, tables: .shared)
  }

  func snapshot(
    states: [UInt16: WeatherBotState], bots: [WeatherBot], place: WeatherPlace?, pick: WeatherBotPick? = nil,
    unansweredAt: [UInt16: Date] = [:], now: Date
  ) -> WeatherScreenSnapshot {
    WeatherScreenSnapshot.make(
      WeatherScreenSnapshot.Inputs(
        states: states, bots: bots, pick: pick, unansweredAt: unansweredAt, place: place, isRadioConnected: true,
        firmwareSupportsWeather: true, firmwareVersion: "v1.15.0", hasWeatherChannel: true,
        session: WeatherSessionInfo(startedAt: now.addingTimeInterval(-3600), lastChannelDatagramAt: now),
        now: now, calendar: P.calendar),
      geometry: NoOutlines(), tables: .shared)
  }

  func state(_ botID: UInt16, coverage: MeshWXCoverage?, heardAt: Date) -> WeatherBotState {
    var state = WeatherBotState(botID: botID)
    if let coverage {
      _ = WeatherStateReducer.apply(F.coverage(seq: 1, coverage, bot: botID), to: &state, receivedAt: heardAt)
    }
    state.lastHeardAt = heardAt
    state.lastLiveHeardAt = heardAt
    return state
  }

  // MARK: - Which bot to ask

  /// Travel: the phone went from Austin to San Antonio. WX-AUS's statement still describes Austin,
  /// and it was the bot used all week, but only WX-SAT can hear this phone now.
  @Test
  func `in San Antonio the bot heard live is asked, not the one that covered home`() async {
    let clock = WeatherTestClock()
    let service = service(clock: clock)
    _ = await service.ingest(F.coverage(seq: 1, bot: Self.aus))
    clock.advance(by: 5 * 3600)
    _ = await service.ingest(F.coverage(seq: 1, Self.sanAntonioCoverage, bot: Self.sat))
    let states = await service.allStates()
    let now = clock.now
    #expect(snapshot(states: states, bots: [Self.wxAus, Self.wxSat], place: Self.sanAntonio, now: now).source?.botID == Self.sat)
    // Even a pick made at home does not follow the phone there.
    let pick = WeatherBotPick(botID: Self.aus, latitude: 30.2672, longitude: -97.7431, pickedAt: now.addingTimeInterval(-3600))
    #expect(snapshot(states: states, bots: [Self.wxAus, Self.wxSat], place: Self.sanAntonio, pick: pick, now: now)
      .source?.botID == Self.sat)
    // Back home it holds, while WX-AUS has been heard in the last six hours.
    let home = snapshot(states: states, bots: [Self.wxAus, Self.wxSat], place: Self.austin, pick: pick, now: now)
    #expect(home.source?.botID == Self.aus)
    #expect(home.source?.isPicked == true)
  }

  @Test
  func `a pick lapses once its bot has gone six hours unheard`() throws {
    let now = F.t0
    let pick = WeatherBotPick(botID: Self.aus, latitude: 30.2672, longitude: -97.7431, pickedAt: now.addingTimeInterval(-7 * 3600))
    #expect(pick.isLapsed(lastLiveHeardAt: now.addingTimeInterval(-6.5 * 3600), now: now))
    #expect(!pick.isLapsed(lastLiveHeardAt: now.addingTimeInterval(-3600), now: now))
    #expect(!pick.applies(to: Self.austin, lastLiveHeardAt: now.addingTimeInterval(-6.5 * 3600), now: now))
    // Kept as one value; the bare id of the app before phase 2 is dropped on read.
    let defaults = try #require(UserDefaults(suiteName: "weather.pick.\(UUID().uuidString)"))
    defaults.set(Int(Self.aus), forKey: WeatherBotPickStore.legacyKey)
    let store = WeatherBotPickStore(defaults: defaults)
    #expect(store.pick == nil)
    #expect(defaults.object(forKey: WeatherBotPickStore.legacyKey) == nil)
    store.pick = pick
    #expect(store.pick == pick)
  }

  /// A bridge: the phone in New Braunfels hears WX-SAT over it and WX-AUS directly. Both cover the
  /// place. The bridge drops; the request to WX-SAT goes unanswered, and WX-AUS is asked instead.
  @Test
  func `when the bridge drops, the unanswered bot gives way to the one still heard`() {
    let now = F.t0
    var states = [
      Self.aus: state(Self.aus, coverage: F.austinCoverage, heardAt: now.addingTimeInterval(-600)),
      Self.sat: state(Self.sat, coverage: Self.sanAntonioCoverage, heardAt: now.addingTimeInterval(-60))
    ]
    let bots = [Self.wxAus, Self.wxSat]
    #expect(snapshot(states: states, bots: bots, place: Self.newBraunfels, now: now).source?.botID == Self.sat,
      "both in range and covering: the one heard last")
    let unanswered = [Self.sat: now]
    let after = snapshot(states: states, bots: bots, place: Self.newBraunfels, unansweredAt: unanswered, now: now)
    #expect(after.source?.botID == Self.aus)
    #expect(WeatherBotChoice.fallback(
      from: Self.sat, states: states, bots: bots, place: Self.newBraunfels, coverage: after.coverage,
      unansweredAt: unanswered, now: now) == Self.aus)
    // Heard again after that, it is in range again.
    states[Self.sat]?.lastLiveHeardAt = now.addingTimeInterval(60)
    #expect(snapshot(
      states: states, bots: bots, place: Self.newBraunfels, unansweredAt: unanswered, now: now.addingTimeInterval(61)
    ).source?.botID == Self.sat)
  }

  /// A spoof: an id nobody announced, chattering every minute, stating no area filter. It is live,
  /// but it covers nothing known, so the real bot covering the place stays everyone's source.
  @Test
  func `a chattering spoof with an empty coverage statement does not become the source`() {
    let now = F.t0
    let states = [
      Self.aus: state(Self.aus, coverage: F.austinCoverage, heardAt: now.addingTimeInterval(-1800)),
      Self.spoof: state(Self.spoof, coverage: Self.everything, heardAt: now.addingTimeInterval(-10))
    ]
    #expect(snapshot(states: states, bots: [Self.wxAus], place: Self.austin, now: now).source?.botID == Self.aus)
    #expect(snapshot(states: states, bots: [Self.wxAus], place: nil, now: now).source?.botID == Self.aus,
      "an advert beats none")
    let coverage = WeatherCoverage.make(states: states, tables: .shared, now: now)
    #expect(coverage.verdict(of: Self.spoof, for: Self.sanAntonio) == .unknown)
  }

  /// Two radios named WX-AUS: nothing on the wire says which is the city's. Neither is chosen, and
  /// the screen says why, until the user picks one.
  @Test
  func `two radios under one name are flagged, and neither is chosen until the user picks`() {
    let now = F.t0
    let impostor = WeatherBot(publicKey: Self.key(0x77, 0x01, 0x99), name: "WX-AUS", latitude: 0, longitude: 0, lastAdvert: nil)
    let conflicts = WeatherBot.conflicts(among: [Self.wxAus, impostor])
    #expect(Set(conflicts.keys) == [0x0177, Self.aus])
    #expect(conflicts[Self.aus]?.label == "WX-AUS")
    let states = [Self.aus: state(Self.aus, coverage: nil, heardAt: now.addingTimeInterval(-60))]
    let flagged = snapshot(states: states, bots: [Self.wxAus, impostor], place: Self.austin, now: now)
    #expect(flagged.source == nil)
    #expect(flagged.banner == .botConflict(label: "WX-AUS"))
    #expect(flagged.requestBlock == .botConflict)
    let pick = WeatherBotPick(botID: Self.aus, publicKey: Self.wxAus.publicKey, pickedAt: now)
    let picked = snapshot(states: states, bots: [Self.wxAus, impostor], place: Self.austin, pick: pick, now: now)
    #expect(picked.source?.botID == Self.aus)
    #expect(picked.source?.bot?.publicKey == Self.wxAus.publicKey)

    // Two whole keys that share the two bytes the wire names a bot by.
    let twin = WeatherBot(publicKey: Self.key(0x1D, 0x04, 0x01), name: "WX-TWIN", latitude: 0, longitude: 0, lastAdvert: nil)
    #expect(WeatherBot.conflicts(among: [Self.wxAus, twin])[Self.aus] == WeatherBot.Conflict(botID: Self.aus, label: "1D04", kind: .id))
  }

  @Test
  func `only a chat advert is a weather radio`() {
    func contact(_ type: UInt8) -> ContactDTO {
      ContactDTO.testContact(publicKey: Self.wxAus.publicKey, name: "WX-AUS", typeRawValue: type)
    }
    #expect(WeatherBot(contact: contact(ContactType.chat.rawValue)) != nil)
    #expect(WeatherBot(contact: contact(ContactType.repeater.rawValue)) == nil, "a repeater")
    #expect(WeatherBot(contact: contact(ContactType.room.rawValue)) == nil, "a room server")
    #expect(WeatherBot(contact: contact(4)) == nil, "a sensor")
  }

  /// The status line counts a gap only from a covering bot heard live in the last three hours, and
  /// names the bot whose gap it is: "missed messages from WX-AUS" while the page asks WX-SAT.
  @Test
  func `the missed-messages line is a live covering bot's, and names that bot`() {
    let now = F.t0
    let nowMinutes = UInt32(now.timeIntervalSince1970 / 60)
    func states(ausHeard: Date) -> [UInt16: WeatherBotState] {
      var aus = state(Self.aus, coverage: F.austinCoverage, heardAt: ausHeard)
      _ = WeatherStateReducer.apply(F.digest(seq: 2, nowMinutes: nowMinutes - 20, entries: [], bot: Self.aus),
        to: &aus, receivedAt: now.addingTimeInterval(-1190))
      aus.lastLiveHeardAt = ausHeard
      aus.needsDigest = true
      var sat = state(Self.sat, coverage: Self.sanAntonioCoverage, heardAt: now.addingTimeInterval(-60))
      _ = WeatherStateReducer.apply(F.digest(seq: 2, nowMinutes: nowMinutes - 20, entries: [], bot: Self.sat),
        to: &sat, receivedAt: now.addingTimeInterval(-1190))
      sat.lastLiveHeardAt = now.addingTimeInterval(-60)
      return [Self.aus: aus, Self.sat: sat]
    }
    let fresh = snapshot(states: states(ausHeard: now.addingTimeInterval(-3600)), bots: [Self.wxAus, Self.wxSat],
      place: Self.newBraunfels, now: now)
    #expect(fresh.source?.botID == Self.sat)
    #expect(fresh.alertStatus == .missedMessages(botID: Self.aus))
    let gone = snapshot(states: states(ausHeard: now.addingTimeInterval(-4 * 3600)), bots: [Self.wxAus, Self.wxSat],
      place: Self.newBraunfels, now: now)
    #expect(gone.alertStatus != .missedMessages(botID: Self.aus), "a gap of a bot unheard for four hours is no news")
  }

  // MARK: - What one id can cost

  @Test
  func `random ids are capped at sixteen states, and never the protected ones`() async {
    let clock = WeatherTestClock()
    let service = WeatherService(
      transport: FakeWeatherTransport(), store: InMemoryWeatherStateStore(), now: { clock.now }, tables: .shared,
      protectedBotIDs: { _, _ in [Self.aus] })
    _ = await service.ingest(F.coverage(seq: 1, bot: Self.aus))
    for index in 0..<40 {
      clock.advance(by: 60)
      _ = await service.ingest(F.observations(seq: 1, stations: [(202, 88)], bot: 0x9000 + UInt16(index)))
    }
    let states = await service.allStates()
    #expect(states.count == WeatherService.maxBotStates)
    #expect(states[Self.aus] != nil, "the protected bot survives, though heard least recently")
    #expect(states[0x9000 + 39] != nil, "the newest stays")
    #expect(states[0x9000] == nil, "the oldest went")
  }

  /// A forged answer under a random id used to fill the "any bot" slot for a forecast point, and
  /// the phone then refused to ask the bot it was using for five minutes.
  @Test
  func `a forged answer from another id never holds off asking the bot in use`() async throws {
    let clock = WeatherTestClock()
    let transport = FakeWeatherTransport()
    let service = service(clock: clock, transport: transport)
    _ = await service.ingest(F.forecast(seq: 1, point: 102, bot: Self.spoof))
    #expect(try await service.send(.forecast(point: 102), to: Self.wxAus) != nil)
    #expect(await transport.channelSent.last?.botID == Self.aus)
  }

  // MARK: - One bot's cancel, another bot's copy

  private actor Poster: WeatherAlertNotificationPoster {
    private(set) var posted: [WeatherAlertNotification] = []
    private(set) var removed: [String] = []
    private var delivered: Set<String> = []
    func post(_ notification: WeatherAlertNotification) async {
      posted.append(notification)
      delivered.insert(notification.identifier)
    }
    func remove(identifiers: [String]) async {
      removed.append(contentsOf: identifiers)
      delivered.subtract(identifiers)
    }
    func deliveredIdentifiers() async -> Set<String> { delivered }
    func isAuthorized() async -> Bool { true }
  }

  private struct Watch: WeatherAlertWatchStore {
    let place: WeatherSavedPlace
    func watch() -> WeatherAlertWatch { WeatherAlertWatch(places: [place]) }
  }

  private final class Ledger: WeatherAlertPostLedger, @unchecked Sendable {
    let box = LockedValue<[String: WeatherAlertPost]>([:])
    func posts() -> [String: WeatherAlertPost] { box.value }
    func save(_ posts: [String: WeatherAlertPost]) { box.value = posts }
  }

  private struct Outlines: WeatherAreaGeometry {
    var isLoaded: Bool { true }
    func distanceKilometres(from point: MeshWXCoordinate, toArea ugc: String) -> Double? { nil }
    func centre(ofArea ugc: String) -> MeshWXCoordinate? { nil }
  }

  /// The scenario of the review: WX-SAT carries Hays County and cancels its Flash Flood Warning;
  /// WX-AUS's feed runs five hours behind and re-broadcasts the warning hours later. The phone
  /// watches San Marcos.
  private func hays(
    satLive: Bool = true, satCoverage: MeshWXCoverage = sanAntonioCoverage
  ) async -> (poster: Poster, items: [WeatherAlertItem], states: [UInt16: WeatherBotState], now: Date) {
    let clock = WeatherTestClock()
    let service = service(clock: clock)
    let poster = Poster()
    let sanMarcos = WeatherSavedPlace(label: "San Marcos, TX", latitude: 29.88, longitude: -97.94, chosenAt: clock.now, isWatched: true)
    let notifier = WeatherAlertNotifier(
      states: { await service.allStates() },
      events: { AsyncStream { $0.finish() } },
      watchStore: Watch(place: sanMarcos),
      ledger: Ledger(),
      poster: poster,
      geometry: Outlines(),
      loadGeometry: {},
      botName: { $0 == Self.aus ? "WX-AUS" : $0 == Self.sat ? "WX-SAT" : nil },
      now: { clock.now })
    func feed(_ message: MeshWXMessage, isBacklog: Bool = false) async {
      let changes = await service.ingest(message, isBacklog: isBacklog)
      await notifier.apply(botID: message.header.bot, changes: changes, isBacklog: isBacklog)
    }
    let issued = UInt32(clock.now.timeIntervalSince1970 / 60) - 30
    func warning(_ bot: UInt16, _ seq: UInt8) -> MeshWXMessage {
      F.warning(seq: seq, identity: Self.ffw, expiresMinutes: issued + 12 * 60, issuedMinutes: issued,
        polygon: Self.haysPolygon, areas: [], bot: bot)
    }
    await feed(F.coverage(seq: 1, satCoverage, bot: Self.sat))
    await feed(F.coverage(seq: 1, bot: Self.aus))
    await feed(warning(Self.sat, 2))
    let first = await poster.posted
    #expect(first.count == 1, "WX-SAT's warning is announced")
    #expect(first.first?.sound == true)
    #expect(first.first?.content.subtitle.contains("WX-SAT 2B11") == true)

    clock.advance(by: 30 * 60)
    if !satLive { clock.advance(by: 3 * 3600) }
    await feed(F.cancel(seq: 3, identity: Self.ffw, bot: Self.sat), isBacklog: !satLive)
    clock.advance(by: 4 * 3600)
    await feed(F.observations(seq: 2, stations: [(202, 88)], bot: Self.aus))
    await feed(warning(Self.aus, 3))
    let states = await service.allStates()
    let items = WeatherAlertItems.make(
      states: states, place: Self.place("San Marcos, TX", 29.88, -97.94), geometry: NoOutlines(), tables: .shared,
      now: clock.now)
    return (poster, items, states, clock.now)
  }

  @Test
  func `WX-SAT's cancel ends WX-AUS's late copy: not active, and no new sound`() async {
    let (poster, items, states, now) = await hays()
    let item = items.first { $0.identity == Self.ffw }
    #expect(item?.kind == .ended(endedAt: now.addingTimeInterval(-4 * 3600), botID: Self.sat))
    #expect(item?.botID == Self.aus)
    #expect(WeatherWarningBanner.make(items) == nil, "the banner shows no cancelled warning")
    #expect(!WeatherCrossBot.isInForce(Self.ffw, in: states, areaCentre: WeatherService.areaCentres(.shared), now: now))
    #expect(await poster.posted.count == 1, "the late copy posts nothing")
    #expect(await poster.removed.count == 1, "the cancel took the notification down")
  }

  /// The cancel counts for the other bot's copy only from a bot in range that carries the ground.
  @Test
  func `a cancel drained from the queue of a bot not heard for hours ends only its own copy`() async {
    let (_, items, _, _) = await hays(satLive: false)
    #expect(items.first { $0.identity == Self.ffw }?.kind == .active)
  }

  @Test
  func `a cancel from a bot that states no area filter ends only its own copy`() async {
    let (_, items, _, _) = await hays(satCoverage: Self.everything)
    #expect(items.first { $0.identity == Self.ffw }?.kind == .active)
  }
}
