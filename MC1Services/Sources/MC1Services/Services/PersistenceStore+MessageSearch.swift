import Foundation
import SwiftData

extension PersistenceStore: MessageSearching {}

public extension PersistenceStore {
  // MARK: - Global Search

  /// Messages matching `query` across every conversation on a radio, newest first.
  ///
  /// Ordering mirrors ``fetchMessages(contactID:limit:offset:)`` — `sortDate`, then
  /// `timestamp`, then `createdAt` — so a result and the timeline row it scrolls to
  /// never disagree about which of two near-simultaneous messages came first. Rows the
  /// timeline hides are dropped for the same reason: a result must be openable.
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

    // Carriers can only be recognized after the fetch, so a raw page can be all but empty
    // once they are dropped. Refill from further down the history until the page is full or
    // the store runs dry, which is what lets a short return mean "these are all the matches
    // there are" — the caller reads it that way instead of running a second, unbounded count
    // query. Bounded: a query that matches mostly carriers ("reacted", "👍") would otherwise
    // walk the entire history at one offset scan per page to fill fifty rows.
    var results: [MessageSearchResult] = []
    var cursor = offset
    for _ in 0..<MessageSearchLimits.carrierRefillPasses {
      guard results.count < limit else { break }
      descriptor.fetchOffset = cursor
      let page = try modelContext.fetch(descriptor)
      cursor += page.count
      results += page
        .lazy
        .filter { !Self.isHiddenReactionCarrier($0) }
        .map(MessageSearchResult.init(from:))
      guard page.count == limit else { break }
    }
    return Array(results.prefix(limit))
  }

  /// How many messages match across every conversation, ignoring any page limit. Counts raw
  /// matches — carriers included — so it can exceed what ``searchMessages`` returns.
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
  ///
  /// Fetched newest-first and reversed in memory so `limit` truncates the *oldest* end: the
  /// bar opens on the newest match, so that is the end that has to be complete.
  private func conversationMatchIDs(predicate: Predicate<Message>, limit: Int) throws -> [UUID] {
    var descriptor = FetchDescriptor(
      predicate: predicate,
      sortBy: [
        SortDescriptor(\Message.sortDate, order: .reverse),
        SortDescriptor(\Message.timestamp, order: .reverse),
        SortDescriptor(\Message.createdAt, order: .reverse)
      ]
    )
    descriptor.fetchLimit = limit

    let matches = try modelContext.fetch(descriptor)
      .reversed()
      .filter { !Self.isHiddenReactionCarrier($0) }
      .map { MessageDTO(from: $0, includeLinkPreviewBlobs: false) }
    // The timeline reorders narrow same-sender clusters by sender timestamp, so ids in raw
    // sort order can step visually backwards. Clusters here are formed over the matches
    // alone; a non-matching row from another sender splits a cluster that this view of the
    // conversation cannot see, which no fetch limited to the matches could fix.
    return MessageDTO.reorderSameSenderClusters(matches).map(\.id)
  }

  /// Whether a row is an outgoing reaction carrier the timeline hides, mirroring
  /// `ChatMessageBakeState.isHiddenOutgoingReaction`.
  ///
  /// Reaction wire text quotes the target text verbatim, so every hit on a reacted-to
  /// message hits its carrier too — and a carrier is never in the timeline, so a result
  /// pointing at one pages the whole conversation and then fails to scroll. Failed carriers
  /// are excluded from the exclusion: the timeline shows those so they can be retried.
  private static func isHiddenReactionCarrier(_ message: Message) -> Bool {
    guard message.direction == .outgoing, message.status != .failed else { return false }
    return message.isChannelMessage
      ? ReactionParser.parse(message.text) != nil
      : ReactionParser.parseDM(message.text) != nil
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
