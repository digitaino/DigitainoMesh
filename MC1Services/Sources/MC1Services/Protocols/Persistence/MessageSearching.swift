import Foundation

/// Store-level full-text queries over message rows.
///
/// Deliberately a role of its own rather than a member of ``PersistenceStoreProtocol``:
/// the search surfaces are the only consumers, and declaring `any MessageSearching`
/// keeps their signatures honest about how little of the store they touch — which is the
/// convention ``PersistenceStoreProtocol`` itself documents.
///
/// Searching is a store query, never an in-memory filter. A radio that has been running
/// for months holds far more history than the timeline ever loads, so filtering the
/// loaded window would quietly return "no results" for anything older than the last page.
public protocol MessageSearching: Actor {
  /// Messages matching `query` across every conversation on a radio, newest first.
  ///
  /// - Parameters:
  ///   - limit: Hard cap on rows returned. Always bounded — a bare substring query can
  ///     match a large fraction of the history.
  ///   - offset: Rows to skip, for paging a long result list.
  /// - Returns: An empty array for a blank query; matching a blank query against every
  ///   row is never what a caller wants.
  func searchMessages(radioID: UUID, query: String, limit: Int, offset: Int) async throws -> [MessageSearchResult]

  /// How many messages match across every conversation, ignoring `limit`.
  /// Lets a result list say "showing 50 of 312" and offer to page.
  func searchMessagesCount(radioID: UUID, query: String) async throws -> Int

  /// Message ids matching `query` inside one direct-message conversation, oldest first.
  ///
  /// Ids rather than rows, and chronological rather than newest-first, because the
  /// in-conversation search steps through matches with previous/next: it needs the
  /// positions, and the timeline already holds the content.
  func searchMessageIDs(contactID: UUID, query: String, limit: Int) async throws -> [UUID]

  /// Message ids matching `query` inside one channel conversation, oldest first.
  func searchMessageIDs(radioID: UUID, channelIndex: UInt8, query: String, limit: Int) async throws -> [UUID]
}

// MARK: - Default Parameter Values

public extension MessageSearching {
  /// Global search with the default page size and no offset.
  func searchMessages(radioID: UUID, query: String) async throws -> [MessageSearchResult] {
    try await searchMessages(radioID: radioID, query: query, limit: MessageSearchLimits.globalPageSize, offset: 0)
  }

  /// In-conversation search with the default cap.
  func searchMessageIDs(contactID: UUID, query: String) async throws -> [UUID] {
    try await searchMessageIDs(contactID: contactID, query: query, limit: MessageSearchLimits.conversationMatches)
  }

  /// In-conversation search with the default cap.
  func searchMessageIDs(radioID: UUID, channelIndex: UInt8, query: String) async throws -> [UUID] {
    try await searchMessageIDs(radioID: radioID, channelIndex: channelIndex, query: query, limit: MessageSearchLimits.conversationMatches)
  }
}

/// The caps message search runs under.
public enum MessageSearchLimits {
  /// Rows fetched per page of global results.
  public static let globalPageSize = 50

  /// Ceiling on matches collected for one conversation's previous/next navigation.
  /// Past this many hits in a single conversation the query is not selective enough for
  /// stepping through to be useful anyway.
  public static let conversationMatches = 500
}
