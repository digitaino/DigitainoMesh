import CoreGraphics
@testable import MC1
import Testing

/// Guards the bottom-overscroll reveal of find-in-conversation. Everything here is invisible on
/// device until it misbehaves: a threshold that is too low turns "jump to the newest message"
/// into an unwanted search bar, and a latch that never re-arms silently kills the gesture after
/// its first use.
///
/// The latch is fed through `reveals(...)` rather than called inside `#expect` directly: the
/// macro evaluates its expression inside a closure, which cannot call a mutating member.
@Suite("Chat search reveal")
struct ChatSearchRevealPolicyTests {
  // MARK: - Geometry

  /// A tall conversation resting at its newest message reports no overscroll, and the raw
  /// distance appears only once the band stretches past it.
  @Test
  func `A long conversation reads zero at rest and grows while rubber-banding`() {
    /// 2000pt of messages in an 800pt viewport with a 34pt bottom inset: resting offset 1234.
    func overscroll(at offsetY: CGFloat) -> CGFloat {
      ChatSearchRevealPolicy.overscrollPastBottom(
        contentOffsetY: offsetY,
        contentHeight: 2000,
        visibleHeight: 800,
        topInset: 100,
        bottomInset: 34
      )
    }

    #expect(overscroll(at: 1234) == 0)
    #expect(overscroll(at: 1294) == 60)
    // Scrolled up into the backlog: negative, never a reveal candidate.
    #expect(overscroll(at: 900) < 0)
  }

  /// The short-content case: the whole conversation fits on screen. The unclamped maximum goes
  /// sharply negative there, so without the `-topInset` floor every resting frame would read as
  /// a huge overscroll and the bar would open the moment the conversation did.
  @Test
  func `A conversation shorter than the viewport rests at zero and still reveals`() {
    func overscroll(at offsetY: CGFloat) -> CGFloat {
      ChatSearchRevealPolicy.overscrollPastBottom(
        contentOffsetY: offsetY,
        contentHeight: 200,
        visibleHeight: 800,
        topInset: 100,
        bottomInset: 34
      )
    }

    #expect(overscroll(at: -100) == 0)
    #expect(overscroll(at: -40) == 60)
  }

  // MARK: - Latch

  @Test
  func `An overscroll short of the threshold does not reveal`() {
    var latch = ChatSearchRevealLatch()
    let shy = ChatSearchRevealPolicy.triggerThreshold - 1

    #expect(!reveals(&latch, overscroll: 10))
    #expect(!reveals(&latch, overscroll: shy))
  }

  @Test
  func `Crossing the threshold reveals exactly once while the pull is held`() {
    var latch = ChatSearchRevealLatch()

    #expect(reveals(&latch, overscroll: ChatSearchRevealPolicy.triggerThreshold))
    // The remaining frames of the same pull must not re-fire.
    #expect(!reveals(&latch, overscroll: 80))
    #expect(!reveals(&latch, overscroll: 120))
  }

  @Test
  func `A crossing with the bar already open is consumed but reveals nothing`() {
    var latch = ChatSearchRevealLatch()

    #expect(!reveals(&latch, overscroll: 90, isSearchActive: true))
    // Consumed: still holding the stretch cannot produce a second reveal (nor a second haptic)
    // even if the bar is dismissed mid-pull.
    #expect(!reveals(&latch, overscroll: 90))
  }

  @Test
  func `The gesture re-arms only after the band settles back to rest`() {
    var latch = ChatSearchRevealLatch()
    #expect(reveals(&latch, overscroll: 90))

    // Easing back but still stretched past the re-arm slack: stays consumed.
    #expect(!reveals(&latch, overscroll: 20))
    #expect(!reveals(&latch, overscroll: 90))

    // Settled — the next pull is a new crossing.
    #expect(!reveals(&latch, overscroll: 0))
    #expect(reveals(&latch, overscroll: 90))
  }

  @Test
  func `Scrolling back into the backlog re-arms the gesture`() {
    var latch = ChatSearchRevealLatch()
    #expect(reveals(&latch, overscroll: 90))

    #expect(!reveals(&latch, overscroll: -400))
    #expect(reveals(&latch, overscroll: 90))
  }

  // MARK: - Helpers

  private func reveals(
    _ latch: inout ChatSearchRevealLatch,
    overscroll: CGFloat,
    isSearchActive: Bool = false
  ) -> Bool {
    latch.shouldReveal(overscroll: overscroll, isSearchActive: isSearchActive)
  }
}
