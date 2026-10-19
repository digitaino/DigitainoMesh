import UIKit

/// Hosts a bubble gesture recognizer without occluding the SwiftUI content it overlays.
///
/// A plain transparent overlay view cannot carry these recognizers: it becomes UIKit's
/// hit-test target for every touch on its pixels, and SwiftUI treats a platform view as
/// opaque in its own hit-testing — so the bubble's `.onLongPressGesture`, link taps, and
/// any sibling overlay's recognizer beneath it silently stop receiving touches. (That was
/// the shipped regression: the row-wide timestamp-reveal overlay killed the actions-sheet
/// long-press on every message.)
///
/// This view instead refuses hit-testing entirely (`isUserInteractionEnabled = false`) and
/// installs its recognizer on the enclosing `UICollectionViewCell`'s `contentView` — an
/// ancestor of the cell's hosting view, so the recognizer still receives every touch that
/// UIKit hit-tests to the SwiftUI-drawn content. The proxy's own frame remains the
/// gesture's active region: the coordinator's `shouldReceive` delegate call filters the
/// initial touch by containment in these bounds.
final class GestureHostingProxyView: UIView {
  private let recognizer: UIGestureRecognizer
  private weak var host: UIView?

  /// Invoked with the recognizer's current state immediately before it leaves its host.
  ///
  /// `removeGestureRecognizer` delivers no terminal state, so a gesture still tracking when the
  /// cell is recycled never reaches `.cancelled` and anything it left mutated outside the row —
  /// the conversation-wide timestamp-reveal offset — is stranded there. Whether UIKit cancels
  /// first is not decidable from here, so owners of state that outlives the row unwind it from
  /// this callback and tolerate the duplicate.
  var onWillDetach: ((UIGestureRecognizer.State) -> Void)?

  init(recognizer: UIGestureRecognizer) {
    self.recognizer = recognizer
    super.init(frame: .zero)
    backgroundColor = .clear
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    let next = window == nil ? nil : Self.recognizerHost(above: self)
    guard next !== host else { return }
    if let host {
      onWillDetach?(recognizer.state)
      host.removeGestureRecognizer(recognizer)
    }
    next?.addGestureRecognizer(recognizer)
    host = next
  }

  /// The view the recognizer should live on: the enclosing cell's `contentView`, so cell
  /// reuse tears the recognizer down with the proxy rather than stranding it. Outside a
  /// collection view (previews, tests) the immediate superview stands in.
  static func recognizerHost(above view: UIView) -> UIView? {
    var ancestor = view.superview
    while let current = ancestor {
      if let cell = current as? UICollectionViewCell { return cell.contentView }
      ancestor = current.superview
    }
    return view.superview
  }

  /// Whether a touch beginning at this window-delivered location falls inside the proxy's
  /// frame — the delegate-side scoping that replaces hit-testing.
  func containsTouch(_ touch: UITouch) -> Bool {
    bounds.contains(touch.location(in: self))
  }
}
