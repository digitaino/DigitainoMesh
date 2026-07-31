import Foundation
import MC1Services

/// Global message search for the chats list: runs the store query, groups the hits by
/// conversation, and remembers which groups the user has expanded.
///
/// Results are grouped rather than listed flat because a query like "yes" matches the same
/// handful of conversations dozens of times, and an ungrouped list buries every other
/// conversation under whichever one is chattiest. Each group shows a few rows until the
/// user asks for the rest.
@Observable
@MainActor
final class MessageSearchViewModel {
  /// Rows shown per conversation before the user expands the group.
  static let collapsedGroupSize = 3

  /// One conversation's hits.
  struct Group: Identifiable {
    let id: MessageSearchResult.Scope
    /// Conversation display name, resolved against the chat list.
    let name: String
    let results: [MessageSearchResult]

    /// The most recent hit, which is what the group sorts on.
    var mostRecent: Date {
      results.first?.sortDate ?? .distantPast
    }
  }

  private(set) var groups: [Group] = []
  /// Whether the store had more matches than this page carried, so the header can say
  /// "showing first N" instead of a total. There is no honest cheap total to show: the page
  /// is capped, and carriers are filtered after the fetch, so a store-side count would
  /// disagree with the list it is captioning.
  private(set) var hasMoreThanLoaded = false
  private(set) var isLoading = false
  /// The query the current `groups` were produced for; guards against showing stale hits
  /// under a query the user has already changed.
  private(set) var resolvedQuery = ""

  private var expandedGroups: Set<MessageSearchResult.Scope> = []

  /// Matches on screen, after grouping dropped the ones no conversation claims.
  var loadedCount: Int {
    groups.reduce(0) { $0 + $1.results.count }
  }

  func isExpanded(_ scope: MessageSearchResult.Scope) -> Bool {
    expandedGroups.contains(scope)
  }

  func expand(_ scope: MessageSearchResult.Scope) {
    expandedGroups.insert(scope)
  }

  /// The rows a group currently shows, and how many it is holding back.
  func visibleResults(in group: Group) -> (shown: ArraySlice<MessageSearchResult>, hidden: Int) {
    guard !isExpanded(group.id), group.results.count > Self.collapsedGroupSize else {
      return (group.results[...], 0)
    }
    return (group.results.prefix(Self.collapsedGroupSize), group.results.count - Self.collapsedGroupSize)
  }

  /// Runs the query and rebuilds the groups.
  ///
  /// - Parameter conversationName: Resolves a scope to a display name; a scope the chat
  ///   list no longer knows about (a deleted contact whose messages survive) is dropped
  ///   rather than shown as an untappable, unnamed row.
  func search(
    query: String,
    radioID: UUID?,
    store: (any MessageSearching)?,
    conversationName: (MessageSearchResult.Scope) -> String?
  ) async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let radioID, let store else {
      clear()
      return
    }

    isLoading = true
    defer { isLoading = false }

    do {
      let results = try await store.searchMessages(radioID: radioID, query: trimmed)
      guard !Task.isCancelled else { return }
      groups = Self.group(results, name: conversationName)
      // A short page is every match there is, so nothing else has to be asked of the store —
      // the count query is an unindexable full scan on the one persistence actor, and it ran
      // per settled keystroke. (A query matching mostly reaction carriers can return a short
      // page with more behind it; the cost of that is one missing caption.)
      hasMoreThanLoaded = results.count >= MessageSearchLimits.globalPageSize
    } catch {
      // A failed search shows nothing rather than the previous query's hits.
      groups = []
      hasMoreThanLoaded = false
    }
    expandedGroups.removeAll()
    resolvedQuery = trimmed
  }

  func clear() {
    groups = []
    hasMoreThanLoaded = false
    expandedGroups.removeAll()
    resolvedQuery = ""
  }

  /// Groups newest-first results by conversation, keeping both the groups and the rows
  /// inside them in the order the store returned.
  private static func group(
    _ results: [MessageSearchResult],
    name: (MessageSearchResult.Scope) -> String?
  ) -> [Group] {
    var order: [MessageSearchResult.Scope] = []
    var byScope: [MessageSearchResult.Scope: [MessageSearchResult]] = [:]

    for result in results {
      let scope = result.conversation
      guard scope != .unattached else { continue }
      if byScope[scope] == nil { order.append(scope) }
      byScope[scope, default: []].append(result)
    }

    return order.compactMap { scope in
      guard let name = name(scope), let results = byScope[scope] else { return nil }
      return Group(id: scope, name: name, results: results)
    }
  }
}
