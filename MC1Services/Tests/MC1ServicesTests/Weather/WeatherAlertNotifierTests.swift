import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// The alert notification rules (docs/MESHWX_UI.md §16): what reaches the user, what only
/// replaces what is already there, what sounds again, and what is taken away.
///
/// Nothing here touches `UNUserNotificationCenter`: the poster is a recorder, so every rule is a
/// value comparison rather than a screenshot of a lock screen.
@Suite("Weather alert notifier")
struct WeatherAlertNotifierTests {
  private typealias F = WeatherFixture
  private typealias Rules = WeatherAlertNotificationRules

  // MARK: - Fixtures

  /// A square of about 11 km a side around 30.00, -97.00.
  private static let polygon = [
    MeshWXCoordinate(latitude: 30.05, longitude: -97.05),
    MeshWXCoordinate(latitude: 30.05, longitude: -96.95),
    MeshWXCoordinate(latitude: 29.95, longitude: -96.95),
    MeshWXCoordinate(latitude: 29.95, longitude: -97.05)
  ]

  /// Inside the polygon.
  private static func here(watched: Bool = true) -> WeatherSavedPlace {
    WeatherSavedPlace(
      label: "Austin, TX", latitude: 30.0, longitude: -97.0, chosenAt: F.t0, isWatched: watched)
  }

  /// About 34 km west of the polygon's edge: near, never here.
  private static func nearby(watched: Bool = true) -> WeatherSavedPlace {
    WeatherSavedPlace(
      label: "Round Rock, TX", latitude: 30.0, longitude: -97.4, chosenAt: F.t0, isWatched: watched)
  }

  /// Far outside: about 110 km north.
  private static func faraway(watched: Bool = true) -> WeatherSavedPlace {
    WeatherSavedPlace(
      label: "Waco, TX", latitude: 31.0, longitude: -97.0, chosenAt: F.t0, isWatched: watched)
  }

  private static func event(_ vtec: String) -> UInt8 {
    MeshWXTables.shared.eventByCode[vtec] ?? 0
  }

  private static func warning(
    _ vtec: String,
    etn: UInt16 = 42,
    expiresMinutes: UInt32 = F.t0Minutes + 45,
    tornado: MeshWXTornadoTag = .none,
    floodDamage: MeshWXFloodDamage = .none,
    polygon: [MeshWXCoordinate]? = polygon,
    areas: [MeshWXAreaRun]? = nil
  ) -> MeshWXWarning {
    MeshWXWarning(
      identity: MeshWXWarningIdentity(event: event(vtec), office: 35, etn: etn),
      expiresMinutes: expiresMinutes,
      tornado: tornado,
      floodDamage: floodDamage,
      polygon: polygon,
      areas: areas)
  }

  /// A recorder in place of the notification centre: what was posted, in order, and what is still
  /// on the lock screen.
  private actor FakePoster: WeatherAlertNotificationPoster {
    private(set) var posted: [WeatherAlertNotification] = []
    private(set) var removed: [String] = []
    private(set) var delivered: Set<String> = []
    var authorized = true

    func post(_ notification: WeatherAlertNotification) async {
      posted.append(notification)
      delivered.insert(notification.identifier)
    }

    func remove(identifiers: [String]) async {
      removed.append(contentsOf: identifiers)
      delivered.subtract(identifiers)
    }

    func deliveredIdentifiers() async -> Set<String> { delivered }

    func isAuthorized() async -> Bool { authorized }

    func setAuthorized(_ value: Bool) { authorized = value }

    /// The user swiped it away, or opened it.
    func dismiss(_ identifier: String) { delivered.remove(identifier) }

    var last: WeatherAlertNotification? { posted.last }
  }

  private struct StubWatchStore: WeatherAlertWatchStore {
    let box: LockedValue<WeatherAlertWatch>
    func watch() -> WeatherAlertWatch { box.value }
  }

  private struct StubLedger: WeatherAlertPostLedger {
    let box: LockedValue<[String: WeatherAlertPost]>
    func posts() -> [String: WeatherAlertPost] { box.value }
    func save(_ posts: [String: WeatherAlertPost]) { box.value = posts }
  }

  /// Outlines that are not loaded until the test says so.
  private struct StubGeometry: WeatherAreaGeometry {
    let loaded: LockedValue<Bool>
    var isLoaded: Bool { loaded.value }
    func distanceKilometres(from point: MeshWXCoordinate, toArea ugc: String) -> Double? { 0 }
    func centre(ofArea ugc: String) -> MeshWXCoordinate? { nil }
  }

  private struct Harness {
    let notifier: WeatherAlertNotifier
    let poster: FakePoster
    let watch: LockedValue<WeatherAlertWatch>
    let ledger: LockedValue<[String: WeatherAlertPost]>
    let states: LockedValue<[UInt16: WeatherBotState]>
    let clock: WeatherTestClock
    let geometryLoaded: LockedValue<Bool>
  }

  private func makeHarness(
    watch: WeatherAlertWatch,
    geometryLoaded: LockedValue<Bool> = LockedValue(true),
    loadGeometry: @escaping @Sendable () async -> Void = {}
  ) -> Harness {
    let poster = FakePoster()
    let watchBox = LockedValue(watch)
    let ledgerBox = LockedValue<[String: WeatherAlertPost]>([:])
    let states = LockedValue<[UInt16: WeatherBotState]>([:])
    let clock = WeatherTestClock()
    let loaded = geometryLoaded
    let notifier = WeatherAlertNotifier(
      states: { states.value },
      events: { AsyncStream { $0.finish() } },
      watchStore: StubWatchStore(box: watchBox),
      ledger: StubLedger(box: ledgerBox),
      poster: poster,
      geometry: StubGeometry(loaded: loaded),
      loadGeometry: loadGeometry,
      botName: { _ in "WX-AUS" },
      now: { clock.now })
    return Harness(
      notifier: notifier, poster: poster, watch: watchBox, ledger: ledgerBox, states: states,
      clock: clock, geometryLoaded: loaded)
  }

  /// Puts a warning in the bot's state and hands the notifier the change the reducer reported.
  private func deliver(
    _ warning: MeshWXWarning,
    to harness: Harness,
    botID: UInt16 = F.botID,
    isBacklog: Bool = false,
    replacedExisting: Bool = false
  ) async {
    var state = harness.states.value[botID] ?? WeatherBotState(botID: botID)
    let existing = state.warnings[warning.identity]
    state.warnings[warning.identity] = WeatherStoredWarning(
      warning: warning, receivedAt: harness.clock.now, updateCount: existing.map { $0.updateCount + 1 } ?? 0)
    harness.states.value[botID] = state
    await harness.notifier.apply(
      botID: botID,
      changes: [.warningStored(warning.identity, replacedExisting: replacedExisting || existing != nil)],
      isBacklog: isBacklog)
  }

  private func cancel(_ warning: MeshWXWarning, in harness: Harness, botID: UInt16 = F.botID) async {
    harness.states.value[botID]?.warnings.removeValue(forKey: warning.identity)
    await harness.notifier.apply(
      botID: botID, changes: [.warningRemoved(warning.identity, reason: .cancelled)], isBacklog: false)
  }

  // MARK: - The gate

  @Test("storm warnings covering the place notify with sound; watches and advisories never do")
  func gateByRank() {
    let off = WeatherAlertSubscriptions()
    // Ranks 0-5 are the six storm warnings, 6 every other warning, 7-9 watches, advisories and
    // statements (`WeatherAlertPriority.rank`).
    for rank in 0...5 {
      #expect(WeatherAlertGate.delivery(rank: rank, placement: .here, subscriptions: off) == .sound)
    }
    #expect(WeatherAlertGate.delivery(rank: 6, placement: .here, subscriptions: off) == nil)
    for rank in 7...9 {
      #expect(WeatherAlertGate.delivery(rank: rank, placement: .here, subscriptions: off) == nil)
    }
  }

  @Test("the other-warnings toggle adds rank 6, silently, and nothing else")
  func gateOtherWarnings() {
    let on = WeatherAlertSubscriptions(notifiesOtherWarnings: true)
    #expect(WeatherAlertGate.delivery(rank: 6, placement: .here, subscriptions: on) == .silent)
    for rank in 7...9 {
      #expect(WeatherAlertGate.delivery(rank: rank, placement: .here, subscriptions: on) == nil)
    }
    // Only where it covers: a rank-6 warning one county over is still a dashboard row.
    #expect(WeatherAlertGate.delivery(
      rank: 6, placement: .near(kilometres: 20, direction: .north), subscriptions: on) == nil)
  }

  @Test("nearby is the tornado toggle's alone, and only for tornado and extreme wind")
  func gateNearby() {
    let near = WeatherAlertPlacement.near(kilometres: 20, direction: .north)
    let off = WeatherAlertSubscriptions()
    let on = WeatherAlertSubscriptions(notifiesTornadoNearby: true)
    #expect(WeatherAlertGate.delivery(rank: 0, placement: near, subscriptions: off) == nil)
    #expect(WeatherAlertGate.delivery(rank: 0, placement: near, subscriptions: on) == .sound)
    #expect(WeatherAlertGate.delivery(rank: 1, placement: near, subscriptions: on) == .sound)
    for rank in 2...9 {
      #expect(WeatherAlertGate.delivery(rank: rank, placement: near, subscriptions: on) == nil)
    }
  }

  @Test("a place the phone cannot place is never read as here")
  func gateUnplaced() {
    let all = WeatherAlertSubscriptions(notifiesOtherWarnings: true, notifiesTornadoNearby: true)
    for placement in [WeatherAlertPlacement.checking, .unplaced, .elsewhere] {
      for rank in 0...9 {
        #expect(WeatherAlertGate.delivery(rank: rank, placement: placement, subscriptions: all) == nil)
      }
    }
  }

  // MARK: - Opt-in

  @Test("with no bell on, a tornado warning covering a saved place notifies nothing")
  func optInOnly() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [], subscriptions: WeatherAlertSubscriptions()))
    await deliver(Self.warning("TO.W", tornado: .radarIndicated), to: harness)
    #expect(await harness.poster.posted.isEmpty)
    #expect(harness.ledger.value.isEmpty)
  }

  @Test("a saved place that is merely saved is not watched")
  func savingIsNotWatching() async {
    let defaults = UserDefaults(suiteName: "weather.optin.tests.\(UUID().uuidString)")!
    WeatherSavedPlacesStore(defaults: defaults).places = [Self.here(watched: false)]
    let store = DefaultsWeatherAlertWatchStore(defaults: defaults)
    #expect(store.watch().isEmpty)

    let harness = makeHarness(watch: store.watch())
    await deliver(Self.warning("TO.W"), to: harness)
    #expect(await harness.poster.posted.isEmpty)
  }

  // MARK: - Posting

  @Test("a tornado warning covering a watched place is posted with sound, named and timed")
  func postsCoveringWarning() async throws {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await deliver(Self.warning("TO.W", tornado: .radarIndicated), to: harness)

    let posted = try #require(await harness.poster.last)
    #expect(posted.sound)
    #expect(posted.content.title == "Tornado Warning")
    #expect(posted.content.subtitle == "National Weather Service via WX-AUS")
    #expect(posted.content.body.hasPrefix("Austin · until "))
    #expect(posted.content.body.hasSuffix("· radar indicated"))
    #expect(posted.identifier.hasPrefix("wx-4C7A-TO.W.EWX.42@"))
    #expect(posted.threadIdentifier == Rules.threadIdentifier(placeID: Self.here().id))
    #expect(harness.ledger.value.count == 1)
  }

  @Test("a warning that covers one watched place and not another posts once, for that one")
  func postsPerPlace() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here(), Self.faraway()]))
    await deliver(Self.warning("SV.W"), to: harness)
    let posted = await harness.poster.posted
    #expect(posted.count == 1)
    #expect(posted.first?.placeID == Self.here().id)
  }

  @Test("two places under the same warning each get their own notification, threaded apart")
  func postsOnePerWatchedPlace() async {
    let wide = [
      MeshWXCoordinate(latitude: 30.4, longitude: -97.6),
      MeshWXCoordinate(latitude: 30.4, longitude: -96.8),
      MeshWXCoordinate(latitude: 29.8, longitude: -96.8),
      MeshWXCoordinate(latitude: 29.8, longitude: -97.6)
    ]
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here(), Self.nearby()]))
    await deliver(Self.warning("SV.W", polygon: wide), to: harness)
    let posted = await harness.poster.posted
    #expect(posted.count == 2)
    #expect(Set(posted.map(\.threadIdentifier)).count == 2)
  }

  @Test("a rank-6 warning arrives only with its toggle, and without a sound")
  func otherWarningsToggle() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await deliver(Self.warning("FL.W"), to: harness)
    #expect(await harness.poster.posted.isEmpty)

    harness.watch.value = WeatherAlertWatch(
      places: [Self.here()], subscriptions: WeatherAlertSubscriptions(notifiesOtherWarnings: true))
    await deliver(Self.warning("FL.W", etn: 43), to: harness)
    let posted = await harness.poster.posted
    #expect(posted.count == 1)
    #expect(posted.first?.sound == false)
  }

  @Test("a tornado warning nearby arrives only with its toggle, and says how far")
  func tornadoNearbyToggle() async throws {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.nearby()]))
    await deliver(Self.warning("TO.W", tornado: .observed), to: harness)
    #expect(await harness.poster.posted.isEmpty)

    harness.watch.value = WeatherAlertWatch(
      places: [Self.nearby()], subscriptions: WeatherAlertSubscriptions(notifiesTornadoNearby: true))
    await deliver(Self.warning("TO.W", etn: 43, tornado: .observed), to: harness)
    let posted = try #require(await harness.poster.last)
    #expect(posted.sound)
    #expect(posted.content.body.contains("of Round Rock"))
    #expect(posted.content.body.contains("km"))
  }

  @Test("a watch covering the place stays on the dashboard")
  func watchesNeverNotify() async {
    let harness = makeHarness(watch: WeatherAlertWatch(
      places: [Self.here()],
      subscriptions: WeatherAlertSubscriptions(notifiesOtherWarnings: true, notifiesTornadoNearby: true)))
    await deliver(Self.warning("TO.A"), to: harness)
    await deliver(Self.warning("SV.A", etn: 43), to: harness)
    #expect(await harness.poster.posted.isEmpty)
  }

  // MARK: - Repeats, updates and escalations

  @Test("a repeat replaces the notification silently, under the same identifier")
  func repeatIsSilent() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await deliver(Self.warning("SV.W"), to: harness)
    harness.clock.advance(by: 5 * 60)
    await deliver(Self.warning("SV.W"), to: harness, replacedExisting: true)

    let posted = await harness.poster.posted
    #expect(posted.count == 2)
    #expect(posted[0].identifier == posted[1].identifier)
    #expect(posted[0].sound)
    #expect(posted[1].sound == false)
  }

  @Test("a repeat of a notification the user has dismissed is not put back")
  func dismissedStaysDismissed() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await deliver(Self.warning("SV.W"), to: harness)
    let identifier = await harness.poster.posted[0].identifier
    await harness.poster.dismiss(identifier)
    harness.clock.advance(by: 5 * 60)
    await deliver(Self.warning("SV.W"), to: harness, replacedExisting: true)
    #expect(await harness.poster.posted.count == 1)
  }

  @Test("a rising tornado tag sounds again, dismissed or not")
  func tornadoTagEscalates() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await deliver(Self.warning("SV.W", tornado: .possible), to: harness)
    let identifier = await harness.poster.posted[0].identifier
    await harness.poster.dismiss(identifier)
    harness.clock.advance(by: 60)
    await deliver(Self.warning("SV.W", tornado: .radarIndicated), to: harness, replacedExisting: true)

    let posted = await harness.poster.posted
    #expect(posted.count == 2)
    #expect(posted[1].sound)
  }

  @Test("flood damage reaching catastrophic sounds again")
  func catastrophicEscalates() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await deliver(Self.warning("FF.W", floodDamage: .considerable), to: harness)
    harness.clock.advance(by: 60)
    await deliver(Self.warning("FF.W", floodDamage: .catastrophic), to: harness, replacedExisting: true)
    #expect(await harness.poster.posted.last?.sound == true)
  }

  @Test("an extension sounds again only once the last sounding post is 20 minutes old")
  func extensionEscalatesAfterTwentyMinutes() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await deliver(Self.warning("SV.W"), to: harness)

    harness.clock.advance(by: 10 * 60)
    await deliver(
      Self.warning("SV.W", expiresMinutes: F.t0Minutes + 90), to: harness, replacedExisting: true)
    #expect(await harness.poster.posted.last?.sound == false)

    harness.clock.advance(by: 15 * 60)
    await deliver(
      Self.warning("SV.W", expiresMinutes: F.t0Minutes + 150), to: harness, replacedExisting: true)
    #expect(await harness.poster.posted.last?.sound == true)
  }

  @Test("a warning that grows to cover the place sounds, after saying it was nearby")
  func nearBecomingHereEscalates() async {
    let wide = [
      MeshWXCoordinate(latitude: 30.4, longitude: -97.6),
      MeshWXCoordinate(latitude: 30.4, longitude: -96.8),
      MeshWXCoordinate(latitude: 29.8, longitude: -96.8),
      MeshWXCoordinate(latitude: 29.8, longitude: -97.6)
    ]
    let harness = makeHarness(watch: WeatherAlertWatch(
      places: [Self.nearby()], subscriptions: WeatherAlertSubscriptions(notifiesTornadoNearby: true)))
    await deliver(Self.warning("TO.W"), to: harness)
    let identifier = await harness.poster.posted[0].identifier
    await harness.poster.dismiss(identifier)
    harness.clock.advance(by: 60)
    await deliver(Self.warning("TO.W", polygon: wide), to: harness, replacedExisting: true)

    let posted = await harness.poster.posted
    #expect(posted.count == 2)
    #expect(posted[1].sound)
    #expect(posted[1].identifier == identifier)
    #expect(posted[1].content.body.hasPrefix("Round Rock · until "))
  }

  @Test("an update that no longer covers the place takes its notification away")
  func updateThatNoLongerCoversRemoves() async {
    let elsewhere = [
      MeshWXCoordinate(latitude: 31.05, longitude: -97.05),
      MeshWXCoordinate(latitude: 31.05, longitude: -96.95),
      MeshWXCoordinate(latitude: 30.95, longitude: -96.95),
      MeshWXCoordinate(latitude: 30.95, longitude: -97.05)
    ]
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await deliver(Self.warning("SV.W"), to: harness)
    let identifier = await harness.poster.posted[0].identifier
    harness.clock.advance(by: 60)
    await deliver(Self.warning("SV.W", polygon: elsewhere), to: harness, replacedExisting: true)

    #expect(await harness.poster.removed == [identifier])
    #expect(harness.ledger.value.isEmpty)
  }

  // MARK: - Endings

  @Test("a cancellation removes the delivered notification and posts no all-clear")
  func cancellationRemoves() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    let warning = Self.warning("SV.W")
    await deliver(warning, to: harness)
    let identifier = await harness.poster.posted[0].identifier
    await cancel(warning, in: harness)

    #expect(await harness.poster.removed == [identifier])
    #expect(await harness.poster.posted.count == 1)
    #expect(harness.ledger.value.isEmpty)
  }

  @Test("a warning a list drops is removed too")
  func digestRemovalRemoves() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    let warning = Self.warning("SV.W")
    await deliver(warning, to: harness)
    harness.states.value[F.botID]?.warnings.removeValue(forKey: warning.identity)
    await harness.notifier.apply(
      botID: F.botID,
      changes: [.digestApplied(missing: [], removed: [warning.identity])],
      isBacklog: false)
    #expect(await harness.poster.removed.count == 1)
  }

  @Test("a warning only listed in the digest, never received, notifies nothing")
  func digestOnlyNeverNotifies() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await harness.notifier.apply(
      botID: F.botID,
      changes: [.digestApplied(missing: [F.svw42], removed: [])],
      isBacklog: false)
    #expect(await harness.poster.posted.isEmpty)
  }

  @Test("an expired warning is never posted, and nothing is scheduled for an expiry")
  func expiredNeverPosts() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await deliver(Self.warning("TO.W", expiresMinutes: F.t0Minutes - 1), to: harness)
    #expect(await harness.poster.posted.isEmpty)
  }

  // MARK: - Backlog

  @Test("a storm warning drained from the radio's queue says it arrived late")
  func backlogSaysItIsLate() async throws {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await deliver(Self.warning("TO.W", tornado: .radarIndicated), to: harness, isBacklog: true)
    let posted = try #require(await harness.poster.last)
    #expect(posted.sound)
    #expect(posted.content.body.hasSuffix("Received late — sent while your radio was out of range."))
  }

  @Test("a backlog warning that has already expired notifies nothing")
  func expiredBacklogNeverNotifies() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await deliver(Self.warning("TO.W", expiresMinutes: F.t0Minutes - 10), to: harness, isBacklog: true)
    #expect(await harness.poster.posted.isEmpty)
  }

  @Test("a backlog warning below the storm ranks notifies nothing, toggle or not")
  func backlogOnlyStormWarnings() async {
    let harness = makeHarness(watch: WeatherAlertWatch(
      places: [Self.here()], subscriptions: WeatherAlertSubscriptions(notifiesOtherWarnings: true)))
    await deliver(Self.warning("FL.W"), to: harness, isBacklog: true)
    #expect(await harness.poster.posted.isEmpty)
  }

  // MARK: - My location

  @Test("my location is matched against the stored position, however old it is")
  func myLocationUsesStoredPosition() async throws {
    // Three hours old: still the last position the app knows, and the only one it has.
    let position = WeatherLastPosition(
      latitude: 30.0, longitude: -97.0, horizontalAccuracy: 50,
      timestamp: F.t0.addingTimeInterval(-3 * 3600))
    let harness = makeHarness(watch: WeatherAlertWatch(
      places: [], myLocation: position,
      subscriptions: WeatherAlertSubscriptions(watchesMyLocation: true)))
    await deliver(Self.warning("TO.W"), to: harness)

    let posted = try #require(await harness.poster.last)
    #expect(posted.placeID == WeatherWatchedPlace.myLocationID)
    #expect(posted.sound)
  }

  @Test("with my location watched and no position held, nothing is matched against nowhere")
  func myLocationWithoutPosition() async {
    let harness = makeHarness(watch: WeatherAlertWatch(
      places: [], myLocation: nil, subscriptions: WeatherAlertSubscriptions(watchesMyLocation: true)))
    await deliver(Self.warning("TO.W"), to: harness)
    #expect(await harness.poster.posted.isEmpty)
  }

  @Test("an old position is matched with the uncertainty its age has earned")
  func oldPositionWidensTheMatch() {
    let fresh = WeatherPlace.uncertainty(accuracyMetres: 50, age: 60)
    let old = WeatherPlace.uncertainty(accuracyMetres: 50, age: 3 * 3600)
    #expect(fresh < 1)
    #expect(old == 25.5)
  }

  // MARK: - Two bots

  @Test("two bots holding one warning post one notification, not two")
  func oneNotificationPerIdentity() async {
    let otherBot: UInt16 = 0x1234
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    let warning = Self.warning("SV.W")
    await deliver(warning, to: harness)
    harness.clock.advance(by: 60)
    await deliver(warning, to: harness, botID: otherBot)

    let posted = await harness.poster.posted
    #expect(posted.count == 2)
    #expect(Set(posted.map(\.identifier)).count == 1)
    #expect(posted[1].sound == false)
  }

  // MARK: - Outlines

  @Test("a warning with no polygon waits for the outlines rather than being called not here")
  func zoneWarningWaitsForOutlines() async {
    let loaded = LockedValue(false)
    let harness = makeHarness(
      watch: WeatherAlertWatch(places: [Self.here()]),
      geometryLoaded: loaded,
      loadGeometry: { loaded.value = true })
    // The area run is what a zone-coded warning carries; with no outlines it can only be
    // "checking", which notifies nothing until they load.
    let warning = Self.warning(
      "TO.W", polygon: nil, areas: [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1)])
    await deliver(warning, to: harness)
    #expect(await harness.poster.posted.isEmpty)

    // The load runs in its own task; the retry follows it.
    let posted = await weatherWaitUntil { await !harness.poster.posted.isEmpty }
    #expect(posted)
    #expect(loaded.value)
  }

  @Test("an update the phone cannot place yet leaves the notification standing")
  func unplaceableUpdateKeepsTheNotification() async {
    let loaded = LockedValue(true)
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]), geometryLoaded: loaded)
    await deliver(Self.warning("TO.W"), to: harness)
    #expect(await harness.poster.posted.count == 1)

    // The update carries areas instead of a polygon and the outlines have gone away: "checking"
    // is not "not here", so nothing is taken down and nothing is posted again.
    loaded.value = false
    harness.clock.advance(by: 60)
    await deliver(
      Self.warning("TO.W", polygon: nil, areas: [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1)]),
      to: harness, replacedExisting: true)
    #expect(await harness.poster.removed.isEmpty)
    #expect(await harness.poster.posted.count == 1)
  }

  // MARK: - Permission

  @Test("with notifications denied, nothing is posted and nothing is recorded as posted")
  func deniedPostsNothing() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await harness.poster.setAuthorized(false)
    await deliver(Self.warning("TO.W"), to: harness)
    #expect(await harness.poster.posted.isEmpty)
    #expect(harness.ledger.value.isEmpty)
  }

  // MARK: - Persistence

  @Test("what was posted survives a relaunch, so a repeat is still silent")
  func ledgerSurvivesRelaunch() async {
    let harness = makeHarness(watch: WeatherAlertWatch(places: [Self.here()]))
    await deliver(Self.warning("SV.W"), to: harness)
    #expect(harness.ledger.value.count == 1)

    // A second notifier over the same ledger and the same state: the phone was relaunched.
    let poster = FakePoster()
    let identifier = await harness.poster.posted[0].identifier
    await poster.post(await harness.poster.posted[0])
    let states = harness.states
    let reborn = WeatherAlertNotifier(
      states: { states.value },
      events: { AsyncStream { $0.finish() } },
      watchStore: StubWatchStore(box: harness.watch),
      ledger: StubLedger(box: harness.ledger),
      poster: poster,
      geometry: StubGeometry(loaded: harness.geometryLoaded),
      botName: { _ in "WX-AUS" },
      now: { harness.clock.now })
    harness.clock.advance(by: 5 * 60)
    var state = states.value[F.botID]!
    state.warnings[Self.warning("SV.W").identity] = WeatherStoredWarning(
      warning: Self.warning("SV.W"), receivedAt: harness.clock.now, updateCount: 1)
    states.value[F.botID] = state
    await reborn.apply(
      botID: F.botID,
      changes: [.warningStored(Self.warning("SV.W").identity, replacedExisting: true)],
      isBacklog: false)

    let posted = await poster.posted
    #expect(posted.count == 2)
    #expect(posted[1].identifier == identifier)
    #expect(posted[1].sound == false)
  }
}

/// The saved list's own rules for bells (docs/MESHWX_UI.md §5, §16).
@Suite("Weather watched places")
struct WeatherWatchedPlacesTests {
  private func place(_ label: String, at time: TimeInterval, watched: Bool = false) -> WeatherSavedPlace {
    WeatherSavedPlace(
      label: label, latitude: 30 + time / 1000, longitude: -97,
      chosenAt: Date(timeIntervalSince1970: time), isWatched: watched)
  }

  @Test("picking a watched place again keeps its bell")
  func rememberKeepsTheBell() {
    let saved = place("Austin, TX", at: 100, watched: true)
    var again = saved
    again.chosenAt = Date(timeIntervalSince1970: 500)
    again.isWatched = false
    let list = WeatherSavedPlaces.remember(again, in: [saved])
    #expect(list.count == 1)
    #expect(list[0].isWatched)
    #expect(list[0].chosenAt == Date(timeIntervalSince1970: 500))
  }

  @Test("a watched place never falls off the end of the list")
  func watchedPlacesAreKept() {
    let watched = place("Austin, TX", at: 0, watched: true)
    var list = [watched]
    for index in 1...20 {
      list = WeatherSavedPlaces.remember(place("Town \(index)", at: TimeInterval(index)), in: list)
    }
    #expect(list.count == WeatherSavedPlaces.limit)
    #expect(list.contains { $0.id == watched.id })
    #expect(list.first?.label == "Town 20")
  }

  @Test("turning a bell off leaves the place saved")
  func settingWatched() {
    let saved = place("Austin, TX", at: 100, watched: true)
    let off = WeatherSavedPlaces.setting(watched: false, id: saved.id, in: [saved])
    #expect(off.count == 1)
    #expect(off[0].isWatched == false)
  }

  @Test("removing a place removes its watch with it")
  func removingRemovesTheWatch() {
    let saved = place("Austin, TX", at: 100, watched: true)
    #expect(WeatherSavedPlaces.removing(saved.id, from: [saved]).isEmpty)
  }

  @Test("a list saved before bells existed reads as saved places with none on")
  func decodesWithoutTheField() throws {
    let json = """
    [{"label":"Austin, TX","latitude":30.27,"longitude":-97.74,"searchedAs":"town","chosenAt":760000000}]
    """
    let decoded = try JSONDecoder().decode([WeatherSavedPlace].self, from: Data(json.utf8))
    #expect(decoded.count == 1)
    #expect(decoded[0].isWatched == false)
  }

  @Test("the subscriptions a phone has never touched are all off")
  func subscriptionsDefaultOff() throws {
    let decoded = try JSONDecoder().decode(WeatherAlertSubscriptions.self, from: Data("{}".utf8))
    #expect(decoded.watchesMyLocation == false)
    #expect(decoded.notifiesOtherWarnings == false)
    #expect(decoded.notifiesTornadoNearby == false)
  }

  @Test("bells and toggles come back from the defaults they were written to")
  func storeRoundTrip() {
    let defaults = UserDefaults(suiteName: "weather.watch.tests.\(UUID().uuidString)")!
    let places = WeatherSavedPlacesStore(defaults: defaults)
    places.places = [
      place("Austin, TX", at: 100, watched: true),
      place("Waco, TX", at: 50)
    ]
    let store = DefaultsWeatherAlertWatchStore(defaults: defaults)
    store.subscriptions = WeatherAlertSubscriptions(watchesMyLocation: true, notifiesOtherWarnings: true)
    WeatherLastPositionStore(defaults: defaults).position = WeatherLastPosition(
      latitude: 30, longitude: -97, horizontalAccuracy: 20, timestamp: Date(timeIntervalSince1970: 100))

    let watch = store.watch()
    #expect(watch.places.map(\.label) == ["Austin, TX"])
    #expect(watch.subscriptions.notifiesOtherWarnings)
    #expect(watch.myLocation?.latitude == 30)

    // Turning My location off deletes the position with it.
    store.subscriptions = WeatherAlertSubscriptions(notifiesOtherWarnings: true)
    #expect(store.watch().myLocation == nil)
    #expect(WeatherLastPositionStore(defaults: defaults).position == nil)
  }
}
