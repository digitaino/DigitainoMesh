import Foundation
import OSLog
import SurveyKit

/// The radio operations a survey probe needs. `ServiceContainer` provides the real
/// implementation over BinaryProtocolService/MessageService; tests inject a spy.
public protocol SurveyProbeTransmitter: Sendable {
    /// Zero-hop node discover request (yields TX SNR via responses).
    func sendDiscover() async throws
    /// Hop-by-hop trace (maps multi-hop paths).
    func sendTrace() async throws
    /// Channel flood message — the only transmission that floods the whole mesh.
    func sendFloodMessage(probeNumber: Int) async throws
}

/// All survey transmissions flow through this actor. It owns a `SamplingPolicy`
/// (SurveyKit) — speed-adaptive cell tiers plus a hard token-bucket TX budget — and
/// is the only component allowed to ask the radio to transmit for survey purposes.
///
/// Replaces the probe loop that previously lived inside the 2,551-line
/// SignalSurveyViewModel: the engine is UI-independent, survives view lifecycle,
/// and is deterministic enough to unit test (policy is pure; the transmitter is a
/// protocol).
public actor SurveyProbeEngine {

    /// UI-facing state snapshot, emitted on every change via `snapshots`.
    public struct Snapshot: Equatable, Sendable {
        /// Active sampling tier (auto-selected from speed unless overridden).
        public var tier: SamplingTier = .fine
        /// Whether the tier came from Auto (speed) or a manual override.
        public var isAutoTier: Bool = true
        /// TX budget tokens currently available / capacity (for the budget gauge).
        public var budgetAvailable: Double = 0
        public var budgetCapacity: Double = 0
        /// Probe cycles transmitted this session.
        public var probeCount: Int = 0
        /// Flood messages transmitted this session.
        public var floodCount: Int = 0
        public var lastProbeAt: Date?
        public var isRunning: Bool = false
    }

    private let logger = Logger(subsystem: "com.mc1", category: "SurveyProbeEngine")

    private var policy: SamplingPolicy
    private let config: SamplingPolicy.Config
    private var transmitter: SurveyProbeTransmitter?
    private var floodEnabled = true
    private var snapshot = Snapshot()
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    /// Serialized transmission state — prevents the racy overlapping `sendProbe`
    /// calls of the old implementation (the flood quota could be exceeded when
    /// several fire-and-forget probes were in flight at once).
    private var transmitting = false

    public init(config: SamplingPolicy.Config = .init()) {
        self.config = config
        self.policy = SamplingPolicy(config: config, at: Date().timeIntervalSince1970)
        self.snapshot.budgetCapacity = config.bucketCapacity
        self.snapshot.budgetAvailable = config.bucketCapacity
    }

    // MARK: - Session lifecycle

    /// Arms the engine for a session. A fresh policy resets novelty/flood/budget state.
    public func start(transmitter: SurveyProbeTransmitter, floodEnabled: Bool) {
        // With floods disabled the policy shouldn't spend flood tokens at all —
        // zero the quota rather than filtering at transmission time.
        var sessionConfig = config
        if !floodEnabled { sessionConfig.floodsPerTierCell = 0 }
        self.policy = SamplingPolicy(config: sessionConfig, at: Date().timeIntervalSince1970)
        self.transmitter = transmitter
        self.floodEnabled = floodEnabled
        snapshot = Snapshot(
            budgetAvailable: config.bucketCapacity,
            budgetCapacity: config.bucketCapacity,
            isRunning: true
        )
        publish()
        logger.info("Probe engine started (flood: \(floodEnabled))")
    }

    public func stop() {
        transmitter = nil
        snapshot.isRunning = false
        publish()
        logger.info("Probe engine stopped")
    }

    public func setFloodEnabled(_ enabled: Bool) {
        floodEnabled = enabled
    }

    /// Manual tier override; nil returns to automatic speed-based selection.
    public func setTierOverride(_ tier: SamplingTier?) {
        policy.tierOverride = tier
        snapshot.tier = policy.currentTier
        snapshot.isAutoTier = tier == nil
        publish()
    }

    // MARK: - State stream

    /// Snapshots for the UI. Emits the current state immediately on subscription.
    public func snapshots() -> AsyncStream<Snapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func publish() {
        let now = Date().timeIntervalSince1970
        snapshot.budgetAvailable = policy.budgetAvailable(at: now)
        snapshot.tier = policy.currentTier
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    // MARK: - Inputs

    /// Feed a GPS update. The policy decides whether the movement warrants a probe;
    /// if so, the transmissions happen here (serialized, budget already consumed).
    public func locationDidUpdate(
        latitude: Double,
        longitude: Double,
        speedMetersPerSecond: Double?
    ) async {
        guard snapshot.isRunning, !transmitting else { return }
        let plan = policy.locationUpdate(
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            speed: speedMetersPerSecond,
            at: Date().timeIntervalSince1970
        )
        if let plan {
            await execute(plan)
        } else {
            publish()   // keep the tier/budget gauge fresh while moving
        }
    }

    /// Record that a survey sample landed at this location (any source — probe
    /// responses or passive RX). Suppresses further automatic probes for the
    /// containing cell at every tier.
    public func recordSample(latitude: Double, longitude: Double) {
        guard let cell = SurveyGrid.cell(
            containing: GeoCoordinate(latitude: latitude, longitude: longitude)
        ) else { return }
        policy.recordSample(in: cell)
    }

    /// User-initiated probe. Bypasses novelty/cadence but not the TX budget; may
    /// spend the reserve automatic probes can't touch. Returns false when the
    /// budget refuses (UI shows "budget exhausted" feedback).
    public func manualProbe(latitude: Double, longitude: Double) async -> Bool {
        guard snapshot.isRunning else { return false }
        guard let plan = policy.manualProbe(
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            at: Date().timeIntervalSince1970
        ) else {
            publish()
            return false
        }
        await execute(plan)
        return true
    }

    // MARK: - Transmission

    private func execute(_ plan: SamplingPolicy.ProbePlan) async {
        guard let transmitter else { return }
        transmitting = true
        defer { transmitting = false }

        snapshot.probeCount += 1
        snapshot.lastProbeAt = Date()
        let probeNumber = snapshot.probeCount
        publish()

        do {
            try await transmitter.sendDiscover()
        } catch {
            logger.warning("Probe #\(probeNumber) discover failed: \(error.localizedDescription)")
        }

        try? await Task.sleep(for: .seconds(0.3))

        do {
            try await transmitter.sendTrace()
        } catch {
            logger.warning("Probe #\(probeNumber) trace failed: \(error.localizedDescription)")
        }

        if plan.includeFlood && floodEnabled {
            try? await Task.sleep(for: .seconds(0.3))
            do {
                try await transmitter.sendFloodMessage(probeNumber: probeNumber)
                snapshot.floodCount += 1
            } catch {
                logger.warning("Probe #\(probeNumber) flood failed: \(error.localizedDescription)")
            }
        }

        logger.debug("Probe #\(probeNumber) sent (tier \(plan.tier.rawValue), flood: \(plan.includeFlood && self.floodEnabled))")
        publish()
    }
}
