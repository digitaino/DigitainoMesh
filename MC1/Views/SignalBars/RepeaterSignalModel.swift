import Foundation
import MC1Services

/// SwiftUI's view of ``SignalBarsEngine``.
///
/// Actors do not participate in SwiftUI observation, so this holds the engine's latest
/// ``SignalBarsSnapshot`` in an `@Observable` property and forwards user intents back. It is
/// deliberately empty of logic: every rule about repeaters, probes, staleness and watch
/// matching lives in the engine, where it is testable without a view. If a computation here
/// grows past reading a field off the snapshot, it belongs in the engine instead.
///
/// One instance lives on `AppState` for the whole app lifetime; `attach(to:)` binds it to the
/// per-connection engine and `detach()` releases it, so the toolbar keeps rendering an empty
/// table while disconnected rather than disappearing mid-animation.
///
/// Named `RepeaterSignalModel` rather than anything with `SignalBars` in it: upstream already
/// has a `SignalBars` view — a BLE RSSI glyph for the device pickers — and the two are
/// unrelated.
@Observable
@MainActor
final class RepeaterSignalModel {
  /// The engine's latest state. Every view in this feature renders from this one value.
  private(set) var snapshot: SignalBarsSnapshot = .empty()

  /// Whether an engine is currently bound. Drives whether the toolbar item shows at all.
  private(set) var isAttached = false

  @ObservationIgnored private var engine: SignalBarsEngine?
  @ObservationIgnored private var streamTask: Task<Void, Never>?

  // MARK: - Binding

  /// Subscribes to `engine` and seeds the current state.
  ///
  /// Re-attaching to the same engine is safe: the previous subscription is cancelled first,
  /// so a re-fired `.task` cannot leave two streams writing the same property.
  func attach(to engine: SignalBarsEngine) async {
    detach()
    self.engine = engine
    isAttached = true

    // Registration is synchronous inside the engine, so a snapshot published between
    // subscribing and seeding is delivered rather than lost.
    let snapshots = engine.snapshots()
    streamTask = Task { [weak self] in
      for await snapshot in snapshots {
        guard !Task.isCancelled else { break }
        self?.snapshot = snapshot
      }
    }
    snapshot = await engine.currentSnapshot()
  }

  /// Releases the engine and resets to the empty table.
  func detach() {
    streamTask?.cancel()
    streamTask = nil
    engine = nil
    isAttached = false
    snapshot = .empty()
  }

  // MARK: - Derived state

  /// The best link — what the toolbar indicator shows.
  var best: RepeaterSignal? {
    snapshot.best
  }

  /// The rows the popover renders: the table minus stale and dismissed entries.
  var displayRepeaters: [RepeaterSignal] {
    snapshot.displayRepeaters
  }

  /// Whether the table is mirrored from the radio or measured by the app.
  var mode: SignalBarsMode {
    snapshot.mode
  }

  var isRefreshing: Bool {
    snapshot.isRefreshing
  }

  var hasStaleRepeaters: Bool {
    snapshot.hasStaleRepeaters
  }

  var watched: WatchedRepeaterState? {
    snapshot.watched
  }

  /// Whether this row is the one being watched, allowing for differing hash widths — the
  /// same repeater heard at a wider hash is still the watched one.
  func isWatched(_ repeater: RepeaterSignal) -> Bool {
    guard let watched = snapshot.watched else { return false }
    return watched.id.identifiesSameNode(as: repeater.id)
  }

  // MARK: - Intents

  /// Finds repeaters and measures them.
  func startProbe() async {
    await engine?.startProbe()
  }

  /// Re-measures one repeater, or all of them when `target` is `nil`.
  func requestRefresh(target: NodeHexID? = nil) async {
    await engine?.requestRefresh(target: target)
  }

  /// Watches a repeater for range testing, or clears the watch with `nil`.
  func watchRepeater(_ id: NodeHexID?) async {
    await engine?.watchRepeater(id)
  }

  /// Hides one repeater from the list until the radio hears it again.
  func dismissRepeater(_ id: NodeHexID) async {
    await engine?.dismissRepeater(id)
  }

  /// Hides every currently-stale row in one action.
  func clearStaleRepeaters() async {
    await engine?.clearStaleRepeaters()
  }

  /// Tells the engine the device's path hash mode changed under it.
  func setPathHashMode(_ mode: UInt8) async {
    await engine?.setPathHashMode(mode)
  }
}
