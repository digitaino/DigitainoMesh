import Foundation

/// Notification that a heard repeat was recorded for a channel message.
///
/// Broadcast by `HeardRepeatsService.events()`. The stream is multicast:
/// every subscriber receives every event.
///
/// The event carries the whole repeat row, not just the counter. The service already
/// builds a `MessageRepeatDTO` — path, SNR, RSSI, receive time — one line before it
/// yields, and re-deriving any of that from the counter would mean a second trip through
/// the RX log for data that was in hand. The chat side reads `messageID`/`count`; the
/// signal mapper reads the measurement (docs/SIGNAL_MAPPER_V2.md §2.1, "TX-heard").
public struct HeardRepeatEvent: Sendable {
  /// The message the repeat was correlated to.
  public let messageID: UUID
  /// The message's updated heard-repeat count.
  public let count: Int
  /// The repeat row just written: which path the copy took, and what our radio measured
  /// of it.
  public let detail: MessageRepeatDTO
  /// Whether the copy arrived flood-routed. Lives here rather than on ``MessageRepeatDTO``
  /// because the stored row has never needed it; it is a property of the packet our radio
  /// heard, and only a consumer classifying route mix (the mapper) asks for it.
  public let isFlood: Bool
  /// True for an echo of a message this radio sent: a repeater heard us. False for an
  /// extra incoming path of someone else's message, which says nothing about our reach —
  /// the mapper must never count it as "heard us here".
  public let isSentEcho: Bool

  public init(messageID: UUID, count: Int, detail: MessageRepeatDTO, isFlood: Bool, isSentEcho: Bool) {
    self.messageID = messageID
    self.count = count
    self.detail = detail
    self.isFlood = isFlood
    self.isSentEcho = isSentEcho
  }
}
