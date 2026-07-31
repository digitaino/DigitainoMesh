import Foundation
@testable import MC1Services
import Testing

/// Timer-side behaviour of the detector: what turns an armed send into a prompt, and what
/// stops it. The wall clock is replaced by an injected suspension, so every test resolves
/// deterministically rather than waiting out a real window.
@Suite("ChatNoRepeatsDetector")
@MainActor
struct ChatNoRepeatsDetectorTests {
  private static let messageA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000A")!
  private static let messageB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000B")!

  private func sent(_ messageID: UUID) -> ChatNoRepeatsInput {
    .sendResolved(messageID: messageID, isChannelMessage: true, isOutgoing: true, status: .sent)
  }

  /// Detector whose window elapses as soon as the arming call returns.
  private func makeImmediateDetector() -> (ChatNoRepeatsDetector, Recorder) {
    let recorder = Recorder()
    let detector = ChatNoRepeatsDetector(window: .seconds(5), sleep: { _ in })
    detector.onPromptChange = { recorder.record($0) }
    return (detector, recorder)
  }

  @MainActor
  private final class Recorder {
    private(set) var values: [UUID?] = []

    func record(_ value: UUID?) {
      values.append(value)
    }
  }

  // MARK: - Prompting

  @Test
  func `a send with no repeats inside the window prompts once the window elapses`() async {
    let (detector, recorder) = makeImmediateDetector()
    detector.handle(sent(Self.messageA))
    await detector.awaitWindowForTesting()

    #expect(detector.promptedMessageID == Self.messageA)
    #expect(recorder.values == [Self.messageA])
  }

  @Test
  func `a repeat arriving before the window elapses cancels the window and prompts nothing`() async {
    // The window stays suspended until the test opens the gate, so evidence can land
    // strictly inside it.
    let (gate, openGate) = AsyncStream<Void>.makeStream()
    let recorder = Recorder()
    let detector = ChatNoRepeatsDetector(window: .seconds(5), sleep: { _ in
      for await _ in gate {}
    })
    detector.onPromptChange = { recorder.record($0) }

    detector.handle(sent(Self.messageA))
    detector.handle(.repeatHeard(messageID: Self.messageA, count: 1))
    openGate.finish()
    await detector.awaitWindowForTesting()

    #expect(detector.promptedMessageID == nil)
    #expect(recorder.values.isEmpty)
  }

  @Test
  func `a direct message send never starts a window`() async {
    let (detector, recorder) = makeImmediateDetector()
    detector.handle(.sendResolved(
      messageID: Self.messageA,
      isChannelMessage: false,
      isOutgoing: true,
      status: .sent
    ))
    await detector.awaitWindowForTesting()

    #expect(detector.promptedMessageID == nil)
    #expect(recorder.values.isEmpty)
  }

  @Test
  func `a window firing after signal data went away retires instead of prompting`() async {
    // The owner's gate only sees the input on the way in; signal bars can detach while the
    // window runs, and a card offered then could never be retired by the evidence that is
    // no longer arriving.
    let (detector, recorder) = makeImmediateDetector()
    var available = true
    detector.isPromptAvailable = { available }

    detector.handle(sent(Self.messageA))
    available = false
    await detector.awaitWindowForTesting()

    #expect(detector.promptedMessageID == nil)
    #expect(detector.policy.armedMessageID == nil)
    #expect(recorder.values.isEmpty)
  }

  @Test
  func `an available connection still prompts through the same check`() async {
    let (detector, recorder) = makeImmediateDetector()
    detector.isPromptAvailable = { true }

    detector.handle(sent(Self.messageA))
    await detector.awaitWindowForTesting()

    #expect(detector.promptedMessageID == Self.messageA)
    #expect(recorder.values == [Self.messageA])
  }

  // MARK: - Window ownership

  @Test
  func `a newer send takes the window from an older one`() async {
    let (detector, recorder) = makeImmediateDetector()
    detector.handle(sent(Self.messageA))
    await detector.awaitWindowForTesting()
    detector.handle(sent(Self.messageB))
    await detector.awaitWindowForTesting()

    #expect(detector.promptedMessageID == Self.messageB)
    #expect(recorder.values == [Self.messageA, Self.messageB])
  }

  @Test
  func `resending the prompted message retires the card and re-runs the window`() async {
    let (detector, recorder) = makeImmediateDetector()
    detector.handle(sent(Self.messageA))
    await detector.awaitWindowForTesting()
    #expect(detector.promptedMessageID == Self.messageA)

    detector.handle(.resendRequested(messageID: Self.messageA))
    #expect(detector.promptedMessageID == nil)

    // The resend lands as a fresh `.sent`, which re-arms and prompts again.
    detector.handle(sent(Self.messageA))
    await detector.awaitWindowForTesting()

    #expect(detector.promptedMessageID == Self.messageA)
    #expect(recorder.values == [Self.messageA, nil, Self.messageA])
  }

  @Test
  func `cancel drops the pending window so no late verdict lands`() {
    // Suspended window, so `cancel` lands while the verdict is still pending.
    let (gate, openGate) = AsyncStream<Void>.makeStream()
    let recorder = Recorder()
    let detector = ChatNoRepeatsDetector(window: .seconds(5), sleep: { _ in
      for await _ in gate {}
    })
    detector.onPromptChange = { recorder.record($0) }

    detector.handle(sent(Self.messageA))
    detector.cancel()
    openGate.finish()

    #expect(detector.promptedMessageID == nil)
    #expect(recorder.values.isEmpty)
  }

  @Test
  func `reset retires an offered card`() async {
    let (detector, recorder) = makeImmediateDetector()
    detector.handle(sent(Self.messageA))
    await detector.awaitWindowForTesting()
    detector.handle(.reset)

    #expect(detector.promptedMessageID == nil)
    #expect(recorder.values == [Self.messageA, nil])
  }
}
