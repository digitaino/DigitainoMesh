import CoreGraphics

/// Tuning and arbitration rules for the two horizontal bubble swipes: drag right to reply,
/// drag left to reveal send times.
///
/// The numbers and the direction gate are carried from the fork's UIKit table implementation.
/// The load-bearing rule is the direction gate: both swipes live inside a vertically scrolling
/// list, so a recognizer that begins on an ambiguous drag steals the pan and the conversation
/// stops scrolling. Requiring the horizontal velocity to dominate by `directionDominance`
/// before either gesture may begin is what kept that from happening, and it is the reason
/// these live in UIKit recognizers with a delegate rather than in a SwiftUI `DragGesture`.
///
/// Pure and host-independent so the arbitration can be unit-tested; the felt behavior is
/// device-only.
enum BubbleSwipeGesturePolicy {
  // MARK: - Direction gate

  /// How much a drag must favour the horizontal axis before a swipe may begin. Below this
  /// the list keeps the pan and scrolls.
  static let directionDominance: CGFloat = 1.5

  /// Whether a rightward drag is committed enough to start swipe-to-reply.
  static func shouldBeginReply(velocity: CGPoint) -> Bool {
    velocity.x > 0 && abs(velocity.x) > abs(velocity.y) * directionDominance
  }

  /// Whether a leftward drag is committed enough to start the timestamp reveal.
  static func shouldBeginReveal(velocity: CGPoint) -> Bool {
    velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * directionDominance
  }

  // MARK: - Swipe to reply

  /// Rightward distance at which releasing fires a reply.
  static let replyTriggerThreshold: CGFloat = 60

  /// Hard stop on how far the bubble travels, so a long drag doesn't pull it off the row.
  static let replyMaxTranslation: CGFloat = 100

  /// Clamps a raw drag to the bubble's travel range. Leftward drags read as zero: reply is a
  /// one-directional gesture and must not let the bubble be dragged the wrong way.
  static func replyTranslation(forDragX dragX: CGFloat) -> CGFloat {
    min(max(dragX, 0), replyMaxTranslation)
  }

  /// Whether the current translation would fire a reply on release.
  static func passedReplyThreshold(_ translation: CGFloat) -> Bool {
    translation >= replyTriggerThreshold
  }

  /// Opacity/scale ramp for the reply arrow: fully in exactly when the threshold is met.
  static func replyIndicatorProgress(for translation: CGFloat) -> CGFloat {
    min(translation / replyTriggerThreshold, 1)
  }

  // MARK: - Timestamp reveal

  /// Leftward distance at which the timestamps are fully revealed.
  static let revealMaxTranslation: CGFloat = 80

  /// Fraction of the overdrag past `revealMaxTranslation` that still moves the row, so the
  /// gesture resists rather than stopping dead.
  static let revealRubberBandFactor: CGFloat = 0.2

  /// Absolute ceiling on the revealed offset, including rubber-band overdrag.
  static let revealOverdragCeiling: CGFloat = revealMaxTranslation * 1.2

  /// Distance over which the timestamp labels fade in. Shorter than the full travel so the
  /// times are readable well before the drag bottoms out.
  static let revealFadeInDistance: CGFloat = 40

  /// Converts a raw drag into the shared row offset, rubber-banding past the max. Rightward
  /// drags read as zero — the reveal only ever pulls content left.
  static func revealOffset(forDragX dragX: CGFloat) -> CGFloat {
    let raw = -dragX
    guard raw > 0 else { return 0 }
    guard raw > revealMaxTranslation else { return raw }
    let overdrag = raw - revealMaxTranslation
    return min(revealMaxTranslation + overdrag * revealRubberBandFactor, revealOverdragCeiling)
  }

  /// Opacity ramp for the revealed timestamps.
  static func revealProgress(for offset: CGFloat) -> CGFloat {
    min(max(offset, 0) / revealFadeInDistance, 1)
  }
}
