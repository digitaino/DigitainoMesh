import CoreLocation
import Foundation
@testable import MC1
import Testing

/// The focus model's transitions: popping a level, surviving a poll, stepping
/// through the frozen ladder, and what the clipboard summary may contain.
@Suite("PacketScope focus")
@MainActor
struct PacketScopeFocusTests {
  /// Three chains: the direct one (two observers), a one-hop chain, and a
  /// two-hop chain three observers heard it by.
  private let order = PacketScopeFrozenOrder(
    groupKeys: ["", "AA", "BB,CC"],
    routeIDsByGroup: [
      "": ["one|", "two|"],
      "AA": ["one|AA"],
      "BB,CC": ["one|BB,CC", "three|BB,CC", "four|BB,CC"],
    ]
  )

  /// The same six routes as the observer-major list holds them: one row per
  /// observer, its own routes inside.
  private let observerOrder = PacketScopeFrozenOrder(
    groupKeys: ["one", "two"],
    routeIDsByGroup: [
      "one": ["one|", "one|AA"],
      "two": ["two|BB,CC"],
    ]
  )

  // MARK: - Route ids and chain keys

  @Test
  func `A chain key survives a round trip through a route id`() {
    let hops = ["AA", "BB"]
    let routeID = PacketScopeCoverageBuilder.routeID(observerID: "obs-1", hops: hops)
    #expect(PacketScopeFocus.pathKey(fromRouteID: routeID) == PacketScopeFocus.pathKey(hops: hops))
    #expect(PacketScopeFocus.observerID(fromRouteID: routeID) == "obs-1")
  }

  @Test
  func `A repeater-free route ids to the empty chain, not to a failure`() {
    let routeID = PacketScopeCoverageBuilder.routeID(observerID: "obs-1", hops: [])
    #expect(routeID == "obs-1|")
    #expect(PacketScopeFocus.pathKey(fromRouteID: routeID) == "")
    #expect(PacketScopeFocus.observerID(fromRouteID: routeID) == "obs-1")
  }

  // MARK: - Popping

  @Test
  func `Popping walks route → path → all, and an observer pops straight to all`() {
    #expect(PacketScopeFocus.route(observerID: "one", routeID: "one|AA").popped(in: .path) == .path("AA"))
    #expect(PacketScopeFocus.route(observerID: "one", routeID: "one|").popped(in: .path) == .path(""))
    #expect(PacketScopeFocus.path("AA").popped(in: .path) == .all)
    // The map's own entry point sits under no single chain.
    #expect(PacketScopeFocus.observer("one").popped(in: .path) == .all)
    #expect(PacketScopeFocus.all.popped(in: .path) == .all)
  }

  @Test
  func `Grouped by observer, a route pops to its observer and a chain pops straight to all`() {
    #expect(PacketScopeFocus.route(observerID: "one", routeID: "one|AA").popped(in: .observer) == .observer("one"))
    #expect(PacketScopeFocus.route(observerID: "one", routeID: "one|").popped(in: .observer) == .observer("one"))
    #expect(PacketScopeFocus.observer("one").popped(in: .observer) == .all)
    // A chain has no row of its own in this list, so there is nothing above it
    // but everything.
    #expect(PacketScopeFocus.path("AA").popped(in: .observer) == .all)
  }

  // MARK: - Group keys

  @Test
  func `A focus reports a group key only for the level its own grouping lists`() {
    let route = PacketScopeFocus.route(observerID: "one", routeID: "one|AA")
    #expect(route.groupKey(in: .path) == "AA")
    #expect(route.groupKey(in: .observer) == "one")
    #expect(PacketScopeFocus.path("AA").groupKey(in: .path) == "AA")
    #expect(PacketScopeFocus.path("AA").groupKey(in: .observer) == nil)
    #expect(PacketScopeFocus.observer("one").groupKey(in: .observer) == "one")
    #expect(PacketScopeFocus.observer("one").groupKey(in: .path) == nil)
    #expect(PacketScopeFocus.all.groupKey(in: .path) == nil)
    #expect(PacketScopeFocus.all.groupKey(in: .observer) == nil)
  }

  // MARK: - Reconciling after a poll

  @Test
  func `A focused route that vanishes falls back to its chain, then its observer, then all`() {
    let focus = PacketScopeFocus.route(observerID: "one", routeID: "one|AA")
    #expect(PacketScopeFocusLogic.reconciled(
      focus, mode: .path, routeIDs: ["one|AA"], pathKeys: ["AA"], observerIDs: ["one"]
    ) == focus)
    #expect(PacketScopeFocusLogic.reconciled(
      focus, mode: .path, routeIDs: [], pathKeys: ["AA"], observerIDs: ["one"]
    ) == .path("AA"))
    #expect(PacketScopeFocusLogic.reconciled(
      focus, mode: .path, routeIDs: [], pathKeys: [], observerIDs: ["one"]
    ) == .observer("one"))
    #expect(PacketScopeFocusLogic.reconciled(
      focus, mode: .path, routeIDs: [], pathKeys: [], observerIDs: []
    ) == .all)
  }

  /// The inverse of the path-mode ladder above: grouped by observer, the row
  /// the reader was looking at is the observer, so a vanished route falls back
  /// to it even while its chain is still on the map.
  @Test
  func `Grouped by observer, a vanished route falls back to its observer before its chain`() {
    let focus = PacketScopeFocus.route(observerID: "one", routeID: "one|AA")
    #expect(PacketScopeFocusLogic.reconciled(
      focus, mode: .observer, routeIDs: [], pathKeys: ["AA"], observerIDs: ["one"]
    ) == .observer("one"))
    #expect(PacketScopeFocusLogic.reconciled(
      focus, mode: .observer, routeIDs: [], pathKeys: ["AA"], observerIDs: []
    ) == .path("AA"))
    // A chain focus belongs to the other list; it cannot survive here.
    #expect(PacketScopeFocusLogic.reconciled(
      .path("AA"), mode: .observer, routeIDs: [], pathKeys: ["AA"], observerIDs: []
    ) == .all)
    #expect(PacketScopeFocusLogic.reconciled(
      .observer("one"), mode: .path, routeIDs: [], pathKeys: [], observerIDs: ["one"]
    ) == .all)
  }

  @Test
  func `A focused chain or observer that vanishes falls back to all, and an intact one is untouched`() {
    #expect(PacketScopeFocusLogic.reconciled(
      .path("AA"), mode: .path, routeIDs: [], pathKeys: ["AA"], observerIDs: []
    ) == .path("AA"))
    #expect(PacketScopeFocusLogic.reconciled(
      .path("AA"), mode: .path, routeIDs: [], pathKeys: ["BB"], observerIDs: []
    ) == .all)
    #expect(PacketScopeFocusLogic.reconciled(
      .observer("one"), mode: .observer, routeIDs: [], pathKeys: [], observerIDs: ["one"]
    ) == .observer("one"))
    #expect(PacketScopeFocusLogic.reconciled(
      .observer("one"), mode: .observer, routeIDs: [], pathKeys: [], observerIDs: ["two"]
    ) == .all)
    #expect(PacketScopeFocusLogic.reconciled(
      .all, mode: .path, routeIDs: [], pathKeys: [], observerIDs: []
    ) == .all)
  }

  // MARK: - Stepping

  @Test
  func `Stepping forward from a chain's last route lands on the next chain's first, and wraps at the end`() {
    let lastOfDirect = PacketScopeFocus.route(observerID: "two", routeID: "two|")
    #expect(PacketScopeFocusLogic.stepped(lastOfDirect, by: 1, mode: .path, order: order)
      == .route(observerID: "one", routeID: "one|AA"))
    let lastOfAll = PacketScopeFocus.route(observerID: "four", routeID: "four|BB,CC")
    #expect(PacketScopeFocusLogic.stepped(lastOfAll, by: 1, mode: .path, order: order)
      == .route(observerID: "one", routeID: "one|"))
  }

  @Test
  func `Stepping back is the exact inverse of stepping forward`() {
    let ladder = order.groupKeys.flatMap { key in
      (order.routeIDsByGroup[key] ?? []).map {
        PacketScopeFocus.route(observerID: PacketScopeFocus.observerID(fromRouteID: $0), routeID: $0)
      }
    }
    #expect(ladder.count == 6)
    for focus in ladder {
      let forward = PacketScopeFocusLogic.stepped(focus, by: 1, mode: .path, order: order)
      #expect(forward.flatMap { PacketScopeFocusLogic.stepped($0, by: -1, mode: .path, order: order) } == focus)
    }
  }

  @Test
  func `From a chain, forward is its first route and back is the previous chain's last; from all, the ends`() {
    #expect(PacketScopeFocusLogic.stepped(.path("AA"), by: 1, mode: .path, order: order)
      == .route(observerID: "one", routeID: "one|AA"))
    #expect(PacketScopeFocusLogic.stepped(.path("AA"), by: -1, mode: .path, order: order)
      == .route(observerID: "two", routeID: "two|"))
    #expect(PacketScopeFocusLogic.stepped(.all, by: 1, mode: .path, order: order)
      == .route(observerID: "one", routeID: "one|"))
    #expect(PacketScopeFocusLogic.stepped(.all, by: -1, mode: .path, order: order)
      == .route(observerID: "four", routeID: "four|BB,CC"))
    let empty = PacketScopeFrozenOrder(groupKeys: [], routeIDsByGroup: [:])
    #expect(PacketScopeFocusLogic.stepped(.all, by: 1, mode: .path, order: empty) == nil)
  }

  @Test
  func `From an observer row, forward is its first route and back is the previous observer's last`() {
    #expect(PacketScopeFocusLogic.stepped(.observer("one"), by: 1, mode: .observer, order: observerOrder)
      == .route(observerID: "one", routeID: "one|"))
    // Wrapping: back from the first row lands on the last route of the last.
    #expect(PacketScopeFocusLogic.stepped(.observer("one"), by: -1, mode: .observer, order: observerOrder)
      == .route(observerID: "two", routeID: "two|BB,CC"))
    #expect(PacketScopeFocusLogic.stepped(.observer("two"), by: -1, mode: .observer, order: observerOrder)
      == .route(observerID: "one", routeID: "one|AA"))
    #expect(PacketScopeFocusLogic.stepped(.all, by: 1, mode: .observer, order: observerOrder)
      == .route(observerID: "one", routeID: "one|"))
    // A chain focus is the other list's level, so it steps from the ends.
    #expect(PacketScopeFocusLogic.stepped(.path("AA"), by: 1, mode: .observer, order: observerOrder)
      == .route(observerID: "one", routeID: "one|"))
  }

  @Test
  func `A focus the frozen order does not know steps from the ends rather than into a random route`() {
    let unknownRoute = PacketScopeFocus.route(observerID: "five", routeID: "five|GG")
    #expect(PacketScopeFocusLogic.stepped(unknownRoute, by: 1, mode: .path, order: order)
      == .route(observerID: "one", routeID: "one|"))
    #expect(PacketScopeFocusLogic.stepped(unknownRoute, by: -1, mode: .path, order: order)
      == .route(observerID: "four", routeID: "four|BB,CC"))
    // An observer sits under no single chain, so it steps from the ends too.
    #expect(PacketScopeFocusLogic.stepped(.observer("one"), by: 1, mode: .path, order: order)
      == .route(observerID: "one", routeID: "one|"))
    #expect(PacketScopeFocusLogic.stepped(.path("ZZ"), by: 1, mode: .path, order: order)
      == .route(observerID: "one", routeID: "one|"))
  }

  @Test
  func `Appending a group to a frozen order puts it at the tail once, its routes included`() {
    let grown = order.appending(groupKey: "GG", routeIDs: ["five|GG"])
    #expect(grown.groupKeys == ["", "AA", "BB,CC", "GG"])
    #expect(grown.routeIDsByGroup["GG"] == ["five|GG"])
    #expect(grown.appending(groupKey: "", routeIDs: ["nine|"]) == grown)
    #expect(PacketScopeFocusLogic.stepped(
      .route(observerID: "four", routeID: "four|BB,CC"), by: 1, mode: .path, order: grown
    ) == .route(observerID: "five", routeID: "five|GG"))

    // The same append, for an observer heard after the freeze.
    let grownObservers = observerOrder.appending(groupKey: "three", routeIDs: ["three|DD"])
    #expect(grownObservers.groupKeys == ["one", "two", "three"])
    #expect(PacketScopeFocusLogic.stepped(
      .route(observerID: "two", routeID: "two|BB,CC"), by: 1, mode: .observer, order: grownObservers
    ) == .route(observerID: "three", routeID: "three|DD"))
  }

  // MARK: - Grouping by chain

  private func reception(
    _ id: String,
    routes: [PacketScopeReception.Route],
    count: Int = 1,
    heard: Date? = nil
  ) -> PacketScopeReception {
    PacketScopeReception(
      observerID: id,
      observerName: "Observer \(id)",
      observerIATA: nil,
      bestSNR: routes.compactMap(\.bestSNR).max(),
      bestRSSI: nil,
      routes: routes,
      firstHeard: heard,
      receptionCount: count
    )
  }

  private func route(_ hops: [String], snr: Double? = nil) -> PacketScopeReception.Route {
    PacketScopeReception.Route(hops: hops, resolvedHops: [], bestSNR: snr)
  }

  @Test
  func `An observer that heard the packet three ways appears under all three chains`() {
    let groups = PacketScopePathGrouping.groups(from: [
      reception("a", routes: [route([]), route(["AA"]), route(["BB", "CC"])]),
    ])
    #expect(groups.map(\.id) == ["", "AA", "BB,CC"])
    #expect(groups.allSatisfy { $0.observerCount == 1 })
    #expect(groups[2].routeIDs == ["a|BB,CC"])
  }

  @Test
  func `Chains order shortest first, then by how many observers heard them`() {
    let groups = PacketScopePathGrouping.groups(from: [
      reception("a", routes: [route(["AA"]), route(["BB"])]),
      reception("b", routes: [route(["BB"])]),
      reception("c", routes: [route([])]),
    ])
    // Direct first; then the two-observer chain ahead of the one-observer chain
    // of the same length.
    #expect(groups.map(\.id) == ["", "BB", "AA"])
    #expect(groups[1].observerCount == 2)
  }

  @Test
  func `Only the chain with no repeaters in it carries a signal figure`() {
    let groups = PacketScopePathGrouping.groups(from: [
      reception("a", routes: [route([], snr: 4.0), route(["AA"], snr: 13.5)]),
      reception("b", routes: [route([], snr: 9.0)]),
    ])
    let direct = groups.first { $0.id == "" }
    let hopped = groups.first { $0.id == "AA" }
    // The best of the direct receptions, and nothing at all for the hopped
    // chain — 13.5 dB there is the repeater's link into the observer.
    #expect(direct?.directSNR == 9.0)
    #expect(hopped?.directSNR == nil)
  }

  @Test
  func `Observers inside a chain order by how many times each heard it`() {
    let groups = PacketScopePathGrouping.groups(from: [
      reception("a", routes: [route(["AA"])], count: 2),
      reception("b", routes: [route(["AA"])], count: 7),
    ])
    #expect(groups.first?.receptions.map(\.observerID) == ["b", "a"])
  }

  @Test
  func `Filtering a chain to one observer keeps only that observer's row`() {
    let groups = PacketScopePathGrouping.groups(from: [
      reception("a", routes: [route(["AA"], snr: 1.0)]),
      reception("b", routes: [route(["AA"], snr: 2.0)]),
    ])
    let group = try! #require(groups.first)
    let filtered = group.filtered(toObserver: "b")
    #expect(filtered?.receptions.map(\.observerID) == ["b"])
    #expect(filtered?.routeIDs == ["b|AA"])
    #expect(group.filtered(toObserver: "zz") == nil)
  }

  // MARK: - Grouping by observer

  @Test
  func `One group per observer, its routes shortest first and its route ids aligned with them`() throws {
    let groups = PacketScopeObserverGrouping.groups(from: [
      reception("a", routes: [route(["BB", "CC"]), route([]), route(["AA"])]),
      reception("b", routes: [route(["AA"])]),
    ])
    #expect(groups.map(\.id) == ["a", "b"])
    let first = try #require(groups.first)
    #expect(first.routes.map(\.hops) == [[], ["AA"], ["BB", "CC"]])
    #expect(first.routeIDs == ["a|", "a|AA", "a|BB,CC"])
    #expect(first.routeCount == 3)
    // Positionally aligned, so the row can pair a route with its id by index.
    #expect(zip(first.routes, first.routeIDs).allSatisfy { route, id in
      id == PacketScopeCoverageBuilder.routeID(observerID: "a", hops: route.hops)
    })
  }

  @Test
  func `Observers order by their shortest route, then by how many times each heard it`() {
    let groups = PacketScopeObserverGrouping.groups(from: [
      reception("far", routes: [route(["AA", "BB"])]),
      reception("quiet", routes: [route(["AA"])], count: 1),
      reception("loud", routes: [route(["AA"])], count: 5),
    ])
    #expect(groups.map(\.id) == ["loud", "quiet", "far"])
  }

  /// The guard against resurrecting the display 9dbdfb6f removed: an observer's
  /// figure is the sender's only when the observer heard the sender's own
  /// radio, so it is never a fold over the route SNRs.
  @Test
  func `An observer's signal is its direct route's, never the loudest of its routes`() {
    let groups = PacketScopeObserverGrouping.groups(from: [
      reception("both", routes: [route([], snr: 4.0), route(["AA"], snr: 13.5)]),
      reception("hopped", routes: [route(["AA"], snr: 13.5)]),
    ])
    let both = groups.first { $0.id == "both" }
    let hopped = groups.first { $0.id == "hopped" }
    #expect(both?.directSNR == 4.0)
    // Three hops or one, a route through a repeater prints no decibels at all.
    #expect(hopped?.directSNR == nil)
  }

  // MARK: - Camera focus id

  @Test
  func `The camera focus id ignores coordinate order, and changes with the focus level or a newly placed point`() {
    let a = CLLocationCoordinate2D(latitude: 30.0, longitude: -97.0)
    let b = CLLocationCoordinate2D(latitude: 30.1, longitude: -97.1)
    let c = CLLocationCoordinate2D(latitude: 30.2, longitude: -97.2)
    let route = PacketScopeFocus.route(observerID: "one", routeID: "one|AA")
    let forward = PacketScopeFocusLogic.cameraFocusID(for: route, coordinates: [a, b, c])
    let reordered = PacketScopeFocusLogic.cameraFocusID(for: route, coordinates: [c, a, b])
    #expect(forward == reordered)
    #expect(PacketScopeFocusLogic.cameraFocusID(for: route, coordinates: [a, b]) != forward)
    #expect(PacketScopeFocusLogic.cameraFocusID(for: .observer("one"), coordinates: [a, b, c]) != forward)
  }

  // MARK: - Copy summary

  @Test
  func `The copy summary names observers and paths, and never the packet identifier`() {
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
      bestDirectSNR: nil,
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
    #expect(text.contains("Alpha › Bravo"))
    // Two hops in: 7.5 dB is the last repeater's link into this observer, not
    // the sender's signal, so it is not the sender's figure to copy.
    #expect(!text.contains(PacketScopeCoverageBuilder.decibels(7.5)))
    #expect(!text.contains(hash))
    // No 16-hex run anywhere, whatever the names look like.
    let hexRun = try? NSRegularExpression(pattern: "[0-9a-f]{16}")
    let matches = hexRun?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? -1
    #expect(matches == 0)
  }

  @Test
  func `The copy summary carries the signal of a reception that was direct`() {
    let receptions = [
      PacketScopeReception(
        observerID: "obs-1",
        observerName: "Near Observer",
        observerIATA: nil,
        bestSNR: 11.0,
        bestRSSI: -70,
        routes: [PacketScopeReception.Route(hops: [], resolvedHops: [], bestSNR: 11.0)],
        firstHeard: nil,
        receptionCount: 1
      ),
    ]
    let summary = PacketScopeSummary(
      observerCount: 1,
      receptionCount: 1,
      bestSNR: 11.0,
      bestDirectSNR: 11.0,
      shortestHopCount: 0,
      firstHeard: nil,
      lastHeard: nil
    )
    let text = PacketScopeFocusLogic.copySummary(
      summary: summary,
      receptions: receptions,
      hopNamesByRoute: [:],
      routeID: { "\($0)|\($1.hops.joined(separator: ","))" }
    )
    #expect(text.contains(PacketScopeCoverageBuilder.decibels(11.0)))
  }

  // MARK: - The direct-only signal rule

  /// Every SNR the observer network reports is measured at the observer on its
  /// last leg. Only a repeater-free reception measured the sender's own
  /// transmission, so only that one is the sender's figure to show.
  @Test
  func `Only a repeater-free reception yields a signal for the sender`() {
    let direct = PacketScopeReception.Route(hops: [], resolvedHops: [], bestSNR: 4.0)
    let hopped = PacketScopeReception.Route(hops: ["AA"], resolvedHops: [], bestSNR: 13.5)

    let viaRepeater = PacketScopeReception(
      observerID: "obs-hopped", observerName: "Far", observerIATA: nil,
      bestSNR: 13.5, bestRSSI: -60, routes: [hopped], firstHeard: nil, receptionCount: 1
    )
    #expect(viaRepeater.heardDirectly == false)
    #expect(viaRepeater.directSNR == nil)
    // The stronger figure is still there in the raw fold; it is simply not the
    // sender's to print.
    #expect(viaRepeater.bestSNR == 13.5)

    let both = PacketScopeReception(
      observerID: "obs-both", observerName: "Near", observerIATA: nil,
      bestSNR: 13.5, bestRSSI: -60, routes: [direct, hopped], firstHeard: nil, receptionCount: 2
    )
    #expect(both.heardDirectly)
    // The direct route's own 4.0 dB, never the louder 13.5 dB a repeater put
    // into this observer.
    #expect(both.directSNR == 4.0)
  }

  /// RSSI is folded across an observer's receptions with no route attribution,
  /// so it can only be read as the sender's where every reception was direct.
  @Test
  func `RSSI is attributed to the sender only when every reception was direct`() {
    let direct = PacketScopeReception.Route(hops: [], resolvedHops: [], bestSNR: 4.0)
    let hopped = PacketScopeReception.Route(hops: ["AA"], resolvedHops: [], bestSNR: 13.5)

    let onlyDirect = PacketScopeReception(
      observerID: "a", observerName: "A", observerIATA: nil,
      bestSNR: 4.0, bestRSSI: -75, routes: [direct], firstHeard: nil, receptionCount: 1
    )
    #expect(onlyDirect.directRSSI == -75)

    let mixed = PacketScopeReception(
      observerID: "b", observerName: "B", observerIATA: nil,
      bestSNR: 13.5, bestRSSI: -75, routes: [direct, hopped], firstHeard: nil, receptionCount: 2
    )
    #expect(mixed.directRSSI == nil)

    let none = PacketScopeReception(
      observerID: "c", observerName: "C", observerIATA: nil,
      bestSNR: nil, bestRSSI: nil, routes: [], firstHeard: nil, receptionCount: 0
    )
    #expect(none.directRSSI == nil)
  }

  @Test
  func `The summary separates the best signal from the best direct signal`() {
    func observation(_ id: Int, snr: Double, hops: [String]) -> PacketScopeObservation {
      PacketScopeObservation(
        id: id,
        observerID: "obs-\(id)",
        observerName: "Observer \(id)",
        observerIATA: nil,
        snr: snr,
        rssi: nil,
        pathHops: hops,
        resolvedPath: [],
        timestamp: nil
      )
    }
    let observations = [
      observation(1, snr: 13.5, hops: ["AA"]),
      observation(2, snr: 4.0, hops: []),
      observation(3, snr: 2.0, hops: ["AA", "BB"]),
    ]
    let summary = PacketScopeFold.summary(from: observations)
    #expect(summary.bestSNR == 13.5)
    #expect(summary.bestDirectSNR == 4.0)

    let noneDirect = PacketScopeFold.summary(from: [observations[0], observations[2]])
    #expect(noneDirect.bestSNR == 13.5)
    #expect(noneDirect.bestDirectSNR == nil)
  }
}
