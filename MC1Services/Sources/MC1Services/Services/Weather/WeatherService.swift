import Foundation
import MeshCore
import MeshWX

// MARK: - Transport

/// The two things the weather service needs from a radio: channel datagrams coming in, and
/// a DM going out. Narrow on purpose so tests can drive the service with a fake and so the
/// requests provably never touch `MessageService` (docs/MESHWX.md: requests stay out of the
/// chat).
public protocol WeatherTransport: Sendable {
  /// A stream of `.channelDataReceived` events. Every other event kind is ignored.
  func datagramEvents() async -> AsyncStream<MeshEvent>
  /// Sends a plain-text DM to a public key.
  func sendRequest(to publicKey: Data, text: String) async throws
}

/// The production transport over a `MeshCoreSession`.
public struct SessionWeatherTransport: WeatherTransport {
  private let session: any MeshCoreSessionProtocol

  public init(session: any MeshCoreSessionProtocol) {
    self.session = session
  }

  public func datagramEvents() async -> AsyncStream<MeshEvent> {
    await session.events(filter: .anyChannelDatagram)
  }

  public func sendRequest(to publicKey: Data, text: String) async throws {
    _ = try await session.sendMessage(to: publicKey, text: text, timestamp: Date(), attempt: 0)
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

  private struct PendingEntry {
    var request: WeatherPendingRequest
    var timer: Task<Void, Never>?
  }

  private struct RecentKey: Hashable {
    let botID: UInt16
    let request: WeatherRequest
  }

  private var pending: [UUID: PendingEntry] = [:]
  private var lastSendAt: Date?
  private var recentAnswers: [RecentKey: Date] = [:]

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
      let cutoff = now().addingTimeInterval(-Self.expiredWarningRetention)
      for botID in states.keys {
        WeatherStateReducer.pruneExpired(&states[botID]!, expiredBefore: cutoff)
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

  /// Forgets everything held for one bot.
  public func clearState(for botID: UInt16) async {
    await loadIfNeeded()
    states.removeValue(forKey: botID)
    recentAnswers = recentAnswers.filter { $0.key.botID != botID }
    await persist()
  }

  // MARK: Ingest

  /// Decodes and applies one datagram. Anything that is not a v5 message is ignored
  /// (spec §2.1: "ignore any `data_type` other than 0xFF10").
  @discardableResult
  public func ingest(_ datagram: ChannelDatagram) async -> [WeatherStateChange]? {
    guard datagram.dataType == MeshWXWire.dataType else { return nil }
    let message: MeshWXMessage
    do {
      message = try MeshWXDecoder.decode(datagram.data)
    } catch {
      logger.warning("Undecodable MeshWX datagram (\(datagram.data.count) bytes): \(error)")
      return nil
    }
    return await ingest(message)
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

    if changes.contains(where: { if case .duplicate = $0 { return true } else { return false } }) {
      // A duplicate changes nothing and settles nothing.
      eventBroadcaster.yield(.received(botID: botID, message: message, changes: changes))
      return changes
    }

    settlePending(with: message, from: botID)
    eventBroadcaster.yield(.received(botID: botID, message: message, changes: changes))
    await persist()
    return changes
  }

  // MARK: Requests

  /// Sends a request to a bot, or answers it from what was already received.
  ///
  /// - Returns: The pending request now on the air, or nil when the answer was served from
  ///   the five-minute cache (a `requestSettled(_, .servedFromCache)` event is emitted).
  /// - Throws: `WeatherRequestError.rateLimited` inside the five-second spacing;
  ///   `.transport` when the radio refuses the DM.
  @discardableResult
  public func send(_ request: WeatherRequest, to bot: WeatherBot) async throws -> WeatherPendingRequest? {
    await loadIfNeeded()
    let sentAt = now()

    let key = RecentKey(botID: bot.botID, request: request)
    if request.isCacheable,
       let answeredAt = recentAnswers[key],
       sentAt.timeIntervalSince(answeredAt) < Self.cacheWindow {
      let served = WeatherPendingRequest(
        request: request, botID: bot.botID, botPublicKey: bot.publicKey, sentAt: sentAt
      )
      eventBroadcaster.yield(.requestSettled(served, .servedFromCache))
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
    guard entry.request.attempt == 0 else {
      settle(id: id, outcome: .timedOut)
      return
    }
    // Spec §8.2: retry once, then tell the user the bot may be out of range.
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

  private func settle(id: UUID, outcome: WeatherRequestOutcome) {
    guard let entry = pending.removeValue(forKey: id) else { return }
    entry.timer?.cancel()
    if outcome == .answered {
      recentAnswers[RecentKey(botID: entry.request.botID, request: entry.request.request)] = now()
    }
    eventBroadcaster.yield(.requestSettled(entry.request, outcome))
  }

  /// Pairs an incoming message with the requests waiting on that bot.
  private func settlePending(with message: MeshWXMessage, from botID: UInt16) {
    let waiting = pending.values
      .filter { $0.request.botID == botID }
      .sorted { $0.request.sentAt < $1.request.sentAt }
    guard !waiting.isEmpty else { return }

    if case let .notAvailable(notAvailable) = message.payload {
      // One refusal answers the oldest request with that letter, not every one of them.
      if let match = waiting.first(where: { $0.request.request.requestLetter == notAvailable.requestLetter }) {
        settle(id: match.request.id, outcome: .notAvailable(notAvailable.reason))
      }
      return
    }

    for entry in waiting where Self.reply(message.payload, satisfies: entry.request.request.expectedReply, stationIndex: stationIndex) {
      labelUnbundledForecast(for: entry.request, with: message.payload, botID: botID)
      settle(id: entry.request.id, outcome: .answered)
    }
  }

  /// A forecast the bot resolved from a place string comes back as point `0xFFFF`; the request
  /// is its only label (spec §7).
  private func labelUnbundledForecast(for request: WeatherPendingRequest, with payload: MeshWXPayload, botID: UInt16) {
    guard case let .forecastForPlace(place) = request.request,
          case let .forecast(forecast) = payload,
          forecast.isUnbundledPoint,
          states[botID]?.forecasts[forecast.pointIndex] != nil else { return }
    states[botID]?.forecasts[forecast.pointIndex]?.requestLabel = place
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
      guard let station, let index = stationIndex(station) else { return true }
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
    let cutoff = now().addingTimeInterval(-Self.expiredWarningRetention)
    for botID in states.keys {
      WeatherStateReducer.pruneExpired(&states[botID]!, expiredBefore: cutoff)
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
      let keep = state.texts.values
        .sorted { $0.lastReceivedAt > $1.lastReceivedAt }
        .prefix(Self.maxTextsPerBot)
        .map(\.group)
      state.texts = state.texts.filter { keep.contains($0.key) }
    }
    if state.forecasts.count > Self.maxForecastsPerBot {
      let keep = state.forecasts
        .sorted { $0.value.receivedAt > $1.value.receivedAt }
        .prefix(Self.maxForecastsPerBot)
        .map(\.key)
      state.forecasts = state.forecasts.filter { keep.contains($0.key) }
    }
  }
}
