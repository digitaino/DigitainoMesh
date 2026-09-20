import Foundation
import MapperRawLog
import MC1Services
import SurveyKit

/// Writes a raw-log row for every packet **we** transmit (docs/SIGNAL_MAPPER_V3.md §2,
/// "Our own packets"; §7 step 2).
///
/// Lives in the app target rather than in a service, for the reason the whole `sent` row
/// exists: MC1Services must never be able to reach a raw row (ACTIVE_SURVEY_M3_5.md §2.4),
/// so the side that knows about transmissions — `MessageEventStream`, the advert action —
/// and the side that stores them are joined here, above both.
///
/// **What writes a `sent` row, and what deliberately does not:**
///
/// - *Messages.* `.messageStatusResolved` at `.sent` (the radio queued the packet) or, for
///   a send whose first resolution is `.delivered`, that. One row per transmission, so a
///   `.messageResent` writes another: the radio really did put a second packet on the air,
///   and a reach lookup for the second one must not be answered with the first one's time.
/// - *Adverts.* ``recordAdvertSend(flood:)``, called by `sendSelfAdvert` once the radio has
///   accepted the command.
/// - *Probes.* **Nothing here.** `SignalMapperProbeEngine` already records a
///   `probeAttempt` row at each `sendDiscover`/`sendTrace`, with the send-time placement
///   and the target — everything a `sent` row would carry and more. Writing a second row
///   for the same transmission would double every probe in the reach query, so
///   `probeAttempt` *is* the `sent` row for probes and queries over our transmissions must
///   read both kinds.
///
/// **The hash arrives late.** The firmware builds the packet, so there is no content hash
/// at send time; the echo reveals it (`Message.packetContentHash`, stamped by the RX
/// correlation) and `.heardRepeatRecorded` is the moment to copy it onto the row. A
/// message nobody repeats keeps a hash-less row, which is not a gap: reach matches our own
/// transmissions by public key and time, never by hash (§2, §4).
@MainActor
final class MapperSentPacketLogger {
  /// How many recently-logged message ids are remembered, to keep `.sent` followed by
  /// `.delivered` from booking one transmission twice.
  ///
  /// Bounded because it only has to outlive the seconds between a send's two status
  /// resolutions; a ledger that grew for the life of the app would be a list of every
  /// message ever sent, held in memory for no further purpose.
  static let sendLedgerLimit = 256

  private let recorder: any MapperRawSampleRecording
  private let store: MapperRawLogStore
  private let fixProvider: any MapperFixProviding
  private let messages: any MessagePersisting
  private let now: @Sendable () -> Date

  private var subscription: Task<Void, Never>?
  private var loggedSends: Set<UUID> = []
  private var loggedOrder: [UUID] = []

  /// Whether the event subscription is live. Read by the wiring so a reconnect does not
  /// tear down and rebuild a subscription that is already working.
  var isRunning: Bool {
    subscription != nil
  }

  init(
    recorder: any MapperRawSampleRecording,
    store: MapperRawLogStore,
    fixProvider: any MapperFixProviding,
    messages: any MessagePersisting,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.recorder = recorder
    self.store = store
    self.fixProvider = fixProvider
    self.messages = messages
    self.now = now
  }

  deinit {
    subscription?.cancel()
  }

  // MARK: - Lifecycle

  /// Subscribes to the app's message events. Idempotent: a second call replaces the
  /// subscription rather than doubling it, which is what a re-wire on reconnect does.
  func start(events: AsyncStream<MessageEvent>) {
    subscription?.cancel()
    subscription = Task { [weak self] in
      for await event in events {
        if Task.isCancelled { break }
        await self?.handle(event)
      }
    }
  }

  func stop() {
    subscription?.cancel()
    subscription = nil
  }

  // MARK: - Events

  /// Exhaustive on purpose (the `MessageEvent` doc asks for it): a new case has to be
  /// classified as "is this one of our transmissions" rather than silently ignored.
  func handle(_ event: MessageEvent) async {
    switch event {
    case let .messageStatusResolved(messageID, status, _):
      guard status == .sent || status == .delivered else { return }
      guard noteSend(messageID) else { return }
      await recordMessageSend(messageID: messageID)

    case let .messageResent(messageID):
      // A second transmission of the same content, and its own row: the ledger is not
      // consulted, because this is not the duplicate the ledger exists to suppress.
      await recordMessageSend(messageID: messageID)

    case let .heardRepeatRecorded(messageID, _):
      await backFillContentHash(messageID: messageID)

    case .directMessageReceived, .channelMessageReceived, .roomMessageReceived,
         .messageFailed, .messageRetrying, .reactionReceived, .messagesRegionUpdated,
         .routingChanged, .roomMessageStatusUpdated, .roomMessageFailed:
      break
    }
  }

  /// Records the advert the radio has just accepted. Both the flood and the zero-hop
  /// variants are transmissions from this hexagon, and the row does not distinguish them:
  /// what reach asks is "did anybody hear us from here", and a zero-hop advert answers it
  /// as well as a flood does.
  func recordAdvertSend() async {
    await recordSend(payloadType: .advert, messageID: nil)
  }

  // MARK: - Internals

  private func recordMessageSend(messageID: UUID) async {
    // The payload type is the one thing the event does not carry, and it is worth one
    // indexed read: a channel broadcast and a DM are different packets on the air and the
    // export has to be able to tell them apart.
    let message = try? await messages.fetchMessage(id: messageID)
    let payloadType: PayloadType? = message.map { $0.channelIndex == nil ? .textMessage : .groupText }
    await recordSend(payloadType: payloadType, messageID: messageID)
  }

  private func recordSend(payloadType: PayloadType?, messageID: UUID?) async {
    let at = now()
    var event = MapperRawSampleEvent(
      timestamp: at,
      kind: .sent,
      payloadTypeRaw: payloadType?.rawValue,
      messageID: messageID
    )

    // The same fix source the capture engine reads, so a `sent` row and the packets heard
    // around it agree about where the phone was. No fix is a recorded fact, not a reason
    // to drop the row — "we transmitted from somewhere unknown" is still evidence that a
    // later observer sighting can be matched against by time.
    if let fix = await fixProvider.latestFix() {
      event.setFix(fix, at: at)
      let cell = SurveyGrid.cell(
        containing: GeoCoordinate(latitude: fix.latitude, longitude: fix.longitude)
      )
      event.cellRaw = cell?.rawValue
      event.gateOutcome = cell == nil ? .noFix : .accepted
    } else {
      event.gateOutcome = .noFix
    }

    await recorder.record(event)
  }

  private func backFillContentHash(messageID: UUID) async {
    guard let message = try? await messages.fetchMessage(id: messageID),
          let contentHash = message.packetContentHash else { return }
    _ = try? await store.setContentHash(messageID: messageID, contentHash: contentHash)
  }

  /// True the first time a message id is seen, false for the `.delivered` that follows its
  /// `.sent`.
  private func noteSend(_ messageID: UUID) -> Bool {
    guard loggedSends.insert(messageID).inserted else { return false }
    loggedOrder.append(messageID)
    if loggedOrder.count > Self.sendLedgerLimit {
      let evicted = loggedOrder.removeFirst()
      loggedSends.remove(evicted)
    }
    return true
  }
}
