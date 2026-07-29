import SwiftUI
import UIKit

/// Shared horizontal offset for the iMessage-style timestamp reveal.
///
/// One instance per conversation, held by `ChatConversationMessagesContent` and injected into
/// every hosted cell. A drag begins on one bubble but has to move the whole conversation, so
/// the offset cannot live in per-row state.
///
/// A reference type is what makes this work across the cell-hosting boundary: `MessagingUI`
/// reconfigures a visible cell only when its item changes, so an environment *value* updated
/// mid-drag would never reach the cells. The object's identity is stable, and each cell's own
/// body observes `offset`, so a mutation invalidates every visible cell directly.
@Observable
@MainActor
final class ChatTimestampRevealState {
  /// Points the rows are currently pulled left. Zero when the gesture is not active.
  var offset: CGFloat = 0
}

extension EnvironmentValues {
  /// Nil outside a conversation list. The default cannot be a live instance — the state is
  /// main-actor isolated and an environment default must be constructible off it — and an
  /// implicit shared fallback would silently couple unrelated surfaces to one offset anyway.
  @Entry var chatTimestampReveal: ChatTimestampRevealState?
}

/// Drag left anywhere on the conversation to slide every row aside and read its send time,
/// releasing to slide them back.
///
/// Unlike swipe-to-reply this coexists with the list's own pan, so the user can keep scrolling
/// with the timestamps held open — the fork's rule, kept because the gesture is a read, not an
/// action, and interrupting the scroll to service it would be worse than the overlap.
private struct ChatTimestampRevealModifier: ViewModifier {
  let date: Date

  @Environment(\.chatTimestampReveal) private var reveal
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var offset: CGFloat {
    reveal?.offset ?? 0
  }

  func body(content: Content) -> some View {
    content
      // The label overlay must sit inside the slide: `.offset` moves only the view it
      // wraps, so an overlay applied after it would stay pinned to the un-slid frame.
      .overlay(alignment: .trailing) { timestampLabel }
      .offset(x: -offset)
      .overlay {
        if reveal != nil {
          BubbleHorizontalPanRecognizer(
            shouldBegin: BubbleSwipeGesturePolicy.shouldBeginReveal(velocity:),
            allowsSimultaneousRecognition: true,
            onChange: handle(state:dragX:)
          )
        }
      }
  }

  @ViewBuilder
  private var timestampLabel: some View {
    if offset > 0 {
      Text(date.formatted(date: .omitted, time: .shortened))
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .opacity(BubbleSwipeGesturePolicy.revealProgress(for: offset))
        // Glued to the rows, iMessage-style: the label starts one full reveal-width past
        // the row's trailing edge, rides in with the slide, and lands right-aligned in the
        // strip the rows vacated once the drag reaches its maximum.
        .offset(x: BubbleSwipeGesturePolicy.revealMaxTranslation)
        .padding(.trailing, 4)
        .accessibilityHidden(true)
    }
  }

  private func handle(state: UIGestureRecognizer.State, dragX: CGFloat) {
    guard let reveal else { return }
    switch state {
    case .began, .changed:
      reveal.offset = BubbleSwipeGesturePolicy.revealOffset(forDragX: dragX)
    case .ended, .cancelled, .failed:
      withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
        reveal.offset = 0
      }
    case .possible, .recognized:
      break
    @unknown default:
      reveal.offset = 0
    }
  }
}

extension View {
  /// Adds drag-left-to-reveal-send-time. Applied to every row, since the gesture may start on
  /// any of them and moves all of them.
  func swipeToRevealTimestamp(date: Date) -> some View {
    modifier(ChatTimestampRevealModifier(date: date))
  }
}
