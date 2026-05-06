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

    /// Measured PA output curve mapping SX1262 config dBm to actual PA output dBm.
    public struct PACurve: Sendable {
        public let minConfig: Int8
        public let outputDbm: [Double]

        public func radioConfig(forTargetEirp target: Double) -> Int8 {
            var bestIdx = 0
            var bestDiff = Double.infinity
            for (idx, output) in outputDbm.enumerated() {
                let diff = abs(output - target)
                if diff < bestDiff {
                    bestDiff = diff
                    bestIdx = idx
                }
            }
            return Int8(bestIdx) + minConfig
        }

        public func actualOutput(atConfig config: Int8) -> Double {
            let idx = Int(config - minConfig)
            guard idx >= 0, idx < outputDbm.count else { return Double(config) }
            return outputDbm[idx]
        }

        /// WisMesh Pocket 1W measured at 915.2 MHz, SF7. Config range 0–22.
        public static let pocket1W = PACurve(minConfig: 0, outputDbm: [
             7.3,  8.4,  9.6, 10.7, 12.0, 13.2, 14.3, 15.5,
            16.6, 17.7, 18.9, 19.9, 21.0, 22.1, 23.1, 24.1,
            25.1, 26.2, 27.3, 28.0, 28.8, 29.6, 30.3
        ])

        /// Heltec V4 measured at 915 MHz. Config range 0–22.
        public static let heltecV4 = PACurve(minConfig: 0, outputDbm: [
            11.34, 12.02, 13.12, 13.61, 14.55, 15.52, 16.92, 17.43,
            18.52, 19.73, 20.93, 21.58, 22.46, 24.04, 24.86, 25.25,
            25.86, 26.60, 27.20, 27.69, 28.13, 28.26, 28.39
        ])
    }

    // MARK: - Power Step Table

    /// All available power steps, ordered low to high.
    public static let allSteps: [PowerStep] = [
        PowerStep(id: 0, targetMilliwatts: 10,   eirpDbm: 10.0, label: "10mW"),
        PowerStep(id: 1, targetMilliwatts: 20,   eirpDbm: 13.0, label: "20mW"),
        PowerStep(id: 2, targetMilliwatts: 100,  eirpDbm: 20.0, label: "100mW"),
        PowerStep(id: 3, targetMilliwatts: 158,  eirpDbm: 22.0, label: "158mW"),
        PowerStep(id: 4, targetMilliwatts: 200,  eirpDbm: 23.0, label: "200mW"),
        PowerStep(id: 5, targetMilliwatts: 500,  eirpDbm: 27.0, label: "500mW"),
        PowerStep(id: 6, targetMilliwatts: 700,  eirpDbm: 28.5, label: "700mW"),
        PowerStep(id: 7, targetMilliwatts: 1000, eirpDbm: 30.0, label: "1W"),
    ]

    // MARK: - Configuration

    /// External PA gain in dB (0 for normal radio, ~8 nominal for WisMesh 1W).
    public private(set) var paGainDb: Double = 0

    /// Measured PA output curve, if available (replaces flat gain assumption).
    public private(set) var paCurve: PACurve?

    /// Maximum TX power the radio chip supports (typically 22 dBm for SX1262).
    public private(set) var radioMaxDbm: Int8 = 22

    // MARK: - State

    /// The user's preferred base power step index.
    public private(set) var baseStepIndex: Int = 3 // default: 158mW

    /// The current active power step index.
    public private(set) var currentStepIndex: Int = 3

    /// Whether the current level is a user override (long-press selection).
    public private(set) var isUserOverride: Bool = false

    /// Consecutive successful sends (repeats heard) at the current or descending levels.
    public private(set) var consecutiveSuccesses: Int = 0

    /// Whether adaptive power mode is enabled.
    public private(set) var isEnabled: Bool = false

    /// The last device-confirmed TX power in dBm, or `nil` if not yet confirmed.
    public private(set) var confirmedRadioDbm: Int8?

    /// Whether the last power-set attempt failed verification.
    public private(set) var lastApplyFailed: Bool = false

    // MARK: - Callbacks

    /// Called when power needs to change on the radio. Wired from AppState.
    /// Returns the device-confirmed TX power in dBm.
    public var setTxPowerHandler: ((Int8) async throws -> Int8)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.mc1", category: "AdaptivePower")

    private static let maxRetries = 3
    private static let retryDelay: Duration = .milliseconds(300)

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
        self.paCurve = Self.curve(forPAGain: paGainDb)
        self.radioMaxDbm = radioMaxDbm
        self.baseStepIndex = clampStepIndex(baseStepIndex)
        self.isEnabled = enabled
        self.currentStepIndex = self.baseStepIndex
        self.consecutiveSuccesses = 0
        self.isUserOverride = false
        self.confirmedRadioDbm = nil
        self.lastApplyFailed = false

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
        paCurve = Self.curve(forPAGain: gain)
        logger.info("PA gain set to \(self.paGainDb)dB\(self.paCurve != nil ? " (measured curve)" : "")")
    }

    /// Enable or disable adaptive power mode.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            currentStepIndex = baseStepIndex
            consecutiveSuccesses = 0
            isUserOverride = false
            confirmedRadioDbm = nil
            lastApplyFailed = false
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
    /// When a measured PA curve is active, deduplicates steps that map to the same radio config.
    public var availableSteps: [PowerStep] {
        let filtered = Self.allSteps.filter { radioDbm(for: $0) <= radioMaxDbm }
        guard paCurve != nil else { return filtered }
        var seenConfigs = Set<Int8>()
        return filtered.filter { seenConfigs.insert(radioDbm(for: $0)).inserted }
    }

    /// Whether the current power is elevated above base.
    public var isElevated: Bool {
        currentStepIndex > baseStepIndex
    }

    /// Whether the device-confirmed power matches the intended power.
    public var isPowerConfirmed: Bool {
        guard let confirmed = confirmedRadioDbm else { return false }
        return confirmed == currentRadioDbm && !lastApplyFailed
    }

    /// Whether we're at max available power.
    public var isAtMax: Bool {
        guard let maxAvailable = availableSteps.last else { return true }
        return currentStepIndex >= maxAvailable.id
    }

    /// The radio TX power setting (dBm) for a given power step.
    public func radioDbm(for step: PowerStep) -> Int8 {
        if let curve = paCurve {
            return curve.radioConfig(forTargetEirp: step.eirpDbm)
        }
        return Int8(clamping: Int(step.eirpDbm - paGainDb))
    }

    /// The actual expected EIRP output for a step, accounting for measured PA curve.
    public func actualEirpDbm(for step: PowerStep) -> Double {
        if let curve = paCurve {
            let config = radioDbm(for: step)
            return curve.actualOutput(atConfig: config)
        }
        return step.eirpDbm
    }

    /// Actual output power in milliwatts for a step.
    public func actualMilliwatts(for step: PowerStep) -> Int {
        let dbm = actualEirpDbm(for: step)
        return Int(round(pow(10.0, dbm / 10.0)))
    }

    /// The radio TX power setting for the current step.
    public var currentRadioDbm: Int8 {
        radioDbm(for: currentStep)
    }

    // MARK: - Power Control Actions

    /// Apply the current power level to the radio, retrying up to 3 times on failure.
    /// Call this before sending a message.
    /// - Returns: `true` if the power was verified on the device, `false` if all retries failed.
    @discardableResult
    public func applyCurrentPower() async -> Bool {
        guard isEnabled, let handler = setTxPowerHandler else { return true }

        let dbm = currentRadioDbm

        for attempt in 1...Self.maxRetries {
            do {
                let confirmed = try await handler(dbm)
                confirmedRadioDbm = confirmed
                lastApplyFailed = false
                if attempt > 1 {
                    logger.info("TX power verified on attempt \(attempt): \(dbm)dBm → device confirmed \(confirmed)dBm")
                } else {
                    logger.info("Verified TX power: \(dbm)dBm → device confirmed \(confirmed)dBm (\(self.currentStep.label))")
                }
                return true
            } catch {
                logger.warning("TX power attempt \(attempt)/\(Self.maxRetries) failed for \(dbm)dBm: \(error.localizedDescription)")
                if attempt < Self.maxRetries {
                    try? await Task.sleep(for: Self.retryDelay)
                }
            }
        }

        lastApplyFailed = true
        logger.error("TX power verification FAILED after \(Self.maxRetries) attempts for \(dbm)dBm")
        return false
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
    /// Power is NOT automatically ramped down — staying at the level that works
    /// avoids oscillation. Power only resets on new conversation, disconnect, or manual change.
    public func onRepeatsHeard() {
        guard isEnabled else { return }
        consecutiveSuccesses += 1

        if isElevated {
            logger.debug("Repeats heard at elevated \(self.currentStep.label), staying (success #\(self.consecutiveSuccesses))")
        } else {
            logger.debug("Repeats heard at base \(self.currentStep.label)")
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

    private static func curve(forPAGain gain: Double) -> PACurve? {
        switch gain {
        case 8.0: .pocket1W
        case 11.0: .heltecV4
        default: nil
        }
    }
}
