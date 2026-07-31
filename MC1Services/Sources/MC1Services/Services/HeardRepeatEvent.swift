import Foundation

/// Notification that a heard repeat was recorded for a sent channel message.
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
  /// The sent message the repeat was correlated to.
  public let messageID: UUID
  /// The message's updated heard-repeat count.
  public let count: Int
  /// The repeat row just written: which path the echo took, and what our radio measured
  /// of it.
  public let detail: MessageRepeatDTO
  /// Whether the echo arrived flood-routed. Lives here rather than on ``MessageRepeatDTO``
  /// because the stored row has never needed it; it is a property of the packet our radio
  /// heard, and only a consumer classifying route mix (the mapper) asks for it.
  public let isFlood: Bool

  public init(messageID: UUID, count: Int, detail: MessageRepeatDTO, isFlood: Bool) {
    self.messageID = messageID
    self.count = count
    self.detail = detail
    self.isFlood = isFlood
  }
}
