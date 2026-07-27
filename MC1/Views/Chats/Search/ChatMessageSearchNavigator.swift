import Foundation
import MC1Services

/// Brings a message into the loaded timeline window and flashes it once it is there.
///
/// `TiledScrollPosition.scrollTo(id:)` silently does nothing for an id that is not in the
/// items array, and the timeline only holds the pages it has fetched — so a search result
/// from six months back needs the intervening history paged in before a scroll request
/// means anything. That is the whole job here: page until the target appears, give up when
/// there is no more history or the budget runs out, and never spin.
///
/// The budget matters. Paging is a store fetch plus a full rebake per page, and a query
/// that matched something very old could otherwise walk the entire conversation while the
/// user waits on a frozen screen.
@MainActor
enum ChatMessageSearchNavigator {
  /// How long paging may run before the jump is abandoned.
  static let pagingBudget: Duration = .seconds(10)

  /// How long the flash stays on the row.
  static let highlightDuration: Duration = .milliseconds(1400)

  enum Outcome: Equatable {
    /// The target is in the window; the caller may scroll to it.
    case loaded
    /// Paging ran out of history without finding it — the message was deleted, or belongs
    /// to a conversation the timeline has since been rebound to.
    case notFound
    /// The budget expired first. The caller leaves the timeline where it is rather than
    /// jumping somewhere arbitrary.
    case timedOut
  }

  /// Pages older messages in until `messageID` is loaded.
  static func loadUntilVisible(_ messageID: UUID, in viewModel: ChatViewModel) async -> Outcome {
    if viewModel.itemIndexByID[messageID] != nil { return .loaded }

    let deadline = ContinuousClock.now + pagingBudget
    while viewModel.itemIndexByID[messageID] == nil {
      guard viewModel.hasMoreMessages else { return .notFound }
      guard ContinuousClock.now < deadline else { return .timedOut }
      guard !Task.isCancelled else { return .timedOut }
      await viewModel.loadOlderMessages()
    }
    return .loaded
  }

  /// Flashes the row, then clears it.
  ///
  /// The flag lives on `MessageItem` so the bubble's `Equatable` short-circuit sees the
  /// change; writing it anywhere else would leave the row looking identical and never
  /// repaint. A rebake between set and clear drops the flag on its own, which is fine —
  /// the flash is meant to be transient either way.
  static func flash(_ messageID: UUID, in viewModel: ChatViewModel) async {
    guard let writer = viewModel.timelineWriter else { return }
    writer.updateRenderItem(id: messageID) { $0.with(isSearchHighlighted: true) }
    try? await Task.sleep(for: highlightDuration)
    viewModel.timelineWriter?.updateRenderItem(id: messageID) { $0.with(isSearchHighlighted: false) }
  }
}
