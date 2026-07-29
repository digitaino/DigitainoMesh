import CoreGraphics

/// Tuning and arming rules for the bottom-overscroll reveal of find-in-conversation.
///
/// Find-in-conversation used to sit behind a magnifying-glass toolbar button. That slot now
/// carries the radio status pair, so the search bar is reached the way the rest of the
/// conversation is driven — by scrolling. Standing at the newest message and pulling *up* past
/// the end (the rubber band) opens the bar, mirroring pull-to-refresh at the other end of the
/// list.
///
/// `TiledScrollGeometry.pointsFromBottom` cannot express this: it clamps at 0 and so reads the
/// entire rubber band as "at the bottom". The raw overscroll has to be derived from the offset
/// and the scroll view's resting maximum instead, which is what `overscrollPastBottom` does.
///
/// Pure and host-independent so the arming rules can be unit-tested; the felt behavior is
/// device-only.
enum ChatSearchRevealPolicy {
  // MARK: - Threshold

  /// Rubber-band distance past the newest message at which the search bar opens.
  ///
  /// Deliberately larger than the slack a fling leaves behind: iOS keeps reporting a decaying
  /// overscroll for a few frames after a fast scroll to the bottom, and a small threshold would
  /// turn "jump to the newest message" into "open search". ~56pt takes a deliberate pull.
  static let triggerThreshold: CGFloat = 56

  /// Overscroll at or below which the gesture re-arms. Not exactly zero: the band settles
  /// through a couple of sub-point frames, and demanding a true zero would leave the gesture
  /// disarmed until the next full scroll.
  static let rearmThreshold: CGFloat = 4

  // MARK: - Geometry

  /// How far the list is rubber-banded past its newest message; `<= 0` anywhere at or above
  /// the resting bottom.
  ///
  /// The resting maximum offset is UIScrollView's own: `contentHeight + bottomInset -
  /// visibleHeight`, floored at `-topInset`. That floor is what makes short conversations work.
  /// When the whole conversation fits on screen the unclamped maximum goes sharply negative,
  /// and every resting frame would read as a huge overscroll; the floor pins the resting offset
  /// to `-topInset` instead, so a short conversation rests at 0 and still reveals when pulled —
  /// the list bounces vertically regardless of content height.
  static func overscrollPastBottom(
    contentOffsetY: CGFloat,
    contentHeight: CGFloat,
    visibleHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat
  ) -> CGFloat {
    let restingMaxOffsetY = max(contentHeight + bottomInset - visibleHeight, -topInset)
    return contentOffsetY - restingMaxOffsetY
  }
}

/// One-shot arming for the reveal, carried across the continuous stream of scroll-geometry
/// reports.
///
/// Geometry arrives on every frame of the drag, so a bare threshold test would fire dozens of
/// times across a single pull. The latch consumes a crossing the first time it is seen and
/// stays consumed until the band settles back to rest, which is also what stops the gesture
/// from re-firing while the reader simply holds the list stretched.
struct ChatSearchRevealLatch {
  private var isArmed = true

  init() {}

  /// Reports whether this geometry frame should open the search bar, updating the arming state.
  ///
  /// - Parameters:
  ///   - overscroll: raw rubber-band distance from `overscrollPastBottom`.
  ///   - isSearchActive: whether the bar is already showing. A crossing is still consumed in
  ///     that case, so releasing and pulling again is what re-fires — holding the stretch does
  ///     not queue up a second reveal (and, more visibly, a second haptic).
  mutating func shouldReveal(overscroll: CGFloat, isSearchActive: Bool) -> Bool {
    guard overscroll > ChatSearchRevealPolicy.rearmThreshold else {
      isArmed = true
      return false
    }
    guard isArmed, overscroll >= ChatSearchRevealPolicy.triggerThreshold else { return false }
    isArmed = false
    return !isSearchActive
  }
}
