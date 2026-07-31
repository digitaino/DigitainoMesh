import CoreLocation
import MC1Services
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.mc1", category: "TrafficHeatmap")

/// Screen state for the traffic map: which window is selected, what the last aggregation found,
/// and whether a load is in flight.
///
/// All the arithmetic lives in ``TrafficHeatmapAggregator``; this is the thin part — fetch,
/// hand off, publish. Aggregation runs off the main actor because a full RX log is a few
/// thousand entries and every hop of every one of them is resolved against the node pool.
@MainActor
@Observable
final class TrafficHeatmapModel {
  /// How much of the RX log to read. The store prunes at 1000 entries plus a 100-entry
  /// slack, so this reads the whole log with room to spare and no window is ever truncated.
  private static let entryFetchLimit = 2000

  private(set) var snapshot: TrafficHeatmapSnapshot = .empty
  /// Window choices scaled to the log on hand; see ``TrafficTimeWindow/available(oldestEntry:now:)``.
  private(set) var availableWindows: [TrafficTimeWindow] = [.all]
  private(set) var isLoading = false
  private(set) var didFail = false
  /// Whether the log held anything at all, which separates "no traffic yet" from
  /// "traffic, but none of it from nodes we can place".
  private(set) var hasEntries = false

  var window: TrafficTimeWindow = .all

  /// The window the in-flight or last-finished `load()` is aggregating. `load()` rewrites
  /// `window` itself when the ladder shrank under the selection, and the view's `onChange`
  /// reload compares against this so that write does not spawn a second aggregation over the
  /// fetch this one already has in hand.
  private(set) var loadedWindow: TrafficTimeWindow?

  private let aggregator = TrafficHeatmapAggregator()

  var hasPlacedNodes: Bool {
    !snapshot.nodes.isEmpty
  }

  // MARK: - Loading

  func load(dataStore: PersistenceStore?, radioID: UUID?, origin: CLLocation?) async {
    guard let dataStore, let radioID else {
      snapshot = .empty
      hasEntries = false
      return
    }

    isLoading = true
    didFail = false
    defer { isLoading = false }

    do {
      let entries = try await dataStore.fetchRxLogEntries(
        radioID: radioID,
        limit: Self.entryFetchLimit
      )
      let contacts = try await dataStore.fetchContacts(radioID: radioID)
      let discovered = try await dataStore.fetchDiscoveredNodes(radioID: radioID)

      let now = Date()
      hasEntries = !entries.isEmpty
      // Entries come back most recent first, so the last one is the oldest we hold. The ladder
      // is scaled to the log actually loaded rather than to a separate "oldest row" query.
      availableWindows = TrafficTimeWindow.available(oldestEntry: entries.last?.receivedAt, now: now)
      if !availableWindows.contains(window) {
        window = .all
      }

      let candidates = contacts.map(AnyResolvableNode.init) + discovered.map(AnyResolvableNode.init)
      let aggregator = aggregator
      let selectedWindow = window
      loadedWindow = selectedWindow
      let anchor = origin.flatMap { TrafficCoordinate($0.coordinate) }

      snapshot = await Task.detached(priority: .userInitiated) {
        aggregator.aggregate(
          entries: entries,
          candidates: candidates,
          window: selectedWindow,
          now: now,
          origin: anchor
        )
      }.value
    } catch {
      logger.error("Traffic aggregation failed: \(error.localizedDescription, privacy: .public)")
      didFail = true
      snapshot = .empty
    }
  }
}
