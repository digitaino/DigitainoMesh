import Foundation
import SwiftData

extension PersistenceStore: MessageSearching {}

public extension PersistenceStore {
  // MARK: - Global Search

  /// Messages matching `query` across every conversation on a radio, newest first.
  ///
  /// Ordering mirrors ``fetchMessages(contactID:limit:offset:)`` — `sortDate`, then
  /// `timestamp`, then `createdAt` — so a result and the timeline row it scrolls to
  /// never disagree about which of two near-simultaneous messages came first.
  func searchMessages(radioID: UUID, query: String, limit: Int = MessageSearchLimits.globalPageSize, offset: Int = 0) throws -> [MessageSearchResult] {
    guard let predicate = Self.searchPredicate(radioID: radioID, query: query) else { return [] }
    var descriptor = FetchDescriptor(
      predicate: predicate,
      sortBy: [
        SortDescriptor(\Message.sortDate, order: .reverse),
        SortDescriptor(\Message.timestamp, order: .reverse),
        SortDescriptor(\Message.createdAt, order: .reverse)
      ]
    )
    descriptor.fetchLimit = limit
    descriptor.fetchOffset = offset

    return try modelContext.fetch(descriptor).map(MessageSearchResult.init(from:))
  }

  /// How many messages match across every conversation, ignoring any page limit.
  func searchMessagesCount(radioID: UUID, query: String) throws -> Int {
    guard let predicate = Self.searchPredicate(radioID: radioID, query: query) else { return 0 }
    return try modelContext.fetchCount(FetchDescriptor(predicate: predicate))
  }

  // MARK: - Within One Conversation

  /// Ids of matching messages in a direct-message conversation, oldest first.
  func searchMessageIDs(contactID: UUID, query: String, limit: Int = MessageSearchLimits.conversationMatches) throws -> [UUID] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let targetContactID: UUID? = contactID
    let predicate = #Predicate<Message> { message in
      message.contactID == targetContactID && message.text.localizedStandardContains(trimmed)
    }
    return try conversationMatchIDs(predicate: predicate, limit: limit)
  }

  /// Ids of matching messages in a channel conversation, oldest first.
  func searchMessageIDs(radioID: UUID, channelIndex: UInt8, query: String, limit: Int = MessageSearchLimits.conversationMatches) throws -> [UUID] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let targetRadioID = radioID
    let targetChannelIndex: UInt8? = channelIndex
    let predicate = #Predicate<Message> { message in
      message.radioID == targetRadioID
        && message.channelIndex == targetChannelIndex
        && message.text.localizedStandardContains(trimmed)
    }
    return try conversationMatchIDs(predicate: predicate, limit: limit)
  }

  // MARK: - Helpers

  /// Chronological ids for a conversation-scoped predicate. Oldest first, because
  /// previous/next navigation steps forward through history.
  private func conversationMatchIDs(predicate: Predicate<Message>, limit: Int) throws -> [UUID] {
    var descriptor = FetchDescriptor(
      predicate: predicate,
      sortBy: [
        SortDescriptor(\Message.sortDate, order: .forward),
        SortDescriptor(\Message.timestamp, order: .forward),
        SortDescriptor(\Message.createdAt, order: .forward)
      ]
    )
    descriptor.fetchLimit = limit
    return try modelContext.fetch(descriptor).map(\.id)
  }

  /// The global-search predicate, or `nil` when the query is blank and there is nothing
  /// to ask the store.
  private static func searchPredicate(radioID: UUID, query: String) -> Predicate<Message>? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let targetRadioID = radioID
    return #Predicate<Message> { message in
      message.radioID == targetRadioID && message.text.localizedStandardContains(trimmed)
    }
  }
}

private extension MessageSearchResult {
  init(from message: Message) {
    self.init(
      id: message.id,
      text: message.text,
      createdAt: message.createdAt,
      sortDate: message.sortDate,
      contactID: message.contactID,
      channelIndex: message.channelIndex,
      radioID: message.radioID,
      senderNodeName: message.senderNodeName,
      directionRawValue: message.directionRawValue
    )
  }
}
