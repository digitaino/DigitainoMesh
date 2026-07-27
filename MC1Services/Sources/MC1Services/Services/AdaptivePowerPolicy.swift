import Foundation

/// Pure decision core for adaptive TX power.
///
/// Holds no mutable state and performs no I/O: every member is a function of the
/// radio's amplifier configuration and a caller-supplied step index. `AdaptivePowerService`
/// owns the live state and the radio writes; the retry card described in
/// `docs/MIGRATION_PLAN.md` §3 row C4 consumes the same escalation rules from here, so
/// nothing power-related may be duplicated in a view model.
public struct AdaptivePowerPolicy: Sendable, Equatable {
  // MARK: - Types

  /// A discrete power step representing a target EIRP output level.
  public struct PowerStep: Identifiable, Equatable, Sendable {
    /// Index into ``AdaptivePowerPolicy/allSteps``.
    public let id: Int
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

  /// Measured PA output curve mapping SX1262 config dBm to actual PA output dBm.
  ///
  /// Flat `paGainDb` arithmetic is wrong for real amplifiers, which compress near the top
  /// of their range; a measured curve replaces the subtraction with a nearest-output lookup.
  public struct PACurve: Sendable, Equatable {
    public let minConfig: Int8
    public let outputDbm: [Double]

    public init(minConfig: Int8, outputDbm: [Double]) {
      self.minConfig = minConfig
      self.outputDbm = outputDbm
    }

    /// The radio config value whose measured output lands closest to `target`.
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

    /// The measured output for a radio config value, falling back to the config value
    /// itself when it falls outside the measured range.
    public func actualOutput(atConfig config: Int8) -> Double {
      let idx = Int(config - minConfig)
      guard idx >= 0, idx < outputDbm.count else { return Double(config) }
      return outputDbm[idx]
    }

    /// WisMesh Pocket 1W measured at 915.2 MHz, SF7. Config range 0–22.
    public static let pocket1W = PACurve(minConfig: 0, outputDbm: [
      7.3, 8.4, 9.6, 10.7, 12.0, 13.2, 14.3, 15.5,
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

  /// All available power steps, ordered low to high. Step indices are persisted in
  /// `DevicePreferenceStore`, so entries may be appended but never reordered or removed.
  public static let allSteps: [PowerStep] = [
    PowerStep(id: 0, targetMilliwatts: 10, eirpDbm: 10.0, label: "10mW"),
    PowerStep(id: 1, targetMilliwatts: 20, eirpDbm: 13.0, label: "20mW"),
    PowerStep(id: 2, targetMilliwatts: 100, eirpDbm: 20.0, label: "100mW"),
    PowerStep(id: 3, targetMilliwatts: 158, eirpDbm: 22.0, label: "158mW"),
    PowerStep(id: 4, targetMilliwatts: 200, eirpDbm: 23.0, label: "200mW"),
    PowerStep(id: 5, targetMilliwatts: 500, eirpDbm: 27.0, label: "500mW"),
    PowerStep(id: 6, targetMilliwatts: 700, eirpDbm: 28.5, label: "700mW"),
    PowerStep(id: 7, targetMilliwatts: 1000, eirpDbm: 30.0, label: "1W")
  ]

  /// Default base step index when the user has never chosen one (158mW).
  public static let defaultBaseStepIndex = 3

  // MARK: - Configuration

  /// External PA gain in dB (0 for a bare radio, ~8 nominal for WisMesh 1W).
  public let paGainDb: Double

  /// Measured PA output curve, when one is known for `paGainDb`.
  public let paCurve: PACurve?

  /// Maximum TX power the radio chip supports (typically 22 dBm for SX1262).
  public let radioMaxDbm: Int8

  // MARK: - Init

  /// - Parameters:
  ///   - paGainDb: External amplifier gain. Negative values are clamped to zero.
  ///   - radioMaxDbm: The connected radio's `maxTxPower`.
  public init(paGainDb: Double = 0, radioMaxDbm: Int8 = 22) {
    let gain = max(0, paGainDb)
    self.paGainDb = gain
    paCurve = Self.curve(forPAGain: gain)
    self.radioMaxDbm = radioMaxDbm
  }

  /// The measured curve for a known amplifier gain, or `nil` to use flat-gain arithmetic.
  public static func curve(forPAGain gain: Double) -> PACurve? {
    switch gain {
    case 8.0: .pocket1W
    case 11.0: .heltecV4
    default: nil
    }
  }

  // MARK: - Step Selection

  /// Steps this radio can actually reach.
  ///
  /// Steps whose required radio config exceeds `radioMaxDbm` are dropped. With a measured
  /// curve, steps that collapse onto the same radio config are deduplicated so the picker
  /// never offers two entries that transmit identically.
  public var availableSteps: [PowerStep] {
    let filtered = Self.allSteps.filter { radioDbm(for: $0) <= radioMaxDbm }
    guard paCurve != nil else { return filtered }
    var seenConfigs = Set<Int8>()
    return filtered.filter { seenConfigs.insert(radioDbm(for: $0)).inserted }
  }

  /// Clamps an arbitrary index into ``allSteps`` bounds.
  public func clampStepIndex(_ index: Int) -> Int {
    max(0, min(index, Self.allSteps.count - 1))
  }

  /// The step reached by escalating one notch above `stepIndex`, or `nil` when already
  /// at the highest reachable step.
  ///
  /// Escalation walks ``availableSteps``, not ``allSteps``, so a deduplicated or
  /// radio-capped step is never selected as the next rung.
  public func escalatedStep(from stepIndex: Int) -> PowerStep? {
    let available = availableSteps
    guard let currentIdx = available.firstIndex(where: { $0.id == stepIndex }),
          currentIdx + 1 < available.count else { return nil }
    return available[currentIdx + 1]
  }

  /// Whether `stepIndex` is the highest step this radio can reach.
  public func isAtMax(_ stepIndex: Int) -> Bool {
    guard let maxAvailable = availableSteps.last else { return true }
    return stepIndex >= maxAvailable.id
  }

  /// Whether `stepIndex` can be selected on this radio at all.
  public func isReachable(_ stepIndex: Int) -> Bool {
    let clamped = clampStepIndex(stepIndex)
    return radioDbm(for: Self.allSteps[clamped]) <= radioMaxDbm
  }

  // MARK: - Power Arithmetic

  /// The radio TX power setting (dBm) that produces `step`'s target EIRP.
  public func radioDbm(for step: PowerStep) -> Int8 {
    if let paCurve {
      return paCurve.radioConfig(forTargetEirp: step.eirpDbm)
    }
    return Int8(clamping: Int(step.eirpDbm - paGainDb))
  }

  /// The expected EIRP for `step`, accounting for a measured PA curve's compression.
  public func actualEirpDbm(for step: PowerStep) -> Double {
    if let paCurve {
      return paCurve.actualOutput(atConfig: radioDbm(for: step))
    }
    return step.eirpDbm
  }

  /// The expected output for `step` in milliwatts.
  public func actualMilliwatts(for step: PowerStep) -> Int {
    Int(round(pow(10.0, actualEirpDbm(for: step) / 10.0)))
  }
}
