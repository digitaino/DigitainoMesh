import Foundation

/// One message matching a search, carrying only what a result row draws.
///
/// Search reads across every conversation at once, so a global query can touch thousands
/// of rows; `MessageDTO` has forty fields, most of them — link-preview image data, ACK
/// bookkeeping, retry counters — irrelevant to a snippet. This is the projection the
/// store returns instead.
public struct MessageSearchResult: Sendable, Identifiable, Hashable {
  /// The message's own id, so a tap can scroll the conversation to it.
  public let id: UUID
  /// Full message text. The snippet window is computed at display time, because it
  /// depends on the query and on how much room the row has.
  public let text: String
  public let createdAt: Date
  /// The ordering date the timeline itself uses, so results and timeline agree.
  public let sortDate: Date
  /// Set for a direct message; `nil` for a channel message.
  public let contactID: UUID?
  /// Set for a channel message; `nil` for a direct message.
  public let channelIndex: UInt8?
  public let radioID: UUID
  /// Who sent it, when that is someone other than this radio.
  public let senderNodeName: String?
  public let directionRawValue: Int

  public var isOutgoing: Bool {
    directionRawValue == MessageDirection.outgoing.rawValue
  }

  /// Which conversation this result belongs to, for grouping results and for routing a tap.
  public var conversation: Scope {
    if let contactID { return .direct(contactID: contactID) }
    if let channelIndex { return .channel(index: channelIndex) }
    return .unattached
  }

  /// The conversation a result lives in.
  public enum Scope: Sendable, Hashable {
    case direct(contactID: UUID)
    case channel(index: UInt8)
    /// Neither a contact nor a channel — a malformed row. Kept as a case rather than a
    /// crash so one bad row cannot take out the whole result list.
    case unattached
  }

  public init(
    id: UUID,
    text: String,
    createdAt: Date,
    sortDate: Date,
    contactID: UUID?,
    channelIndex: UInt8?,
    radioID: UUID,
    senderNodeName: String?,
    directionRawValue: Int
  ) {
    self.id = id
    self.text = text
    self.createdAt = createdAt
    self.sortDate = sortDate
    self.contactID = contactID
    self.channelIndex = channelIndex
    self.radioID = radioID
    self.senderNodeName = senderNodeName
    self.directionRawValue = directionRawValue
  }
}
