@testable import MC1
import Testing
import UIKit

/// Guards the hit-test posture of the bubble gesture overlays. The shipped regression this
/// design fixes was invisible in review: a hit-testable overlay carrying a recognizer works
/// for its own gesture while silently starving every SwiftUI gesture beneath it, so the
/// actions-sheet long-press died on every message the moment the row-wide timestamp-reveal
/// overlay landed. These tests pin the two halves of the replacement contract: the proxy
/// never hit-tests, and the recognizer rides the enclosing cell instead.
@Suite("Gesture hosting proxy")
@MainActor
struct GestureHostingProxyTests {
  @Test
  func `the proxy refuses hit-testing so SwiftUI gestures beneath it keep receiving touches`() {
    let proxy = GestureHostingProxyView(recognizer: UIPanGestureRecognizer())
    #expect(proxy.isUserInteractionEnabled == false)
  }

  @Test
  func `entering a cell hierarchy moves the recognizer onto the cell's contentView`() {
    let recognizer = UIPanGestureRecognizer()
    let proxy = GestureHostingProxyView(recognizer: recognizer)

    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let cell = UICollectionViewCell(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
    let hostingContainer = UIView(frame: cell.contentView.bounds)

    cell.contentView.addSubview(hostingContainer)
    hostingContainer.addSubview(proxy)
    #expect(recognizer.view == nil)

    window.addSubview(cell)
    #expect(recognizer.view === cell.contentView)
  }

  @Test
  func `leaving the window detaches the recognizer so cell reuse cannot strand it`() {
    let recognizer = UIPanGestureRecognizer()
    let proxy = GestureHostingProxyView(recognizer: recognizer)

    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let cell = UICollectionViewCell(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
    cell.contentView.addSubview(proxy)
    window.addSubview(cell)
    #expect(recognizer.view === cell.contentView)

    cell.removeFromSuperview()
    #expect(recognizer.view == nil)
  }

  @Test
  func `moving between cells re-homes the recognizer with the proxy`() {
    let recognizer = UIPanGestureRecognizer()
    let proxy = GestureHostingProxyView(recognizer: recognizer)

    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let first = UICollectionViewCell(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
    let second = UICollectionViewCell(frame: CGRect(x: 0, y: 44, width: 320, height: 44))
    window.addSubview(first)
    window.addSubview(second)

    first.contentView.addSubview(proxy)
    #expect(recognizer.view === first.contentView)

    proxy.removeFromSuperview()
    second.contentView.addSubview(proxy)
    #expect(recognizer.view === second.contentView)
    #expect(first.contentView.gestureRecognizers?.contains(recognizer) != true)
  }

  @Test
  func `outside a collection view the immediate superview stands in as host`() {
    let recognizer = UITapGestureRecognizer()
    let proxy = GestureHostingProxyView(recognizer: recognizer)

    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let plain = UIView(frame: window.bounds)
    plain.addSubview(proxy)
    window.addSubview(plain)
    #expect(recognizer.view === plain)
  }

  @Test
  func `the pan coordinator scopes initial touches to its proxy's frame`() {
    // The delegate falls back to accepting when it has no proxy — a recognizer that
    // silently receives nothing is worse than one that is unscoped in previews.
    let coordinator = BubbleHorizontalPanRecognizer.Coordinator(
      shouldBegin: { _ in true },
      allowsSimultaneousRecognition: true,
      onChange: { _, _ in }
    )
    #expect(coordinator.gestureRecognizer(UIPanGestureRecognizer(), shouldReceive: UITouch()))
  }
}
