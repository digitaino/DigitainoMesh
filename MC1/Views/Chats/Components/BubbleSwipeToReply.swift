import SwiftUI
import UIKit

/// Drag a bubble to the right to reply to it.
///
/// The bubble tracks the finger up to a hard stop, a reply arrow fades in behind it, and
/// crossing the trigger threshold tints the arrow and fires a haptic so the commit is felt
/// before release. Releasing past the threshold springs the bubble home and *then* fires the
/// reply, so the composer takes focus after the row has settled rather than mid-animation.
///
/// The reply itself goes through the same entry point as the actions sheet's Reply — this is
/// a shortcut to that action, not a second implementation of it.
private struct BubbleSwipeToReplyModifier: ViewModifier {
  let isEnabled: Bool
  let onReply: () -> Void

  @State private var translation: CGFloat = 0
  @State private var hasPassedThreshold = false
  @State private var thresholdHaptic = 0

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .offset(x: translation)
      .background(alignment: .leading) { replyIndicator }
      .overlay {
        if isEnabled {
          BubbleHorizontalPanRecognizer(
            shouldBegin: BubbleSwipeGesturePolicy.shouldBeginReply(velocity:),
            // Exclusive: the row moves with the finger, so the list must not scroll
            // underneath it at the same time.
            allowsSimultaneousRecognition: false,
            onChange: handle(state:dragX:)
          )
        }
      }
      .sensoryFeedback(.impact(flexibility: .solid), trigger: thresholdHaptic)
  }

  @ViewBuilder
  private var replyIndicator: some View {
    if translation > 0 {
      Image(systemName: "arrowshape.turn.up.left.fill")
        .font(.system(size: 16))
        .foregroundStyle(hasPassedThreshold ? Color.accentColor : Color.secondary)
        .scaleEffect(hasPassedThreshold ? 1 : 0.7)
        .opacity(BubbleSwipeGesturePolicy.replyIndicatorProgress(for: translation))
        .padding(.leading, 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hasPassedThreshold)
        .accessibilityHidden(true)
    }
  }

  private func handle(state: UIGestureRecognizer.State, dragX: CGFloat) {
    switch state {
    case .began, .changed:
      let next = BubbleSwipeGesturePolicy.replyTranslation(forDragX: dragX)
      translation = next
      let passed = BubbleSwipeGesturePolicy.passedReplyThreshold(next)
      if passed != hasPassedThreshold {
        hasPassedThreshold = passed
        // Only the crossing into the committed zone is worth a bump; dragging back
        // out is silent, matching the actions sheet's single confirm haptic.
        if passed { thresholdHaptic += 1 }
      }
    case .ended:
      let shouldReply = hasPassedThreshold
      reset()
      if shouldReply { onReply() }
    case .cancelled, .failed:
      reset()
    case .possible, .recognized:
      break
    @unknown default:
      reset()
    }
  }

  private func reset() {
    hasPassedThreshold = false
    withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8)) {
      translation = 0
    }
  }
}

extension View {
  /// Adds drag-right-to-reply. Pass `isEnabled: false` on rows that cannot be replied to
  /// (see `MessageActionAvailability.canReply`) so the gesture is not installed at all and
  /// the list keeps every horizontal drag on those rows.
  func swipeToReply(isEnabled: Bool, perform onReply: @escaping () -> Void) -> some View {
    modifier(BubbleSwipeToReplyModifier(isEnabled: isEnabled, onReply: onReply))
  }
}
