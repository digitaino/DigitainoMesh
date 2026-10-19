import Foundation

/// The one SNR quality scale for the whole system — iOS overlays, legend, server
/// labels, and the web map all derive from these thresholds. (Replaces three divergent
/// palettes and two divergent server threshold sets.)
public enum SignalQuality: String, CaseIterable, Sendable, Codable {
  case excellent
  case good
  case fair
  case poor
  case veryPoor
  case unknown

  /// Thresholds in dB, inclusive lower bounds.
  public static let excellentMin: Double = 10
  public static let goodMin: Double = 5
  public static let fairMin: Double = 0
  public static let poorMin: Double = -10

  public init(snr: Double?) {
    guard let snr else {
      self = .unknown
      return
    }
    switch snr {
    case Self.excellentMin...: self = .excellent
    case Self.goodMin...: self = .good
    case Self.fairMin...: self = .fair
    case Self.poorMin...: self = .poor
    default: self = .veryPoor
    }
  }

  /// Stable rank for sorting/comparisons (higher is better; unknown sorts last).
  public var rank: Int {
    switch self {
    case .excellent: 5
    case .good: 4
    case .fair: 3
    case .poor: 2
    case .veryPoor: 1
    case .unknown: 0
    }
  }
}
