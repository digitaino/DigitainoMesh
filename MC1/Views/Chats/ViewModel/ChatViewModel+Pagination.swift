import MC1Services
import SwiftUI

extension ChatViewModel {
  // MARK: - Pagination

  /// Load older messages when user scrolls near the top. The timeline owns
  /// the paging sequence (spinner, fetch, dedupe, prepend, rebake); this
  /// wrapper layers the caller-side bookkeeping on top: mention-picker
  /// sender registration, reaction indexing, and the error surface.
  ///
  /// Reports what the page did so a caller that pages in a loop (the search jump) can tell
  /// progress from a no-op; scroll-driven paging ignores it.
  @discardableResult
  func loadOlderMessages() async -> ChatTimeline.OlderPage {
    guard let dataStore else { return .unavailable }

    // Snapshot conversation context before any await — actor reentrancy
    // means currentContact/currentChannel can change during suspensions
    let contact = currentContact
    let channel = currentChannel

    do {
      let page = try await timeline.loadOlder()
      guard let olderMessages = page.loadedMessages, !olderMessages.isEmpty else { return page }

      // Register senders from the older page; without this, scrolling
      // back to a sender who only appears in older pages leaves them
      // missing from the @-autocomplete list.
      if let channel {
        for message in olderMessages {
          if let senderName = message.senderNodeName {
            addChannelSenderIfNew(senderName, radioID: channel.radioID, timestamp: message.timestamp)
          }
        }
      }

      // Index older channel messages for reaction matching and process pending reactions
      if let channel,
         let reactionService = reactionServiceProvider() {
        await indexMessagesForReactions(
          olderMessages,
          scope: .channel(channel, localNodeName: connectedDeviceProvider()?.nodeName),
          reactionService: reactionService,
          dataStore: dataStore
        )
      }

      // Index older DM messages for reaction matching and process pending reactions
      if let contact,
         let reactionService = reactionServiceProvider() {
        await indexMessagesForReactions(
          olderMessages,
          scope: .direct(contact),
          reactionService: reactionService,
          dataStore: dataStore
        )
      }

      return page
    } catch {
      errorBannerMessage = L10n.Chats.Chats.Error.loadOlderMessagesFailed
      logger.error("Failed to load older messages: \(error)")
      return .unavailable
    }
  }
}
