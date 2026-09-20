import Foundation
@testable import MC1
@testable import MC1Services
import Testing

@Suite("Message status text")
struct MessageStatusTextTests {
  private func makeItem(
    status: MessageStatus,
    isChannelMessage: Bool,
    heardRepeats: Int = 0,
    sendCount: Int = 1,
    retryAttempt: Int = 0,
    maxRetryAttempts: Int = 0
  ) -> MessageItem {
    MessageItem(
      id: UUID(),
      envelope: MessageEnvelope(
        messageID: UUID(),
        isOutgoing: true,
        senderName: "me",
        senderResolution: NodeNameResolution(displayName: "me", matchKind: .exact),
        status: status,
        date: Date(timeIntervalSince1970: 1_700_000_000),
        hasFailed: status == .failed,
        containsSelfMention: false,
        mentionSeen: false,
        incomingAvatar: nil
      ),
      content: [],
      footer: MessageFooter(
        showHop: false,
        hopCount: 0,
        formattedPath: nil,
        regionToShow: nil,
        sendTimeToShow: nil,
        sendTimeWasCorrected: false,
        showStatusRow: true,
        status: status,
        isChannelMessage: isChannelMessage,
        heardRepeats: heardRepeats,
        retryAttempt: retryAttempt,
        maxRetryAttempts: maxRetryAttempts,
        sendCount: sendCount
      ),
      grouping: GroupingFlags(
        showTimestamp: false,
        showDirectionGap: false,
        showSenderName: false,
        showNewMessagesDivider: false
      ),
      shouldRequestPreviewFetch: false
    )
  }

  /// A DM `.sent` only means the radio queued the packet; it must read as
  /// in-progress so the user never sees a settled "Sent" that later fails.
  @Test
  func `DM .sent renders as Sending`() {
    let text = MessageStatusText.text(for: makeItem(status: .sent, isChannelMessage: false).footer)
    #expect(text == L10n.Chats.Chats.Message.Status.sending)
  }

  /// A channel broadcast has no ACK, so `.sent` is its terminal success state.
  @Test
  func `Channel .sent renders as Sent`() {
    let text = MessageStatusText.text(for: makeItem(status: .sent, isChannelMessage: true).footer)
    #expect(text == L10n.Chats.Chats.Message.Status.sent)
  }

  @Test
  func `DM .delivered still renders as Delivered`() {
    let text = MessageStatusText.text(for: makeItem(status: .delivered, isChannelMessage: false).footer)
    #expect(text == L10n.Chats.Chats.Message.Status.delivered)
  }

  @Test
  func `DM .failed still renders as Failed`() {
    let text = MessageStatusText.text(for: makeItem(status: .failed, isChannelMessage: false).footer)
    #expect(text == L10n.Chats.Chats.Message.Status.failed)
  }

  /// The retry loop stores the retry index (0 for the second send) and the retry budget,
  /// `maxAttempts - 1`. The count reads as sends out of the config's total: the second send
  /// reads 2/4, the last (flood) send 4/4.
  @Test
  func `DM .retrying counts the send in flight out of the config's total sends`() {
    let maxAttempts = MessageServiceConfig.default.maxAttempts
    #expect(maxAttempts == 4)
    func text(retryAttempt: Int, maxRetryAttempts: Int) -> String {
      MessageStatusText.text(for: makeItem(
        status: .retrying, isChannelMessage: false,
        retryAttempt: retryAttempt, maxRetryAttempts: maxRetryAttempts
      ).footer)
    }
    #expect(text(retryAttempt: 0, maxRetryAttempts: maxAttempts - 1)
      == L10n.Chats.Chats.Message.Status.retryingAttempt(2, maxAttempts))
    #expect(text(retryAttempt: maxAttempts - 2, maxRetryAttempts: maxAttempts - 1)
      == L10n.Chats.Chats.Message.Status.retryingAttempt(maxAttempts, maxAttempts))
    #expect(text(retryAttempt: 0, maxRetryAttempts: 0) == L10n.Chats.Chats.Message.Status.retrying)
  }
}
