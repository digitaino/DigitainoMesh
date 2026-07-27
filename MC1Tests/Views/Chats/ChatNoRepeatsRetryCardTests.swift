import Foundation
@testable import MC1
@testable import MC1Services
import Testing

/// Coordinator-level wiring for the no-repeats retry card: the detector's verdict has to
/// reach the rendered `MessageItem`, survive a rebake, retire cleanly, and stay entirely
/// inert when the connection has no repeater signal data.
@Suite("No-repeats retry card wiring")
@MainActor
struct ChatNoRepeatsRetryCardTests {
  private static let radioID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
  private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

  /// Accepts every write and reports back what it was given.
  private actor EchoTxPowerApplier: TxPowerApplying {
    func applyTxPower(_ dbm: Int8) async throws -> Int8 {
      dbm
    }
  }

  private func makeViewModel(
    signalDataAvailable: Bool = true,
    adaptivePower: AdaptivePowerService? = nil
  ) -> (ChatViewModel, ChatCoordinator) {
    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(
      adaptivePowerService: { adaptivePower },
      signalDataAvailable: { signalDataAvailable }
    ))
    let coordinator = ChatCoordinator.makeForTesting()
    viewModel.bindCoordinatorForTesting(coordinator)
    return (viewModel, coordinator)
  }

  private func makeChannelMessage(id: UUID = UUID(), text: String = "hello channel") -> MessageDTO {
    MessageDTO(
      id: id,
      radioID: Self.radioID,
      contactID: nil,
      channelIndex: 1,
      text: text,
      timestamp: UInt32(Self.referenceDate.timeIntervalSince1970),
      createdAt: Self.referenceDate,
      direction: .outgoing,
      status: .sent,
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

  // MARK: - Rendering the verdict

  @Test
  func `the prompt lands on the message's footer and retires cleanly`() async throws {
    let (viewModel, coordinator) = makeViewModel()
    let message = makeChannelMessage()
    coordinator.replaceAllForTesting([message])
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value

    let baked = try #require(viewModel.items.first)
    #expect(baked.footer.noRepeatsRetry == nil)

    viewModel.applyNoRepeatsPrompt(message.id)
    let prompted = try #require(viewModel.items.first)
    #expect(prompted.footer.noRepeatsRetry != nil)

    viewModel.applyNoRepeatsPrompt(nil)
    let retired = try #require(viewModel.items.first)
    #expect(retired.footer.noRepeatsRetry == nil)
  }

  @Test
  func `the prompt survives a full rebake`() async throws {
    let (viewModel, coordinator) = makeViewModel()
    let message = makeChannelMessage()
    coordinator.replaceAllForTesting([message])
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value

    viewModel.applyNoRepeatsPrompt(message.id)
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value

    let rebaked = try #require(viewModel.items.first)
    #expect(rebaked.footer.noRepeatsRetry != nil)
  }

  @Test
  func `the prompt only lands on the message it names`() async {
    let (viewModel, coordinator) = makeViewModel()
    let first = makeChannelMessage(text: "first")
    let second = makeChannelMessage(text: "second")
    coordinator.replaceAllForTesting([first, second])
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value

    viewModel.applyNoRepeatsPrompt(second.id)
    #expect(viewModel.items.first { $0.id == first.id }?.footer.noRepeatsRetry == nil)
    #expect(viewModel.items.first { $0.id == second.id }?.footer.noRepeatsRetry != nil)

    // Moving the card must clear the row that had it.
    viewModel.applyNoRepeatsPrompt(first.id)
    #expect(viewModel.items.first { $0.id == first.id }?.footer.noRepeatsRetry != nil)
    #expect(viewModel.items.first { $0.id == second.id }?.footer.noRepeatsRetry == nil)
  }

  // MARK: - Gating

  @Test
  func `no signal data means the detector is never fed`() async {
    let (viewModel, coordinator) = makeViewModel(signalDataAvailable: false)
    let message = makeChannelMessage()
    coordinator.replaceAllForTesting([message])
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value

    viewModel.noteSendResolved(messageID: message.id, status: .sent)
    #expect(viewModel.noRepeatsDetector.policy.armedMessageID == nil)
  }

  @Test
  func `with signal data a resolved channel send arms the detector`() async {
    let (viewModel, coordinator) = makeViewModel()
    let message = makeChannelMessage()
    coordinator.replaceAllForTesting([message])
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value

    viewModel.noteSendResolved(messageID: message.id, status: .sent)
    #expect(viewModel.noRepeatsDetector.policy.armedMessageID == message.id)

    // Repeats arriving disarm it before any card can be offered.
    viewModel.noteNoRepeatsInput(.repeatHeard(messageID: message.id, count: 1))
    #expect(viewModel.noRepeatsDetector.policy.armedMessageID == nil)
  }

  // MARK: - Escalated power label

  @Test
  func `the escalated label is the next rung from the shared power policy`() {
    let power = AdaptivePowerService(txPowerApplier: EchoTxPowerApplier(), retryDelay: .zero)
    // A measured 1W amplifier makes the whole step table reachable, so there is a rung
    // above the 158mW default base.
    power.configure(
      paGainDb: 8,
      radioMaxDbm: 22,
      baseStepIndex: AdaptivePowerPolicy.defaultBaseStepIndex,
      enabled: true
    )
    let (viewModel, _) = makeViewModel(adaptivePower: power)

    let expected = power.policy.escalatedStep(from: power.currentStepIndex)
    #expect(viewModel.nextEscalatedPowerLabel() == expected?.label)
    #expect(expected?.id == power.currentStepIndex + 1)
  }

  @Test
  func `escalating moves exactly one rung and stays there`() async {
    let power = AdaptivePowerService(txPowerApplier: EchoTxPowerApplier(), retryDelay: .zero)
    power.configure(
      paGainDb: 8,
      radioMaxDbm: 22,
      baseStepIndex: AdaptivePowerPolicy.defaultBaseStepIndex,
      enabled: true
    )
    let (viewModel, _) = makeViewModel(adaptivePower: power)

    let before = power.currentStepIndex
    let promised = viewModel.nextEscalatedPowerLabel()
    await power.escalate()

    #expect(power.currentStepIndex == before + 1)
    #expect(power.currentStep.label == promised)
    // Sticky: nothing brings it back down on its own.
    #expect(power.isElevated)
    #expect(power.lastChangeReason == .escalation)
  }

  @Test
  func `no label is offered when adaptive power is off`() {
    let power = AdaptivePowerService(txPowerApplier: EchoTxPowerApplier(), retryDelay: .zero)
    power.configure(paGainDb: 8, radioMaxDbm: 22, baseStepIndex: 3, enabled: false)
    let (viewModel, _) = makeViewModel(adaptivePower: power)

    #expect(viewModel.nextEscalatedPowerLabel() == nil)
  }

  @Test
  func `no label is offered at the radio's highest reachable rung`() {
    let power = AdaptivePowerService(txPowerApplier: EchoTxPowerApplier(), retryDelay: .zero)
    // A bare 22 dBm radio tops out at step 3 (158mW).
    power.configure(paGainDb: 0, radioMaxDbm: 22, baseStepIndex: 3, enabled: true)
    let (viewModel, _) = makeViewModel(adaptivePower: power)

    #expect(power.isAtMax)
    #expect(viewModel.nextEscalatedPowerLabel() == nil)
  }
}
