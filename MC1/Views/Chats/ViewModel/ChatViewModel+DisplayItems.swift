import Foundation
import MC1Services

extension ChatViewModel {
  // MARK: - Display Items

  /// Optimistically append a message if not already present. Called from
  /// the incoming admission path after the receive-time prefetch resolves
  /// or hits its timeout, and from the outgoing send paths immediately
  /// after `createPendingMessage`. Preserves unread-counter math via the
  /// item-count delta observed by `ChatTiledView`.
  ///
  /// Synchronous: timeline admission and channel sender bookkeeping mutate
  /// Observable state on the main actor in one call frame, so SwiftUI
  /// invalidates dependent views once per change cycle without an explicit
  /// transaction.
  func appendMessageIfNew(_ message: MessageDTO) {
    let admission = timeline.admit(message)
    guard admission.inserted else { return }
    if let handoff = admission.handoff {
      incomingAvatarFlight?.beginFlight(
        from: handoff.fromID,
        to: handoff.toID,
        identity: handoff.identity
      )
    }
    if let senderName = message.senderNodeName,
       let radioID = currentChannel?.radioID {
      addChannelSenderIfNew(senderName, radioID: radioID, timestamp: message.timestamp)
    }
  }

  /// Build MessageItems with pre-computed properties via the shared bake pipeline.
  func buildItems() {
    timeline.rebakeAll()
  }

  /// Toggle the duplicate run containing `messageID` (badge tap).
  func toggleDuplicateRun(containing messageID: UUID) {
    timeline.toggleDuplicateRun(containing: messageID)
  }

  /// Expand the run hiding `messageID` so it has a row to scroll to.
  /// Returns true when an expansion happened.
  @discardableResult
  func revealHiddenDuplicate(_ messageID: UUID) -> Bool {
    timeline.revealHiddenDuplicate(messageID)
  }

  /// Get full message DTO for a MessageItem.
  /// Logs a warning if lookup fails (indicates data inconsistency).
  func message(for item: MessageItem) -> MessageDTO? {
    guard let message = messagesByID[item.id] else {
      logger.warning("Message lookup failed for item id=\(item.id)")
      return nil
    }
    return message
  }
}
