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
}

/// The production transport over a `MeshCoreSession`.
public struct SessionWeatherTransport: WeatherTransport {
  private let session: any MeshCoreSessionProtocol
  private let storedChannelSecret: @Sendable (UInt8) async -> Data?

  /// - Parameter storedChannelSecret: the app's own channel table, consulted when the radio
  ///   cannot be asked.
  public init(
    session: any MeshCoreSessionProtocol,
    storedChannelSecret: @escaping @Sendable (UInt8) async -> Data? = { _ in nil }
  ) {
    self.session = session
    self.storedChannelSecret = storedChannelSecret
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
  private let logger = PersistentLogger(subsystem: "com.mc1", category: "WeatherService")

  private nonisolated let eventBroadcaster = EventBroadcaster<WeatherEvent>()

  private var states: [UInt16: WeatherBotState] = [:]
  private var isLoaded = false
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
  enum AnswerKey: Hashable {
    case digest
    case coverageObservations
    case station(UInt16)
    case forecast(UInt16)
  }

  private struct AnswerSlot: Hashable {
    /// Nil for answers that are the same whichever bot sends them.
    let botID: UInt16?
    let key: AnswerKey
  }

  private var lastAnswers: [AnswerSlot: Date] = [:]

  /// - Parameters:
  ///   - transport: The radio.
  ///   - store: Where state persists.
  ///   - now: The clock, injectable for tests.
  ///   - answerTimeout: How long to wait for an answer before the retry; tests shorten it.
  ///   - stationIndex: ICAO → wire station index, for matching a one-station answer to
  ///     its request. Defaults to the bundled tables.
  public init(
    transport: any WeatherTransport,
    store: any WeatherStateStore,
    now: @escaping @Sendable () -> Date = { Date() },
    answerTimeout: Duration = WeatherService.answerTimeout,
    stationIndex: @escaping @Sendable (String) -> UInt16? = { MeshWXTables.shared.stationIndex(forICAO: $0) }
  ) {
    self.transport = transport
    self.store = store
    self.now = now
    self.answerTimeout = answerTimeout
    self.stationIndex = stationIndex
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

  /// Subscribes to channel datagrams. Called before the message polling service drains the
  /// firmware queue, so datagrams queued while the phone was away are seen too.
  public func startEventMonitoring() async {
    await loadIfNeeded()
    monitorTask?.cancel()
    session = WeatherSessionInfo(startedAt: now())
    weatherSlots = []
    foreignSlotsCheckedAt = [:]
    let stream = await transport.datagramEvents()
    monitorTask = Task { [weak self] in
      for await event in stream {
        guard !Task.isCancelled, let self else { break }
        if case let .channelDataReceived(datagram) = event {
          await self.ingest(datagram)
        }
      }
    }
  }

  public func stopEventMonitoring() {
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

  /// Forgets everything held for one bot.
  public func clearState(for botID: UInt16) async {
    await loadIfNeeded()
    states.removeValue(forKey: botID)
    lastAnswers = lastAnswers.filter { $0.key.botID != botID }
    await persist()
  }

  // MARK: Ingest

  /// Decodes and applies one datagram. Anything that is not a v5 message on the `#meshwx` slot
  /// is ignored (spec §2.1: "ignore any `data_type` other than 0xFF10"; `0xFF10` is in the
  /// development range, so another application may use it on another channel).
  @discardableResult
  public func ingest(_ datagram: ChannelDatagram) async -> [WeatherStateChange]? {
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
    return await ingest(message)
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
  @discardableResult
  public func ingest(_ message: MeshWXMessage) async -> [WeatherStateChange] {
    await loadIfNeeded()
    let botID = message.header.bot
    let receivedAt = now()
    var state = states[botID] ?? WeatherBotState(botID: botID)
    let changes = WeatherStateReducer.apply(message, to: &state, receivedAt: receivedAt)
    states[botID] = state

    let isDuplicate = changes.contains { change in
      if case .duplicate = change { return true }
      return false
    }
    if isDuplicate {
      // A duplicate changes nothing and settles nothing.
      eventBroadcaster.yield(.received(botID: botID, message: message, changes: changes))
      return changes
    }

    recordAnswer(message.payload, from: botID, at: receivedAt)
    settlePending(with: message, from: botID)
    eventBroadcaster.yield(.received(botID: botID, message: message, changes: changes))
    await persist()
    return changes
  }

  private func recordAnswer(_ payload: MeshWXPayload, from botID: UInt16, at date: Date) {
    switch payload {
    case .digest:
      lastAnswers[AnswerSlot(botID: botID, key: .digest)] = date
    case let .observations(batch):
      if batch.stations.count > 1 {
        lastAnswers[AnswerSlot(botID: botID, key: .coverageObservations)] = date
      }
      for station in batch.stations {
        lastAnswers[AnswerSlot(botID: nil, key: .station(station.stationIndex))] = date
      }
    case let .forecast(forecast):
      if !forecast.isUnbundledPoint {
        lastAnswers[AnswerSlot(botID: nil, key: .forecast(forecast.pointIndex))] = date
      }
    default:
      break
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
       let answeredAt = lastAnswers[slot],
       sentAt.timeIntervalSince(answeredAt) < Self.cacheWindow {
      let served = WeatherPendingRequest(
        request: request, botID: bot.botID, botPublicKey: bot.publicKey, sentAt: sentAt
      )
      eventBroadcaster.yield(.requestSettled(served, .servedFromCache(receivedAt: answeredAt)))
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
    default: nil
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
    let botWasHeard = wasHeard(botID: entry.request.botID, since: entry.request.sentAt)
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

  private func wasHeard(botID: UInt16, since date: Date) -> Bool {
    guard let heard = states[botID]?.lastHeardAt else { return false }
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

    for request in waiting
    where Self.reply(message.payload, satisfies: request.request.expectedReply, stationIndex: stationIndex) {
      markAnswered(request, by: message.payload, from: botID)
      settle(id: request.id, outcome: .answered)
    }
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

  /// Whether a message answers what a request asked for. Static and injectable so the
  /// pairing rules are testable without a service.
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
