import Foundation
import Observation

/// Holds the Weather tool's model for one visit to the tool.
///
/// The model cannot live in the tool view's `@State`: `ContentView` swaps the whole shell
/// (`MainTabView` ↔ `MainSidebarView`) when the size class changes, which destroys that view and
/// everything under it. So the model lives here, keyed to the visit rather than to a view: it
/// survives the swap, a pushed detail screen and a switch to another tab, and it is released
/// once no Weather root is on screen and the navigation no longer names Weather as the open tool.
@Observable
@MainActor
final class WeatherModelStore {
  static let shared = WeatherModelStore()

  private(set) var model: WeatherToolModel?

  @ObservationIgnored private var visibleRoots = 0
  @ObservationIgnored private var isToolOpen: (@MainActor () -> Bool)?
  @ObservationIgnored private var releaseTask: Task<Void, Never>?

  /// Long enough for a shell swap to bring the new root on screen.
  static let releaseDelay: Duration = .milliseconds(800)

  /// A Weather root came on screen: the visit's model, created on the first appearance.
  @discardableResult
  func rootAppeared(isToolOpen: @escaping @MainActor () -> Bool) -> WeatherToolModel {
    self.isToolOpen = isToolOpen
    releaseTask?.cancel()
    releaseTask = nil
    visibleRoots += 1
    if let model { return model }
    let created = WeatherToolModel()
    model = created
    return created
  }

  /// A Weather root left the screen: a push, a shell swap, or the end of the visit. Which one is
  /// only known a moment later, so the decision waits.
  func rootDisappeared() {
    visibleRoots = max(0, visibleRoots - 1)
    releaseTask?.cancel()
    releaseTask = Task { [weak self] in
      try? await Task.sleep(for: Self.releaseDelay)
      guard !Task.isCancelled else { return }
      self?.evaluate()
    }
  }

  func isCurrent(_ candidate: WeatherToolModel) -> Bool {
    model === candidate
  }

  /// Releases the model when the visit has ended; otherwise waits for the navigation to change.
  /// A detail screen pushed over the root keeps the tool open with no root on screen, and a pop
  /// straight to the tool list from there fires no root disappearance, so the open tool is
  /// watched rather than checked once.
  func evaluate() {
    guard visibleRoots == 0, model != nil else { return }
    let open = isToolOpen?() ?? false
    guard open else {
      model = nil
      isToolOpen = nil
      return
    }
    withObservationTracking {
      _ = self.isToolOpen?()
    } onChange: { [weak self] in
      Task { @MainActor in self?.evaluate() }
    }
  }
}
