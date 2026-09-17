import Foundation
import MeshWX

/// How a request went out (spec §7B, §8.2). Both carry the same `>` text and both are answered
/// on `#meshwx`; what differs is whether a stored route has to be right.
public enum WeatherRequestTransportKind: Sendable, Hashable, Codable {
  /// A Request datagram, flooded on `#meshwx`. The normal path since spec revision 6: no route
  /// to go stale, and no acknowledgement either — the answer is the acknowledgement.
  case channel
  /// A DM to the bot's public key, the ladder of spec §8.2. The fallback, for a radio that
  /// cannot send channel datagrams at all.
  case dm
}

/// A request the app has on the air, waiting for the bot's answer on `#meshwx`.
public struct WeatherPendingRequest: Sendable, Hashable, Identifiable {
  public let id: UUID
  public let request: WeatherRequest
  public let botID: UInt16
  public let botPublicKey: Data
  public var sentAt: Date
  /// How it went out. Defaults to `.dm`, so anything built before the channel path still reads
  /// as what it was.
  public let transportKind: WeatherRequestTransportKind
  /// 0 for the first transmission, 1 for the one retry spec §8.2 allows; on the DM ladder 2 is
  /// the flood after the route is forgotten. A channel request never goes past 1 (spec §7B:
  /// send once, once more after 10 s, never a third time).
  public var attempt: Int
  /// The timestamp on the wire, the same for every transmission: with attempt 0 then 1 the
  /// retry is one message sent again to the bot's radio, and the same request to the bot. A
  /// Request datagram carries it as its `ts`, which is exactly what makes a resend a copy.
  public let timestamp: Date
  /// The sender's own sequence number, on a channel request only (spec §7B), repeated on the
  /// resend. 0 and meaningless for a DM.
  public let seq: UInt8
  /// The ACK code the radio expects back for each transmission. Empty for a channel request:
  /// a datagram has no acknowledgement.
  public var ackCodes: Set<Data>
  /// The radio confirmed (an ACK for either transmission) that the bot's radio received the
  /// request. Says nothing about the answer, and never true for a channel request.
  public var botRadioReceived: Bool

  /// - Parameter timestamp: the wire timestamp; defaults to `sentAt`.
  public init(
    id: UUID = UUID(),
    request: WeatherRequest,
    botID: UInt16,
    botPublicKey: Data,
    sentAt: Date,
    transportKind: WeatherRequestTransportKind = .dm,
    attempt: Int = 0,
    timestamp: Date? = nil,
    seq: UInt8 = 0,
    ackCodes: Set<Data> = [],
    botRadioReceived: Bool = false
  ) {
    self.id = id
    self.request = request
    self.botID = botID
    self.botPublicKey = botPublicKey
    self.sentAt = sentAt
    self.transportKind = transportKind
    self.attempt = attempt
    self.timestamp = timestamp ?? sentAt
    self.seq = seq
    self.ackCodes = ackCodes
    self.botRadioReceived = botRadioReceived
  }
}

/// How a request ended.
public enum WeatherRequestOutcome: Sendable, Hashable {
  /// The expected answer arrived and is in state.
  case answered
  /// Nothing was sent: the same answer — to this phone or anyone else on the channel — arrived
  /// at `receivedAt`, within the last five minutes. The bot keeps no cache: asking again would
  /// have it rebuild and re-transmit what this phone already holds, on everyone's airtime (spec
  /// §13). `receivedAt` is the phone's clock; `contentAsOf` is what the answer was as of on the
  /// bot's clock where the message says — a list's build time, a batch's observation time, a
  /// forecast's issue time — and nil for a warning or a text.
  case alreadyReceived(receivedAt: Date, contentAsOf: Date?)
  /// The bot said it cannot serve this (spec §8.3).
  case notAvailable(MeshWXNotAvailableReason)
  /// No answer. `botWasHeard`: the bot was heard live after the request went out, so it is in
  /// range and the answer was lost, or the bot dropped the request — the request is not
  /// repeated into a busy channel. Otherwise nothing came from the bot through one retry: it may
  /// be out of range, or busy. The bot drops requests silently past one per sender every five
  /// seconds, 60 answer packets an hour across everyone, and for a DM 40 replies per sender an
  /// hour (spec §8.2, §8.3, revision 3); the app cannot tell that from range. A backlog drained
  /// from the radio's queue meanwhile does not count as hearing it.
  ///
  /// `botRadioReceived`: the radio confirmed that the bot's radio received the request (an ACK
  /// for either transmission), so range is not why no answer reached this phone — the bot may be
  /// busy, or its answer was lost. False when nothing confirmed it, which is not proof it did not
  /// arrive: a confirmation can be lost too.
  case timedOut(botWasHeard: Bool, botRadioReceived: Bool = false)
  /// The radio refused the DM (no such contact, not connected, …).
  case failed(String)
}

/// Why a request could not be sent now.
public enum WeatherRequestError: Error, Sendable, Hashable {
  /// Spec §13: at most one request every five seconds.
  case rateLimited(retryAfter: TimeInterval)
  case transport(String)
}

/// What the service knows about the current radio session, for the claims a screen may make:
/// "no alerts" needs a session that was listening when the alert list arrived, and a channel
/// prompt must not appear while `#meshwx` is plainly delivering.
public struct WeatherSessionInfo: Sendable, Hashable {
  /// When datagram monitoring started for this connection; nil with no radio.
  public var startedAt: Date?
  /// The last v5 datagram accepted from the `#meshwx` slot this session.
  public var lastChannelDatagramAt: Date?
  /// v5-typed datagrams dropped because they arrived on a slot that is not `#meshwx`.
  public var foreignDatagramsIgnored: Int

  public init(startedAt: Date? = nil, lastChannelDatagramAt: Date? = nil, foreignDatagramsIgnored: Int = 0) {
    self.startedAt = startedAt
    self.lastChannelDatagramAt = lastChannelDatagramAt
    self.foreignDatagramsIgnored = foreignDatagramsIgnored
  }
}

/// What `WeatherService` tells its observers. Coarse on purpose: a consumer re-reads the
/// bot's state on `received`; the change list is for logging and for anything that wants to
/// react to one rule (a new warning, a completed text).
public enum WeatherEvent: Sendable {
  case stateLoaded
  /// - Parameter isBacklog: the message was drained from the radio's queue at connect rather than
  ///   heard live, so it can be hours old. The alert notifier says so and only notifies for a
  ///   warning that is still active (docs/MESHWX_UI.md §16).
  case received(botID: UInt16, message: MeshWXMessage, changes: [WeatherStateChange], isBacklog: Bool)
  case requestSent(WeatherPendingRequest)
  /// The radio confirmed that the bot's radio received a pending request (`botRadioReceived`).
  case requestReceivedByBotRadio(WeatherPendingRequest)
  case requestSettled(WeatherPendingRequest, WeatherRequestOutcome)
}
