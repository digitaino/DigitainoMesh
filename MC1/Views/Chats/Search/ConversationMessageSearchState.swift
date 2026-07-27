import Foundation
import MC1Services

/// Find-in-conversation state: the query, the ids it matched, and which one the user is
/// standing on.
///
/// It holds ids rather than messages because the timeline already has the content; what
/// the bar needs is positions to step through, and what the list needs is a target to
/// scroll to. Matches come back oldest-first, so "next" walks forward through history the
/// way the conversation reads.
@Observable
@MainActor
final class ConversationMessageSearchState {
  /// Whether the search bar is showing.
  var isActive = false

  /// Live search-field text.
  var query = ""

  private(set) var matchIDs: [UUID] = []
  private(set) var currentIndex = 0
  private(set) var isLoading = false

  /// The query `matchIDs` was produced for, so the counter never describes stale results.
  private(set) var resolvedQuery = ""

  var matchCount: Int {
    matchIDs.count
  }

  /// The match the user is on, or `nil` when nothing matched.
  var currentMatchID: UUID? {
    matchIDs.indices.contains(currentIndex) ? matchIDs[currentIndex] : nil
  }

  /// Human position of the current match, 1-based; zero when there are none.
  var currentPosition: Int {
    matchIDs.isEmpty ? 0 : currentIndex + 1
  }

  var canStep: Bool {
    matchIDs.count > 1
  }

  /// Whether the bar should say "no results" — a settled search that found nothing.
  var hasSettledWithNoMatches: Bool {
    !isLoading && matchIDs.isEmpty && !resolvedQuery.isEmpty
  }

  /// Runs the conversation-scoped query.
  ///
  /// Opens on the *last* match rather than the first: the user is looking at the bottom of
  /// a conversation and searching backwards through it, so the newest hit is the nearest
  /// one and reaching it needs no paging.
  func run(
    query: String,
    conversation: ChatConversationType?,
    store: (any MessageSearching)?
  ) async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let conversation, let store else {
      reset()
      return
    }

    isLoading = true
    defer { isLoading = false }

    let found: [UUID]
    do {
      switch conversation {
      case let .dm(contact):
        found = try await store.searchMessageIDs(contactID: contact.id, query: trimmed)
      case let .channel(channel):
        found = try await store.searchMessageIDs(
          radioID: channel.radioID,
          channelIndex: channel.index,
          query: trimmed
        )
      }
    } catch {
      reset(resolvedQuery: trimmed)
      return
    }

    guard !Task.isCancelled else { return }
    matchIDs = found
    currentIndex = max(0, found.count - 1)
    resolvedQuery = trimmed
  }

  /// Moves `offset` matches forward (positive) or back, wrapping at both ends so stepping
  /// never dead-ends on a long conversation.
  func step(_ offset: Int) {
    guard !matchIDs.isEmpty else { return }
    let count = matchIDs.count
    currentIndex = ((currentIndex + offset) % count + count) % count
  }

  /// Closes the bar and forgets the search.
  func dismiss() {
    isActive = false
    query = ""
    reset()
  }

  private func reset(resolvedQuery: String = "") {
    matchIDs = []
    currentIndex = 0
    self.resolvedQuery = resolvedQuery
  }
}
