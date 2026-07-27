import Foundation
@testable import MC1Services
import Testing

@Suite("AdaptivePowerPolicy")
struct AdaptivePowerPolicyTests {
  // MARK: - Step Table

  @Test
  func `step table is ordered low to high and self-indexed`() {
    let steps = AdaptivePowerPolicy.allSteps
    #expect(steps.count == 8)
    for (index, step) in steps.enumerated() {
      #expect(step.id == index)
    }
    #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.eirpDbm < $1.eirpDbm })
    #expect(AdaptivePowerPolicy.allSteps[AdaptivePowerPolicy.defaultBaseStepIndex].label == "158mW")
  }

  // MARK: - Radio Config Without a PA

  @Test
  func `without a PA the radio config is the target EIRP`() {
    let policy = AdaptivePowerPolicy(paGainDb: 0, radioMaxDbm: 22)
    #expect(policy.paCurve == nil)
    #expect(policy.radioDbm(for: AdaptivePowerPolicy.allSteps[0]) == 10)
    #expect(policy.radioDbm(for: AdaptivePowerPolicy.allSteps[3]) == 22)
    #expect(policy.actualEirpDbm(for: AdaptivePowerPolicy.allSteps[3]) == 22.0)
  }

  @Test
  func `an unrecognised PA gain falls back to flat subtraction`() {
    let policy = AdaptivePowerPolicy(paGainDb: 6, radioMaxDbm: 22)
    #expect(policy.paCurve == nil)
    // 27 dBm EIRP through a flat +6 dB amplifier needs 21 dBm from the radio.
    #expect(policy.radioDbm(for: AdaptivePowerPolicy.allSteps[5]) == 21)
  }

  @Test
  func `negative PA gain is clamped to zero`() {
    let policy = AdaptivePowerPolicy(paGainDb: -5, radioMaxDbm: 22)
    #expect(policy.paGainDb == 0)
  }

  // MARK: - Reachable Steps

  @Test
  func `steps above the radio ceiling are unreachable without a PA`() {
    let policy = AdaptivePowerPolicy(paGainDb: 0, radioMaxDbm: 22)
    // 23 dBm and above cannot be produced by a 22 dBm radio with no amplifier.
    #expect(policy.availableSteps.map(\.id) == [0, 1, 2, 3])
    #expect(policy.isReachable(3))
    #expect(!policy.isReachable(4))
    #expect(policy.isAtMax(3))
  }

  @Test
  func `a measured PA curve unlocks the full step table`() {
    let policy = AdaptivePowerPolicy(paGainDb: 8, radioMaxDbm: 22)
    #expect(policy.paCurve == AdaptivePowerPolicy.PACurve.pocket1W)
    #expect(policy.availableSteps.last?.id == 7)
    #expect(policy.isAtMax(7))
  }

  @Test
  func `steps that collapse onto one radio config are deduplicated`() {
    // The Heltec V4 curve compresses above 28 dBm, so 700mW and 1W both resolve to
    // config 22; only the first survives.
    let policy = AdaptivePowerPolicy(paGainDb: 11, radioMaxDbm: 22)
    let configs = policy.availableSteps.map { policy.radioDbm(for: $0) }
    #expect(Set(configs).count == configs.count)
    #expect(policy.availableSteps.count < AdaptivePowerPolicy.allSteps.count)
    #expect(policy.availableSteps.last?.id == 6)
  }

  // MARK: - Escalation

  @Test
  func `escalation walks reachable steps one rung at a time`() {
    let policy = AdaptivePowerPolicy(paGainDb: 0, radioMaxDbm: 22)
    #expect(policy.escalatedStep(from: 0)?.id == 1)
    #expect(policy.escalatedStep(from: 1)?.id == 2)
    #expect(policy.escalatedStep(from: 2)?.id == 3)
  }

  @Test
  func `escalation stops at the highest reachable step`() {
    let policy = AdaptivePowerPolicy(paGainDb: 0, radioMaxDbm: 22)
    #expect(policy.escalatedStep(from: 3) == nil)
  }

  @Test
  func `escalation skips steps the measured curve deduplicated away`() {
    let policy = AdaptivePowerPolicy(paGainDb: 11, radioMaxDbm: 22)
    let available = policy.availableSteps.map(\.id)
    for (current, next) in zip(available, available.dropFirst()) {
      #expect(policy.escalatedStep(from: current)?.id == next)
    }
    #expect(policy.escalatedStep(from: available[available.count - 1]) == nil)
  }

  @Test
  func `escalating from a step outside the reachable set yields nothing`() {
    let policy = AdaptivePowerPolicy(paGainDb: 0, radioMaxDbm: 22)
    #expect(policy.escalatedStep(from: 7) == nil)
  }

  // MARK: - Clamping

  @Test
  func `step indices are clamped into the table`() {
    let policy = AdaptivePowerPolicy()
    #expect(policy.clampStepIndex(-4) == 0)
    #expect(policy.clampStepIndex(99) == AdaptivePowerPolicy.allSteps.count - 1)
    #expect(policy.clampStepIndex(2) == 2)
  }

  // MARK: - PA Curve

  @Test
  func `PA curve maps a target EIRP to the nearest measured config`() {
    let curve = AdaptivePowerPolicy.PACurve.pocket1W
    // 30.0 dBm sits closest to the top measured output (30.3 at config 22).
    #expect(curve.radioConfig(forTargetEirp: 30.0) == 22)
    // 21.0 dBm is measured exactly at config 12.
    #expect(curve.radioConfig(forTargetEirp: 21.0) == 12)
    #expect(curve.actualOutput(atConfig: 12) == 21.0)
  }

  @Test
  func `PA curve reports compression rather than the nominal target`() {
    let policy = AdaptivePowerPolicy(paGainDb: 8, radioMaxDbm: 22)
    let oneWatt = AdaptivePowerPolicy.allSteps[7]
    // The amplifier tops out at 30.3 dBm, so 1W nominal is honoured but not exceeded.
    #expect(policy.actualEirpDbm(for: oneWatt) == 30.3)
    #expect(policy.actualMilliwatts(for: oneWatt) > 1000)
  }

  @Test
  func `PA curve falls back to the config value outside the measured range`() {
    let curve = AdaptivePowerPolicy.PACurve(minConfig: 0, outputDbm: [10, 12, 14])
    #expect(curve.actualOutput(atConfig: 9) == 9)
    #expect(curve.actualOutput(atConfig: -1) == -1)
  }

  @Test
  func `known PA gains resolve to their measured curves`() {
    #expect(AdaptivePowerPolicy.curve(forPAGain: 8) == .pocket1W)
    #expect(AdaptivePowerPolicy.curve(forPAGain: 11) == .heltecV4)
    #expect(AdaptivePowerPolicy.curve(forPAGain: 12) == nil)
  }
}
