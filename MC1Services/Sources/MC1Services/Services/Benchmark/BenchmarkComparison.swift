import Foundation

// MARK: - Run group

/// One saved benchmark run: every target measured under the same note.
///
/// The note is the identity because that is what the user changes between runs — swap an
/// antenna, re-run with a new note, compare the two groups.
public struct BenchmarkRunGroup: Sendable, Equatable, Identifiable {
  public var id: String {
    note
  }

  /// The note the run was saved under; empty when it was saved without one.
  public let note: String
  /// One saved path per target.
  public let paths: [SavedTracePathDTO]
  /// The most recent run date across the group's paths.
  public let date: Date
  /// Mean of the per-path average round trips, `0` when nothing succeeded.
  public let averageRTT: Int
  /// Mean of the per-path success rates.
  public let averageSuccessRate: Int

  public init(
    note: String,
    paths: [SavedTracePathDTO],
    date: Date,
    averageRTT: Int,
    averageSuccessRate: Int
  ) {
    self.note = note
    self.paths = paths
    self.date = date
    self.averageRTT = averageRTT
    self.averageSuccessRate = averageSuccessRate
  }

  /// Names of the targets this run covered, in stored order.
  public var targetNames: [String] {
    paths.compactMap { BenchmarkNaming.components(from: $0.name)?.target }
  }

  /// The test repeater the run was measured through, when the names agree on one.
  public var testRepeaterName: String? {
    let names = Set(paths.compactMap { BenchmarkNaming.components(from: $0.name)?.testRepeater })
      .filter { !$0.isEmpty }
    return names.count == 1 ? names.first : nil
  }
}

// MARK: - Comparison row

/// One target as measured in two runs, with the deltas between them.
///
/// Every delta is `B − A`, so a *positive* SNR delta is an improvement and a *negative* RTT
/// delta is an improvement. Which direction is good is the caller's to colour;
/// ``BenchmarkComparison/isImprovement(delta:lowerIsBetter:)`` gives the same answer the UI
/// uses so the rule is stated once.
public struct BenchmarkComparisonRow: Sendable, Equatable, Identifiable {
  public var id: String {
    targetName
  }

  public let targetName: String
  public let rttA: Int?
  public let rttB: Int?
  public let successRateA: Int?
  public let successRateB: Int?
  public let txSNRA: Double?
  public let txSNRB: Double?
  public let rxSNRA: Double?
  public let rxSNRB: Double?

  public init(
    targetName: String,
    rttA: Int?,
    rttB: Int?,
    successRateA: Int?,
    successRateB: Int?,
    txSNRA: Double?,
    txSNRB: Double?,
    rxSNRA: Double?,
    rxSNRB: Double?
  ) {
    self.targetName = targetName
    self.rttA = rttA
    self.rttB = rttB
    self.successRateA = successRateA
    self.successRateB = successRateB
    self.txSNRA = txSNRA
    self.txSNRB = txSNRB
    self.rxSNRA = rxSNRA
    self.rxSNRB = rxSNRB
  }

  public var rttDelta: Int? {
    BenchmarkComparison.delta(rttA, rttB)
  }

  public var successRateDelta: Int? {
    BenchmarkComparison.delta(successRateA, successRateB)
  }

  public var txDelta: Double? {
    BenchmarkComparison.delta(txSNRA, txSNRB)
  }

  public var rxDelta: Double? {
    BenchmarkComparison.delta(rxSNRA, rxSNRB)
  }
}

/// The headline numbers over a whole comparison.
public struct BenchmarkComparisonSummary: Sendable, Equatable {
  public let rttDelta: Int?
  public let txSNRDelta: Double?
  public let rxSNRDelta: Double?

  public init(rttDelta: Int?, txSNRDelta: Double?, rxSNRDelta: Double?) {
    self.rttDelta = rttDelta
    self.txSNRDelta = txSNRDelta
    self.rxSNRDelta = rxSNRDelta
  }

  /// Whether anything at all could be compared.
  public var isEmpty: Bool {
    rttDelta == nil && txSNRDelta == nil && rxSNRDelta == nil
  }
}

// MARK: - Comparison

/// Grouping saved benchmark paths into runs, and diffing two runs against each other.
///
/// Pure functions over persisted DTOs: history and comparison never touch the engine, the
/// radio or the clock, so both are exercised from literal fixtures.
public enum BenchmarkComparison {
  /// Groups saved paths into runs by the note encoded in their names, newest run first.
  ///
  /// Paths that were not written by the benchmark tool are dropped rather than lumped into a
  /// group — the same store also holds hand-saved trace paths.
  public static func groups(from paths: [SavedTracePathDTO]) -> [BenchmarkRunGroup] {
    var byNote: [String: [SavedTracePathDTO]] = [:]
    for path in paths {
      guard let components = BenchmarkNaming.components(from: path.name) else { continue }
      byNote[components.note, default: []].append(path)
    }

    return byNote.map { note, paths in
      let latest = paths.flatMap { $0.runs.map(\.date) }.max() ?? .distantPast
      let rtts = paths.compactMap(\.averageRoundTripMs)
      return BenchmarkRunGroup(
        note: note,
        paths: paths,
        date: latest,
        averageRTT: BenchmarkScoring.mean(rtts) ?? 0,
        averageSuccessRate: BenchmarkScoring.mean(paths.map(\.successRate)) ?? 0
      )
    }
    .sorted { $0.date > $1.date }
  }

  /// One row per target seen in either run, matched by the target name in the path name.
  ///
  /// The union rather than the intersection: a target that only one run covered is worth
  /// showing with a blank column, because a target that stopped answering entirely is
  /// exactly the regression a comparison is for.
  public static func rows(
    groupA: BenchmarkRunGroup,
    groupB: BenchmarkRunGroup
  ) -> [BenchmarkComparisonRow] {
    let byTargetA = indexByTarget(groupA.paths)
    let byTargetB = indexByTarget(groupB.paths)
    let targets = Set(byTargetA.keys).union(byTargetB.keys).sorted()

    return targets.map { target in
      let pathA = byTargetA[target]
      let pathB = byTargetB[target]
      return BenchmarkComparisonRow(
        targetName: target,
        rttA: pathA?.averageRoundTripMs,
        rttB: pathB?.averageRoundTripMs,
        successRateA: pathA.map(\.successRate),
        successRateB: pathB.map(\.successRate),
        txSNRA: hopSNR(pathA, index: BenchmarkScoring.txHopIndex),
        txSNRB: hopSNR(pathB, index: BenchmarkScoring.txHopIndex),
        rxSNRA: hopSNR(pathA, index: BenchmarkScoring.rxHopIndex),
        rxSNRB: hopSNR(pathB, index: BenchmarkScoring.rxHopIndex)
      )
    }
  }

  /// Mean delta across the rows that have both sides.
  public static func summary(rows: [BenchmarkComparisonRow]) -> BenchmarkComparisonSummary {
    BenchmarkComparisonSummary(
      rttDelta: BenchmarkScoring.mean(rows.compactMap(\.rttDelta)),
      txSNRDelta: BenchmarkScoring.mean(rows.compactMap(\.txDelta)),
      rxSNRDelta: BenchmarkScoring.mean(rows.compactMap(\.rxDelta))
    )
  }

  /// Whether a delta moved the right way. `lowerIsBetter` is true for round-trip time and
  /// false for SNR and success rate.
  public static func isImprovement(delta: Double, lowerIsBetter: Bool) -> Bool {
    lowerIsBetter ? delta < 0 : delta > 0
  }

  // MARK: - Internals

  static func delta(_ a: Int?, _ b: Int?) -> Int? {
    guard let a, let b else { return nil }
    return b - a
  }

  static func delta(_ a: Double?, _ b: Double?) -> Double? {
    guard let a, let b else { return nil }
    return b - a
  }

  /// Latest path per target name — a run that was saved twice under the same note keeps the
  /// newer measurement rather than an arbitrary one.
  private static func indexByTarget(_ paths: [SavedTracePathDTO]) -> [String: SavedTracePathDTO] {
    var index: [String: SavedTracePathDTO] = [:]
    for path in paths {
      guard let target = BenchmarkNaming.components(from: path.name)?.target else { continue }
      if let existing = index[target], existing.createdDate >= path.createdDate { continue }
      index[target] = path
    }
    return index
  }

  private static func hopSNR(_ path: SavedTracePathDTO?, index: Int) -> Double? {
    guard let path else { return nil }
    return BenchmarkScoring.directionalSNR(runs: path.runs, hopIndex: index)
  }
}
