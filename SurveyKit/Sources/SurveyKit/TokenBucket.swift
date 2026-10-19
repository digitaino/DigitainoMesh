import Foundation

/// A token bucket enforcing a hard ceiling on mesh transmissions.
///
/// Pure value type: callers supply monotonic timestamps, nothing here reads the clock,
/// so policy behavior is fully deterministic in tests.
public struct TokenBucket: Sendable {
  public let capacity: Double
  public let refillPerSecond: Double

  private var tokens: Double
  private var lastRefill: TimeInterval

  public init(capacity: Double, refillPerSecond: Double, at now: TimeInterval, full: Bool = true) {
    self.capacity = capacity
    self.refillPerSecond = refillPerSecond
    self.tokens = full ? capacity : 0
    self.lastRefill = now
  }

  /// Tokens currently available (after refilling up to `now`).
  public mutating func available(at now: TimeInterval) -> Double {
    refill(to: now)
    return tokens
  }

  /// Consumes `cost` tokens if available. `floor` reserves headroom: automatic
  /// consumers pass a floor so manual actions always retain a small reserve.
  public mutating func tryConsume(_ cost: Double, at now: TimeInterval, floor: Double = 0) -> Bool {
    refill(to: now)
    guard tokens - cost >= floor else { return false }
    tokens -= cost
    return true
  }

  private mutating func refill(to now: TimeInterval) {
    guard now > lastRefill else { return }
    tokens = min(capacity, tokens + (now - lastRefill) * refillPerSecond)
    lastRefill = now
  }
}
