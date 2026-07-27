import Foundation

/// Cadences and bounds for a benchmark run.
///
/// Everything the engine would otherwise hard-code lives here, so a test can shrink a run to
/// nothing and the tool's real timings stay in one readable place.
public struct RepeaterBenchmarkPolicy: Sendable, Equatable {
  /// Batch sizes offered in the UI. Five is enough to average out one bad probe without
  /// putting a long burst of traffic on a shared channel.
  public static let traceCountOptions = [1, 3, 5, 10]
  public static let defaultTracesPerTarget = 5

  /// Quiet time between consecutive probes to the same target. Back-to-back traces on a
  /// duty-cycled band measure the queue, not the link.
  public var interTraceDelay: Duration = .milliseconds(500)

  /// Scale applied to the firmware's `suggested_timeout_ms` hint before clamping. The hint
  /// covers outbound airtime only; the reply re-crosses the mesh.
  public var timeoutMultiplier: Double = 1.2

  /// Used when the firmware supplies no hint at all.
  public var defaultTimeoutSeconds: Double = 15

  /// Clamp band for the scaled hint. Mirrors the app-side `FirmwareSuggestedTimeout.Profile`
  /// flood band; duplicated rather than shared because that helper lives in the app target
  /// and MC1Services must not depend upward.
  public var minimumTimeoutSeconds: Double = 5
  public var maximumTimeoutSeconds: Double = 60

  public init() {}

  /// The wait a probe gets, from whatever the radio suggested when it accepted the send.
  public func replyTimeout(suggestedTimeoutMs: UInt32) -> Duration {
    guard suggestedTimeoutMs > 0 else { return .seconds(defaultTimeoutSeconds) }
    let scaled = Double(suggestedTimeoutMs) / 1000 * timeoutMultiplier
    let clamped = min(max(scaled, minimumTimeoutSeconds), maximumTimeoutSeconds)
    return .seconds(clamped)
  }

  /// Clamps a requested batch size to the offered options.
  public static func clampTracesPerTarget(_ value: Int) -> Int {
    traceCountOptions.contains(value)
      ? value
      : traceCountOptions.min(by: { abs($0 - value) < abs($1 - value) }) ?? defaultTracesPerTarget
  }
}
