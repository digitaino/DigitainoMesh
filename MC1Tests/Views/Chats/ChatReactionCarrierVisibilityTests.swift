import Foundation
@testable import MC1
@testable import MC1Services
import Testing

/// Reactions ride the send queue as ordinary outgoing messages (the "carrier"), so the
/// timeline filter is what keeps them from showing up as bubbles. These lock the contract
/// the queue-routed send path depends on: a carrier is invisible while it is queued or
/// sent, and only surfaces once it has failed and needs a user retry.
@Suite("Chat Reaction Carrier Visibility")
@MainActor
struct ChatReactionCarrierVisibilityTests {
  private func makeCarrier(
    text: String,
    status: MessageStatus,
    direction: MessageDirection = .outgoing,
    channelIndex: UInt8? = nil
  ) -> MessageDTO {
    MessageDTO(
      id: UUID(),
      radioID: UUID(),
      contactID: channelIndex == nil ? UUID() : nil,
      channelIndex: channelIndex,
      text: text,
      timestamp: 1_704_067_200,
      createdAt: Date(),
      direction: direction,
      status: status,
      textType: .plain,
      ackCode: nil,
      pathLength: 0,
      snr: nil,
      senderKeyPrefix: nil,
      senderNodeName: nil,
      isRead: true,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0
    )
  }

  private var channelReaction: String {
    ReactionParser.buildChannelReactionText(
      emoji: "👍",
      targetSender: "AlphaNode",
      targetText: "see you at the meetup",
      targetTimestamp: 1_704_067_200,
      localNodeNameByteCount: "MyNode".utf8.count
    )
  }

  private var dmReaction: String {
    ReactionParser.buildDMReactionText(
      emoji: "👍",
      targetText: "see you at the meetup",
      targetTimestamp: 1_704_067_200
    )
  }

  @Test
  func `Queued channel reaction carrier stays out of the timeline`() {
    let bake = ChatViewModel().bake
    let carrier = makeCarrier(text: channelReaction, status: .pending, channelIndex: 3)
    #expect(bake.isHiddenOutgoingReaction(carrier, isDM: false))
  }

  @Test
  func `Sent channel reaction carrier stays out of the timeline`() {
    let bake = ChatViewModel().bake
    let carrier = makeCarrier(text: channelReaction, status: .sent, channelIndex: 3)
    #expect(bake.isHiddenOutgoingReaction(carrier, isDM: false))
  }

  @Test
  func `Failed channel reaction carrier becomes visible so it can be retried`() {
    let bake = ChatViewModel().bake
    let carrier = makeCarrier(text: channelReaction, status: .failed, channelIndex: 3)
    #expect(!bake.isHiddenOutgoingReaction(carrier, isDM: false))
  }

  @Test
  func `Queued DM reaction carrier stays out of the timeline`() {
    let bake = ChatViewModel().bake
    let carrier = makeCarrier(text: dmReaction, status: .pending)
    #expect(bake.isHiddenOutgoingReaction(carrier, isDM: true))
  }

  @Test
  func `Failed DM reaction carrier becomes visible so it can be retried`() {
    let bake = ChatViewModel().bake
    let carrier = makeCarrier(text: dmReaction, status: .failed)
    #expect(!bake.isHiddenOutgoingReaction(carrier, isDM: true))
  }

  @Test
  func `Incoming reaction text is never treated as a hidden carrier`() {
    // Incoming reactions are consumed at ingest and never persisted as messages;
    // the filter must not swallow an incoming bubble that merely looks like one.
    let bake = ChatViewModel().bake
    let incoming = makeCarrier(text: channelReaction, status: .delivered, direction: .incoming, channelIndex: 3)
    #expect(!bake.isHiddenOutgoingReaction(incoming, isDM: false))
  }

  @Test
  func `A legacy v1 carrier from an older build is still hidden`() {
    let bake = ChatViewModel().bake
    let carrier = makeCarrier(text: "👍@[AlphaNode]\n7f3a9c12", status: .sent, channelIndex: 3)
    #expect(bake.isHiddenOutgoingReaction(carrier, isDM: false))
  }
}
