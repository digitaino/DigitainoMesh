import CoreGraphics

/// Tuning and arming rules for the scroll-up reveal of find-in-conversation.
///
/// Find-in-conversation used to sit behind a magnifying-glass toolbar button; that slot now
/// carries the radio status pair. The bar is reached the way the rest of the conversation is
/// driven — by scrolling: standing at the newest message and scrolling a little way back into
/// history slides the bar in. It appears without claiming the keyboard, and settles away again
/// when the reader returns to the bottom without having typed, so browsing history leaves no
/// residue. (An earlier revision used a rubber-band pull past the newest message instead; the
/// deliberate stretch felt like work for what should be an ambient affordance.)
///
/// A conversation short enough to fit on screen cannot scroll up, so there — and only there —
/// the rubber-band pull still opens the bar; `TiledView` bounces vertically regardless of
/// content height, so the pull is always available.
///
/// Pure and host-independent so the arming rules can be unit-tested; the felt behavior is
/// device-only.
enum ChatSearchRevealPolicy {
  // MARK: - Thresholds

  /// Distance scrolled back from the newest message at which the bar appears. Roughly a
  /// bubble's height past the at-bottom slack: enough that a nudge to peek at the previous
  /// message doesn't open it, small enough that "scroll up a bit" is literally the gesture.
  static let revealDistance: CGFloat = 100

  /// Slack for "resting at the bottom", shared with the scroll surface's own at-bottom rule
  /// (`ChatScrollConstants.bottomDetectionThreshold`) so arming, auto-hide, and the
  /// scroll-to-bottom button all agree on where the bottom is.
  static let atBottomSlack: CGFloat = ChatScrollConstants.bottomDetectionThreshold

  /// Rubber-band distance that opens the bar in a conversation too short to scroll.
  /// Deliberately larger than the slack a fling leaves behind: iOS keeps reporting a decaying
  /// overscroll for a few frames after a fast settle, and a small threshold would turn every
  /// bounce into a reveal.
  static let shortContentPullThreshold: CGFloat = 56

  /// Overscroll at or below which the band counts as settled for re-arming. Not exactly zero:
  /// the band settles through a couple of sub-point frames, and demanding a true zero would
  /// leave the gesture disarmed until the next full scroll.
  static let settledSlack: CGFloat = 4

  // MARK: - Geometry

  /// How far the list is rubber-banded past its newest message; `<= 0` anywhere at or above
  /// the resting bottom.
  ///
  /// `TiledScrollGeometry.pointsFromBottom` cannot express this — it clamps at 0 and reads the
  /// whole rubber band as "at the bottom" — so the raw offset arithmetic derives it. The
  /// resting maximum offset is UIScrollView's own: `contentHeight + bottomInset -
  /// visibleHeight`, floored at `-topInset`. The floor is what makes short conversations work:
  /// when the whole conversation fits on screen the unclamped maximum goes sharply negative
  /// and every resting frame would read as a huge overscroll; the floor pins the resting
  /// offset to `-topInset` instead.
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

/// What one scroll-geometry frame means for the search bar.
enum ChatSearchRevealEvent {
  /// Nothing to do.
  case none
  /// The reader scrolled up from the bottom (or, in a short conversation, pulled past the
  /// end): open the bar — without claiming the keyboard.
  case reveal
  /// The list just came to rest at the bottom again: the owner may retire an untouched bar.
  case settledAtBottom
}

/// Arming state for the reveal, carried across the continuous stream of scroll-geometry
/// reports.
///
/// Geometry arrives on every frame of a scroll, so bare threshold tests would fire dozens of
/// times per gesture. The latch arms only while resting at the bottom and consumes itself on
/// the first crossing, which yields the intended shape: a conversation opened deep in history
/// (a search jump, an unread divider) never reveals uninvited, and each reveal requires
/// having visited the bottom since the last one. `settledAtBottom` is edge-triggered the same
/// way, firing once per return rather than once per frame.
///
/// A crossing also has to be *travel back into history*, because distance from the bottom
/// grows on its own: appending a message taller than the reveal distance pushes the newest
/// content below a reader who is resting at the bottom, and the scroll-to-bottom that follows
/// reports its animation frames through the same callback (`TiledScrollGeometry` carries no
/// is-dragging flag to ask instead — the library publishes geometry for programmatic scrolls
/// deliberately). Those frames all move *toward* the newest message, so requiring the content
/// offset to have decreased since the previous frame is what separates a finger scrolling back
/// through the backlog from the list catching up with an append.
struct ChatSearchRevealLatch {
  private var isArmed = false
  private var wasAtBottom = false
  private var lastContentOffsetY: CGFloat?

  init() {}

  /// Classifies one geometry frame, updating the arming state.
  ///
  /// - Parameters:
  ///   - pointsFromBottom: the scroll surface's clamped distance from the newest message.
  ///   - contentOffsetY: the frame's raw vertical offset, compared against the previous
  ///     frame's to tell travel into history from the list moving under the reader.
  ///   - overscroll: raw rubber-band distance from `overscrollPastBottom`.
  ///   - contentFits: whether the whole conversation fits on screen (no upward travel
  ///     exists, so the pull is the only possible reveal gesture).
  ///   - isSearchActive: whether the bar is already showing. A crossing is still consumed,
  ///     so the next reveal requires returning to the bottom first.
  mutating func event(
    pointsFromBottom: CGFloat,
    contentOffsetY: CGFloat,
    overscroll: CGFloat,
    contentFits: Bool,
    isSearchActive: Bool
  ) -> ChatSearchRevealEvent {
    let movedIntoHistory = lastContentOffsetY.map { contentOffsetY < $0 } ?? false
    let atRest = pointsFromBottom < ChatSearchRevealPolicy.atBottomSlack
      && overscroll <= ChatSearchRevealPolicy.settledSlack
    defer {
      wasAtBottom = atRest
      lastContentOffsetY = contentOffsetY
    }

    if atRest {
      isArmed = true
      return wasAtBottom ? .none : .settledAtBottom
    }

    guard isArmed else { return .none }
    // The pull needs no direction gate: stretching the band past the end is movement only a
    // finger produces, and it is the same direction an append's catch-up travels.
    let crossed = contentFits
      ? overscroll >= ChatSearchRevealPolicy.shortContentPullThreshold
      : pointsFromBottom >= ChatSearchRevealPolicy.revealDistance && movedIntoHistory
    guard crossed else { return .none }

    isArmed = false
    return isSearchActive ? .none : .reveal
  }

  /// Drops the arming ahead of a scroll the owner is about to perform itself.
  ///
  /// A jump to a message — a reply quote, a mention, a deeplink, a search hit — travels back
  /// into history exactly the way a finger does, so the direction gate above cannot tell them
  /// apart and the owner has to say so. Landing somewhere deep is not a reveal, and re-arming
  /// still waits for a visit to the bottom; a jump *to* the bottom re-arms on arrival.
  mutating func noteProgrammaticScroll() {
    isArmed = false
  }
}
