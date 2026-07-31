import Foundation

/// The speed-adaptive sampling tier. Coarser tiers mean bigger cells, which means
/// fewer novel-cell crossings per minute, which means fewer mesh transmissions.
///
/// The tier governs *when a probe is worth transmitting* and how the live map paints
/// progress. Recorded samples are always bucketed at `SurveyGrid.baseResolution`
/// regardless of tier, so data fidelity never degrades — coverage just gets sparser
/// at speed.
public enum SamplingTier: String, CaseIterable, Sendable, Codable {
    /// ~350 m cells — walking, jogging, slow cycling.
    case fine
    /// ~920 m cells — cycling, city driving.
    case medium
    /// ~2.4 km cells — highway driving.
    case coarse

    public var resolution: Int {
        switch self {
        case .fine: SurveyGrid.baseResolution        // 9
        case .medium: SurveyGrid.baseResolution - 1  // 8
        case .coarse: SurveyGrid.baseResolution - 2  // 7
        }
    }
}

/// Maps GPS speed to a `SamplingTier` with hysteresis and a dwell time so noisy
/// speed readings can't flap the tier back and forth.
///
/// Pure state machine: callers supply timestamps, nothing here reads the clock.
public struct TierController: Sendable {

    public struct Config: Sendable {
        /// Speed at which fine→medium engages (m/s). ~16 km/h.
        public var mediumEnter: Double = 4.5
        /// Speed below which medium→fine returns (m/s). ~13 km/h.
        public var mediumExit: Double = 3.6
        /// Speed at which medium→coarse engages (m/s). ~50 km/h.
        public var coarseEnter: Double = 14.0
        /// Speed below which coarse→medium returns (m/s). ~43 km/h.
        public var coarseExit: Double = 12.0
        /// How long a candidate tier must hold before the switch commits.
        public var dwell: TimeInterval = 5.0

        public init() {}
    }

    public private(set) var current: SamplingTier
    private let config: Config
    private var candidate: SamplingTier?
    private var candidateSince: TimeInterval = 0

    public init(initial: SamplingTier = .fine, config: Config = Config()) {
        self.current = initial
        self.config = config
    }

    /// Feed a speed reading (m/s; pass nil or negative when GPS speed is invalid)
    /// and get the tier to use. Invalid speed readings keep the current tier.
    @discardableResult
    public mutating func update(speed: Double?, at now: TimeInterval) -> SamplingTier {
        guard let speed, speed >= 0 else {
            candidate = nil
            return current
        }

        let target = targetTier(for: speed)
        guard target != current else {
            candidate = nil
            return current
        }

        if candidate != target {
            candidate = target
            candidateSince = now
            return current
        }

        if now - candidateSince >= config.dwell {
            current = target
            candidate = nil
        }
        return current
    }

    /// The tier the current speed calls for, honoring hysteresis around the
    /// thresholds relative to the *current* tier.
    private func targetTier(for speed: Double) -> SamplingTier {
        switch current {
        case .fine:
            if speed >= config.coarseEnter { return .coarse }
            if speed >= config.mediumEnter { return .medium }
            return .fine
        case .medium:
            if speed >= config.coarseEnter { return .coarse }
            if speed < config.mediumExit { return .fine }
            return .medium
        case .coarse:
            if speed < config.mediumExit { return .fine }
            if speed < config.coarseExit { return .medium }
            return .coarse
        }
    }
}
