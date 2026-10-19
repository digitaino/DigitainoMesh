import Foundation

/// Session operations for sending direct and channel messages.
public protocol MessagingSessionOps: Actor {
  /// Returns the device's self info after session start.
  ///
  /// Populated once the session handshake completes; `nil` before that.
  var currentSelfInfo: SelfInfo? { get }

  /// Sends a direct message to a contact.
  ///
  /// - Parameters:
  ///   - destination: The recipient's public key (6-byte prefix).
  ///   - text: The message text to send.
  ///   - timestamp: The timestamp of the message.
  ///   - attempt: Retry attempt counter (0 for first attempt). Included in ACK hash.
  /// - Returns: A `MessageSentInfo` object containing information about the sent message, including the ACK code.
  /// - Throws: `MeshCoreError` if the message fails to send or the device returns an error.
  func sendMessage(
    to destination: Data,
    text: String,
    timestamp: Date,
    attempt: UInt8
  ) async throws -> MessageSentInfo

  /// Sends a message to a channel.
  ///
  /// - Parameters:
  ///   - channel: The channel index (0-7).
  ///   - text: The message text to send.
  ///   - timestamp: The timestamp of the message.
  /// - Throws: `MeshCoreError` if the channel message fails to send.
  func sendChannelMessage(
    channel: UInt8,
    text: String,
    timestamp: Date
  ) async throws

  /// Sends a binary datagram to a channel (`CMD_SEND_CHANNEL_DATA`, 0x3E).
  ///
  /// Requires firmware v11+ (MeshCore v1.15.0+); older firmware has no such command. The
  /// counterpart of the `GRP_DATA` packets the radio delivers as
  /// ``MeshEvent/channelDataReceived(_:)``, and the way an app puts one of its own on the
  /// channel — MeshWX's `>` requests are the first (docs/MESHWX.md, "Requests").
  ///
  /// - Parameters:
  ///   - channelIndex: The channel slot index.
  ///   - dataType: Application data-type namespace. `0x0000` is rejected by firmware;
  ///     `0xFF00-0xFFFF` is the developer namespace.
  ///   - payload: Binary payload, clamped to 163 bytes by the builder.
  ///   - pathLength: Encoded `path_len` byte; `0xFF` (``PacketBuilder/floodPathSentinel``)
  ///     floods, which is what a datagram to nobody in particular wants.
  ///   - pathBytes: Path bytes, written verbatim and ignored when flooding.
  /// - Throws: `MeshCoreError` if the datagram fails to send.
  func sendChannelData(
    channelIndex: UInt8,
    dataType: UInt16,
    payload: Data,
    pathLength: UInt8,
    pathBytes: Data
  ) async throws
}

// MARK: - Default Implementations

public extension MessagingSessionOps {
  /// Sends a direct message with default attempt counter of 0.
  func sendMessage(
    to destination: Data,
    text: String,
    timestamp: Date
  ) async throws -> MessageSentInfo {
    try await sendMessage(to: destination, text: text, timestamp: timestamp, attempt: 0)
  }
}
