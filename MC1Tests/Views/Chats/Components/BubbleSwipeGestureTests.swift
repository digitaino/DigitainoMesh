import CoreGraphics
@testable import MC1
import Testing
import UIKit

/// Guards the arbitration behind the two horizontal bubble swipes. Both live inside a
/// vertically scrolling list, so the direction gate and the simultaneity rules are what keep
/// them from stealing the conversation's pan — a regression that is invisible in code review
/// and obvious on device. The felt motion is device-only; this covers what can rot silently.
@Suite("Bubble swipe gestures")
@MainActor
struct BubbleSwipeGestureTests {
  // MARK: - Direction gate

  @Test
  func `A dominant rightward drag starts reply, a dominant leftward drag starts reveal`() {
    let right = CGPoint(x: 400, y: 20)
    let left = CGPoint(x: -400, y: 20)

    #expect(BubbleSwipeGesturePolicy.shouldBeginReply(velocity: right))
    #expect(!BubbleSwipeGesturePolicy.shouldBeginReveal(velocity: right))

    #expect(BubbleSwipeGesturePolicy.shouldBeginReveal(velocity: left))
    #expect(!BubbleSwipeGesturePolicy.shouldBeginReply(velocity: left))
  }

  @Test
  func `A vertical drag starts neither swipe so the list keeps scrolling`() {
    let up = CGPoint(x: 10, y: -900)
    let down = CGPoint(x: -10, y: 900)

    #expect(!BubbleSwipeGesturePolicy.shouldBeginReply(velocity: up))
    #expect(!BubbleSwipeGesturePolicy.shouldBeginReveal(velocity: up))
    #expect(!BubbleSwipeGesturePolicy.shouldBeginReply(velocity: down))
    #expect(!BubbleSwipeGesturePolicy.shouldBeginReveal(velocity: down))
  }

  @Test
  func `An ambiguous diagonal is left to the list rather than claimed`() {
    // Horizontal leads, but not by the dominance factor — the drag reads as a scroll
    // that drifted sideways, so neither swipe may begin.
    let drifting = CGPoint(x: 120, y: 100)
    #expect(!BubbleSwipeGesturePolicy.shouldBeginReply(velocity: drifting))

    let justOver = CGPoint(x: 151, y: 100)
    #expect(BubbleSwipeGesturePolicy.shouldBeginReply(velocity: justOver))
  }

  // MARK: - Swipe to reply travel

  @Test
  func `Reply travel clamps to the forward range`() {
    #expect(BubbleSwipeGesturePolicy.replyTranslation(forDragX: -50) == 0)
    #expect(BubbleSwipeGesturePolicy.replyTranslation(forDragX: 0) == 0)
    #expect(BubbleSwipeGesturePolicy.replyTranslation(forDragX: 40) == 40)
    #expect(
      BubbleSwipeGesturePolicy.replyTranslation(forDragX: 500)
        == BubbleSwipeGesturePolicy.replyMaxTranslation
    )
  }

  @Test
  func `Reply fires only at or past the trigger threshold`() {
    let threshold = BubbleSwipeGesturePolicy.replyTriggerThreshold
    #expect(!BubbleSwipeGesturePolicy.passedReplyThreshold(threshold - 1))
    #expect(BubbleSwipeGesturePolicy.passedReplyThreshold(threshold))
    #expect(BubbleSwipeGesturePolicy.passedReplyThreshold(threshold + 20))
  }

  @Test
  func `The reply arrow reaches full strength exactly at the threshold`() {
    let threshold = BubbleSwipeGesturePolicy.replyTriggerThreshold
    #expect(BubbleSwipeGesturePolicy.replyIndicatorProgress(for: 0) == 0)
    #expect(BubbleSwipeGesturePolicy.replyIndicatorProgress(for: threshold / 2) == 0.5)
    #expect(BubbleSwipeGesturePolicy.replyIndicatorProgress(for: threshold) == 1)
    #expect(BubbleSwipeGesturePolicy.replyIndicatorProgress(for: threshold * 2) == 1)
  }

  // MARK: - Timestamp reveal travel

  @Test
  func `Reveal ignores rightward drags and tracks leftward ones one-to-one`() {
    #expect(BubbleSwipeGesturePolicy.revealOffset(forDragX: 60) == 0)
    #expect(BubbleSwipeGesturePolicy.revealOffset(forDragX: 0) == 0)
    #expect(BubbleSwipeGesturePolicy.revealOffset(forDragX: -30) == 30)
  }

  @Test
  func `Reveal rubber-bands past its maximum instead of stopping dead`() {
    let max = BubbleSwipeGesturePolicy.revealMaxTranslation
    let overdragged = BubbleSwipeGesturePolicy.revealOffset(forDragX: -(max + 100))

    #expect(overdragged > max)
    #expect(overdragged < max + 100)
    #expect(overdragged <= BubbleSwipeGesturePolicy.revealOverdragCeiling)
  }

  @Test
  func `Reveal overdrag never exceeds the ceiling`() {
    let extreme = BubbleSwipeGesturePolicy.revealOffset(forDragX: -5000)
    #expect(extreme == BubbleSwipeGesturePolicy.revealOverdragCeiling)
  }

  /// The labels ride in glued to the rows, so the fade finishes at half travel — while they are
  /// still outside the row's trailing edge — rather than at the end of the drag.
  @Test
  func `Timestamps reach full strength at half travel, still riding in`() {
    let fadeIn = BubbleSwipeGesturePolicy.revealFadeInDistance
    #expect(BubbleSwipeGesturePolicy.revealProgress(for: 0) == 0)
    #expect(BubbleSwipeGesturePolicy.revealProgress(for: fadeIn) == 1)
    #expect(BubbleSwipeGesturePolicy.revealProgress(for: BubbleSwipeGesturePolicy.revealMaxTranslation) == 1)
    #expect(fadeIn < BubbleSwipeGesturePolicy.revealMaxTranslation)
  }

  // MARK: - Recognizer wiring

  @Test
  func `The pan never consumes touches and always carries its delegate`() {
    let coordinator = BubbleHorizontalPanRecognizer.Coordinator(
      shouldBegin: { _ in true },
      allowsSimultaneousRecognition: false,
      onChange: { _, _ in }
    )
    let recognizer = BubbleHorizontalPanRecognizer.makeRecognizer(coordinator: coordinator)

    // The bubble's long-press and the fragments' tap catcher sit on the same pixels.
    #expect(recognizer.cancelsTouchesInView == false)
    #expect(recognizer.delegate != nil)
  }

  @Test
  func `A long-press always wins a contested press, whatever the simultaneity setting`() {
    for allowsSimultaneous in [true, false] {
      let coordinator = BubbleHorizontalPanRecognizer.Coordinator(
        shouldBegin: { _ in true },
        allowsSimultaneousRecognition: allowsSimultaneous,
        onChange: { _, _ in }
      )
      #expect(
        coordinator.gestureRecognizer(
          UIPanGestureRecognizer(),
          shouldRecognizeSimultaneouslyWith: UILongPressGestureRecognizer()
        ) == false
      )
    }
  }

  @Test
  func `Reply is exclusive with the list pan while the reveal coexists with it`() {
    let exclusive = BubbleHorizontalPanRecognizer.Coordinator(
      shouldBegin: { _ in true },
      allowsSimultaneousRecognition: false,
      onChange: { _, _ in }
    )
    let coexisting = BubbleHorizontalPanRecognizer.Coordinator(
      shouldBegin: { _ in true },
      allowsSimultaneousRecognition: true,
      onChange: { _, _ in }
    )
    let listPan = UIPanGestureRecognizer()

    #expect(
      exclusive.gestureRecognizer(UIPanGestureRecognizer(), shouldRecognizeSimultaneouslyWith: listPan)
        == false
    )
    #expect(
      coexisting.gestureRecognizer(UIPanGestureRecognizer(), shouldRecognizeSimultaneouslyWith: listPan)
        == true
    )
  }

  @Test
  func `The begin gate is consulted for the recognizer's own decision`() {
    var seen: CGPoint?
    let coordinator = BubbleHorizontalPanRecognizer.Coordinator(
      shouldBegin: { velocity in
        seen = velocity
        return false
      },
      allowsSimultaneousRecognition: false,
      onChange: { _, _ in }
    )
    let recognizer = BubbleHorizontalPanRecognizer.makeRecognizer(coordinator: coordinator)

    #expect(coordinator.gestureRecognizerShouldBegin(recognizer) == false)
    #expect(seen != nil)
  }

  /// Cell recycling can take the recognizer off its host mid-drag, and UIKit sends no terminal
  /// state when it does — so the detach is translated into the `.cancelled` consumers already
  /// unwind on. An idle detach must stay silent: recycling is continuous while scrolling, and
  /// the shared reveal offset is observable, so a cancel per recycled row would rewrite zero
  /// over zero and invalidate every visible cell.
  @Test
  func `A detach mid-drag cancels, an idle detach says nothing`() {
    var seen: [(UIGestureRecognizer.State, CGFloat)] = []
    let coordinator = BubbleHorizontalPanRecognizer.Coordinator(
      shouldBegin: { _ in true },
      allowsSimultaneousRecognition: true,
      onChange: { state, dragX in seen.append((state, dragX)) }
    )

    for idle in [UIGestureRecognizer.State.possible, .ended, .cancelled, .failed] {
      coordinator.cancelTrackingGesture(state: idle)
    }
    #expect(seen.isEmpty)

    coordinator.cancelTrackingGesture(state: .began)
    coordinator.cancelTrackingGesture(state: .changed)
    #expect(seen.count == 2)
    #expect(seen.allSatisfy { $0.0 == .cancelled && $0.1 == 0 })
  }

  // MARK: - Shared reveal state

  @Test
  func `The reveal offset is shared, so a drag on one row moves the conversation`() {
    let state = ChatTimestampRevealState()
    #expect(state.offset == 0)

    state.offset = BubbleSwipeGesturePolicy.revealOffset(forDragX: -50)
    #expect(state.offset == 50)
  }
}
