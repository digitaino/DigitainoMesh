import Foundation

/// Every survey transmission decision flows through this one type.
///
/// The policy combines four mechanisms, all tunable via `Config`:
///  1. **Token bucket** — the hard ceiling on transmissions per minute, shared by
///     automatic and manual probes.
///  2. **Speed-adaptive tier** — fast movement coarsens the sampling cell, so cell
///     crossings (the probe trigger) happen at a sane rate at any speed.
///  3. **Novelty gating** — automatic probes fire only on entering a tier-cell that has
///     no sample yet this session; passive RX still records everything for free.
///  4. **Flood quota** — at most one channel flood per tier-cell per session, on top of
///     the bucket cost.
///
/// Pure state machine — no clocks, no radios, no location services. The engine feeds it
/// location updates and sample events; it answers with decisions.
public struct SamplingPolicy: Sendable {

    public struct Config: Sendable {
        /// Hard TX ceiling: bucket capacity (in transmission tokens).
        public var bucketCapacity: Double = 6
        /// Sustained refill rate: 1 token / 10 s ≈ 6 transmissions/minute.
        public var bucketRefillPerSecond: Double = 0.1
        /// Reserve automatic probes may not dip into, kept for the manual button.
        public var manualReserve: Double = 2
        /// Token cost of the discover + trace pair sent by every probe.
        public var probeCost: Double = 2
        /// Additional token cost of a channel flood.
        public var floodCost: Double = 2
        /// Minimum interval between automatic probe cycles (seconds).
        public var minProbeInterval: TimeInterval = 8
        /// When stationary in an unsampled cell, retry a probe at most this often.
        public var stationaryRetryInterval: TimeInterval = 60
        /// Max channel floods per tier-cell per session.
        public var floodsPerTierCell: Int = 1
        public var tier = TierController.Config()

        public init() {}
    }

    /// What the engine should transmit right now.
    public struct ProbePlan: Equatable, Sendable {
        /// Tier-resolution cell that triggered the probe (novelty bookkeeping key).
        public let tierCell: H3Cell
        /// Base-resolution cell at the trigger location (recording key).
        public let baseCell: H3Cell
        public let tier: SamplingTier
        /// Whether the plan includes a channel flood (quota + budget allowed it).
        public let includeFlood: Bool
    }

    public private(set) var tierController: TierController
    /// Manual tier override (nil = automatic speed-based selection, the default).
    public var tierOverride: SamplingTier?
    private var config: Config
    private var bucket: TokenBucket
    /// Tier-cells (any resolution) that already have at least one sample this session.
    private var sampledTierCells: Set<H3Cell> = []
    /// Tier-cells whose flood quota is spent.
    private var floodedTierCells: [H3Cell: Int] = [:]
    private var lastProbeAt: TimeInterval = -.infinity
    private var lastProbeTierCell: H3Cell?

    public init(config: Config = Config(), at now: TimeInterval) {
        self.config = config
        self.tierController = TierController(config: config.tier)
        self.bucket = TokenBucket(
            capacity: config.bucketCapacity,
            refillPerSecond: config.bucketRefillPerSecond,
            at: now
        )
    }

    /// Current sampling tier (for UI display).
    public var currentTier: SamplingTier { tierOverride ?? tierController.current }

    /// Tokens available right now (for UI display of the TX budget).
    public mutating func budgetAvailable(at now: TimeInterval) -> Double {
        bucket.available(at: now)
    }

    /// Feed a location update; returns a probe plan when a transmission is warranted.
    ///
    /// - Parameters:
    ///   - coordinate: current GPS position (degrees)
    ///   - speed: GPS ground speed in m/s, nil/negative when invalid
    ///   - now: monotonic timestamp in seconds
    public mutating func locationUpdate(
        coordinate: GeoCoordinate,
        speed: Double?,
        at now: TimeInterval
    ) -> ProbePlan? {
        // The controller keeps tracking speed even under an override, so clearing
        // the override snaps straight to the right automatic tier.
        let autoTier = tierController.update(speed: speed, at: now)
        let tier = tierOverride ?? autoTier
        guard let tierCell = SurveyGrid.cell(containing: coordinate, resolution: tier.resolution),
              let baseCell = SurveyGrid.cell(containing: coordinate)
        else { return nil }

        // Novelty: only unsampled tier-cells trigger automatic probes. A cell we've
        // already probed (successfully or not) only re-triggers on the slow
        // stationary-retry cadence, and only while it remains sample-free.
        let isNovel = !sampledTierCells.contains(tierCell)
        guard isNovel else { return nil }

        let sinceLast = now - lastProbeAt
        guard sinceLast >= config.minProbeInterval else { return nil }
        if tierCell == lastProbeTierCell, sinceLast < config.stationaryRetryInterval {
            return nil
        }

        // Budget: automatic probes leave the manual reserve untouched.
        guard bucket.tryConsume(config.probeCost, at: now, floor: config.manualReserve) else {
            return nil
        }

        let includeFlood = consumeFloodIfAllowed(tierCell: tierCell, at: now, floor: config.manualReserve)

        lastProbeAt = now
        lastProbeTierCell = tierCell
        return ProbePlan(tierCell: tierCell, baseCell: baseCell, tier: tier, includeFlood: includeFlood)
    }

    /// A user-initiated probe. Bypasses novelty and cadence, but not the bucket —
    /// it may spend the reserve automatic probes can't touch.
    public mutating func manualProbe(
        coordinate: GeoCoordinate,
        at now: TimeInterval
    ) -> ProbePlan? {
        let tier = tierOverride ?? tierController.current
        guard let tierCell = SurveyGrid.cell(containing: coordinate, resolution: tier.resolution),
              let baseCell = SurveyGrid.cell(containing: coordinate)
        else { return nil }
        guard bucket.tryConsume(config.probeCost, at: now) else { return nil }

        let includeFlood = consumeFloodIfAllowed(tierCell: tierCell, at: now, floor: 0)
        lastProbeAt = now
        lastProbeTierCell = tierCell
        return ProbePlan(tierCell: tierCell, baseCell: baseCell, tier: tier, includeFlood: includeFlood)
    }

    /// Record that a sample landed in `baseCell` (from any source — probe responses or
    /// passive RX). Marks the containing cell at every tier resolution so novelty
    /// gating sees it no matter which tier is active later.
    public mutating func recordSample(in baseCell: H3Cell) {
        for tier in SamplingTier.allCases {
            if let cell = SurveyGrid.parent(of: baseCell, resolution: tier.resolution) {
                sampledTierCells.insert(cell)
            }
        }
    }

    private mutating func consumeFloodIfAllowed(
        tierCell: H3Cell,
        at now: TimeInterval,
        floor: Double
    ) -> Bool {
        guard floodedTierCells[tierCell, default: 0] < config.floodsPerTierCell else {
            return false
        }
        guard bucket.tryConsume(config.floodCost, at: now, floor: floor) else { return false }
        floodedTierCells[tierCell, default: 0] += 1
        return true
    }
}
