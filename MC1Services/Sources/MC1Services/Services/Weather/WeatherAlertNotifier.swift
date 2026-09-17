import Foundation
import MeshWX

/// Turns the warnings arriving on `#meshwx` into notifications for the places the user watches
/// (docs/MESHWX_UI.md §16).
///
/// It lives at service lifetime, beside `WeatherService`, and not on the tool's model: warnings
/// are broadcast whether or not the screen exists, the model lives for one visit to the tool, and
/// the whole point is a notification with the tool closed and the app in the background. Nothing
/// here asks the radio for anything — filtering a broadcast costs the mesh no airtime.
///
/// Nothing is watched until a bell is turned on, so the common case is the first two lines of
/// ``apply(botID:changes:isBacklog:)``: no warning in the message, or nothing watched, and the
/// evaluator reads no state at all.
public actor WeatherAlertNotifier {
  private let states: @Sendable () async -> [UInt16: WeatherBotState]
  private let events: @Sendable () -> AsyncStream<WeatherEvent>
  private let watchStore: any WeatherAlertWatchStore
  private let ledger: any WeatherAlertPostLedger
  private let poster: any WeatherAlertNotificationPoster
  private let geometry: any WeatherAreaGeometry
  private let loadGeometry: @Sendable () async -> Void
  private let botName: @Sendable (UInt16) async -> String?
  private let tables: MeshWXTables
  private let now: @Sendable () -> Date

  /// What this phone has posted, by request identifier. Loaded once, written on every change.
  private var posts: [String: WeatherAlertPost] = [:]
  private var isLoaded = false
  private var monitorTask: Task<Void, Never>?
  /// Bot names as they are looked up, so a night of warnings is one contact read.
  private var names: [UInt16: String] = [:]
  /// Identities waiting on the county and zone outlines, and the message they arrived in.
  private var awaitingGeometry: [Pending] = []
  private var isLoadingGeometry = false

  private struct Pending: Sendable, Hashable {
    var identity: MeshWXWarningIdentity
    var botID: UInt16
    var isBacklog: Bool
  }

  /// - Parameters:
  ///   - states: every bot's state, read fresh for each message: the reducer has already applied
  ///     the warning by the time the event arrives.
  ///   - events: the service's event stream, subscribed to by ``start()``.
  ///   - geometry: the bundled county and zone outlines, for a warning with no polygon.
  ///   - loadGeometry: parses them when one needs them and they are not loaded yet.
  ///   - botName: the bot's advertised name, for the source line.
  public init(
    states: @escaping @Sendable () async -> [UInt16: WeatherBotState],
    events: @escaping @Sendable () -> AsyncStream<WeatherEvent>,
    watchStore: any WeatherAlertWatchStore = DefaultsWeatherAlertWatchStore(),
    ledger: any WeatherAlertPostLedger = DefaultsWeatherAlertPostLedger(),
    poster: any WeatherAlertNotificationPoster = UserNotificationWeatherAlertPoster(),
    geometry: any WeatherAreaGeometry = MeshWXGeometry.shared,
    loadGeometry: @escaping @Sendable () async -> Void = { await MeshWXGeometry.shared.preload() },
    botName: @escaping @Sendable (UInt16) async -> String? = { _ in nil },
    tables: MeshWXTables = .shared,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.states = states
    self.events = events
    self.watchStore = watchStore
    self.ledger = ledger
    self.poster = poster
    self.geometry = geometry
    self.loadGeometry = loadGeometry
    self.botName = botName
    self.tables = tables
    self.now = now
  }

  // MARK: - Lifecycle

  /// Subscribes to the weather service's events for this connection.
  public func start() {
    monitorTask?.cancel()
    let stream = events()
    monitorTask = Task { [weak self] in
      for await event in stream {
        guard !Task.isCancelled, let self else { break }
        await self.handle(event)
      }
    }
  }

  public func stop() {
    monitorTask?.cancel()
    monitorTask = nil
  }

  // MARK: - Ingest

  func handle(_ event: WeatherEvent) async {
    guard case let .received(botID, _, changes, isBacklog) = event else { return }
    await apply(botID: botID, changes: changes, isBacklog: isBacklog)
  }

  /// Applies one message's changes: what it ended, and what it said.
  func apply(botID: UInt16, changes: [WeatherStateChange], isBacklog: Bool) async {
    var stored: [MeshWXWarningIdentity] = []
    var ended: [MeshWXWarningIdentity] = []
    var listArrived = false
    for change in changes {
      switch change {
      case let .warningStored(identity, _):
        stored.append(identity)
      case let .warningRemoved(identity, _):
        ended.append(identity)
      case let .digestApplied(_, removed):
        // A warning the list no longer carries has ended; one it never named was never received
        // and has no geometry, so it stays the dashboard's row and notifies nothing.
        ended.append(contentsOf: removed)
        listArrived = true
      default:
        break
      }
    }
    guard !stored.isEmpty || !ended.isEmpty || listArrived else { return }
    loadIfNeeded()
    if !ended.isEmpty { await withdraw(ended) }

    let watch = watchStore.watch()
    guard !watch.isEmpty else { return }
    // A list extends expiries, and the notification is the thing saying "until": re-read what has
    // already been posted. It announces nothing new — a warning is announced by its own message.
    var identities = Set(stored)
    if listArrived { identities.formUnion(posts.values.map(\.identity)) }
    guard !identities.isEmpty else { return }
    guard await poster.isAuthorized() else { return }

    let now = now()
    let places = watchedPlaces(watch, now: now)
    guard !places.isEmpty else { return }
    let states = await states()
    let delivered = await poster.deliveredIdentifiers()
    var changed = false
    for identity in identities.sorted(by: WeatherStateReducer.identityOrder) {
      changed = await evaluate(
        identity, preferredBotID: botID, states: states, places: places,
        subscriptions: watch.subscriptions, isBacklog: isBacklog, delivered: delivered, now: now) || changed
    }
    if changed { persist() }
  }

  /// One warning against every watched place. Returns whether anything was posted or removed.
  @discardableResult
  private func evaluate(
    _ identity: MeshWXWarningIdentity,
    preferredBotID: UInt16,
    states: [UInt16: WeatherBotState],
    places: [WeatherWatchedPlace],
    subscriptions: WeatherAlertSubscriptions,
    isBacklog: Bool,
    delivered: Set<String>,
    now: Date
  ) async -> Bool {
    guard let held = held(identity, preferredBotID: preferredBotID, in: states) else { return false }
    let warning = held.stored.warning
    let rank = WeatherAlertPriority.rank(warning, tables: tables)
    var changed = false
    var needsOutlines = false

    for place in places {
      let placement = WeatherAlertPlacement.place(warning, at: place.place, geometry: geometry, tables: tables)
      if placement == .checking { needsOutlines = true }
      let posted = posts.values.first { $0.identity == identity && $0.placeID == place.id }
      let identifier = posted?.identifier ?? WeatherAlertNotificationRules.identifier(
        botID: held.botID, identity: identity, placeID: place.id, tables: tables)
      let coversPlace = placement == .here
      let decision = WeatherAlertNotificationRules.decide(
        warning: warning,
        rank: rank,
        placement: placement,
        delivery: WeatherAlertGate.delivery(rank: rank, placement: placement, subscriptions: subscriptions),
        isBacklog: isBacklog,
        posted: posted,
        isDelivered: delivered.contains(identifier),
        now: now)

      switch decision {
      case .none:
        continue
      case .remove:
        await poster.remove(identifiers: [identifier])
        posts.removeValue(forKey: identifier)
        changed = true
      case let .post(sound, isLate):
        let subject = WeatherAlertNotificationSubject(
          warning: warning,
          placeLabel: place.place.label,
          placement: placement,
          botName: await name(of: held.botID),
          isLate: isLate,
          now: now)
        await poster.post(WeatherAlertNotification(
          identifier: identifier,
          threadIdentifier: WeatherAlertNotificationRules.threadIdentifier(placeID: place.id),
          content: WeatherAlertNotificationCopyRegistry.current.content(for: subject, tables: tables),
          sound: sound,
          identity: identity,
          botID: posted?.botID ?? held.botID,
          placeID: place.id))
        posts[identifier] = WeatherAlertNotificationRules.record(
          identifier: identifier,
          warning: warning,
          placeID: place.id,
          botID: posted?.botID ?? held.botID,
          coversPlace: coversPlace,
          sound: sound,
          posted: posted,
          now: now)
        changed = true
      }
    }

    if needsOutlines {
      waitForOutlines(Pending(identity: identity, botID: preferredBotID, isBacklog: isBacklog))
    }
    return changed
  }

  /// Takes down what these warnings had posted. A cancellation removes the notification; nothing
  /// takes its place, because "the warning ended" and "the weather is fine" are not the same
  /// sentence and this phone can only know the first.
  private func withdraw(_ identities: [MeshWXWarningIdentity]) async {
    let ended = Set(identities)
    let identifiers = posts.values.filter { ended.contains($0.identity) }.map(\.identifier)
    guard !identifiers.isEmpty else { return }
    await poster.remove(identifiers: identifiers)
    for identifier in identifiers { posts.removeValue(forKey: identifier) }
    persist()
  }

  /// The copy of a warning to judge: the bot the message came from, else whichever bot holds one.
  /// Bots are read in a fixed order so two holding the same identity give the same answer twice.
  private func held(
    _ identity: MeshWXWarningIdentity,
    preferredBotID: UInt16,
    in states: [UInt16: WeatherBotState]
  ) -> (botID: UInt16, stored: WeatherStoredWarning)? {
    if let stored = states[preferredBotID]?.warnings[identity] { return (preferredBotID, stored) }
    for botID in states.keys.sorted() {
      if let stored = states[botID]?.warnings[identity] { return (botID, stored) }
    }
    return nil
  }

  // MARK: - Places

  /// The watched places, resolved for this moment: the saved ones as they were chosen, and the
  /// phone's own position with the uncertainty its age has earned (`WeatherPlace.location`), so a
  /// fix from three hours ago is matched generously rather than pretended to be current.
  private func watchedPlaces(_ watch: WeatherAlertWatch, now: Date) -> [WeatherWatchedPlace] {
    var places = watch.places.map(WeatherWatchedPlace.init(saved:))
    if let position = watch.myLocation {
      let label = WeatherNames.placeLabel(near: position.sample.coordinate, tables: tables)
        ?? WeatherAlertNotificationCopyRegistry.current.myLocationLabel
      places.append(WeatherWatchedPlace.myLocation(position, label: label, now: now))
    }
    return places
  }

  // MARK: - Outlines

  /// A warning with no polygon is placed by its counties and zones, which are 15 MB of GeoJSON
  /// loaded on demand. When they are not loaded yet the placement is "checking", which notifies
  /// nothing, so the warning is parked and judged again once they are — once, and never in a
  /// loop: with the outlines loaded no placement can come back as checking.
  private func waitForOutlines(_ pending: Pending) {
    guard !awaitingGeometry.contains(pending) else { return }
    awaitingGeometry.append(pending)
    guard !isLoadingGeometry else { return }
    isLoadingGeometry = true
    Task { [weak self] in
      await self?.loadOutlinesAndRetry()
    }
  }

  private func loadOutlinesAndRetry() async {
    await loadGeometry()
    isLoadingGeometry = false
    let pending = awaitingGeometry
    awaitingGeometry = []
    guard geometry.isLoaded, !pending.isEmpty else { return }
    let watch = watchStore.watch()
    guard !watch.isEmpty, await poster.isAuthorized() else { return }
    let now = now()
    let places = watchedPlaces(watch, now: now)
    guard !places.isEmpty else { return }
    let states = await states()
    let delivered = await poster.deliveredIdentifiers()
    var changed = false
    for item in pending {
      changed = await evaluate(
        item.identity, preferredBotID: item.botID, states: states, places: places,
        subscriptions: watch.subscriptions, isBacklog: item.isBacklog, delivered: delivered, now: now) || changed
    }
    if changed { persist() }
  }

  // MARK: - Names

  private func name(of botID: UInt16) async -> String? {
    if let name = names[botID] { return name }
    guard let name = await botName(botID) else { return nil }
    names[botID] = name
    return name
  }

  // MARK: - Ledger

  private func loadIfNeeded() {
    guard !isLoaded else { return }
    isLoaded = true
    posts = WeatherAlertNotificationRules.pruned(ledger.posts(), now: now())
  }

  private func persist() {
    posts = WeatherAlertNotificationRules.pruned(posts, now: now())
    ledger.save(posts)
  }
}
