import Foundation
import os

/// Manages adaptive TX power control for radios with optional external power amplifiers.
///
/// Starts at a user-configured base power level and escalates on resend when no repeats
/// are heard. Gradually ramps back down after consecutive successful sends with repeats.
@Observable
@MainActor
public final class AdaptivePowerService {

    // MARK: - Types

    /// A discrete power step representing a target EIRP output level.
    public struct PowerStep: Identifiable, Equatable, Sendable {
        public let id: Int // index in the steps array
        public let targetMilliwatts: Int
        public let eirpDbm: Double
        public let label: String

        public init(id: Int, targetMilliwatts: Int, eirpDbm: Double, label: String) {
            self.id = id
            self.targetMilliwatts = targetMilliwatts
            self.eirpDbm = eirpDbm
            self.label = label
        }
    }

    /// Reason the power level changed (for UI display).
    public enum PowerChangeReason: Sendable {
        case userOverride
        case escalation
        case rampDown
        case reset
    }

    // MARK: - Power Step Table

    /// All available power steps, ordered low to high.
    public static let allSteps: [PowerStep] = [
        PowerStep(id: 0, targetMilliwatts: 20,   eirpDbm: 13.0, label: "20mW"),
        PowerStep(id: 1, targetMilliwatts: 100,  eirpDbm: 20.0, label: "100mW"),
        PowerStep(id: 2, targetMilliwatts: 158,  eirpDbm: 22.0, label: "158mW"),
        PowerStep(id: 3, targetMilliwatts: 200,  eirpDbm: 23.0, label: "200mW"),
        PowerStep(id: 4, targetMilliwatts: 500,  eirpDbm: 27.0, label: "500mW"),
        PowerStep(id: 5, targetMilliwatts: 700,  eirpDbm: 28.5, label: "700mW"),
        PowerStep(id: 6, targetMilliwatts: 1000, eirpDbm: 30.0, label: "1W"),
    ]

    // MARK: - Configuration

    /// External PA gain in dB (0 for normal radio, ~8 for WisMesh 1W).
    public private(set) var paGainDb: Double = 0

    /// Maximum TX power the radio chip supports (typically 22 dBm for SX1262).
    public private(set) var radioMaxDbm: Int8 = 22

    // MARK: - State

    /// The user's preferred base power step index.
    public private(set) var baseStepIndex: Int = 2 // default: 158mW

    /// The current active power step index.
    public private(set) var currentStepIndex: Int = 2

    /// Whether the current level is a user override (long-press selection).
    public private(set) var isUserOverride: Bool = false

    /// Consecutive successful sends (repeats heard) at the current or descending levels.
    public private(set) var consecutiveSuccesses: Int = 0

    /// Whether adaptive power mode is enabled.
    public private(set) var isEnabled: Bool = false


    // MARK: - Callbacks

    /// Called when power needs to change on the radio. Wired from AppState.
    public var setTxPowerHandler: ((Int8) async throws -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.mc1", category: "AdaptivePower")

    private static let rampDownThreshold = 2 // successes before stepping down
    private static let fullResetThreshold = 3 // successes at base before clearing counter

    // MARK: - Init

    public init() {}

    // MARK: - Configuration

    /// Configure the service for a specific device.
    public func configure(
        paGainDb: Double,
        radioMaxDbm: Int8 = 22,
        baseStepIndex: Int,
        enabled: Bool
    ) {
        self.paGainDb = paGainDb
        self.radioMaxDbm = radioMaxDbm
        self.baseStepIndex = clampStepIndex(baseStepIndex)
        self.isEnabled = enabled
        self.currentStepIndex = self.baseStepIndex
        self.consecutiveSuccesses = 0
        self.isUserOverride = false

        logger.info("Configured: paGain=\(paGainDb)dB, radioMax=\(radioMaxDbm)dBm, base=\(self.baseStepIndex), enabled=\(enabled)")
    }

    /// Update just the base step (from settings UI).
    public func setBaseStep(_ index: Int) {
        baseStepIndex = clampStepIndex(index)
        if !isUserOverride && currentStepIndex <= baseStepIndex {
            currentStepIndex = baseStepIndex
        }
        logger.info("Base step set to \(self.baseStepIndex) (\(self.currentStep.label))")
    }

    /// Update PA gain (from settings UI).
    public func setPAGain(_ gain: Double) {
        paGainDb = max(0, gain)
        logger.info("PA gain set to \(self.paGainDb)dB")
    }

    /// Enable or disable adaptive power mode.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            currentStepIndex = baseStepIndex
            consecutiveSuccesses = 0
            isUserOverride = false
        }
        logger.info("Adaptive power \(enabled ? "enabled" : "disabled")")
    }

    // MARK: - Computed Properties

    /// The current active power step.
    public var currentStep: PowerStep {
        Self.allSteps[currentStepIndex]
    }

    /// The base (home) power step.
    public var baseStep: PowerStep {
        Self.allSteps[baseStepIndex]
    }

    /// Available steps for the current radio configuration.
    public var availableSteps: [PowerStep] {
        Self.allSteps.filter { radioDbm(for: $0) <= radioMaxDbm }
    }

    /// Whether the current power is elevated above base.
    public var isElevated: Bool {
        currentStepIndex > baseStepIndex
    }

    /// Whether we're at max available power.
    public var isAtMax: Bool {
        guard let maxAvailable = availableSteps.last else { return true }
        return currentStepIndex >= maxAvailable.id
    }

    /// The radio TX power setting (dBm) for a given power step.
    public func radioDbm(for step: PowerStep) -> Int8 {
        Int8(clamping: Int(step.eirpDbm - paGainDb))
    }

    /// The radio TX power setting for the current step.
    public var currentRadioDbm: Int8 {
        radioDbm(for: currentStep)
    }

    // MARK: - Power Control Actions

    /// Apply the current power level to the radio.
    /// Call this before sending a message.
    /// - Returns: `true` if the power was verified on the device, `false` if it failed.
    @discardableResult
    public func applyCurrentPower() async -> Bool {
        guard isEnabled, let handler = setTxPowerHandler else { return true }

        let dbm = currentRadioDbm
        do {
            try await handler(dbm)
            logger.info("Verified TX power: \(dbm)dBm (\(self.currentStep.label))")
            return true
        } catch {
            logger.error("TX power verification FAILED for \(dbm)dBm: \(error.localizedDescription)")
            return false
        }
    }

    /// Escalate power one step up. Called on resend when no repeats were heard.
    @discardableResult
    public func escalate() async -> PowerStep? {
        guard isEnabled else { return nil }

        let available = availableSteps
        guard let currentAvailableIdx = available.firstIndex(where: { $0.id == currentStepIndex }),
              currentAvailableIdx + 1 < available.count else {
            logger.info("Already at max power (\(self.currentStep.label)), cannot escalate")
            return nil
        }

        let nextStep = available[currentAvailableIdx + 1]
        currentStepIndex = nextStep.id
        consecutiveSuccesses = 0
        isUserOverride = false

        logger.info("Escalated to step \(nextStep.id): \(nextStep.label) (reason: no repeats)")

        await applyCurrentPower()
        return nextStep
    }

    /// User manually selects a power level (persistent override from popover).
    public func setUserOverride(stepIndex: Int) async {
        guard isEnabled else { return }
        let clamped = clampStepIndex(stepIndex)

        guard radioDbm(for: Self.allSteps[clamped]) <= radioMaxDbm else {
            logger.warning("Step \(clamped) exceeds radio max, ignoring override")
            return
        }

        currentStepIndex = clamped
        isUserOverride = true
        consecutiveSuccesses = 0

        logger.info("User override to step \(clamped): \(self.currentStep.label)")

        await applyCurrentPower()
    }

    /// Notify that repeats were heard for the last sent message.
    public func onRepeatsHeard() async {
        guard isEnabled else { return }

        if isUserOverride {
            logger.debug("Repeats heard at user-override level \(self.currentStep.label), not ramping")
            return
        }

        consecutiveSuccesses += 1

        if currentStepIndex > baseStepIndex {
            if consecutiveSuccesses >= Self.rampDownThreshold {
                let available = availableSteps
                if let currentAvailableIdx = available.firstIndex(where: { $0.id == currentStepIndex }),
                   currentAvailableIdx > 0 {
                    let lowerStep = available[currentAvailableIdx - 1]
                    currentStepIndex = max(baseStepIndex, lowerStep.id)
                    consecutiveSuccesses = 0
                    logger.info("Ramped down to step \(self.currentStepIndex): \(self.currentStep.label)")
                    await applyCurrentPower()
                }
            } else {
                logger.debug("Repeats heard at elevated \(self.currentStep.label), successes: \(self.consecutiveSuccesses)/\(Self.rampDownThreshold)")
            }
        } else {
            if consecutiveSuccesses >= Self.fullResetThreshold {
                consecutiveSuccesses = 0
                logger.debug("Stable at base power, counter reset")
            }
        }
    }

    /// Notify that no repeats were heard for the last sent message.
    public func onNoRepeatsHeard() {
        guard isEnabled else { return }
        consecutiveSuccesses = 0
    }

    /// Reset to base power (e.g., on new conversation or disconnect).
    public func resetToBase() async {
        currentStepIndex = baseStepIndex
        consecutiveSuccesses = 0
        isUserOverride = false

        logger.info("Reset to base power: step \(self.baseStepIndex) (\(self.baseStep.label))")

        await applyCurrentPower()
    }

    // MARK: - Helpers

    private func clampStepIndex(_ index: Int) -> Int {
        max(0, min(index, Self.allSteps.count - 1))
    }
}
