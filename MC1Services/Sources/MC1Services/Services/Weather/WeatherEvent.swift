import Foundation
import MeshWX

/// A request the app has on the air, waiting for the bot's answer on `#meshwx`.
public struct WeatherPendingRequest: Sendable, Hashable, Identifiable {
  public let id: UUID
  public let request: WeatherRequest
  public let botID: UInt16
  public let botPublicKey: Data
  public var sentAt: Date
  /// 0 for the first transmission, 1 for the one retry spec §8.2 allows.
  public var attempt: Int

  public init(
    id: UUID = UUID(),
    request: WeatherRequest,
    botID: UInt16,
    botPublicKey: Data,
    sentAt: Date,
    attempt: Int = 0
  ) {
    self.id = id
    self.request = request
    self.botID = botID
    self.botPublicKey = botPublicKey
    self.sentAt = sentAt
    self.attempt = attempt
  }
}

/// How a request ended.
public enum WeatherRequestOutcome: Sendable, Hashable {
  /// The expected answer arrived and is in state.
  case answered
  /// Nothing was sent: the same answer — to this phone or anyone else on the channel — arrived
  /// at `receivedAt`, within the last five minutes, and the bot would only re-send the cached
  /// bytes (spec §13). `receivedAt` is the phone's clock, which is what the bot's cache runs
  /// from; `contentAsOf` is what the answer was as of on the bot's clock where the message says —
  /// a list's build time, a batch's observation time, a forecast's issue time — and nil for a
  /// warning or a text.
  case servedFromCache(receivedAt: Date, contentAsOf: Date?)
  /// The bot said it cannot serve this (spec §8.3).
  case notAvailable(MeshWXNotAvailableReason)
  /// No answer. `botWasHeard`: the bot was heard live after the request went out, so it is in
  /// range and the answer was lost or never sent — the request is not repeated into a busy
  /// channel. Otherwise nothing came from the bot through one retry: it may be out of range. A
  /// backlog drained from the radio's queue meanwhile does not count as hearing it.
  case timedOut(botWasHeard: Bool)
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
  case received(botID: UInt16, message: MeshWXMessage, changes: [WeatherStateChange])
  case requestSent(WeatherPendingRequest)
  case requestSettled(WeatherPendingRequest, WeatherRequestOutcome)
}
