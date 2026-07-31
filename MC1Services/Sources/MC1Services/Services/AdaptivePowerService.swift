import Foundation
import os

/// Applies a verified TX power change to the radio.
///
/// Exists so ``AdaptivePowerService`` depends on the capability rather than on
/// `SettingsService`, keeping the service constructible in tests without a session.
public protocol TxPowerApplying: Sendable {
  /// Writes `dbm` to the radio and reads the value back.
  /// - Returns: The device-confirmed TX power in dBm.
  func applyTxPower(_ dbm: Int8) async throws -> Int8
}

extension SettingsService: TxPowerApplying {
  public func applyTxPower(_ dbm: Int8) async throws -> Int8 {
    try await setTxPowerVerified(dbm).txPower
  }
}

/// Manages adaptive TX power control for radios with an optional external power amplifier.
///
/// Starts at a user-configured base power step and escalates one step when a send is
/// retried with no repeats heard. Power does not ramp back down automatically: staying at
/// the level that worked avoids oscillation, so it only returns to base on an explicit
/// reset (new device, disconnect, or the user's Reset action).
///
/// All step selection and power arithmetic lives in ``AdaptivePowerPolicy``; this type owns
/// only the live state and the radio writes.
@Observable
@MainActor
public final class AdaptivePowerService {
  // MARK: - Types

  /// Why the active power step changed. Surfaced for UI and diagnostics.
  public enum PowerChangeReason: Sendable {
    case userOverride
    case escalation
    case reset
  }

  // MARK: - Configuration

  /// The pure decision core. Replaced wholesale whenever the amplifier configuration changes.
  public private(set) var policy = AdaptivePowerPolicy()

  /// The user's preferred base power step index.
  public private(set) var baseStepIndex = AdaptivePowerPolicy.defaultBaseStepIndex

  /// Whether adaptive power mode is enabled. Every mutating action is inert while `false`.
  public private(set) var isEnabled = false

  // MARK: - State

  /// The currently active power step index.
  public private(set) var currentStepIndex = AdaptivePowerPolicy.defaultBaseStepIndex

  /// Whether the active step came from an explicit user selection rather than escalation.
  public private(set) var isUserOverride = false

  /// Consecutive sends at the current level for which repeats were heard.
  public private(set) var consecutiveSuccesses = 0

  /// The last device-confirmed TX power in dBm, or `nil` when nothing has been confirmed.
  public private(set) var confirmedRadioDbm: Int8?

  /// Whether the last apply exhausted its retries without the device confirming.
  public private(set) var lastApplyFailed = false

  /// Why the active step last changed, or `nil` before the first change.
  public private(set) var lastChangeReason: PowerChangeReason?

  // MARK: - Dependencies

  private let txPowerApplier: any TxPowerApplying
  private let retryDelay: Duration
  private let logger = Logger(subsystem: "com.mc1", category: "AdaptivePower")

  private static let maxRetries = 3

  // MARK: - Init

  /// - Parameters:
  ///   - txPowerApplier: Writes and verifies TX power on the radio.
  ///   - retryDelay: Pause between apply attempts. Injected so tests do not sleep.
  public init(
    txPowerApplier: any TxPowerApplying,
    retryDelay: Duration = .milliseconds(300)
  ) {
    self.txPowerApplier = txPowerApplier
    self.retryDelay = retryDelay
  }

  // MARK: - Configuration

  /// Configures the service for a connected device and returns its state to base power.
  ///
  /// Seeds state only. The radio itself is reconciled by ``applyCurrentPower()``, which the
  /// caller runs once the container is wired — a previous session may have left the firmware
  /// at an escalated level, and nothing but this service records what it should be.
  ///
  /// - Parameters:
  ///   - paGainDb: External amplifier gain in dB (0 for a bare radio).
  ///   - radioMaxDbm: The device's `maxTxPower`.
  ///   - baseStepIndex: The user's persisted base step for this device.
  ///   - enabled: The user's persisted enablement for this device.
  public func configure(
    paGainDb: Double,
    radioMaxDbm: Int8 = 22,
    baseStepIndex: Int,
    enabled: Bool
  ) {
    policy = AdaptivePowerPolicy(paGainDb: paGainDb, radioMaxDbm: radioMaxDbm)
    self.baseStepIndex = policy.clampStepIndex(baseStepIndex)
    isEnabled = enabled
    currentStepIndex = self.baseStepIndex
    consecutiveSuccesses = 0
    isUserOverride = false
    confirmedRadioDbm = nil
    lastApplyFailed = false
    lastChangeReason = nil

    logger.info("Configured: paGain=\(paGainDb)dB, radioMax=\(radioMaxDbm)dBm, base=\(self.baseStepIndex), enabled=\(enabled)")
  }

  /// Updates the base step from the settings UI and moves the radio with it.
  ///
  /// An active escalation is preserved: only a step that was sitting at or below the old
  /// base follows the new one, so raising the base while escalated cannot lower the radio
  /// and lowering it cannot strand the user above the level they just picked.
  public func setBaseStep(_ index: Int) async {
    let previousBaseStepIndex = baseStepIndex
    baseStepIndex = policy.clampStepIndex(index)
    logger.info("Base step set to \(self.baseStepIndex) (\(self.baseStep.label))")

    guard !isUserOverride, currentStepIndex <= max(previousBaseStepIndex, baseStepIndex),
          currentStepIndex != baseStepIndex else { return }
    currentStepIndex = baseStepIndex
    await applyCurrentPower()
  }

  /// Updates the external amplifier gain from the settings UI, re-deriving the policy.
  ///
  /// The same step maps to a different radio config once an amplifier is in the chain, so
  /// the radio is rewritten whenever the derived target moves.
  public func setPAGain(_ gain: Double) async {
    let previousRadioDbm = currentRadioDbm
    policy = AdaptivePowerPolicy(paGainDb: gain, radioMaxDbm: policy.radioMaxDbm)
    baseStepIndex = policy.clampStepIndex(baseStepIndex)
    currentStepIndex = policy.clampStepIndex(currentStepIndex)
    // Losing gain can strand a step above what the radio alone reaches; snapping down keeps
    // the write below `radioMaxDbm` instead of asking the chip for a level it cannot produce.
    if let highest = policy.availableSteps.last {
      baseStepIndex = min(baseStepIndex, highest.id)
      currentStepIndex = min(currentStepIndex, highest.id)
    }
    logger.info("PA gain set to \(self.policy.paGainDb)dB\(self.policy.paCurve != nil ? " (measured curve)" : "")")

    guard currentRadioDbm != previousRadioDbm else { return }
    await applyCurrentPower()
  }

  /// Enables or disables adaptive power mode.
  ///
  /// Enabling writes the base level, so the radio actually starts where the UI says it
  /// does. Disabling returns an escalated radio to base *before* clearing state: this
  /// service is the only record of the escalation, so dropping it first would leave the
  /// firmware transmitting at the elevated level until the next reconnect.
  public func setEnabled(_ enabled: Bool) async {
    guard enabled != isEnabled else { return }

    guard enabled else {
      if currentStepIndex != baseStepIndex {
        currentStepIndex = baseStepIndex
        await applyCurrentPower()
      }
      isEnabled = false
      consecutiveSuccesses = 0
      isUserOverride = false
      confirmedRadioDbm = nil
      lastChangeReason = nil
      // `lastApplyFailed` deliberately survives: a restore that never landed means the
      // radio may still be above base, and that is worth keeping on the record.
      logger.info("Adaptive power disabled")
      return
    }

    isEnabled = true
    currentStepIndex = baseStepIndex
    consecutiveSuccesses = 0
    isUserOverride = false
    lastChangeReason = nil
    logger.info("Adaptive power enabled")
    await applyCurrentPower()
  }

  // MARK: - Derived State

  /// The currently active power step.
  public var currentStep: AdaptivePowerPolicy.PowerStep {
    AdaptivePowerPolicy.allSteps[currentStepIndex]
  }

  /// The base (home) power step.
  public var baseStep: AdaptivePowerPolicy.PowerStep {
    AdaptivePowerPolicy.allSteps[baseStepIndex]
  }

  /// Steps this radio can reach, for the settings picker.
  public var availableSteps: [AdaptivePowerPolicy.PowerStep] {
    policy.availableSteps
  }

  /// Whether the active step sits above base.
  public var isElevated: Bool {
    currentStepIndex > baseStepIndex
  }

  /// Whether the active step is the highest this radio can reach.
  public var isAtMax: Bool {
    policy.isAtMax(currentStepIndex)
  }

  /// The radio TX power setting for the active step.
  public var currentRadioDbm: Int8 {
    policy.radioDbm(for: currentStep)
  }

  /// Whether the device has confirmed the intended power.
  public var isPowerConfirmed: Bool {
    guard let confirmedRadioDbm else { return false }
    return confirmedRadioDbm == currentRadioDbm && !lastApplyFailed
  }

  // MARK: - Power Control

  /// Applies the active power level to the radio, retrying on failure.
  ///
  /// A no-op that reports success when adaptive power is off, so callers on the send path
  /// need no enablement check of their own.
  ///
  /// - Returns: `true` when the device confirmed the write.
  @discardableResult
  public func applyCurrentPower() async -> Bool {
    guard isEnabled else { return true }

    let dbm = currentRadioDbm

    for attempt in 1...Self.maxRetries {
      do {
        let confirmed = try await txPowerApplier.applyTxPower(dbm)
        confirmedRadioDbm = confirmed
        lastApplyFailed = false
        logger.info("Verified TX power on attempt \(attempt): \(dbm)dBm → device confirmed \(confirmed)dBm (\(self.currentStep.label))")
        return true
      } catch {
        logger.warning("TX power attempt \(attempt)/\(Self.maxRetries) failed for \(dbm)dBm: \(error.localizedDescription)")
        if attempt < Self.maxRetries {
          try? await Task.sleep(for: retryDelay)
        }
      }
    }

    lastApplyFailed = true
    logger.error("TX power verification FAILED after \(Self.maxRetries) attempts for \(dbm)dBm")
    return false
  }

  /// Escalates one step. Called when a send is retried after no repeats were heard.
  ///
  /// - Returns: The new step, or `nil` when disabled or already at maximum.
  @discardableResult
  public func escalate() async -> AdaptivePowerPolicy.PowerStep? {
    guard isEnabled else { return nil }
    guard let nextStep = policy.escalatedStep(from: currentStepIndex) else {
      logger.info("Already at max power (\(self.currentStep.label)), cannot escalate")
      return nil
    }

    currentStepIndex = nextStep.id
    consecutiveSuccesses = 0
    isUserOverride = false
    lastChangeReason = .escalation

    logger.info("Escalated to step \(nextStep.id): \(nextStep.label) (reason: no repeats)")

    await applyCurrentPower()
    return nextStep
  }

  /// Selects a power level explicitly. Out-of-range selections are ignored rather than clamped,
  /// so a stale picker cannot silently transmit at a level the user did not choose.
  public func setUserOverride(stepIndex: Int) async {
    guard isEnabled else { return }
    let clamped = policy.clampStepIndex(stepIndex)

    guard policy.isReachable(clamped) else {
      logger.warning("Step \(clamped) exceeds radio max, ignoring override")
      return
    }

    currentStepIndex = clamped
    isUserOverride = true
    consecutiveSuccesses = 0
    lastChangeReason = .userOverride

    logger.info("User override to step \(clamped): \(self.currentStep.label)")

    await applyCurrentPower()
  }

  /// Records that repeats were heard for the last send. Power is deliberately not lowered.
  public func onRepeatsHeard() {
    guard isEnabled else { return }
    consecutiveSuccesses += 1
  }

  /// Records that no repeats were heard for the last send.
  public func onNoRepeatsHeard() {
    guard isEnabled else { return }
    consecutiveSuccesses = 0
  }

  /// Returns to base power (new conversation, disconnect, or the user's Reset action).
  public func resetToBase() async {
    currentStepIndex = baseStepIndex
    consecutiveSuccesses = 0
    isUserOverride = false
    lastChangeReason = .reset

    logger.info("Reset to base power: step \(self.baseStepIndex) (\(self.baseStep.label))")

    await applyCurrentPower()
  }
}
