import Foundation
import MC1Services

extension ChatTimeline {
  // MARK: - Baking

  /// Rebuilds every render item from canonical messages via the shared bake
  /// pipeline. A no-op while unbound; a stale writer drops the build at the
  /// coordinator.
  func rebakeAll() {
    guard let coordinator, let writer else { return }
    bake.bakeAll(
      messages: coordinator.messages,
      writer: writer,
      envInputs: envInputs,
      senderTables: senderTablesProvider(),
      postApply: postApply
    )
  }

  /// Rebuilds a single row's `MessageItem` with current preview, image, and
  /// message state. No-ops when the message is no longer present, or when it
  /// is a collapsed duplicate with no row of its own (a reaction or preview
  /// landing on a hidden copy surfaces when the run expands and rebakes).
  func rebakeRow(_ messageID: UUID) {
    guard let coordinator, let writer else { return }
    let messages = coordinator.messages
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
      logger.warning("rebake requested for missing message id \(messageID)")
      return
    }
    let message = messages[index]
    guard !bake.duplicatePlan.hiddenIDs.contains(messageID) else { return }
    // Previous/next *visible* message, matching `bakeAll`: grouping flags and
    // cluster ends computed against a collapsed copy would disagree with the
    // full pass.
    let previous: MessageDTO? = {
      var cursor = index
      while cursor > 0 {
        cursor -= 1
        let candidate = messages[cursor]
        if !bake.duplicatePlan.hiddenIDs.contains(candidate.id) { return candidate }
      }
      return nil
    }()
    let next: MessageDTO? = {
      var cursor = index
      while cursor + 1 < messages.count {
        cursor += 1
        let candidate = messages[cursor]
        if !bake.duplicatePlan.hiddenIDs.contains(candidate.id) { return candidate }
      }
      return nil
    }()
    writer.updateRenderItem(id: messageID) { _ in
      makeItem(for: message, previous: previous, next: next)
    }
  }

  // MARK: - Duplicate runs

  /// Toggles the duplicate run containing `messageID` between collapsed and
  /// expanded, rebaking so the row set changes in the same call. No-ops for
  /// messages outside any run.
  func toggleDuplicateRun(containing messageID: UUID) {
    guard let leaderID = bake.duplicatePlan.leaderIDByMemberID[messageID] else { return }
    if bake.expandedDuplicateRuns.remove(leaderID) == nil {
      bake.expandedDuplicateRuns.insert(leaderID)
    }
    rebakeAll()
  }

  /// Expands the run hiding `messageID`, if any, so the row exists to scroll
  /// to. Returns true when it expanded (and rebaked); false when the message
  /// already has a row or is not loaded. Search jumps call this before
  /// paging: a collapsed copy is loaded but absent from `itemIndexByID`, and
  /// paging alone would walk to end-of-history without ever finding it.
  @discardableResult
  func revealHiddenDuplicate(_ messageID: UUID) -> Bool {
    guard bake.duplicatePlan.hiddenIDs.contains(messageID),
          let leaderID = bake.duplicatePlan.leaderIDByMemberID[messageID] else { return false }
    bake.expandedDuplicateRuns.insert(leaderID)
    rebakeAll()
    return true
  }

  /// Builds one `MessageItem` from current bake and env state. URL detection
  /// and decoded-cache rehydration run synchronously inside
  /// `makeBuildInputs`, so the returned item already carries its preview
  /// fragment at a stable height.
  func makeItem(for message: MessageDTO, previous: MessageDTO?, next: MessageDTO?) -> MessageItem {
    MessageFragmentBuilder.makeItem(
      for: message,
      inputs: bake.makeBuildInputs(
        for: message,
        previous: previous,
        next: next,
        envInputs: envInputs,
        senderTables: senderTablesProvider()
      ),
      envInputs: envInputs
    )
  }
}
