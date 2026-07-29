import SwiftUI
import UIKit

/// Attaches a horizontal `UIPanGestureRecognizer` to a bubble without taking its touches.
///
/// Built the same way as `TapYieldingToLongPress`: a `GestureHostingProxyView` that marks
/// the gesture's active region while the recognizer itself lives on the enclosing cell, so
/// the overlay never becomes a hit-test target and the SwiftUI gestures beneath it (the
/// bubble's long-press, link taps) keep receiving touches. A SwiftUI `DragGesture` cannot
/// be used here — inside a scrolling list it reserves the touch on the first movement and
/// the conversation stops scrolling, which is exactly the regression the fork hit before
/// moving these swipes to UIKit recognizers.
///
/// `shouldBegin` runs the direction gate, so an ambiguous or vertical drag never starts the
/// swipe and the list keeps the pan. `allowsSimultaneousRecognition` decides whether the
/// swipe coexists with the list's own pan once it has begun: the timestamp reveal does (it
/// tracks the finger while the list may still scroll under it), swipe-to-reply does not (it
/// moves one row and must own the drag).
struct BubbleHorizontalPanRecognizer: UIViewRepresentable {
  /// Direction gate, given the pan velocity in the bubble's coordinate space.
  let shouldBegin: (CGPoint) -> Bool
  /// Whether the recognizer may run alongside the enclosing list's pan.
  let allowsSimultaneousRecognition: Bool
  /// Fires on every state change with the horizontal translation.
  let onChange: (UIGestureRecognizer.State, CGFloat) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      shouldBegin: shouldBegin,
      allowsSimultaneousRecognition: allowsSimultaneousRecognition,
      onChange: onChange
    )
  }

  func makeUIView(context: Context) -> GestureHostingProxyView {
    let view = GestureHostingProxyView(
      recognizer: Self.makeRecognizer(coordinator: context.coordinator)
    )
    context.coordinator.proxy = view
    return view
  }

  func updateUIView(_: GestureHostingProxyView, context: Context) {
    context.coordinator.shouldBegin = shouldBegin
    context.coordinator.allowsSimultaneousRecognition = allowsSimultaneousRecognition
    context.coordinator.onChange = onChange
  }

  /// Builds the pan recognizer. Pure so the non-consuming and delegated wiring can be
  /// asserted in a unit test.
  static func makeRecognizer(coordinator: Coordinator) -> UIPanGestureRecognizer {
    let recognizer = UIPanGestureRecognizer(
      target: coordinator,
      action: #selector(Coordinator.handlePan(_:))
    )
    // Never swallow the touch: the bubble's long-press and the fragments' tap catcher sit on
    // the same pixels and must still see it.
    recognizer.cancelsTouchesInView = false
    recognizer.delegate = coordinator
    return recognizer
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: (CGPoint) -> Bool
    var allowsSimultaneousRecognition: Bool
    var onChange: (UIGestureRecognizer.State, CGFloat) -> Void
    /// The overlay marking the gesture's active region; the recognizer itself lives on the
    /// enclosing cell and would otherwise fire for touches anywhere in the row.
    weak var proxy: GestureHostingProxyView?

    init(
      shouldBegin: @escaping (CGPoint) -> Bool,
      allowsSimultaneousRecognition: Bool,
      onChange: @escaping (UIGestureRecognizer.State, CGFloat) -> Void
    ) {
      self.shouldBegin = shouldBegin
      self.allowsSimultaneousRecognition = allowsSimultaneousRecognition
      self.onChange = onChange
    }

    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
      onChange(recognizer.state, recognizer.translation(in: recognizer.view).x)
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
      return shouldBegin(pan.velocity(in: pan.view))
    }

    func gestureRecognizer(
      _: UIGestureRecognizer,
      shouldReceive touch: UITouch
    ) -> Bool {
      guard let proxy else { return true }
      return proxy.containsTouch(touch)
    }

    func gestureRecognizer(
      _: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
      // Always yield to a long-press: a press that drifts a few points must still open the
      // actions sheet rather than being converted into a swipe.
      if other is UILongPressGestureRecognizer { return false }
      return allowsSimultaneousRecognition
    }
  }
}
