import Foundation
@testable import MC1
import Testing

/// The focus model's transitions: popping a level, surviving a poll, stepping
/// through the frozen ladder, and what the clipboard summary may contain.
@Suite("PacketScope focus")
@MainActor
struct PacketScopeFocusTests {
  private let order = PacketScopeFrozenOrder(
    observerIDs: ["one", "two", "three"],
    routeIDsByObserver: [
      "one": ["one|AA", "one|BB"],
      "two": ["two|CC"],
      "three": ["three|DD", "three|EE", "three|FF"],
    ]
  )

  // MARK: - Popping

  @Test
  func `Popping walks route → observer → all, and all stays put`() {
    #expect(PacketScopeFocus.route(observerID: "one", routeID: "one|AA").popped() == .observer("one"))
    #expect(PacketScopeFocus.observer("one").popped() == .all)
    #expect(PacketScopeFocus.all.popped() == .all)
  }

  // MARK: - Reconciling after a poll

  @Test
  func `A focused route that vanishes falls back to its observer, then to all`() {
    let focus = PacketScopeFocus.route(observerID: "one", routeID: "one|AA")
    #expect(PacketScopeFocusLogic.reconciled(focus, routeIDs: ["one|AA"], observerIDs: ["one"]) == focus)
    #expect(PacketScopeFocusLogic.reconciled(focus, routeIDs: [], observerIDs: ["one"]) == .observer("one"))
    #expect(PacketScopeFocusLogic.reconciled(focus, routeIDs: [], observerIDs: []) == .all)
  }

  @Test
  func `A focused observer that vanishes falls back to all, and an intact one is untouched`() {
    #expect(PacketScopeFocusLogic.reconciled(.observer("one"), routeIDs: [], observerIDs: ["one"]) == .observer("one"))
    #expect(PacketScopeFocusLogic.reconciled(.observer("one"), routeIDs: [], observerIDs: ["two"]) == .all)
    #expect(PacketScopeFocusLogic.reconciled(.all, routeIDs: [], observerIDs: []) == .all)
  }

  // MARK: - Stepping

  @Test
  func `Stepping forward from an observer's last route lands on the next observer's first, and wraps at the end`() {
    let lastOfOne = PacketScopeFocus.route(observerID: "one", routeID: "one|BB")
    #expect(PacketScopeFocusLogic.stepped(lastOfOne, by: 1, order: order) == .route(observerID: "two", routeID: "two|CC"))
    let lastOfAll = PacketScopeFocus.route(observerID: "three", routeID: "three|FF")
    #expect(PacketScopeFocusLogic.stepped(lastOfAll, by: 1, order: order) == .route(observerID: "one", routeID: "one|AA"))
  }

  @Test
  func `Stepping back is the exact inverse of stepping forward`() {
    let ladder = order.observerIDs.flatMap { observer in
      (order.routeIDsByObserver[observer] ?? []).map { PacketScopeFocus.route(observerID: observer, routeID: $0) }
    }
    for focus in ladder {
      let forward = PacketScopeFocusLogic.stepped(focus, by: 1, order: order)
      #expect(forward.flatMap { PacketScopeFocusLogic.stepped($0, by: -1, order: order) } == focus)
    }
  }

  @Test
  func `From an observer, forward is its first route and back is the previous observer's last; from all, the ends`() {
    #expect(PacketScopeFocusLogic.stepped(.observer("two"), by: 1, order: order) == .route(observerID: "two", routeID: "two|CC"))
    #expect(PacketScopeFocusLogic.stepped(.observer("two"), by: -1, order: order) == .route(observerID: "one", routeID: "one|BB"))
    #expect(PacketScopeFocusLogic.stepped(.all, by: 1, order: order) == .route(observerID: "one", routeID: "one|AA"))
    #expect(PacketScopeFocusLogic.stepped(.all, by: -1, order: order) == .route(observerID: "three", routeID: "three|FF"))
    let empty = PacketScopeFrozenOrder(observerIDs: [], routeIDsByObserver: [:])
    #expect(PacketScopeFocusLogic.stepped(.all, by: 1, order: empty) == nil)
  }

  // MARK: - Copy summary

  @Test
  func `The copy summary names observers, signals and paths, and never the packet identifier`() {
    let hash = "286dcbdeab84b458"
    let route = PacketScopeReception.Route(hops: ["AA", "BB"], resolvedHops: [], bestSNR: 7.5)
    let receptions = [
      PacketScopeReception(
        observerID: "obs-deadbeefcafe0001",
        observerName: "Observer deadbeef",
        observerIATA: "AUS",
        bestSNR: 7.5,
        bestRSSI: -80,
        routes: [route],
        firstHeard: nil,
        receptionCount: 1
      ),
    ]
    let summary = PacketScopeSummary(
      observerCount: 1,
      receptionCount: 1,
      bestSNR: 7.5,
      shortestHopCount: 2,
      firstHeard: nil,
      lastHeard: nil
    )
    let text = PacketScopeFocusLogic.copySummary(
      summary: summary,
      receptions: receptions,
      hopNamesByRoute: ["obs-deadbeefcafe0001|AA,BB": ["Alpha", "Bravo"]],
      routeID: { "\($0)|\($1.hops.joined(separator: ","))" }
    )
    #expect(text.contains("Observer deadbeef"))
    #expect(text.contains(PacketScopeCoverageBuilder.decibels(7.5)))
    #expect(text.contains("Alpha › Bravo"))
    #expect(!text.contains(hash))
    // No 16-hex run anywhere, whatever the names look like.
    let hexRun = try? NSRegularExpression(pattern: "[0-9a-f]{16}")
    let matches = hexRun?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? -1
    #expect(matches == 0)
  }
}
