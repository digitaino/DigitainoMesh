import Foundation

/// The "no repeats heard" retry affordance carried on a rendered message row.
///
/// Baked into ``MessageFooter`` rather than held in a side-channel store, because the
/// bubble views are `Equatable` on ``MessageItem`` alone: state the card renders from has
/// to live inside the item or the row would never redraw when the card appears.
///
/// The payload is only the escalated-power label; whether the card shows at all is encoded
/// by the presence of the value. `nextPowerLabel` is `nil` when adaptive power is off or the
/// radio is already at its highest reachable step, in which case the card offers the
/// same-power resend alone.
public struct NoRepeatsRetryPrompt: Sendable, Hashable {
  /// Label of the next power rung (for example `"500mW"`), taken from
  /// ``AdaptivePowerPolicy/escalatedStep(from:)``. `nil` hides the escalated button.
  public let nextPowerLabel: String?

  public init(nextPowerLabel: String? = nil) {
    self.nextPowerLabel = nextPowerLabel
  }
}
