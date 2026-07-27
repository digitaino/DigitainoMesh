import Foundation

/// The benchmark's arithmetic, as free functions over probe outcomes.
///
/// Kept out of the engine so every figure a row shows can be checked against a literal
/// batch without a session, a clock or an actor. Integer division is deliberate throughout:
/// these are milliseconds and percentages read at a glance, and rounding them differently
/// from the legacy tool would silently move every historical comparison.
public enum BenchmarkScoring {
  /// Index into ``BenchmarkTraceOutcome/intermediateSNRs`` for the outbound leg — the
  /// target receiving from the test repeater.
  ///
  /// A benchmark path is `test → target → test`, so the intermediate hops are
  /// `[test, target, test]`: index 0 is the test repeater hearing *us*, index 1 is the
  /// target hearing the test repeater (TX), index 2 is the test repeater hearing the
  /// target on the way back (RX).
  public static let txHopIndex = 1

  /// Index into ``BenchmarkTraceOutcome/intermediateSNRs`` for the return leg.
  public static let rxHopIndex = 2

  // MARK: - Reliability

  /// Successful probes as a whole percentage. An empty batch scores 0, not 100: nothing was
  /// measured, and calling that perfect would rank an unrun target above a working one.
  public static func successRate(successes: Int, total: Int) -> Int {
    guard total > 0 else { return 0 }
    return (successes * 100) / total
  }

  // MARK: - Round-trip time

  /// Mean round-trip of the successful probes, `nil` when none succeeded.
  public static func averageRTT(_ outcomes: [BenchmarkTraceOutcome]) -> Int? {
    let values = outcomes.filter(\.success).map(\.durationMs)
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / values.count
  }

  public static func minRTT(_ outcomes: [BenchmarkTraceOutcome]) -> Int? {
    outcomes.filter(\.success).map(\.durationMs).min()
  }

  public static func maxRTT(_ outcomes: [BenchmarkTraceOutcome]) -> Int? {
    outcomes.filter(\.success).map(\.durationMs).max()
  }

  // MARK: - Directional signal

  /// Mean SNR at one intermediate hop across the successful probes.
  ///
  /// Probes whose path came back shorter than `hopIndex` contribute nothing rather than
  /// zero — a truncated path means that leg was not observed, and averaging in a zero would
  /// read as a poor link instead of an unknown one.
  public static func directionalSNR(
    _ outcomes: [BenchmarkTraceOutcome],
    hopIndex: Int
  ) -> Double? {
    let values = outcomes.filter(\.success).compactMap { outcome -> Double? in
      let snrs = outcome.intermediateSNRs
      guard hopIndex < snrs.count else { return nil }
      return snrs[hopIndex]
    }
    return mean(values)
  }

  /// Mean SNR at one hop index across a set of persisted runs.
  ///
  /// The history side of ``directionalSNR(_:hopIndex:)``: saved runs keep only the hop SNR
  /// array, so comparison reads the same index out of the same array.
  public static func directionalSNR(
    runs: [TracePathRunDTO],
    hopIndex: Int
  ) -> Double? {
    let values = runs.filter(\.success).compactMap { run -> Double? in
      guard hopIndex < run.hopsSNR.count else { return nil }
      return run.hopsSNR[hopIndex]
    }
    return mean(values)
  }

  /// Arithmetic mean, `nil` for an empty sample.
  public static func mean(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }

  /// Integer arithmetic mean, `nil` for an empty sample.
  public static func mean(_ values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / values.count
  }
}
