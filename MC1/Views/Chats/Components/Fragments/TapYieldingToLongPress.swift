import SwiftUI
import UIKit

/// A transparent tap catcher for an interactive bubble fragment (GIF, image, preview card). A quick
/// tap routes to `onTap`; a sustained press yields to the bubble's long-press so the actions sheet
/// opens. It replaces a SwiftUI `Button`, whose press gesture grabs the touch on touch-down and
/// cancels the bubble's long-press.
///
/// The overlay is a `GestureHostingProxyView`: it marks the fragment's active region while the
/// recognizer lives on the enclosing cell, so the overlay never hit-tests and the bubble's own
/// long-press below keeps receiving touches. The delegate scopes the tap to the proxy's frame
/// (the recognizer's host spans the whole row) and, off Mac, denies simultaneous recognition
/// with a `UILongPressGestureRecognizer` so the bubble's long-press wins a contested press. On
/// Mac the secondary click routes through a context-menu interaction, which that denial must
/// not disturb — there the delegate scopes the touch but vetoes nothing.
struct TapYieldingToLongPress: UIViewRepresentable {
  let onTap: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onTap: onTap, isMac: ProcessInfo.processInfo.isiOSAppOnMac)
  }

  func makeUIView(context: Context) -> GestureHostingProxyView {
    let view = GestureHostingProxyView(
      recognizer: Self.makeRecognizer(coordinator: context.coordinator)
    )
    context.coordinator.proxy = view
    return view
  }

  func updateUIView(_ uiView: GestureHostingProxyView, context: Context) {
    context.coordinator.onTap = onTap
  }

  /// Builds the tap recognizer with the yielding policy. Pure so the `cancelsTouchesInView`
  /// flag and the delegate wiring can be exercised in a unit test.
  static func makeRecognizer(coordinator: Coordinator) -> UITapGestureRecognizer {
    let recognizer = UITapGestureRecognizer(
      target: coordinator,
      action: #selector(Coordinator.handleTap)
    )
    recognizer.cancelsTouchesInView = false
    recognizer.delegate = coordinator
    return recognizer
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var onTap: () -> Void
    let isMac: Bool
    /// The overlay marking the fragment's active region; the recognizer itself lives on the
    /// enclosing cell and would otherwise fire for taps anywhere in the row.
    weak var proxy: GestureHostingProxyView?

    init(onTap: @escaping () -> Void, isMac: Bool) {
      self.onTap = onTap
      self.isMac = isMac
    }

    @objc func handleTap() {
      onTap()
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      if isMac { return true }
      return !(otherGestureRecognizer is UILongPressGestureRecognizer)
    }

    func gestureRecognizer(
      _: UIGestureRecognizer,
      shouldReceive touch: UITouch
    ) -> Bool {
      guard let proxy else { return true }
      return proxy.containsTouch(touch)
    }
  }
}

extension View {
  /// Routes a quick tap to `perform` while yielding a sustained press to the bubble's long-press.
  /// Use on interactive bubble fragments instead of a `Button`, whose press gesture would cancel
  /// the bubble's `.onLongPressGesture` before the actions sheet can open.
  func tapYieldingToLongPress(perform: @escaping () -> Void) -> some View {
    overlay { TapYieldingToLongPress(onTap: perform) }
  }
}
