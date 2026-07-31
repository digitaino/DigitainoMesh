import Foundation

// MARK: - Target

/// A repeater a benchmark run addresses, as the engine needs it.
///
/// Only two things matter to a probe: the public key it is addressed by, and a name to
/// show. Everything else about a contact — favourite state, path, advert timestamps — is a
/// UI concern and stays in the app layer, so the engine can be driven from a literal.
public struct BenchmarkTarget: Sendable, Hashable, Identifiable {
  /// Full public key. The leading bytes of it are what a trace path is built from.
  public let publicKey: Data
  /// Display name at the time the run was configured.
  public let name: String

  public var id: Data {
    publicKey
  }

  public init(publicKey: Data, name: String) {
    self.publicKey = publicKey
    self.name = name
  }

  /// The leading key bytes a trace path addresses this repeater with.
  ///
  /// Trace hops are 1, 2 or 3 bytes wide — see `DeviceDTO.traceHashSize` and
  /// ``PathEncoding/hashSize(forMode:)``.
  public func pathHash(byteWidth: Int) -> Data {
    Data(publicKey.prefix(max(1, byteWidth)))
  }

  /// Short hex form used in rows and in resolved-name fallbacks.
  public var hexID: String {
    publicKey.prefix(NodeHexID.maxByteWidth).map { String(format: "%02X", $0) }.joined()
  }

  /// The identity this target is matched against signal-bars rows and watch state with.
  public func hexID(byteWidth: Int) -> NodeHexID? {
    NodeHexID(data: publicKey.prefix(max(1, byteWidth)))
  }
}

// MARK: - Hops

/// One node in a completed trace, with the SNR *it* measured when it received the packet.
public struct BenchmarkHop: Sendable, Equatable {
  /// Where the hop sits in the path. The endpoints are this radio; everything between is
  /// mesh infrastructure, and only those carry usable directional SNR.
  public enum Position: Sendable, Equatable {
    case start
    case intermediate
    case end
  }

  public let position: Position
  /// Hash bytes as the firmware reported them, `nil` for the endpoints.
  public let hash: Data?
  /// Resolved name, or `nil` when nothing in the run answers to the hash.
  public var name: String?
  public let snr: Double

  public init(position: Position, hash: Data?, name: String?, snr: Double) {
    self.position = position
    self.hash = hash
    self.name = name
    self.snr = snr
  }

  /// Name if resolved, otherwise the short hex of the hash, otherwise `nil`.
  public var label: String? {
    if let name { return name }
    guard let hash, !hash.isEmpty else { return nil }
    return hash.prefix(2).map { String(format: "%02X", $0) }.joined()
  }
}

// MARK: - Outcome

/// The result of one probe in a target's batch.
public struct BenchmarkTraceOutcome: Sendable, Equatable, Identifiable {
  /// Why a probe produced no measurement.
  public enum Failure: Sendable, Equatable {
    /// The probe was sent and nothing came back inside the timeout.
    case timeout
    /// The radio refused the send; nothing went on the air.
    case sendFailed
  }

  public let id: UUID
  /// 1-based position within this target's batch.
  public let sequence: Int
  public let startedAt: Date
  /// Round-trip time, 0 for failures.
  public let durationMs: Int
  public let hops: [BenchmarkHop]
  public let failure: Failure?

  public init(
    id: UUID = UUID(),
    sequence: Int,
    startedAt: Date,
    durationMs: Int,
    hops: [BenchmarkHop],
    failure: Failure?
  ) {
    self.id = id
    self.sequence = sequence
    self.startedAt = startedAt
    self.durationMs = durationMs
    self.hops = hops
    self.failure = failure
  }

  public var success: Bool {
    failure == nil
  }

  /// SNRs of the intermediate hops in path order.
  ///
  /// This is the array persistence stores as a run's `hopsSNR`, and the array
  /// ``BenchmarkScoring/txHopIndex`` and ``BenchmarkScoring/rxHopIndex`` index into.
  public var intermediateSNRs: [Double] {
    hops.filter { $0.position == .intermediate }.map(\.snr)
  }
}

// MARK: - Per-target result

/// Everything measured for one target, accumulated live as the batch runs.
///
/// Every figure on it is a call into ``BenchmarkScoring``; nothing is computed twice, so a
/// row rendered mid-run and a row reloaded from history agree by construction.
public struct BenchmarkTargetResult: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let target: BenchmarkTarget
  public var outcomes: [BenchmarkTraceOutcome]
  /// Whether the whole batch for this target has finished (or was cancelled out of).
  public var isComplete: Bool

  public init(
    id: UUID = UUID(),
    target: BenchmarkTarget,
    outcomes: [BenchmarkTraceOutcome] = [],
    isComplete: Bool = false
  ) {
    self.id = id
    self.target = target
    self.outcomes = outcomes
    self.isComplete = isComplete
  }

  public var totalCount: Int {
    outcomes.count
  }

  public var successCount: Int {
    outcomes.count(where: \.success)
  }

  public var successRate: Int {
    BenchmarkScoring.successRate(successes: successCount, total: totalCount)
  }

  public var averageRTT: Int? {
    BenchmarkScoring.averageRTT(outcomes)
  }

  public var minRTT: Int? {
    BenchmarkScoring.minRTT(outcomes)
  }

  public var maxRTT: Int? {
    BenchmarkScoring.maxRTT(outcomes)
  }

  /// How well the *target* hears the test repeater — the outbound leg.
  public var txSNR: Double? {
    BenchmarkScoring.directionalSNR(outcomes, hopIndex: BenchmarkScoring.txHopIndex)
  }

  /// How well the *test repeater* hears the target — the return leg.
  public var rxSNR: Double? {
    BenchmarkScoring.directionalSNR(outcomes, hopIndex: BenchmarkScoring.rxHopIndex)
  }
}

// MARK: - Plan

/// What a run is going to do: one test repeater, a set of targets, and a batch size.
public struct BenchmarkPlan: Sendable, Equatable {
  public var testRepeater: BenchmarkTarget?
  public var targets: [BenchmarkTarget]
  public var tracesPerTarget: Int

  public init(
    testRepeater: BenchmarkTarget? = nil,
    targets: [BenchmarkTarget] = [],
    tracesPerTarget: Int = RepeaterBenchmarkPolicy.defaultTracesPerTarget
  ) {
    self.testRepeater = testRepeater
    self.targets = targets
    self.tracesPerTarget = tracesPerTarget
  }

  /// Whether the plan describes something the engine can actually run.
  public var isRunnable: Bool {
    testRepeater != nil && !targets.isEmpty && tracesPerTarget > 0
  }

  /// Targets excluding the test repeater — a repeater cannot benchmark itself.
  public func selectable(from candidates: [BenchmarkTarget]) -> [BenchmarkTarget] {
    guard let testRepeater else { return candidates }
    return candidates.filter { $0.publicKey != testRepeater.publicKey }
  }

  public func isSelected(_ target: BenchmarkTarget) -> Bool {
    targets.contains { $0.publicKey == target.publicKey }
  }
}

// MARK: - Snapshot

/// Everything the benchmark UI renders, as one immutable value.
///
/// Published on every observable change and never on an unchanged one, so a SwiftUI façade
/// is a subscription and an assignment — the same contract `SignalBarsSnapshot` has.
public struct RepeaterBenchmarkSnapshot: Sendable, Equatable {
  public let plan: BenchmarkPlan
  /// Live results, appended to as probes complete.
  public let results: [BenchmarkTargetResult]
  public let isRunning: Bool
  /// 1-based index of the target being probed, `0` when idle.
  public let currentTargetIndex: Int
  /// 1-based index of the probe in flight, `0` when idle.
  public let currentTraceIndex: Int
  /// When the last run finished, `nil` while one has never completed in this session.
  public let completedAt: Date?

  public init(
    plan: BenchmarkPlan,
    results: [BenchmarkTargetResult],
    isRunning: Bool,
    currentTargetIndex: Int,
    currentTraceIndex: Int,
    completedAt: Date?
  ) {
    self.plan = plan
    self.results = results
    self.isRunning = isRunning
    self.currentTargetIndex = currentTargetIndex
    self.currentTraceIndex = currentTraceIndex
    self.completedAt = completedAt
  }

  public var totalTargets: Int {
    plan.targets.count
  }

  /// Probes finished over probes planned, `0` when there is nothing to do.
  ///
  /// Counted from the outcomes, not from the indices: `currentTraceIndex` names the probe in
  /// flight, so counting it would reach 100% the moment the last probe was *sent*.
  public var progressFraction: Double {
    let total = totalTargets * plan.tracesPerTarget
    guard total > 0 else { return 0 }
    let done = results.reduce(0) { $0 + $1.outcomes.count }
    return min(1, Double(done) / Double(total))
  }

  /// Whether there is anything worth saving to history.
  public var hasResults: Bool {
    results.contains { !$0.outcomes.isEmpty }
  }

  public static func idle(plan: BenchmarkPlan = BenchmarkPlan()) -> RepeaterBenchmarkSnapshot {
    RepeaterBenchmarkSnapshot(
      plan: plan,
      results: [],
      isRunning: false,
      currentTargetIndex: 0,
      currentTraceIndex: 0,
      completedAt: nil
    )
  }
}
