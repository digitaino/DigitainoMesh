import Foundation
@testable import MC1Services
import Testing

/// Behaviour spec for the "no repeats heard" decision core, ported from the legacy
/// `scheduleNoRepeatsRetry` / `clearNoRepeatsRetry` pair (commit fa936a68 and follow-ups).
/// No clock and no services: the window is expressed as an explicit `.windowElapsed` input.
@Suite("ChatNoRepeatsPolicy")
struct ChatNoRepeatsPolicyTests {
  private static let messageA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
  private static let messageB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

  private func sent(
    _ messageID: UUID,
    isChannelMessage: Bool = true,
    isOutgoing: Bool = true,
    status: MessageStatus = .sent
  ) -> ChatNoRepeatsInput {
    .sendResolved(
      messageID: messageID,
      isChannelMessage: isChannelMessage,
      isOutgoing: isOutgoing,
      status: status
    )
  }

  // MARK: - Arming

  @Test
  func `an outgoing channel send that reaches sent arms the window`() {
    var policy = ChatNoRepeatsPolicy()
    let armed = policy.handle(sent(Self.messageA))
    #expect(armed)
    #expect(policy.armedMessageID == Self.messageA)
    #expect(policy.promptedMessageID == nil)
  }

  @Test
  func `a delivered channel send also arms`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA, status: .delivered))
    #expect(policy.armedMessageID == Self.messageA)
  }

  @Test
  func `a direct message never arms because it has no repeat evidence`() {
    var policy = ChatNoRepeatsPolicy()
    let changed = policy.handle(sent(Self.messageA, isChannelMessage: false))
    #expect(!changed)
    #expect(policy.armedMessageID == nil)
  }

  @Test
  func `an incoming message never arms`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA, isOutgoing: false))
    #expect(policy.armedMessageID == nil)
  }

  @Test
  func `a non-terminal status does not arm`() {
    for status in [MessageStatus.pending, .sending, .retrying, .failed] {
      var policy = ChatNoRepeatsPolicy()
      policy.handle(sent(Self.messageA, status: status))
      #expect(policy.armedMessageID == nil, "\(status) must not arm")
    }
  }

  // MARK: - Window expiry

  @Test
  func `the window expiring on a still-armed message offers the card`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA))
    let prompted = policy.handle(.windowElapsed(messageID: Self.messageA))
    #expect(prompted)
    #expect(policy.promptedMessageID == Self.messageA)
    #expect(policy.armedMessageID == nil)
  }

  @Test
  func `a stale window expiry for a message that is no longer armed is ignored`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA))
    policy.handle(sent(Self.messageB))
    let changed = policy.handle(.windowElapsed(messageID: Self.messageA))
    #expect(!changed)
    #expect(policy.promptedMessageID == nil)
    #expect(policy.armedMessageID == Self.messageB)
  }

  @Test
  func `a window expiry with nothing armed offers nothing`() {
    var policy = ChatNoRepeatsPolicy()
    let changed = policy.handle(.windowElapsed(messageID: Self.messageA))
    #expect(!changed)
    #expect(policy.promptedMessageID == nil)
  }

  // MARK: - Repeats heard

  @Test
  func `a repeat heard inside the window disarms so no card is ever offered`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA))
    policy.handle(.repeatHeard(messageID: Self.messageA, count: 1))
    #expect(policy.armedMessageID == nil)

    policy.handle(.windowElapsed(messageID: Self.messageA))
    #expect(policy.promptedMessageID == nil)
  }

  @Test
  func `a late repeat retires a card that is already showing`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA))
    policy.handle(.windowElapsed(messageID: Self.messageA))
    #expect(policy.promptedMessageID == Self.messageA)

    let retired = policy.handle(.repeatHeard(messageID: Self.messageA, count: 1))
    #expect(retired)
    #expect(policy.promptedMessageID == nil)
  }

  @Test
  func `a zero-count repeat event changes nothing`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA))
    let changed = policy.handle(.repeatHeard(messageID: Self.messageA, count: 0))
    #expect(!changed)
    #expect(policy.armedMessageID == Self.messageA)
  }

  @Test
  func `a repeat for a different message leaves the armed one alone`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA))
    policy.handle(.repeatHeard(messageID: Self.messageB, count: 2))
    #expect(policy.armedMessageID == Self.messageA)
  }

  // MARK: - Retirement

  @Test
  func `a resend retires the card and a fresh send re-arms it`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA))
    policy.handle(.windowElapsed(messageID: Self.messageA))
    #expect(policy.promptedMessageID == Self.messageA)

    policy.handle(.resendRequested(messageID: Self.messageA))
    #expect(policy.promptedMessageID == nil)
    #expect(policy.armedMessageID == nil)

    policy.handle(sent(Self.messageA))
    #expect(policy.armedMessageID == Self.messageA)
  }

  @Test
  func `a terminal send failure retires the card so the failure UI owns the row`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA))
    policy.handle(.windowElapsed(messageID: Self.messageA))
    policy.handle(.sendFailed(messageID: Self.messageA))
    #expect(policy.promptedMessageID == nil)
    #expect(policy.armedMessageID == nil)
  }

  @Test
  func `re-arming the same message retires its own card but not another message's`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA))
    policy.handle(.windowElapsed(messageID: Self.messageA))
    #expect(policy.promptedMessageID == Self.messageA)

    // A different message going out leaves A's verdict standing — A genuinely was not
    // heard, and legacy kept its card until A's own evidence changed.
    policy.handle(sent(Self.messageB))
    #expect(policy.promptedMessageID == Self.messageA)
    #expect(policy.armedMessageID == Self.messageB)

    // A re-send of A itself does clear it.
    policy.handle(sent(Self.messageA))
    #expect(policy.promptedMessageID == nil)
  }

  @Test
  func `reset forgets both slots`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA))
    policy.handle(.windowElapsed(messageID: Self.messageA))
    policy.handle(sent(Self.messageB))
    let cleared = policy.handle(.reset)
    #expect(cleared)
    #expect(policy.armedMessageID == nil)
    #expect(policy.promptedMessageID == nil)
  }

  // MARK: - Arm sequence

  @Test
  func `re-arming the already-armed message bumps the arm sequence`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA))
    let first = policy.armSequence
    policy.handle(sent(Self.messageA))
    #expect(policy.armSequence == first &+ 1)
    #expect(policy.armedMessageID == Self.messageA)
  }

  @Test
  func `an ineligible send does not bump the arm sequence`() {
    var policy = ChatNoRepeatsPolicy()
    policy.handle(sent(Self.messageA))
    let first = policy.armSequence
    policy.handle(sent(Self.messageB, isChannelMessage: false))
    #expect(policy.armSequence == first)
  }
}
