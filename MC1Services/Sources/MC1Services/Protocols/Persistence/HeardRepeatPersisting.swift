import Foundation

/// Store operations for correlating sent channel messages with heard repeats.
public protocol HeardRepeatPersisting: Actor {
  /// Find a sent channel message by exact channel, sender timestamp, and text on the sending radio
  func findSentChannelMessage(radioID: UUID, channelIndex: UInt8, timestamp: UInt32, text: String) async throws -> MessageDTO?

  /// Save a message repeat entry
  func saveMessageRepeat(_ dto: MessageRepeatDTO) async throws

  /// Fetch all repeats for a message
  func fetchMessageRepeats(messageID: UUID) async throws -> [MessageRepeatDTO]

  /// Delete all repeats for a message
  func deleteMessageRepeats(messageID: UUID) async throws

  /// Check if a repeat exists for the given RX log entry
  func messageRepeatExists(rxLogEntryID: UUID) async throws -> Bool

  /// Increment heard repeats count and return new count
  func incrementMessageHeardRepeats(id: UUID) async throws -> Int

  /// Stamp the mesh-wide packet content hash onto a message, first writer wins.
  /// Every echo of one transmission shares the hash, so which echo stamps it is
  /// immaterial — but a hash already present (a retry's echo racing an earlier
  /// attempt's) is never overwritten, keeping the row pinned to one wire packet.
  func setMessagePacketContentHashIfMissing(id: UUID, contentHash: String) async throws

  /// Cache the distinct observer count for a message's packet. The count grows as
  /// more observers report, so unlike the hash every write overwrites, and
  /// `checkedAt` records when the figure was read from the server.
  func setMessageObserverCount(id: UUID, count: Int, checkedAt: Date) async throws

  /// Forget everything this row knows about its packet: the content hash and the
  /// cached observer count with its check time.
  ///
  /// The counterpart to `setMessagePacketContentHashIfMissing`'s first-writer-wins
  /// rule. That rule is right for the echoes of one transmission and wrong for a
  /// resend, which puts a *different* packet on the air under the same message id:
  /// without this the row would keep pointing at the packet that was resent, so
  /// the eye badge and the Network View would describe the previous attempt
  /// forever (Rafael, 2026-09-05: "when we resend a message the eye/network view
  /// does not update"). Clearing all three lets the next echo stamp the new hash.
  func clearMessagePacketScope(id: UUID) async throws

  /// Increment send count and return new count
  func incrementMessageSendCount(id: UUID) async throws -> Int
}
