import Foundation
import MeshCore
import MeshWX
import os

// MARK: - Transport

/// A link a transport provides *of its own*, for a transport that is not a radio.
///
/// Over Bluetooth there is none: whether weather can be asked for follows the radio, which is
/// the app's business and not the transport's. The DEBUG bridge (`RemoteBotWeatherTransport`)
/// is the other case — an HTTP connection straight to one real bot, with no radio anywhere —
/// and it says so here, naming the bot it speaks for: the tool then treats the radio as
/// connected and that bot as announced, though no advert of its ever reached this phone.
public enum WeatherTransportLink: Sendable, Hashable {
  /// The transport has a live link to this bot.
  case up(bot: WeatherBot)

  /// The bot the link speaks for.
  public var bot: WeatherBot {
    switch self {
    case let .up(bot): bot
    }
  }

  /// `bots` with this link's bot added, unless one of them already carries its id: a real
  /// contact for the same bot stays the one the screen uses, advert position and all.
  public func announcing(_ bots: [WeatherBot]) -> [WeatherBot] {
    bots.contains { $0.botID == bot.botID } ? bots : bots + [bot]
  }
}

/// Why a request could not go out on the channel, so the service can fall back to the DM.
///
/// Not a failure the user is told about: a radio that cannot flood a datagram can still send
/// the DM of spec §8.2, and the fallback is silent (docs/MESHWX.md, "Requests").
public enum WeatherTransportError: Error, Sendable, Hashable {
  /// This radio cannot put a Request datagram on `#meshwx`: firmware older than the command
  /// (v1.15.0), no slot carrying the channel, or no public key of its own to name a sender by.
  /// `reason` is for the log, never for the screen.
  case channelRequestsUnavailable(String)
}

/// What the weather service needs from a radio: channel datagrams in both directions, a DM going
/// out, and a way to tell which slot is `#meshwx`. Narrow on purpose so tests can drive the
/// service with a fake and so the requests provably never touch `MessageService`
/// (docs/MESHWX.md).
public protocol WeatherTransport: Sendable {
  /// A stream of `.channelDataReceived` events. Every other event kind is ignored.
  func datagramEvents() async -> AsyncStream<MeshEvent>
  /// The codes of the radio's delivery confirmations (the ACK push) as they arrive: each says
  /// the recipient's radio received a DM this radio sent.
  func acknowledgements() async -> AsyncStream<Data>
  /// Sends a plain-text DM to a public key with `timestamp` and `attempt` on the wire as given,
  /// and returns the ACK code the radio expects back for this transmission. A resend passes the
  /// first send's timestamp with the next attempt: the same message to the bot's radio, under a
  /// new code.
  func sendRequest(to publicKey: Data, text: String, timestamp: Date, attempt: UInt8) async throws -> Data
  /// Sends the same `>` text as a **Request datagram**, flooded on `#meshwx` (spec §7B): the
  /// normal path since revision 6, because a flood needs no stored route.
  ///
  /// Nothing comes back. A datagram has no acknowledgement — the answer on the channel is the
  /// acknowledgement — so a send that returns says only that the radio took it.
  ///
  /// - Parameters:
  ///   - botID: the bot asked, the first two bytes of its public key.
  ///   - timestamp: the request's own time, repeated byte for byte on the one resend; it is
  ///     what makes the resend a copy to the bot rather than a second request.
  ///   - seq: the **sender's** counter, likewise repeated on the resend.
  /// - Throws: ``WeatherTransportError/channelRequestsUnavailable(_:)`` when this radio cannot
  ///   send one at all, which is the service's cue to fall back to the DM ladder.
  func sendChannelRequest(text: String, botID: UInt16, timestamp: Date, seq: UInt8) async throws
  /// Forgets the route the radio holds to a public key, so the next DM to it goes out by flood
  /// — every repeater forwards it once — rather than hop by hop along a route that may be
  /// stale. The chat rule (docs/guides/Messaging.md, D5), applied to a weather request after
  /// its on-route sends have gone unanswered and unconfirmed.
  func resetPath(to publicKey: Data) async throws
  /// The 16-byte secret of a channel slot, or nil when it cannot be read.
  func channelSecret(at index: UInt8) async -> Data?
  /// Whether the radio's message queue — what it held while the phone was away — is being
  /// drained right now, at connect or on resync. A datagram delivered meanwhile is backlog: it
  /// can be hours old, and it says nothing about whether the bot is in range now.
  func isDrainingBacklog() async -> Bool
  /// The link this transport provides of its own, or nil when it has none — which is the
  /// answer over a radio, and the default, so nothing else implementing this protocol changes.
  func linkState() async -> WeatherTransportLink?
}

public extension WeatherTransport {
  /// No link of its own: the radio's state is the app's to report.
  func linkState() async -> WeatherTransportLink? { nil }
}

/// The production transport over a `MeshCoreSession`.
public struct SessionWeatherTransport: WeatherTransport {
  /// Channel slots searched for `#meshwx` when a request is about to go out and the app's own
  /// table does not name it: the companion firmware's `MAX_GROUP_CHANNELS`, 40. The first cut
  /// scanned 0-7 and the owner's radio keeps `#meshwx` in slot 31, so every request went out as
  /// a DM with "no slot on this radio carries #meshwx" in the log (17 September). A radio with
  /// fewer slots answers an error past its last one, which reads as "not here" and moves on.
  static let channelSlots: UInt8 = 40

  private let session: any MeshCoreSessionProtocol
  private let storedChannelSecret: @Sendable (UInt8) async -> Data?
  private let drainingBacklog: @Sendable () async -> Bool
  private let channelDataSupported: @Sendable () async -> Bool
  /// The slot the app's own channel table holds `#meshwx` in, by secret first and then by
  /// name — what the radio reported at the last channel sync, so no radio round trip.
  private let storedWeatherSlot: @Sendable () async -> UInt8?
  /// The slot proven to carry `#meshwx`, once one has been found. Only positive answers are
  /// kept: a slot is what the user just wrote the channel into, so "not there" must not stick.
  private let weatherSlot = OSAllocatedUnfairLock<UInt8?>(initialState: nil)

  /// - Parameters:
  ///   - storedChannelSecret: the app's own channel table, consulted when the radio
  ///     cannot be asked.
  ///   - isDrainingBacklog: whether the firmware queue is being drained; the container wires it
  ///     to the message poller. The default says never, so everything reads as live.
  ///   - supportsChannelData: whether this radio can *send* a channel datagram
  ///     (`CMD_SEND_CHANNEL_DATA`, 0x3E, firmware v11+). The container wires it to
  ///     `DeviceDTO.supportsChannelDatagrams`, the same gate the screen's
  ///     `firmwareSupportsWeather` is read from; the default assumes it can, and a radio that
  ///     cannot refuses the command anyway.
  ///   - storedWeatherSlot: the slot the app's channel table holds `#meshwx` in, if it holds
  ///     it at all — asked before any slot is scanned. The container wires it to the table;
  ///     the default knows nothing and leaves it to the scan.
  public init(
    session: any MeshCoreSessionProtocol,
    storedChannelSecret: @escaping @Sendable (UInt8) async -> Data? = { _ in nil },
    isDrainingBacklog: @escaping @Sendable () async -> Bool = { false },
    supportsChannelData: @escaping @Sendable () async -> Bool = { true },
    storedWeatherSlot: @escaping @Sendable () async -> UInt8? = { nil }
  ) {
    self.session = session
    self.storedChannelSecret = storedChannelSecret
    drainingBacklog = isDrainingBacklog
    channelDataSupported = supportsChannelData
    self.storedWeatherSlot = storedWeatherSlot
  }

  public func datagramEvents() async -> AsyncStream<MeshEvent> {
    await session.events(filter: .anyChannelDatagram)
  }

  public func acknowledgements() async -> AsyncStream<Data> {
    let events = await session.events(filter: .anyAcknowledgement)
    let (codes, continuation) = AsyncStream.makeStream(of: Data.self)
    let task = Task {
      for await event in events {
        if case let .acknowledgement(code, _) = event { continuation.yield(code) }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return codes
  }

  public func sendRequest(to publicKey: Data, text: String, timestamp: Date, attempt: UInt8) async throws -> Data {
    try await session.sendMessage(to: publicKey, text: text, timestamp: timestamp, attempt: attempt).expectedAck
  }

  /// The request as a datagram on the `#meshwx` slot, flooded (spec §7B).
  ///
  /// Three things have to be true and each of them is a different "no": the firmware has the
  /// command, some slot on this radio carries the channel, and the radio has told the app its
  /// own public key — the six bytes the bot pairs this phone's datagrams and DMs by. Any of
  /// them missing is `channelRequestsUnavailable`, and the service sends the DM instead.
  public func sendChannelRequest(text: String, botID: UInt16, timestamp: Date, seq: UInt8) async throws {
    guard await channelDataSupported() else {
      throw WeatherTransportError.channelRequestsUnavailable(
        "the radio's firmware is older than v1.15.0 and has no send-channel-data command")
    }
    guard let slot = await meshWXSlot() else {
      throw WeatherTransportError.channelRequestsUnavailable("no slot on this radio carries #meshwx")
    }
    guard let key = await session.currentSelfInfo?.publicKey,
          key.count >= MeshWXWire.requestSenderPrefixSize
    else {
      throw WeatherTransportError.channelRequestsUnavailable("the radio has not reported its own public key")
    }
    let request = MeshWXRequest(
      seq: seq,
      botID: botID,
      senderPrefix: Data(key.prefix(MeshWXWire.requestSenderPrefixSize)),
      timestamp: UInt32(truncatingIfNeeded: Int64(timestamp.timeIntervalSince1970)),
      text: text)
    // Flooded: every repeater in reach forwards it once, and no stored route can lose it —
    // which is the whole reason the datagram replaced the DM (spec §7B).
    try await session.sendChannelData(
      channelIndex: slot,
      dataType: MeshWXWire.dataType,
      payload: request.encode(),
      pathLength: PacketBuilder.floodPathSentinel,
      pathBytes: Data())
  }

  /// The slot carrying `#meshwx`, by secret, cached for the session once found.
  private func meshWXSlot() async -> UInt8? {
    if let known = weatherSlot.withLock({ $0 }) { return known }
    // The table first: it is what the radio said at the last sync, and it knows slot 31 without
    // thirty-one round trips.
    if let stored = await storedWeatherSlot() {
      weatherSlot.withLock { $0 = stored }
      return stored
    }
    for index in 0..<Self.channelSlots where await channelSecret(at: index) == WeatherChannel.secret {
      weatherSlot.withLock { $0 = index }
      return index
    }
    return nil
  }

  public func resetPath(to publicKey: Data) async throws {
    try await session.resetPath(publicKey: publicKey)
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
  /// Spec §7B / §13: a Request datagram is waited on for 10 s, then sent once more — the same
  /// bytes, same `ts`, same `seq` — and never a third time. Shorter than the DM's 15 s because
  /// a flood needs no route: an answer that is coming arrives in one to three seconds.
  public static let channelAnswerTimeout: Duration = .seconds(10)
  /// The attempt that goes out by flood after a route reset, and the last one: attempts 0 and 1
  /// ride the stored route, attempt 2 rides every repeater. Three sends, 45 s, then the request
  /// is settled as unanswered (docs/MESHWX.md, "Requests").
  public static let floodAttempt = 2
  /// Spec §13: do not re-request something received in the last five minutes. Airtime etiquette
  /// only: the bot keeps no cache and rebuilds every answer (spec §8.2, revision 2).
  public static let recentAnswerWindow: TimeInterval = 5 * 60
  /// The bot answers `>f <index>` with the forecast for that point's coordinates, which may come
  /// from a nearby point up to this far away.
  static let forecastSubstituteKilometres = 80.0
  /// The bot answers `>o <ICAO>` for a station with no fresh report with the nearest station within
  /// this distance of it that has one, as a batch of one under that station's own index (spec §6,
  /// revision 8): Dayton's nearest bundled station, Wright-Patterson AFB, never reports.
  static let observationSubstituteKilometres = 40.0
  /// Retention for finished text replies and forecasts per bot, newest kept.
  static let maxTextsPerBot = 24
  static let maxForecastsPerBot = 24
  /// How long a text reply and a forecast are kept, whoever asked for them: the same treatment
  /// readings get, so the channel's answers to other people cannot pile up for ever. What a
  /// screen would still show survives it (`WeatherStateReducer.shownTextGroups`,
  /// `shownForecastPoints`).
  static let textRetention: TimeInterval = 48 * 60 * 60
  static let forecastRetention: TimeInterval = 48 * 60 * 60
  /// A station is forgotten once it has neither been in one of the bot's scheduled batches nor
  /// been heard at all for this long: twice the footprint window (§6), so a bot quiet for a night
  /// keeps its area, while somebody's `>o KJFK` from last week does not linger as a reading.
  static let observationRetention: TimeInterval = 48 * 60 * 60
  /// A ceiling whatever the times say. The spec's batch is at most 14 stations, so this is room
  /// for a bot's own area several times over plus everything anyone asked about.
  static let maxObservationsPerBot = 64
  /// Expired warnings linger this long before pruning, so a screen can still say what just
  /// ended.
  static let expiredWarningRetention: TimeInterval = 60 * 60
  /// Upgrade markers older than this are forgotten.
  static let pendingUpgradeRetention: TimeInterval = 6 * 60 * 60

  private let transport: any WeatherTransport
  private let store: any WeatherStateStore
  private let now: @Sendable () -> Date
  private let answerTimeout: Duration
  private let channelAnswerTimeout: Duration
  private let stationIndex: @Sendable (String) -> UInt16?
  private let tables: MeshWXTables
  private let logger = PersistentLogger(subsystem: "com.mc1", category: "WeatherService")

  private nonisolated let eventBroadcaster = EventBroadcaster<WeatherEvent>()

  private var states: [UInt16: WeatherBotState] = [:]
  private var isLoaded = false
  private var stampTask: Task<Void, Never>?
  private var monitorTask: Task<Void, Never>?
  private var acknowledgementTask: Task<Void, Never>?
  /// Confirmations that matched no pending request, newest last. One can reach the service while
  /// the send that expects it is still coming back from the radio, before its code is known; it
  /// is taken once the code is. Chat DMs' confirmations pass through here too, so only the last
  /// few are kept — the radio itself tracks only its last eight expected codes.
  private var unmatchedAcknowledgements: [Data] = []
  static let unmatchedAcknowledgementLimit = 8

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
  /// This phone's own request counter (spec §7B): one more for every **new** channel request,
  /// repeated on its resend, and wrapping 255 to 0. Informational to the bot, which keys copies
  /// on the timestamp; it is how a listener on the channel could tell two requests apart.
  private var nextRequestSeq: UInt8 = 0

  /// An answer anyone on the channel has already received, for the five-minute rule. Filled
  /// on ingest — not when this phone's own request settles — so twenty phones tapping after a
  /// siren send one request between them, not twenty.
  ///
  /// Only from a message the reducer applied and that was heard live. A duplicate, a list older
  /// than the one held, a late warning the reducer set aside, or anything drained from the
  /// radio's queue at connect says nothing about what the bot would answer now.
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
    /// `>cov`: the bot's own statement of its area.
    case coverage
  }

  struct AnswerSlot: Hashable {
    /// Nil for answers that are the same whichever bot sends them.
    let botID: UInt16?
    let key: AnswerKey
  }

  struct AnswerRecord: Hashable {
    /// Phone clock: when the answer arrived, which the five minutes run from.
    var receivedAt: Date
    /// The answer's own time on the bot's clock, where the message carries one.
    var contentAsOf: Date?
  }

  private var lastAnswers: [AnswerSlot: AnswerRecord] = [:]

  /// - Parameters:
  ///   - transport: The radio.
  ///   - store: Where state persists.
  ///   - now: The clock, injectable for tests.
  ///   - answerTimeout: How long to wait for a DM's answer before the retry; tests shorten it.
  ///   - channelAnswerTimeout: The same for a Request datagram, which is waited on for less and
  ///     resent once; tests shorten it.
  ///   - stationIndex: ICAO → wire station index, for matching a one-station answer to
  ///     its request. Defaults to the bundled tables.
  ///   - tables: For reading warning identities and text replies against requests.
  public init(
    transport: any WeatherTransport,
    store: any WeatherStateStore,
    now: @escaping @Sendable () -> Date = { Date() },
    answerTimeout: Duration = WeatherService.answerTimeout,
    channelAnswerTimeout: Duration = WeatherService.channelAnswerTimeout,
    stationIndex: @escaping @Sendable (String) -> UInt16? = { MeshWXTables.shared.stationIndex(forICAO: $0) },
    tables: MeshWXTables = .shared
  ) {
    self.transport = transport
    self.store = store
    self.now = now
    self.answerTimeout = answerTimeout
    self.channelAnswerTimeout = channelAnswerTimeout
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
    acknowledgementTask?.cancel()
    session = WeatherSessionInfo(startedAt: now())
    weatherSlots = []
    foreignSlotsCheckedAt = [:]
    unmatchedAcknowledgements = []
    let acknowledgements = await transport.acknowledgements()
    acknowledgementTask = Task { [weak self] in
      for await code in acknowledgements {
        guard !Task.isCancelled, let self else { break }
        await self.acknowledge(code)
      }
    }
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
    acknowledgementTask?.cancel()
    acknowledgementTask = nil
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

  /// The transport's own link, for the tool (`WeatherTransport.linkState()`). Nil over a radio,
  /// where the connection is the app's to report; the DEBUG bridge names the bot it talks to.
  public func transportLink() async -> WeatherTransportLink? {
    await transport.linkState()
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
    if case .request = message.payload {
      // Another phone asking the bot something, heard because requests are flooded on the
      // channel now (spec §7B). It is not from a bot, so it is not the bot's `seq` and not the
      // bot being heard; its answer will arrive as a message of its own, for everyone. Dropped
      // here rather than in the reducer so nothing about it can reach state.
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
    // Somebody else's request (spec §7B). Not a bot, not an answer, not a `seq` of the bot's:
    // nothing about it is state, and the reducer must never see one.
    if case .request = message.payload { return [] }
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
      eventBroadcaster.yield(.received(botID: botID, message: message, changes: changes, isBacklog: isBacklog))
      return changes
    }

    let settled = settlePending(with: message, from: botID)
    if !isBacklog {
      recordAnswer(message.payload, changes: changes, settled: settled, from: botID, at: receivedAt)
    }
    eventBroadcaster.yield(.received(botID: botID, message: message, changes: changes, isBacklog: isBacklog))
    await persist()
    return changes
  }

  /// Fills the answer slots a live message fills — keyed off the reducer's changes, so only what
  /// it applied counts. Runs after settlement: a text reply becomes an answer only once this
  /// phone owns it.
  private func recordAnswer(
    _ payload: MeshWXPayload,
    changes: [WeatherStateChange],
    settled: [WeatherRequest],
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
        // A single station is usually somebody's `>o KJFK`, but the answer to this phone's own
        // `>o` is a batch of one when only one station reported.
        if batch.stations.count > 1 || settled.contains(.observations) {
          fill(botID, .coverageObservations, asOf: observedAt)
        }
        // Each station's slot carries that station's own report time (spec §6.1): a reading two
        // hours behind the batch must not look two hours fresher than it is.
        for station in stored {
          let reported = batch.stations.first { $0.stationIndex == station }
            .map { batch.reportMinutes(for: $0) } ?? batch.timestampMinutes
          fill(nil, .station(station), asOf: Date(unixMinutes: reported))
        }
      case let (.forecastStored(point), .forecast(forecast)) where !forecast.isUnbundledPoint:
        fill(nil, .forecast(point), asOf: Date(unixMinutes: forecast.issuedMinutes))
      case (.coverageStored, .coverage):
        // No content time: the statement describes the bot, not an hour (spec §7A), so the
        // five-minute rule runs from receipt alone and nothing claims it is "as of" anything.
        fill(botID, .coverage)
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
  /// **Channel first** (spec §7B): the request goes out as a datagram flooded on `#meshwx`,
  /// because a DM rides one stored route and fails silently once that route has gone stale. The
  /// DM ladder of §8.2 is the fallback, for a radio that cannot send a datagram at all.
  ///
  /// - Returns: The pending request now on the air, or nil when this phone received the answer
  ///   in the last five minutes and asking again would only spend airtime (a
  ///   `requestSettled(_, .alreadyReceived)` event is emitted).
  /// - Throws: `WeatherRequestError.rateLimited` inside the five-second spacing;
  ///   `.transport` when the radio refuses the send.
  @discardableResult
  public func send(_ request: WeatherRequest, to bot: WeatherBot) async throws -> WeatherPendingRequest? {
    await loadIfNeeded()
    let sentAt = now()

    if let slot = answerSlot(for: request, botID: bot.botID),
       let answer = lastAnswers[slot],
       sentAt.timeIntervalSince(answer.receivedAt) < Self.recentAnswerWindow,
       !answerLeavesSomethingOutstanding(request, answer: answer, botID: bot.botID, now: sentAt) {
      let served = WeatherPendingRequest(
        request: request, botID: bot.botID, botPublicKey: bot.publicKey, sentAt: sentAt
      )
      eventBroadcaster.yield(.requestSettled(
        served, .alreadyReceived(receivedAt: answer.receivedAt, contentAsOf: answer.contentAsOf)))
      return nil
    }

    if let lastSendAt {
      let elapsed = sentAt.timeIntervalSince(lastSendAt)
      if elapsed < Self.requestSpacing {
        throw WeatherRequestError.rateLimited(retryAfter: Self.requestSpacing - elapsed)
      }
    }

    // Claim the slot before the await so a second caller inside the window is refused even
    // while this request is still going out.
    lastSendAt = sentAt

    // One wire timestamp and one seq for the request's life: the resend repeats both
    // (`handleTimeout`), which is what makes it a copy rather than a second request.
    let seq = nextRequestSeq
    do {
      try await transport.sendChannelRequest(
        text: request.wireText, botID: bot.botID, timestamp: sentAt, seq: seq)
      nextRequestSeq &+= 1
      let entry = WeatherPendingRequest(
        request: request, botID: bot.botID, botPublicKey: bot.publicKey, sentAt: sentAt,
        transportKind: .channel, timestamp: sentAt, seq: seq
      )
      pending[entry.id] = PendingEntry(request: entry, timer: nil)
      armTimer(for: entry.id)
      eventBroadcaster.yield(.requestSent(entry))
      return pending[entry.id]?.request ?? entry
    } catch let WeatherTransportError.channelRequestsUnavailable(reason) {
      // This radio cannot flood a datagram: no v1.15.0 firmware, no `#meshwx` slot, or no key
      // of its own. The DM still works, and the bot still answers it (spec §7B).
      logger.notice("Channel requests unavailable (\(reason)); sending \(request.wireText) as a DM")
    } catch {
      throw WeatherRequestError.transport(error.localizedDescription)
    }

    var entry = WeatherPendingRequest(
      request: request, botID: bot.botID, botPublicKey: bot.publicKey, sentAt: sentAt,
      transportKind: .dm, timestamp: sentAt
    )
    let ackCode: Data
    do {
      ackCode = try await transport.sendRequest(
        to: bot.publicKey, text: request.wireText, timestamp: entry.timestamp, attempt: 0)
    } catch {
      throw WeatherRequestError.transport(error.localizedDescription)
    }
    entry.ackCodes.insert(ackCode)
    pending[entry.id] = PendingEntry(request: entry, timer: nil)
    armTimer(for: entry.id)
    eventBroadcaster.yield(.requestSent(entry))
    takeEarlyAcknowledgement(ackCode, for: entry.id)
    return pending[entry.id]?.request ?? entry
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
    case .coverage: AnswerSlot(botID: botID, key: .coverage)
    case .homeForecast, .forecastForPlace: nil
    }
  }

  /// Whether an alert request goes out although its answer arrived in the last five minutes,
  /// because that answer cannot speak for what the addressed bot's state has outstanding now:
  ///
  /// - A gap detected after the answer arrived: what was missed came later, and only a new
  ///   answer can say what it was.
  /// - A gap at or before an answer built too soon after it to clear it (a list inside
  ///   `WeatherStateReducer.digestMargin` of the gap, including the list whose own `seq`
  ///   revealed it), once a list built now would. Before then a new list could not clear it
  ///   either, and would carry nothing the one just received does not.
  /// - For `>w` and `>w <area>`: a warning a list named that never arrived, or an upgrade whose
  ///   replacement never came. Whatever arrived evidently did not carry it.
  private func answerLeavesSomethingOutstanding(
    _ request: WeatherRequest,
    answer: AnswerRecord,
    botID: UInt16,
    now: Date
  ) -> Bool {
    switch request {
    case .digest, .activeWarnings, .warningsTouching, .warning: break
    default: return false
    }
    guard let state = states[botID] else { return false }
    if state.needsDigest, let gap = state.gapDetectedAt {
      if gap > answer.receivedAt { return true }
      let margin = WeatherStateReducer.digestMargin
      if let builtAt = answer.contentAsOf, gap >= builtAt.addingTimeInterval(-margin),
         now >= gap.addingTimeInterval(margin) {
        return true
      }
    }
    switch request {
    // `>d` is where asking for missing warnings one at a time ends, once the bot has said it has
    // none of them, so it must not wait out the five minutes either.
    case .digest, .activeWarnings, .warningsTouching:
      return !state.missingFromDigest.isEmpty || !state.pendingUpgrades.isEmpty
    default:
      return false
    }
  }

  private func armTimer(for id: UUID) {
    pending[id]?.timer?.cancel()
    // A flood is answered in one to three seconds or not at all; a DM may still be finding its
    // way along a route (spec §13: 10 s for a datagram, 15 s for a DM).
    let timeout = pending[id]?.request.transportKind == .channel ? channelAnswerTimeout : answerTimeout
    pending[id]?.timer = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      await self?.handleTimeout(id: id)
    }
  }

  private func handleTimeout(id: UUID) async {
    guard var entry = pending[id] else { return }
    // Heard since the **first** send (the wire timestamp is the first send's time): a bot that
    // answered somebody else while this request was on its second or third try was in range for
    // the whole of it, and "heard but didn't answer" is the honest label for that.
    let botWasHeard = wasHeardLive(botID: entry.request.botID, since: entry.request.timestamp)
    if entry.request.transportKind == .channel {
      await handleChannelTimeout(id: id, entry: entry, botWasHeard: botWasHeard)
      return
    }
    let attempt = entry.request.attempt
    // What the next send is, or nil to stop asking:
    //
    // - Attempt 0 unheard and unconfirmed → attempt 1, the same DM along the same route, into
    //   silence.
    // - Attempt 0 **confirmed** by the bot's radio but unanswered → attempt 1 too: the request
    //   arrived, its answer may not have, and the bot answers a copy from its cache for one
    //   packet. Never a flood for a confirmed request: the route works.
    // - Attempt 0 unconfirmed while the bot **was** heard, or attempt 1 unconfirmed → the route
    //   is the suspect, not the range. Forget it and send attempt 2 by flood, once (the chat
    //   rule, D5). The field log of 16 September had seven requests in six minutes that never
    //   reached a bot which was on the air and answering others.
    // - Attempt 2, or a confirmed request past attempt 0 → done.
    let next: Int?
    switch (attempt, entry.request.botRadioReceived, botWasHeard) {
    case (0, false, false): next = 1
    case (0, true, false): next = 1
    case (0, false, true), (1, false, _): next = Self.floodAttempt
    default: next = nil
    }
    guard let next else {
      settle(id: id, outcome: .timedOut(botWasHeard: botWasHeard, botRadioReceived: entry.request.botRadioReceived))
      return
    }
    if next == Self.floodAttempt {
      // A reset that fails still leaves the send worth making: on the route it has is no worse
      // than not asking again at all.
      try? await transport.resetPath(to: entry.request.botPublicKey)
      guard pending[id] != nil else { return }
    }
    entry.request.attempt = next
    entry.request.sentAt = now()
    pending[id] = entry
    let ackCode: Data
    do {
      lastSendAt = entry.request.sentAt
      // The first send's timestamp and text again: to the bot's radio the same message, to the
      // bot (the same text from one sender within two minutes is one request) the same request,
      // which it answers again from its cache once its last answer is 12 s gone.
      ackCode = try await transport.sendRequest(
        to: entry.request.botPublicKey, text: entry.request.request.wireText,
        timestamp: entry.request.timestamp, attempt: UInt8(next))
    } catch {
      settle(id: id, outcome: .failed(error.localizedDescription))
      return
    }
    // Answered while the resend was going out. Otherwise update the entry in place: a
    // confirmation of an earlier send may have landed meanwhile.
    guard pending[id] != nil else { return }
    pending[id]?.request.ackCodes.insert(ackCode)
    if let request = pending[id]?.request {
      eventBroadcaster.yield(.requestSent(request))
    }
    takeEarlyAcknowledgement(ackCode, for: id)
    armTimer(for: id)
  }

  /// The datagram's etiquette (spec §7B, §13): send once, send the same bytes once more after
  /// 10 s, never a third time.
  ///
  /// The resend repeats the first send's `ts`, `seq` and text exactly, so to the bot it is a
  /// copy of one request and not a second one — answered again only once its last answer is 12 s
  /// gone, so a resend can never double the airtime of an answer. Nothing here waits on a
  /// confirmation: a datagram has none, which is why `botRadioReceived` is always false for one.
  private func handleChannelTimeout(id: UUID, entry: PendingEntry, botWasHeard: Bool) async {
    guard entry.request.attempt == 0 else {
      settle(id: id, outcome: .timedOut(botWasHeard: botWasHeard, botRadioReceived: false))
      return
    }
    var entry = entry
    entry.request.attempt = 1
    entry.request.sentAt = now()
    pending[id] = entry
    do {
      lastSendAt = entry.request.sentAt
      try await transport.sendChannelRequest(
        text: entry.request.request.wireText, botID: entry.request.botID,
        timestamp: entry.request.timestamp, seq: entry.request.seq)
    } catch {
      settle(id: id, outcome: .failed(error.localizedDescription))
      return
    }
    // Answered while the resend was going out.
    guard pending[id] != nil else { return }
    if let request = pending[id]?.request {
      eventBroadcaster.yield(.requestSent(request))
    }
    armTimer(for: id)
  }

  /// Live only: a backlog drained from the radio's queue after the request went out is stamped
  /// with the drain time, and says nothing about whether the bot can hear this phone now.
  private func wasHeardLive(botID: UInt16, since date: Date) -> Bool {
    guard let heard = states[botID]?.lastLiveHeardAt else { return false }
    return heard > date
  }

  // MARK: Confirmations

  /// Takes one of the radio's delivery confirmations: the pending request expecting the code,
  /// from either transmission, was received by the bot's radio.
  func acknowledge(_ code: Data) {
    guard let id = pending.first(where: { $0.value.request.ackCodes.contains(code) })?.key else {
      unmatchedAcknowledgements.append(code)
      if unmatchedAcknowledgements.count > Self.unmatchedAcknowledgementLimit {
        unmatchedAcknowledgements.removeFirst()
      }
      return
    }
    markReceivedByBotRadio(id: id)
  }

  /// A confirmation that reached the service before the send expecting it came back.
  private func takeEarlyAcknowledgement(_ code: Data, for id: UUID) {
    guard let index = unmatchedAcknowledgements.firstIndex(of: code) else { return }
    unmatchedAcknowledgements.remove(at: index)
    markReceivedByBotRadio(id: id)
  }

  private func markReceivedByBotRadio(id: UUID) {
    guard let request = pending[id]?.request, !request.botRadioReceived else { return }
    pending[id]?.request.botRadioReceived = true
    if let updated = pending[id]?.request {
      eventBroadcaster.yield(.requestReceivedByBotRadio(updated))
    }
  }

  private func settle(id: UUID, outcome: WeatherRequestOutcome) {
    guard let entry = pending.removeValue(forKey: id) else { return }
    entry.timer?.cancel()
    eventBroadcaster.yield(.requestSettled(entry.request, outcome))
  }

  /// Pairs an incoming message with the requests waiting on it; returns the requests it answered.
  private func settlePending(with message: MeshWXMessage, from botID: UInt16) -> [WeatherRequest] {
    let waiting = pending.values
      .map(\.request)
      .filter { $0.botID == botID || $0.request.acceptsAnswerFromAnyBot }
      .sorted { $0.sentAt < $1.sentAt }
    guard !waiting.isEmpty else { return [] }

    if case let .notAvailable(notAvailable) = message.payload {
      // One refusal answers the oldest request with that letter — and only a request to the
      // bot that refused.
      if let match = waiting.first(where: {
        $0.botID == botID && $0.request.requestLetter == notAvailable.requestLetter
      }) {
        settle(id: match.id, outcome: .notAvailable(notAvailable.reason))
      }
      return []
    }

    var answered: [WeatherRequest] = []
    for request in waiting where answers(message.payload, request: request, from: botID) {
      markAnswered(request, by: message.payload, from: botID)
      settle(id: request.id, outcome: .answered)
      answered.append(request.request)
    }
    return answered
  }

  /// Whether a message answers a request: its kind and what it names, and for a text reply, its
  /// words (`WeatherTextMatch`) read over every chunk of the reply received so far.
  private func answers(_ payload: MeshWXPayload, request: WeatherPendingRequest, from botID: UInt16) -> Bool {
    guard Self.reply(
      payload, satisfies: request.request.expectedReply, fromAddressedBot: request.botID == botID,
      stationIndex: stationIndex, tables: tables)
    else { return false }
    guard case let .text(chunk) = payload else { return true }
    guard let assembly = states[botID]?.texts[chunk.group] else { return false }
    return WeatherTextMatch.matches(request.request, assembly: assembly, states: states, tables: tables)
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

  /// Whether a message is the answer a request expects. Static and injectable so the pairing
  /// rules are testable without a service. For text this checks the subject only; the service
  /// also reads the words (`WeatherTextMatch`) before a reply settles anything.
  ///
  /// - Parameter fromAddressedBot: the message came from the bot the request went to. A request
  ///   that only its own bot can settle never reaches here with another bot's message
  ///   (`WeatherRequest.acceptsAnswerFromAnyBot`); a forecast uses it to accept a substituted
  ///   point only from the bot that chose it.
  static func reply(
    _ payload: MeshWXPayload,
    satisfies kind: WeatherReplyKind,
    fromAddressedBot: Bool,
    stationIndex: (String) -> UInt16?,
    tables: MeshWXTables
  ) -> Bool {
    switch (kind, payload) {
    case (.digest, .digest):
      return true
    case (.warnings, .warning), (.warnings, .digest):
      // `>w` answers with warnings then a digest. Either first message settles the request; the
      // rest keep flowing into state regardless.
      return true
    case let (.warning(identity), .warning(warning)):
      // An identity the tables cannot read matches nothing; a Not available or the timeout
      // settles it instead.
      return WeatherAlertRequests.identity(from: identity, tables: tables) == warning.identity
    case let (.warningsTouching(ugc), .warning(warning)):
      // The bot matches the code exactly against the product's own area list (spec §8.2), but cuts
      // the list it sends to 30, 12 or 6 runs, or drops it, to fit one packet. From the bot asked,
      // a warning whose list may have been cut can be the answer without naming the code.
      if tables.namedAreas(for: warning).contains(where: { $0.ugc.caseInsensitiveCompare(ugc) == .orderedSame }) {
        return true
      }
      guard fromAddressedBot else { return false }
      return [0, 6, 12, MeshWXWire.maxAreaRuns].contains(warning.areas?.count ?? 0)
    case let (.observations(station), .observations(batch)):
      // `>o` is answered by the bot's batch whatever its size: one station when only one reported.
      guard let station else { return true }
      guard let index = stationIndex(station) else { return fromAddressedBot }
      if batch.stations.contains(where: { $0.stationIndex == index }) { return true }
      // The named station had nothing fresh, so the bot sent the nearest one that did (spec §6,
      // revision 8). Only from the bot asked, only alone: somebody else's batch that happens to
      // hold a neighbour is not this request's answer.
      guard fromAddressedBot, batch.stations.count == 1,
            let asked = tables.station(icao: station),
            let answered = tables.station(at: batch.stations[0].stationIndex)
      else { return false }
      return MeshWXGeo.distanceKilometres(fromLat: asked.lat, lon: asked.lon, toLat: answered.lat, lon: answered.lon)
        <= observationSubstituteKilometres
    case let (.forecast(point), .forecast(forecast)):
      guard let point else { return true }
      if forecast.pointIndex == point { return true }
      // The bot forecasts the point's coordinates: what comes back may be a nearby point within
      // 80 km under its own index, a place with no bundled point, or — from a revision 2 bot —
      // another index with the same coordinates.
      guard fromAddressedBot else { return false }
      if forecast.isUnbundledPoint { return true }
      guard let asked = tables.point(at: point), let answered = tables.point(at: forecast.pointIndex) else {
        return false
      }
      return MeshWXGeo.distanceKilometres(fromLat: asked.lat, lon: asked.lon, toLat: answered.lat, lon: answered.lon)
        <= forecastSubstituteKilometres
    case let (.text(subject), .text(chunk)):
      return chunk.subject.rawValue == subject
    case (.coverage, .coverage):
      // Nothing to check it against: a statement is about the bot that sent it, and only the
      // bot asked can answer this one (`acceptsAnswerFromAnyBot`).
      return true
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
      trim(&states[botID]!, now: now)
    }
    do {
      try await store.save(states)
    } catch {
      logger.error("Weather state save failed: \(error.localizedDescription)")
    }
  }

  /// Keeps the per-bot collections bounded: every answer the channel carries is kept, whoever
  /// asked, so all three have both an age and a ceiling — and what a screen is showing survives
  /// both (`WeatherStateReducer`).
  private func trim(_ state: inout WeatherBotState, now: Date) {
    WeatherStateReducer.pruneTexts(
      &state, receivedBefore: now.addingTimeInterval(-Self.textRetention), limit: Self.maxTextsPerBot)
    WeatherStateReducer.pruneForecasts(
      &state, receivedBefore: now.addingTimeInterval(-Self.forecastRetention), limit: Self.maxForecastsPerBot)
    // The reducer already keeps one reading per station; what grows is the number of stations,
    // one for every `>o <ICAO>` anyone on the channel has ever asked for. A station goes once it
    // has neither been in one of this bot's scheduled batches nor been heard at all in the
    // window — a reading nothing on screen would use, and no evidence of the bot's area either.
    let cutoff = now.addingTimeInterval(-Self.observationRetention)
    state.observations = state.observations.filter { _, stored in
      (stored.lastBatchAt ?? .distantPast) >= cutoff || stored.receivedAt >= cutoff
    }
    if state.observations.count > Self.maxObservationsPerBot {
      // The bot's own area first, newest batch down: it outlives answers to one-off questions.
      let keep = Set(state.observations
        .sorted { lhs, rhs in
          let lhsBatch = lhs.value.lastBatchMinutes ?? 0
          let rhsBatch = rhs.value.lastBatchMinutes ?? 0
          if lhsBatch != rhsBatch { return lhsBatch > rhsBatch }
          if lhs.value.receivedAt != rhs.value.receivedAt { return lhs.value.receivedAt > rhs.value.receivedAt }
          return lhs.key < rhs.key
        }
        .prefix(Self.maxObservationsPerBot)
        .map(\.key))
      state.observations = state.observations.filter { keep.contains($0.key) }
    }
  }
}
