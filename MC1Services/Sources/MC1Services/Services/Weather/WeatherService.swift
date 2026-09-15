import Foundation
import MeshCore
import MeshWX

// MARK: - Transport

/// What the weather service needs from a radio: channel datagrams coming in, a DM going out,
/// and a way to tell which slot is `#meshwx`. Narrow on purpose so tests can drive the service
/// with a fake and so the requests provably never touch `MessageService` (docs/MESHWX.md).
public protocol WeatherTransport: Sendable {
  /// A stream of `.channelDataReceived` events. Every other event kind is ignored.
  func datagramEvents() async -> AsyncStream<MeshEvent>
  /// Sends a plain-text DM to a public key.
  func sendRequest(to publicKey: Data, text: String) async throws
  /// The 16-byte secret of a channel slot, or nil when it cannot be read.
  func channelSecret(at index: UInt8) async -> Data?
  /// Whether the radio's message queue — what it held while the phone was away — is being
  /// drained right now, at connect or on resync. A datagram delivered meanwhile is backlog: it
  /// can be hours old, and it says nothing about whether the bot is in range now.
  func isDrainingBacklog() async -> Bool
}

/// The production transport over a `MeshCoreSession`.
public struct SessionWeatherTransport: WeatherTransport {
  private let session: any MeshCoreSessionProtocol
  private let storedChannelSecret: @Sendable (UInt8) async -> Data?
  private let drainingBacklog: @Sendable () async -> Bool

  /// - Parameters:
  ///   - storedChannelSecret: the app's own channel table, consulted when the radio
  ///     cannot be asked.
  ///   - isDrainingBacklog: whether the firmware queue is being drained; the container wires it
  ///     to the message poller. The default says never, so everything reads as live.
  public init(
    session: any MeshCoreSessionProtocol,
    storedChannelSecret: @escaping @Sendable (UInt8) async -> Data? = { _ in nil },
    isDrainingBacklog: @escaping @Sendable () async -> Bool = { false }
  ) {
    self.session = session
    self.storedChannelSecret = storedChannelSecret
    drainingBacklog = isDrainingBacklog
  }

  public func datagramEvents() async -> AsyncStream<MeshEvent> {
    await session.events(filter: .anyChannelDatagram)
  }

  public func sendRequest(to publicKey: Data, text: String) async throws {
    _ = try await session.sendMessage(to: publicKey, text: text, timestamp: Date(), attempt: 0)
  }

  /// The app's table first — no radio round trip while the firmware queue is draining — then
  /// the radio on a miss: weather monitoring starts before the connect-time channel sync, so
  /// a fresh table can lack a slot the radio has.
  public func channelSecret(at index: UInt8) async -> Data? {
    if let stored = await storedChannelSecret(index), stored == WeatherChannel.secret { return stored }
    if let info = try? await session.getChannel(index: index) { return info.secret }
    return await storedChannelSecret(index)
  }

  public func isDrainingBacklog() async -> Bool {
    await drainingBacklog()
  }
}

// MARK: - Service

/// Listens to the MeshWX weather bots on `#meshwx`, keeps one `WeatherBotState` per bot, and
/// sends the app's `>` requests with the spec's etiquette (docs/MESHWX.md, spec §13).
///
/// Per connection, like every service in the container — the datagram stream belongs to the
/// session — but the *state* is not: it is loaded from and saved to a store shared across
/// connections, because a warning belongs to a place, not to the radio that heard it.
public actor WeatherService {
  /// Spec §8.2 / §13: one request per sender every five seconds.
  public static let requestSpacing: TimeInterval = 5
  /// Spec §8.2: wait up to 15 s before retrying, once.
  public static let answerTimeout: Duration = .seconds(15)
  /// Spec §13: do not re-request something received in the last five minutes.
  public static let cacheWindow: TimeInterval = 5 * 60
  /// Retention for finished text replies and forecasts per bot, newest kept.
  static let maxTextsPerBot = 24
  static let maxForecastsPerBot = 24
  /// Expired warnings linger this long before pruning, so a screen can still say what just
  /// ended.
  static let expiredWarningRetention: TimeInterval = 60 * 60
  /// Upgrade markers older than this are forgotten.
  static let pendingUpgradeRetention: TimeInterval = 6 * 60 * 60

  private let transport: any WeatherTransport
  private let store: any WeatherStateStore
  private let now: @Sendable () -> Date
  private let answerTimeout: Duration
  private let stationIndex: @Sendable (String) -> UInt16?
  private let tables: MeshWXTables
  private let logger = PersistentLogger(subsystem: "com.mc1", category: "WeatherService")

  private nonisolated let eventBroadcaster = EventBroadcaster<WeatherEvent>()

  private var states: [UInt16: WeatherBotState] = [:]
  private var isLoaded = false
  private var stampTask: Task<Void, Never>?
  private var monitorTask: Task<Void, Never>?

  private var session = WeatherSessionInfo()
  /// Per session: slots proven to be `#meshwx`, by secret.
  private var weatherSlots: Set<UInt8> = []
  /// Slots proven *not* to be `#meshwx`, and when. Rechecked after a minute rather than
  /// remembered for the session: the channel prompt writes `#meshwx` into a slot, and a
  /// session-long "no" for that slot would drop every weather packet that followed.
  private var foreignSlotsCheckedAt: [UInt8: Date] = [:]
  static let foreignSlotRecheck: TimeInterval = 60

  private struct PendingEntry {
    var request: WeatherPendingRequest
    var timer: Task<Void, Never>?
  }

  private var pending: [UUID: PendingEntry] = [:]
  private var lastSendAt: Date?

  /// An answer anyone on the channel has already received, for the five-minute rule. Filled
  /// on ingest — not when this phone's own request settles — so twenty phones tapping after a
  /// siren send one request between them, not twenty.
  ///
  /// Only from a message the reducer applied and that was heard live. A duplicate, a list older
  /// than the one held, an out-of-order warning the reducer set aside, or anything drained from
  /// the radio's queue at connect is not something the bot would re-send from its cache now.
  enum AnswerKey: Hashable {
    case digest
    case coverageObservations
    case station(UInt16)
    case forecast(UInt16)
    /// `>w`: any warning or alert list from the bot.
    case activeWarnings
    /// `>w <county or zone>`: the same.
    case warningsTouching
    /// `>w <identity>`: that warning, from any bot.
    case warning(MeshWXWarningIdentity)
    /// A text request, by subject and argument: only a complete reply this phone owns.
    case text(WeatherRequest)
  }

  struct AnswerSlot: Hashable {
    /// Nil for answers that are the same whichever bot sends them.
    let botID: UInt16?
    let key: AnswerKey
  }

  struct AnswerRecord: Hashable {
    /// Phone clock: the bot's cache runs five minutes from its answer, which receipt stands for.
    var receivedAt: Date
    /// The answer's own time on the bot's clock, where the message carries one.
    var contentAsOf: Date?
  }

  private var lastAnswers: [AnswerSlot: AnswerRecord] = [:]

  /// - Parameters:
  ///   - transport: The radio.
  ///   - store: Where state persists.
  ///   - now: The clock, injectable for tests.
  ///   - answerTimeout: How long to wait for an answer before the retry; tests shorten it.
  ///   - stationIndex: ICAO → wire station index, for matching a one-station answer to
  ///     its request. Defaults to the bundled tables.
  ///   - tables: For reading warning identities and text replies against requests.
  public init(
    transport: any WeatherTransport,
    store: any WeatherStateStore,
    now: @escaping @Sendable () -> Date = { Date() },
    answerTimeout: Duration = WeatherService.answerTimeout,
    stationIndex: @escaping @Sendable (String) -> UInt16? = { MeshWXTables.shared.stationIndex(forICAO: $0) },
    tables: MeshWXTables = .shared
  ) {
    self.transport = transport
    self.store = store
    self.now = now
    self.answerTimeout = answerTimeout
    self.stationIndex = stationIndex
    self.tables = tables
  }

  // MARK: Events

  /// A fresh stream of events. Registration is synchronous, so nothing yielded after this
  /// call is dropped. Re-subscribe per connection: the container is rebuilt.
  public nonisolated func events() -> AsyncStream<WeatherEvent> {
    eventBroadcaster.subscribe()
  }

  /// Ends every subscriber's loop; called from `ServiceContainer.tearDown()`.
  nonisolated func finishEvents() {
    eventBroadcaster.finish()
  }

  // MARK: Lifecycle

  private struct StampedDatagram: Sendable {
    let datagram: ChannelDatagram
    let isBacklog: Bool
  }

  /// Subscribes to channel datagrams. Called before the message polling service drains the
  /// firmware queue, so datagrams queued while the phone was away are seen too — and marked as
  /// backlog.
  public func startEventMonitoring() async {
    await loadIfNeeded()
    stampTask?.cancel()
    monitorTask?.cancel()
    session = WeatherSessionInfo(startedAt: now())
    weatherSlots = []
    foreignSlotsCheckedAt = [:]
    let stream = await transport.datagramEvents()
    // Each datagram is marked live or backlog as it arrives, not when ingest reaches it: ingest
    // can wait on a radio round trip for the slot check, and by then the drain may be over and
    // a queued datagram would read as live. The mark costs one hop to the poller; the drain's
    // next fetch after the last queued datagram is a radio round trip, which it beats.
    let (stamped, continuation) = AsyncStream.makeStream(of: StampedDatagram.self)
    stampTask = Task { [transport] in
      for await event in stream {
        guard !Task.isCancelled else { break }
        if case let .channelDataReceived(datagram) = event {
          continuation.yield(StampedDatagram(datagram: datagram, isBacklog: await transport.isDrainingBacklog()))
        }
      }
      continuation.finish()
    }
    monitorTask = Task { [weak self] in
      for await item in stamped {
        guard !Task.isCancelled, let self else { break }
        await self.ingest(item.datagram, isBacklog: item.isBacklog)
      }
    }
  }

  public func stopEventMonitoring() {
    stampTask?.cancel()
    stampTask = nil
    monitorTask?.cancel()
    monitorTask = nil
    session.startedAt = nil
    for id in pending.keys {
      settle(id: id, outcome: .failed("disconnected"))
    }
  }

  /// Loads persisted state once. Safe to call repeatedly.
  public func loadIfNeeded() async {
    guard !isLoaded else { return }
    isLoaded = true
    do {
      states = try await store.load()
      let now = now()
      for botID in states.keys {
        WeatherStateReducer.pruneExpired(&states[botID]!, expiredBefore: now.addingTimeInterval(-Self.expiredWarningRetention))
        WeatherStateReducer.prunePendingUpgrades(&states[botID]!, olderThan: now.addingTimeInterval(-Self.pendingUpgradeRetention))
      }
    } catch {
      logger.error("Weather state load failed: \(error.localizedDescription)")
      states = [:]
    }
    eventBroadcaster.yield(.stateLoaded)
  }

  // MARK: State

  public func allStates() async -> [UInt16: WeatherBotState] {
    await loadIfNeeded()
    return states
  }

  public func state(for botID: UInt16) async -> WeatherBotState? {
    await loadIfNeeded()
    return states[botID]
  }

  public func pendingRequests() -> [WeatherPendingRequest] {
    pending.values.map(\.request).sorted { $0.sentAt < $1.sentAt }
  }

  public func sessionInfo() -> WeatherSessionInfo {
    session
  }

  /// Forgets everything held for one bot, with every answer it gave and every answer any bot
  /// gave: a forecast or warning slot filled by another bot would otherwise still answer for
  /// data the user just cleared.
  public func clearState(for botID: UInt16) async {
    await loadIfNeeded()
    states.removeValue(forKey: botID)
    lastAnswers = lastAnswers.filter { slot, _ in slot.botID != nil && slot.botID != botID }
    await persist()
  }

  // MARK: Ingest

  /// Decodes and applies one datagram. Anything that is not a v5 message on the `#meshwx` slot
  /// is ignored (spec §2.1: "ignore any `data_type` other than 0xFF10"; `0xFF10` is in the
  /// development range, so another application may use it on another channel).
  ///
  /// - Parameter isBacklog: the datagram was drained from the radio's queue (see
  ///   `ingest(_:isBacklog:)` for the message).
  @discardableResult
  public func ingest(_ datagram: ChannelDatagram, isBacklog: Bool = false) async -> [WeatherStateChange]? {
    guard datagram.dataType == MeshWXWire.dataType else { return nil }
    guard await isWeatherSlot(datagram.channelIndex) else {
      session.foreignDatagramsIgnored += 1
      logger.warning("Ignored a MeshWX-typed datagram on channel slot \(datagram.channelIndex), which is not #meshwx")
      return nil
    }
    let message: MeshWXMessage
    do {
      message = try MeshWXDecoder.decode(datagram.data)
    } catch {
      logger.warning("Undecodable MeshWX datagram (\(datagram.data.count) bytes): \(error)")
      return nil
    }
    session.lastChannelDatagramAt = now()
    return await ingest(message, isBacklog: isBacklog)
  }

  private func isWeatherSlot(_ index: UInt8) async -> Bool {
    if weatherSlots.contains(index) { return true }
    if let checkedAt = foreignSlotsCheckedAt[index], now().timeIntervalSince(checkedAt) < Self.foreignSlotRecheck {
      return false
    }
    guard let secret = await transport.channelSecret(at: index) else {
      // Unreadable: accept, and ask again next time. Dropping a tornado warning because a
      // channel read timed out is the worse error of the two.
      return true
    }
    if secret == WeatherChannel.secret {
      weatherSlots.insert(index)
      foreignSlotsCheckedAt.removeValue(forKey: index)
      return true
    }
    foreignSlotsCheckedAt[index] = now()
    return false
  }

  /// Applies an already-decoded message: the reducer, then request settlement, then
  /// persistence. Public so tests and previews can feed traffic without a radio.
  ///
  /// - Parameter isBacklog: the message was drained from the radio's queue rather than heard
  ///   live. It changes state like any other — a warning is a warning — but proves nothing about
  ///   now: it answers nothing for the five-minute rule and does not count as hearing the bot.
  @discardableResult
  public func ingest(_ message: MeshWXMessage, isBacklog: Bool = false) async -> [WeatherStateChange] {
    await loadIfNeeded()
    let botID = message.header.bot
    let receivedAt = now()
    var state = states[botID] ?? WeatherBotState(botID: botID)
    let changes = WeatherStateReducer.apply(message, to: &state, receivedAt: receivedAt)

    let isDuplicate = changes.contains { change in
      if case .duplicate = change { return true }
      return false
    }
    if !isDuplicate, !isBacklog {
      state.lastLiveHeardAt = max(state.lastLiveHeardAt ?? receivedAt, receivedAt)
    }
    states[botID] = state
    if isDuplicate {
      // A duplicate changes nothing and settles nothing.
      eventBroadcaster.yield(.received(botID: botID, message: message, changes: changes))
      return changes
    }

    settlePending(with: message, from: botID)
    if !isBacklog {
      recordAnswer(message.payload, changes: changes, from: botID, at: receivedAt)
    }
    eventBroadcaster.yield(.received(botID: botID, message: message, changes: changes))
    await persist()
    return changes
  }

  /// Fills the answer slots a live message fills — keyed off the reducer's changes, so only what
  /// it applied counts. Runs after settlement: a text reply becomes an answer only once this
  /// phone owns it.
  private func recordAnswer(
    _ payload: MeshWXPayload,
    changes: [WeatherStateChange],
    from botID: UInt16,
    at receivedAt: Date
  ) {
    func fill(_ slotBotID: UInt16?, _ key: AnswerKey, asOf contentAsOf: Date? = nil) {
      lastAnswers[AnswerSlot(botID: slotBotID, key: key)] = AnswerRecord(receivedAt: receivedAt, contentAsOf: contentAsOf)
    }
    for change in changes {
      switch (change, payload) {
      case let (.digestApplied, .digest(digest)):
        let builtAt = Date(unixMinutes: digest.nowMinutes)
        fill(botID, .digest, asOf: builtAt)
        fill(botID, .activeWarnings, asOf: builtAt)
        fill(botID, .warningsTouching, asOf: builtAt)
      case let (.warningStored(identity, _), .warning):
        fill(botID, .activeWarnings)
        fill(botID, .warningsTouching)
        fill(nil, .warning(identity))
      case let (.observationsStored(stored), .observations(batch)) where !stored.isEmpty:
        let observedAt = Date(unixMinutes: batch.timestampMinutes)
        if batch.stations.count > 1 { fill(botID, .coverageObservations, asOf: observedAt) }
        for station in stored { fill(nil, .station(station), asOf: observedAt) }
      case let (.forecastStored(point), .forecast(forecast)) where !forecast.isUnbundledPoint:
        fill(nil, .forecast(point), asOf: Date(unixMinutes: forecast.issuedMinutes))
      case let (.textChunkStored(group, _, _), .text):
        // Complete, so a reply still missing a part can be asked for again (spec §8.1).
        if let assembly = states[botID]?.texts[group], assembly.isComplete, let request = assembly.request {
          fill(botID, .text(request))
        }
      default:
        break
      }
    }
  }

  // MARK: Requests

  /// Sends a request to a bot, or answers it from what the channel already delivered.
  ///
  /// - Returns: The pending request now on the air, or nil when the answer was already
  ///   received in the last five minutes (a `requestSettled(_, .servedFromCache)` event is
  ///   emitted).
  /// - Throws: `WeatherRequestError.rateLimited` inside the five-second spacing;
  ///   `.transport` when the radio refuses the DM.
  @discardableResult
  public func send(_ request: WeatherRequest, to bot: WeatherBot) async throws -> WeatherPendingRequest? {
    await loadIfNeeded()
    let sentAt = now()

    if let slot = answerSlot(for: request, botID: bot.botID),
       let answer = lastAnswers[slot],
       sentAt.timeIntervalSince(answer.receivedAt) < Self.cacheWindow,
       !answerLeftSomethingOutstanding(request, botID: bot.botID) {
      let served = WeatherPendingRequest(
        request: request, botID: bot.botID, botPublicKey: bot.publicKey, sentAt: sentAt
      )
      eventBroadcaster.yield(.requestSettled(
        served, .servedFromCache(receivedAt: answer.receivedAt, contentAsOf: answer.contentAsOf)))
      return nil
    }

    if let lastSendAt {
      let elapsed = sentAt.timeIntervalSince(lastSendAt)
      if elapsed < Self.requestSpacing {
        throw WeatherRequestError.rateLimited(retryAfter: Self.requestSpacing - elapsed)
      }
    }

    let entry = WeatherPendingRequest(
      request: request, botID: bot.botID, botPublicKey: bot.publicKey, sentAt: sentAt
    )
    // Claim the slot before the await so a second caller inside the window is refused even
    // while this DM is still going out.
    lastSendAt = sentAt
    do {
      try await transport.sendRequest(to: bot.publicKey, text: request.wireText)
    } catch {
      throw WeatherRequestError.transport(error.localizedDescription)
    }
    pending[entry.id] = PendingEntry(request: entry, timer: nil)
    armTimer(for: entry.id)
    eventBroadcaster.yield(.requestSent(entry))
    return entry
  }

  private func answerSlot(for request: WeatherRequest, botID: UInt16) -> AnswerSlot? {
    switch request {
    case .digest: AnswerSlot(botID: botID, key: .digest)
    case .observations: AnswerSlot(botID: botID, key: .coverageObservations)
    case let .observation(station): stationIndex(station).map { AnswerSlot(botID: nil, key: .station($0)) }
    case let .forecast(point): AnswerSlot(botID: nil, key: .forecast(point))
    case .activeWarnings: AnswerSlot(botID: botID, key: .activeWarnings)
    case .warningsTouching: AnswerSlot(botID: botID, key: .warningsTouching)
    case let .warning(identity):
      WeatherAlertRequests.identity(from: identity, tables: tables).map { AnswerSlot(botID: nil, key: .warning($0)) }
    case .warningText, .forecastDiscussion, .spaceWeather, .stormReports, .rainfall, .metar, .taf, .hazardousOutlook:
      AnswerSlot(botID: botID, key: .text(request))
    case .homeForecast, .forecastForPlace: nil
    }
  }

  /// A `>w` or `>w <area>` is how a missing identity or an upgrade whose replacement never came
  /// is repaired. While either is still outstanding, whatever arrived in the last five minutes
  /// evidently did not carry it — lost on the way, or never part of it — and the bot's cached
  /// re-send is the recovery, not waste.
  private func answerLeftSomethingOutstanding(_ request: WeatherRequest, botID: UInt16) -> Bool {
    switch request {
    case .activeWarnings, .warningsTouching:
      guard let state = states[botID] else { return false }
      return !state.missingFromDigest.isEmpty || !state.pendingUpgrades.isEmpty
    default:
      return false
    }
  }

  private func armTimer(for id: UUID) {
    pending[id]?.timer?.cancel()
    let timeout = answerTimeout
    pending[id]?.timer = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      await self?.handleTimeout(id: id)
    }
  }

  private func handleTimeout(id: UUID) async {
    guard var entry = pending[id] else { return }
    let botWasHeard = wasHeardLive(botID: entry.request.botID, since: entry.request.sentAt)
    // Retry only into silence: a bot heard since the request is in range, so a repeat would
    // only add to whatever is keeping the channel busy.
    guard entry.request.attempt == 0, !botWasHeard else {
      settle(id: id, outcome: .timedOut(botWasHeard: botWasHeard))
      return
    }
    entry.request.attempt = 1
    entry.request.sentAt = now()
    pending[id] = entry
    do {
      lastSendAt = entry.request.sentAt
      try await transport.sendRequest(to: entry.request.botPublicKey, text: entry.request.request.wireText)
    } catch {
      settle(id: id, outcome: .failed(error.localizedDescription))
      return
    }
    guard pending[id] != nil else { return } // answered while the retry was going out
    eventBroadcaster.yield(.requestSent(entry.request))
    armTimer(for: id)
  }

  /// Live only: a backlog drained from the radio's queue after the request went out is stamped
  /// with the drain time, and says nothing about whether the bot can hear this phone now.
  private func wasHeardLive(botID: UInt16, since date: Date) -> Bool {
    guard let heard = states[botID]?.lastLiveHeardAt else { return false }
    return heard > date
  }

  private func settle(id: UUID, outcome: WeatherRequestOutcome) {
    guard let entry = pending.removeValue(forKey: id) else { return }
    entry.timer?.cancel()
    eventBroadcaster.yield(.requestSettled(entry.request, outcome))
  }

  /// Pairs an incoming message with the requests waiting on it.
  private func settlePending(with message: MeshWXMessage, from botID: UInt16) {
    let waiting = pending.values
      .map(\.request)
      .filter { $0.botID == botID || $0.request.acceptsAnswerFromAnyBot }
      .sorted { $0.sentAt < $1.sentAt }
    guard !waiting.isEmpty else { return }

    if case let .notAvailable(notAvailable) = message.payload {
      // One refusal answers the oldest request with that letter — and only a request to the
      // bot that refused.
      if let match = waiting.first(where: {
        $0.botID == botID && $0.request.requestLetter == notAvailable.requestLetter
      }) {
        settle(id: match.id, outcome: .notAvailable(notAvailable.reason))
      }
      return
    }

    for request in waiting where answers(message.payload, request: request.request, from: botID) {
      markAnswered(request, by: message.payload, from: botID)
      settle(id: request.id, outcome: .answered)
    }
  }

  /// Whether a message answers a request: its kind, and for a text reply, its words
  /// (`WeatherTextMatch`) read over every chunk of the reply received so far.
  private func answers(_ payload: MeshWXPayload, request: WeatherRequest, from botID: UInt16) -> Bool {
    guard Self.reply(payload, satisfies: request.expectedReply, stationIndex: stationIndex) else { return false }
    guard case let .text(chunk) = payload else { return true }
    guard let assembly = states[botID]?.texts[chunk.group] else { return false }
    return WeatherTextMatch.matches(request, assembly: assembly, states: states, tables: tables)
  }

  /// Records on the stored answer that this phone asked for it: the channel is shared, and a
  /// forecast or a text reply is otherwise indistinguishable from one somebody else requested.
  private func markAnswered(_ request: WeatherPendingRequest, by payload: MeshWXPayload, from botID: UInt16) {
    switch payload {
    case let .forecast(forecast):
      guard states[botID]?.forecasts[forecast.pointIndex] != nil else { return }
      states[botID]?.forecasts[forecast.pointIndex]?.requestedHere = true
      if forecast.isUnbundledPoint, case let .forecastForPlace(place) = request.request {
        // A forecast the bot resolved from a place string comes back as point 0xFFFF; the
        // request is its only label (spec §7).
        states[botID]?.forecasts[forecast.pointIndex]?.requestLabel = place
      }
    case let .text(chunk):
      states[botID]?.texts[chunk.group]?.request = request.request
    default:
      break
    }
  }

  /// Whether a message is the kind of answer a request expects. Static and injectable so the
  /// pairing rules are testable without a service. For text this checks the subject only; the
  /// service also reads the words (`WeatherTextMatch`) before a reply settles anything.
  static func reply(
    _ payload: MeshWXPayload,
    satisfies kind: WeatherReplyKind,
    stationIndex: (String) -> UInt16?
  ) -> Bool {
    switch (kind, payload) {
    case (.digest, .digest):
      return true
    case (.warnings, .warning), (.warnings, .digest):
      // `>w` answers with warnings then a digest; `>w <identity>` with the one warning. Either
      // first message settles the request; the rest keep flowing into state regardless.
      return true
    case let (.observations(station), .observations(batch)):
      guard let station, let index = stationIndex(station) else { return batch.stations.count > 1 }
      return batch.stations.contains { $0.stationIndex == index }
    case let (.forecast(point), .forecast(forecast)):
      guard let point else { return true }
      return forecast.pointIndex == point
    case let (.text(subject), .text(chunk)):
      return chunk.subject.rawValue == subject
    default:
      return false
    }
  }

  // MARK: Persistence

  private func persist() async {
    let now = now()
    for botID in states.keys {
      WeatherStateReducer.pruneExpired(&states[botID]!, expiredBefore: now.addingTimeInterval(-Self.expiredWarningRetention))
      WeatherStateReducer.prunePendingUpgrades(&states[botID]!, olderThan: now.addingTimeInterval(-Self.pendingUpgradeRetention))
      trim(&states[botID]!)
    }
    do {
      try await store.save(states)
    } catch {
      logger.error("Weather state save failed: \(error.localizedDescription)")
    }
  }

  /// Keeps the per-bot collections bounded: the newest texts and forecasts survive.
  private func trim(_ state: inout WeatherBotState) {
    if state.texts.count > Self.maxTextsPerBot {
      let keep = Set(state.texts.values
        .sorted { $0.lastReceivedAt > $1.lastReceivedAt }
        .prefix(Self.maxTextsPerBot)
        .map(\.group))
      state.texts = state.texts.filter { keep.contains($0.key) }
    }
    if state.forecasts.count > Self.maxForecastsPerBot {
      let keep = Set(state.forecasts
        .sorted { $0.value.receivedAt > $1.value.receivedAt }
        .prefix(Self.maxForecastsPerBot)
        .map(\.key))
      state.forecasts = state.forecasts.filter { keep.contains($0.key) }
    }
  }
}
