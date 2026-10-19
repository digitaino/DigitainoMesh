import Foundation

/// How fast the phone is moving, as coarse a signal as the firmware's own `_td` level.
///
/// A moving radio's links change quickly, so probes are worth more and are sent more
/// often; a stationary one can stay quiet. Only three levels exist because that is all the
/// wire format carries and all the cadence needs.
public enum MovementHint: UInt8, Sendable, Equatable, CaseIterable {
  case stationary = 0
  case slow = 1
  case fast = 2

  /// Divides the base probe interval: stationary keeps it, slow halves it, fast quarters it.
  /// Mirrors the firmware's cadence scaling so app and device probe at the same rate.
  public var cadenceDivisor: Int {
    switch self {
    case .stationary: 1
    case .slow: 2
    case .fast: 4
    }
  }
}

/// Supplies the current ``MovementHint``.
///
/// The real implementation is CoreMotion-backed and lives in the app target — MC1Services
/// deliberately does not import CoreMotion, so the engine stays testable and this package
/// stays free of device-framework dependencies. Everything here is pull-based: the engine
/// asks when it is about to choose a cadence, so an implementation only has to keep its
/// latest reading.
public protocol MovementHintProvider: Sendable {
  /// The most recent movement level. Called on every probe cycle, so it must be cheap.
  func currentMovementHint() async -> MovementHint
}

/// The default provider: always stationary.
///
/// Used when no motion source is wired — the engine then probes at its base cadence, which
/// is what a stationary radio wants anyway.
public struct StationaryMovementHintProvider: MovementHintProvider {
  public init() {}

  public func currentMovementHint() async -> MovementHint {
    .stationary
  }
}
