import Foundation
@testable import MC1Services
import Testing

/// Records TX power writes and can be told to fail the first `failuresBeforeSuccess`
/// attempts, or to report a value other than the one requested.
private actor MockTxPowerApplier: TxPowerApplying {
  private(set) var appliedDbm: [Int8] = []
  private var failuresRemaining: Int
  private let confirmedOverride: Int8?

  init(failuresBeforeSuccess: Int = 0, confirmedOverride: Int8? = nil) {
    failuresRemaining = failuresBeforeSuccess
    self.confirmedOverride = confirmedOverride
  }

  struct ApplyFailure: Error {}

  func applyTxPower(_ dbm: Int8) async throws -> Int8 {
    appliedDbm.append(dbm)
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw ApplyFailure()
    }
    return confirmedOverride ?? dbm
  }
}

@Suite("AdaptivePowerService")
@MainActor
struct AdaptivePowerServiceTests {
  private func makeService(
    applier: MockTxPowerApplier = MockTxPowerApplier(),
    paGainDb: Double = 0,
    radioMaxDbm: Int8 = 22,
    baseStepIndex: Int = AdaptivePowerPolicy.defaultBaseStepIndex,
    enabled: Bool = true
  ) -> AdaptivePowerService {
    let service = AdaptivePowerService(txPowerApplier: applier, retryDelay: .zero)
    service.configure(
      paGainDb: paGainDb,
      radioMaxDbm: radioMaxDbm,
      baseStepIndex: baseStepIndex,
      enabled: enabled
    )
    return service
  }

  // MARK: - Configuration

  @Test
  func `configure seeds current step from base and clears prior state`() {
    let service = makeService(baseStepIndex: 2)
    #expect(service.baseStepIndex == 2)
    #expect(service.currentStepIndex == 2)
    #expect(!service.isElevated)
    #expect(!service.isUserOverride)
    #expect(service.confirmedRadioDbm == nil)
    #expect(service.lastChangeReason == nil)
  }

  @Test
  func `configure clamps an out-of-range persisted base step`() {
    let service = makeService(baseStepIndex: 42)
    #expect(service.baseStepIndex == AdaptivePowerPolicy.allSteps.count - 1)
  }

  @Test
  func `disabling returns to base and clears confirmation state`() async {
    let service = makeService(baseStepIndex: 1)
    await service.escalate()
    #expect(service.isElevated)

    service.setEnabled(false)
    #expect(service.currentStepIndex == service.baseStepIndex)
    #expect(!service.isElevated)
    #expect(service.confirmedRadioDbm == nil)
    #expect(service.lastChangeReason == nil)
  }

  @Test
  func `raising the base while escalated does not lower the active step`() async {
    let service = makeService(baseStepIndex: 0)
    await service.escalate()
    await service.escalate()
    #expect(service.currentStepIndex == 2)

    service.setBaseStep(1)
    #expect(service.currentStepIndex == 2)
    #expect(service.isElevated)
  }

  @Test
  func `raising the base pulls a non-escalated step up with it`() {
    let service = makeService(baseStepIndex: 0)
    service.setBaseStep(2)
    #expect(service.currentStepIndex == 2)
  }

  @Test
  func `changing PA gain re-derives the policy`() {
    let service = makeService(paGainDb: 0, radioMaxDbm: 22)
    #expect(service.availableSteps.count == 4)

    service.setPAGain(8)
    #expect(service.policy.paCurve == AdaptivePowerPolicy.PACurve.pocket1W)
    #expect(service.availableSteps.last?.id == 7)
  }

  // MARK: - Escalation

  @Test
  func `escalate advances one step and applies it to the radio`() async {
    let applier = MockTxPowerApplier()
    let service = makeService(applier: applier, baseStepIndex: 0)

    let step = await service.escalate()
    #expect(step?.id == 1)
    #expect(service.currentStepIndex == 1)
    #expect(service.lastChangeReason == .escalation)

    let applied = await applier.appliedDbm
    #expect(applied == [13])
    #expect(service.confirmedRadioDbm == 13)
    #expect(service.isPowerConfirmed)
  }

  @Test
  func `escalate stops at the radio ceiling without writing`() async {
    let applier = MockTxPowerApplier()
    let service = makeService(applier: applier, radioMaxDbm: 22, baseStepIndex: 3)

    #expect(service.isAtMax)
    let step = await service.escalate()
    #expect(step == nil)
    #expect(service.currentStepIndex == 3)
    let applied = await applier.appliedDbm
    #expect(applied.isEmpty)
  }

  @Test
  func `escalate clears a user override`() async {
    let service = makeService(baseStepIndex: 0)
    await service.setUserOverride(stepIndex: 1)
    #expect(service.isUserOverride)

    await service.escalate()
    #expect(!service.isUserOverride)
  }

  @Test
  func `escalate is inert while disabled`() async {
    let applier = MockTxPowerApplier()
    let service = makeService(applier: applier, baseStepIndex: 0, enabled: false)

    let step = await service.escalate()
    #expect(step == nil)
    #expect(service.currentStepIndex == 0)
    let applied = await applier.appliedDbm
    #expect(applied.isEmpty)
  }

  // MARK: - User Override

  @Test
  func `user override selects and applies a reachable step`() async {
    let applier = MockTxPowerApplier()
    let service = makeService(applier: applier, baseStepIndex: 0)

    await service.setUserOverride(stepIndex: 2)
    #expect(service.currentStepIndex == 2)
    #expect(service.isUserOverride)
    #expect(service.lastChangeReason == .userOverride)
    let applied = await applier.appliedDbm
    #expect(applied == [20])
  }

  @Test
  func `user override ignores a step the radio cannot reach`() async {
    let applier = MockTxPowerApplier()
    let service = makeService(applier: applier, radioMaxDbm: 22, baseStepIndex: 0)

    await service.setUserOverride(stepIndex: 7)
    #expect(service.currentStepIndex == 0)
    #expect(!service.isUserOverride)
    let applied = await applier.appliedDbm
    #expect(applied.isEmpty)
  }

  // MARK: - Reset

  @Test
  func `reset returns to base and re-applies`() async {
    let applier = MockTxPowerApplier()
    let service = makeService(applier: applier, baseStepIndex: 1)
    await service.escalate()

    await service.resetToBase()
    #expect(service.currentStepIndex == 1)
    #expect(!service.isElevated)
    #expect(!service.isUserOverride)
    #expect(service.lastChangeReason == .reset)
    let applied = await applier.appliedDbm
    #expect(applied.last == 13)
  }

  // MARK: - Apply and Verification

  @Test
  func `apply retries and succeeds within the retry budget`() async {
    let applier = MockTxPowerApplier(failuresBeforeSuccess: 2)
    let service = makeService(applier: applier, baseStepIndex: 2)

    let ok = await service.applyCurrentPower()
    #expect(ok)
    let applied = await applier.appliedDbm
    #expect(applied == [20, 20, 20])
    #expect(!service.lastApplyFailed)
  }

  @Test
  func `apply gives up after three attempts and flags the failure`() async {
    let applier = MockTxPowerApplier(failuresBeforeSuccess: 5)
    let service = makeService(applier: applier, baseStepIndex: 2)

    let ok = await service.applyCurrentPower()
    #expect(!ok)
    let applied = await applier.appliedDbm
    #expect(applied.count == 3)
    #expect(service.lastApplyFailed)
    #expect(!service.isPowerConfirmed)
  }

  @Test
  func `a device reporting a different power is not treated as confirmed`() async {
    let applier = MockTxPowerApplier(confirmedOverride: 5)
    let service = makeService(applier: applier, baseStepIndex: 2)

    let ok = await service.applyCurrentPower()
    #expect(ok)
    #expect(service.confirmedRadioDbm == 5)
    #expect(!service.isPowerConfirmed)
  }

  @Test
  func `apply is a no-op success while disabled`() async {
    let applier = MockTxPowerApplier(failuresBeforeSuccess: 5)
    let service = makeService(applier: applier, baseStepIndex: 2, enabled: false)

    let ok = await service.applyCurrentPower()
    #expect(ok)
    let applied = await applier.appliedDbm
    #expect(applied.isEmpty)
  }

  // MARK: - Repeat Feedback

  @Test
  func `repeats heard accumulate without lowering power`() async {
    let service = makeService(baseStepIndex: 0)
    await service.escalate()

    service.onRepeatsHeard()
    service.onRepeatsHeard()
    #expect(service.consecutiveSuccesses == 2)
    #expect(service.currentStepIndex == 1)

    service.onNoRepeatsHeard()
    #expect(service.consecutiveSuccesses == 0)
    #expect(service.currentStepIndex == 1)
  }

  @Test
  func `repeat feedback is ignored while disabled`() {
    let service = makeService(enabled: false)
    service.onRepeatsHeard()
    #expect(service.consecutiveSuccesses == 0)
  }
}
