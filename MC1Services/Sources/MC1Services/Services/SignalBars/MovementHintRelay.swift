import Foundation

/// A ``MovementHintProvider`` whose value is pushed in from outside.
///
/// The engine pulls its movement hint on every probe cycle, but the only real source of one
/// is CoreMotion, which MC1Services deliberately does not import. This relay closes that gap:
/// the app target's motion monitor pushes a level in, the engine reads the latest value out,
/// and neither has to know about the other.
///
/// ``update(_:)`` reports whether the level actually changed, which is what gates the
/// firmware-side motion hint — a repeated reading must not cost a radio write.
public actor MovementHintRelay: MovementHintProvider {
  private var hint: MovementHint

  public init(initial: MovementHint = .stationary) {
    hint = initial
  }

  public func currentMovementHint() async -> MovementHint {
    hint
  }

  /// Stores a new level.
  /// - Returns: `true` when this differs from the level already held.
  @discardableResult
  public func update(_ hint: MovementHint) -> Bool {
    guard hint != self.hint else { return false }
    self.hint = hint
    return true
  }

  /// Returns to `.stationary`. Used when motion updates stop, so a stale "driving" reading
  /// cannot keep the probe cadence high after the source goes away.
  public func reset() {
    hint = .stationary
  }
}
