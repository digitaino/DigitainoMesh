import CoreGraphics
@testable import MC1
import Testing

/// Guards the scroll-up reveal of find-in-conversation. Everything here is invisible on device
/// until it misbehaves: an unarmed-by-default latch that armed anyway would pop the bar over a
/// search jump's deep landing, and a latch that never re-arms silently kills the gesture after
/// its first use.
///
/// The latch is fed through `event(...)`/`reveals(...)` helpers rather than called inside
/// `#expect` directly: the macro evaluates its expression inside a closure, which cannot call a
/// mutating member.
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
    // Scrolled up into the backlog: negative, never a pull candidate.
    #expect(overscroll(at: 900) < 0)
  }

  /// The short-content case: the whole conversation fits on screen. The unclamped maximum goes
  /// sharply negative there, so without the `-topInset` floor every resting frame would read as
  /// a huge overscroll and the bar would open the moment the conversation did.
  @Test
  func `A conversation shorter than the viewport rests at zero and reads its pull`() {
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

  // MARK: - Arming

  /// The latch starts disarmed: a conversation opened deep in history (a search jump, an
  /// unread divider) streams far-from-bottom frames from its first report, and none of them
  /// may reveal. Only visiting the bottom arms the gesture.
  @Test
  func `A deep-history open never reveals until the bottom has been visited`() {
    var latch = ChatSearchRevealLatch()

    #expect(!reveals(&latch, pointsFromBottom: 4000))
    #expect(!reveals(&latch, pointsFromBottom: ChatSearchRevealPolicy.revealDistance + 200))

    settle(&latch)
    #expect(reveals(&latch, pointsFromBottom: ChatSearchRevealPolicy.revealDistance))
  }

  @Test
  func `A nudge short of the reveal distance does not open the bar`() {
    var latch = ChatSearchRevealLatch()
    settle(&latch)

    #expect(!reveals(&latch, pointsFromBottom: ChatSearchRevealPolicy.atBottomSlack + 1))
    #expect(!reveals(&latch, pointsFromBottom: ChatSearchRevealPolicy.revealDistance - 1))
    // The unconsumed latch still fires once the distance is reached.
    #expect(reveals(&latch, pointsFromBottom: ChatSearchRevealPolicy.revealDistance))
  }

  @Test
  func `Scrolling on into the backlog after a reveal does not fire again`() {
    var latch = ChatSearchRevealLatch()
    settle(&latch)

    #expect(reveals(&latch, pointsFromBottom: ChatSearchRevealPolicy.revealDistance))
    #expect(!reveals(&latch, pointsFromBottom: 500))
    #expect(!reveals(&latch, pointsFromBottom: 2000))
  }

  @Test
  func `Each reveal requires a fresh visit to the bottom`() {
    var latch = ChatSearchRevealLatch()
    settle(&latch)
    #expect(reveals(&latch, pointsFromBottom: 150))

    // Dropping back toward the bottom without reaching it does not re-arm.
    #expect(!reveals(&latch, pointsFromBottom: ChatSearchRevealPolicy.atBottomSlack + 1))
    #expect(!reveals(&latch, pointsFromBottom: 150))

    settle(&latch)
    #expect(reveals(&latch, pointsFromBottom: 150))
  }

  @Test
  func `A crossing with the bar already open is consumed and reveals nothing`() {
    var latch = ChatSearchRevealLatch()
    settle(&latch)

    #expect(!reveals(&latch, pointsFromBottom: 150, isSearchActive: true))
    // Consumed: the bar being dismissed mid-scroll cannot produce a surprise reveal.
    #expect(!reveals(&latch, pointsFromBottom: 150))
  }

  // MARK: - Appended content

  /// A message taller than the reveal distance pushes the newest content below a reader who is
  /// resting at the bottom, and the surface reports the animated catch-up frame by frame. None
  /// of that is a scroll back into history, so none of it may open the bar: the shipped bug was
  /// the find bar flashing open and dismissing itself again on every tall append — including
  /// the reader's own sent message.
  @Test
  func `A tall message appended at the bottom does not reveal while the list catches up`() {
    var latch = ChatSearchRevealLatch()
    // Resting at the newest message of a conversation whose bottom sits at offset 1234.
    #expect(event(&latch, pointsFromBottom: 0, contentOffsetY: 1234) == .settledAtBottom)

    // A 300pt bubble lands: the bottom moves away while the reader has not moved at all.
    #expect(event(&latch, pointsFromBottom: 300, contentOffsetY: 1234) == .none)
    // The scroll-to-bottom animation then walks the offset up to the new resting position.
    #expect(event(&latch, pointsFromBottom: 234, contentOffsetY: 1300) == .none)
    #expect(event(&latch, pointsFromBottom: 114, contentOffsetY: 1420) == .none)
    // Back at rest. The settle report is inert here — the bar was never opened — and it
    // re-arms the latch, so the append cannot swallow the next real gesture either.
    #expect(event(&latch, pointsFromBottom: 0, contentOffsetY: 1534) == .settledAtBottom)
    #expect(event(&latch, pointsFromBottom: 150, contentOffsetY: 1384) == .reveal)
  }

  /// The other half of the same rule: a finger walking the offset back through the backlog is
  /// exactly what the affordance is for, and must survive the append gate.
  @Test
  func `A finger dragging back into history still opens the bar`() {
    var latch = ChatSearchRevealLatch()
    _ = event(&latch, pointsFromBottom: 0, contentOffsetY: 1234)

    #expect(event(&latch, pointsFromBottom: 60, contentOffsetY: 1174) == .none)
    #expect(event(&latch, pointsFromBottom: 130, contentOffsetY: 1104) == .reveal)
  }

  /// A jump the app performs — a reply quote, a mention, a deeplink — travels into history the
  /// same direction a finger does, so the direction gate cannot separate them and the owner
  /// announces the command instead. Tapping a quote from the newest message must not leave the
  /// find bar open over the message it landed on.
  @Test
  func `An announced jump into history does not reveal, and does not re-arm on the way`() {
    var latch = ChatSearchRevealLatch()
    _ = event(&latch, pointsFromBottom: 0, contentOffsetY: 1234)
    latch.noteProgrammaticScroll()

    #expect(event(&latch, pointsFromBottom: 400, contentOffsetY: 834) == .none)
    #expect(event(&latch, pointsFromBottom: 800, contentOffsetY: 434) == .none)
    // Reading on from where the jump landed stays quiet; only the bottom re-arms.
    #expect(event(&latch, pointsFromBottom: 900, contentOffsetY: 334) == .none)

    _ = event(&latch, pointsFromBottom: 0, contentOffsetY: 1234)
    #expect(event(&latch, pointsFromBottom: 150, contentOffsetY: 1084) == .reveal)
  }

  // MARK: - Settling

  /// `settledAtBottom` is edge-triggered: once per return to the bottom, not once per resting
  /// frame — the owner's auto-hide must not be spammed through the settle animation.
  @Test
  func `Coming to rest at the bottom is reported exactly once`() {
    var latch = ChatSearchRevealLatch()
    settle(&latch)
    #expect(reveals(&latch, pointsFromBottom: 150))

    #expect(event(&latch, pointsFromBottom: 0) == .settledAtBottom)
    #expect(event(&latch, pointsFromBottom: 0) == .none)
    #expect(event(&latch, pointsFromBottom: 2) == .none)
  }

  /// A stretched rubber band is not "at rest": re-arming and the settle report both wait for
  /// the band to relax, so a fling's bounce cannot fire the auto-hide early.
  @Test
  func `A stretched band does not count as settled`() {
    var latch = ChatSearchRevealLatch()

    #expect(event(&latch, pointsFromBottom: 0, overscroll: 30) == .none)
    #expect(event(&latch, pointsFromBottom: 0, overscroll: 0) == .settledAtBottom)
  }

  // MARK: - Short conversations

  /// With no upward travel available, the pull past the end is the only possible gesture, so
  /// there — and only there — it still opens the bar.
  @Test
  func `A conversation that fits on screen reveals on the pull instead`() {
    var latch = ChatSearchRevealLatch()
    settle(&latch)

    let pull = ChatSearchRevealPolicy.shortContentPullThreshold
    #expect(event(&latch, pointsFromBottom: 0, overscroll: pull - 1, contentFits: true) == .none)
    #expect(event(&latch, pointsFromBottom: 0, overscroll: pull, contentFits: true) == .reveal)
    // Held stretch: consumed, no re-fire until the band settles.
    #expect(event(&latch, pointsFromBottom: 0, overscroll: pull + 20, contentFits: true) == .none)
  }

  @Test
  func `A scrollable conversation does not reveal on the pull`() {
    var latch = ChatSearchRevealLatch()
    settle(&latch)

    let pull = ChatSearchRevealPolicy.shortContentPullThreshold
    #expect(event(&latch, pointsFromBottom: 0, overscroll: pull + 40, contentFits: false) == .none)
  }

  // MARK: - Helpers

  /// `contentOffsetY` defaults to the offset a *user scroll* would have produced: with the
  /// resting maximum at zero, standing `pointsFromBottom` back from the newest message means
  /// the offset sits that far below it. Frames that are not user travel (an append pushing the
  /// bottom away, the catch-up animation) pass their offsets explicitly.
  private func event(
    _ latch: inout ChatSearchRevealLatch,
    pointsFromBottom: CGFloat,
    contentOffsetY: CGFloat? = nil,
    overscroll: CGFloat = 0,
    contentFits: Bool = false,
    isSearchActive: Bool = false
  ) -> ChatSearchRevealEvent {
    latch.event(
      pointsFromBottom: pointsFromBottom,
      contentOffsetY: contentOffsetY ?? -pointsFromBottom,
      overscroll: overscroll,
      contentFits: contentFits,
      isSearchActive: isSearchActive
    )
  }

  private func reveals(
    _ latch: inout ChatSearchRevealLatch,
    pointsFromBottom: CGFloat,
    isSearchActive: Bool = false
  ) -> Bool {
    event(&latch, pointsFromBottom: pointsFromBottom, isSearchActive: isSearchActive) == .reveal
  }

  /// Feeds one resting frame, arming the latch (and consuming the settle edge).
  private func settle(_ latch: inout ChatSearchRevealLatch) {
    _ = event(&latch, pointsFromBottom: 0)
  }
}
