import CoreLocation
import Foundation

/// What the Network View is showing: everything, one repeater path, one
/// observer's routes, or one route. One value, so "a route selected under no
/// path" cannot be represented, and every entry point — a row, a pin, a badge,
/// a crumb, the step buttons — writes the same thing.
///
/// The panel's own hierarchy is `all › path › route`: the list is a list of
/// repeater paths, and an observer sits inside the path it heard the packet by.
/// `observer` is the map's entry — a tap on an observer pin, which has no path
/// to sit under — and is one level below `all` like a path is.
///
/// Observer ids are carried **as the receptions carry them** (original case).
/// Only the map's pin-id hash and link ids lowercase; see the builder.
enum PacketScopeFocus: Equatable {
  case all
  /// One repeater chain, keyed by ``pathKey(hops:)``: every observer that heard
  /// the packet by exactly these repeaters, in this order. `""` is the chain of
  /// no repeaters at all — the observers that heard the sender directly.
  case path(String)
  case observer(String)
  /// `routeID` is the builder's `"observerID|hops"`.
  case route(observerID: String, routeID: String)

  var observerID: String? {
    switch self {
    case .all, .path: nil
    case let .observer(id): id
    case let .route(id, _): id
    }
  }

  var routeID: String? {
    if case let .route(_, routeID) = self { return routeID }
    return nil
  }

  /// The repeater chain this focus sits on, when it sits on one. Nil for
  /// everything and for an observer reached from the map, which is not under a
  /// single chain.
  var pathKey: String? {
    switch self {
    case .all, .observer: nil
    case let .path(key): key
    case let .route(_, routeID): Self.pathKey(fromRouteID: routeID)
    }
  }

  /// One level out: a route to its path, a path or an observer to everything.
  func popped() -> PacketScopeFocus {
    switch self {
    case .all: .all
    case .path: .all
    case .observer: .all
    case let .route(_, routeID): .path(Self.pathKey(fromRouteID: routeID))
    }
  }

  /// The chain's key: the hop hashes in order, comma-joined. Empty for a
  /// reception with no repeaters in it.
  static func pathKey(hops: [String]) -> String {
    hops.joined(separator: ",")
  }

  /// The chain out of a route id.
  ///
  /// Paired with `PacketScopeCoverageBuilder.routeID(observerID:hops:)`, which
  /// writes `"<observerID>|<comma-joined hops>"`. Observer ids are the server's
  /// hex public keys and hop hashes are hex, so neither side can contain the
  /// separator and the first one splits the id exactly. A direct route's id
  /// ends at the separator, yielding `""` — the direct chain, not a failure.
  static func pathKey(fromRouteID routeID: String) -> String {
    guard let separator = routeID.firstIndex(of: "|") else { return "" }
    return String(routeID[routeID.index(after: separator)...])
  }

  /// The observer out of a route id; see ``pathKey(fromRouteID:)`` for why the
  /// first separator is the right one.
  static func observerID(fromRouteID routeID: String) -> String {
    guard let separator = routeID.firstIndex(of: "|") else { return routeID }
    return String(routeID[routeID.startIndex..<separator])
  }
}

/// The panel's order, frozen for the life of a focus so a poll cannot move a
/// row or re-rank a group under a reaching finger. Paths first heard after the
/// freeze append at the tail.
struct PacketScopeFrozenOrder: Equatable {
  let pathKeys: [String]
  /// Route ids per path, in the order that path's observers are listed.
  let routeIDsByPath: [String: [String]]

  /// The order with a path heard since the freeze appended at the tail, so the
  /// steppers can reach it. A path already in the order is left where it is,
  /// its observers included.
  func appending(pathKey: String, routeIDs: [String]) -> PacketScopeFrozenOrder {
    guard !pathKeys.contains(pathKey) else { return self }
    var lists = routeIDsByPath
    lists[pathKey] = routeIDs
    return PacketScopeFrozenOrder(pathKeys: pathKeys + [pathKey], routeIDsByPath: lists)
  }
}

/// One repeater chain and every observer that heard the packet by exactly it.
///
/// The panel's row model. Observers are the network's microphones, not the
/// mesh: nine observers reached through three chains are three facts, and
/// listing them per observer told the third one nine times. Grouping by the
/// chain also makes the numbered hop pills unambiguous — every route in a group
/// traverses the same repeaters in the same order, so a repeater has one
/// position here, where an observer with several routes could put it in two.
struct PacketScopePathGroup: Identifiable, Equatable {
  /// ``PacketScopeFocus/pathKey(hops:)`` of `hops`.
  let id: String
  /// The hop hashes, in travel order. Empty for the direct group.
  let hops: [String]
  /// The observers that heard the packet by exactly this chain.
  let receptions: [PacketScopeReception]
  /// `receptions`' route ids, positionally aligned.
  let routeIDs: [String]
  /// The earliest any of them heard it.
  let firstHeard: Date?
  /// The best signal measured on this chain — the sender's own only when the
  /// chain is empty, which is the only case that fills this in.
  let directSNR: Double?

  var observerCount: Int {
    receptions.count
  }

  /// This group with only one observer's row left in it, for the map's own
  /// entry point: an observer pin tap focuses an observer, and the list then
  /// shows the chains that reach it and nothing else.
  func filtered(toObserver observerID: String) -> PacketScopePathGroup? {
    guard let index = receptions.firstIndex(where: { $0.observerID == observerID }) else { return nil }
    return PacketScopePathGroup(
      id: id,
      hops: hops,
      receptions: [receptions[index]],
      routeIDs: [routeIDs[index]],
      firstHeard: receptions[index].firstHeard,
      directSNR: hops.isEmpty ? receptions[index].directSNR : nil
    )
  }
}

/// Folds receptions into one row per repeater chain. Main-actor like the
/// builder whose route ids it writes.
@MainActor
enum PacketScopePathGrouping {
  /// One group per distinct hop sequence. An observer that heard the packet by
  /// three chains appears in three groups — it genuinely did three different
  /// things, and the alternative is a row that names one chain and hides two.
  ///
  /// Groups order shortest chain first, then most observers, then key; the
  /// observers inside order by how many times each heard it, then by id. Both
  /// are total, so a poll returning the same data never reshuffles a row.
  static func groups(from receptions: [PacketScopeReception]) -> [PacketScopePathGroup] {
    var byKey: [String: [(reception: PacketScopeReception, route: PacketScopeReception.Route)]] = [:]
    var hopsByKey: [String: [String]] = [:]
    for reception in receptions {
      for route in reception.routes {
        let key = PacketScopeFocus.pathKey(hops: route.hops)
        hopsByKey[key] = route.hops
        byKey[key, default: []].append((reception, route))
      }
    }
    return byKey.map { key, entries in
      let sorted = entries.sorted { lhs, rhs in
        if lhs.reception.receptionCount != rhs.reception.receptionCount {
          return lhs.reception.receptionCount > rhs.reception.receptionCount
        }
        return lhs.reception.observerID < rhs.reception.observerID
      }
      let hops = hopsByKey[key] ?? []
      return PacketScopePathGroup(
        id: key,
        hops: hops,
        receptions: sorted.map(\.reception),
        routeIDs: sorted.map { PacketScopeCoverageBuilder.routeID(observerID: $0.reception.observerID, hops: hops) },
        firstHeard: sorted.compactMap(\.reception.firstHeard).min(),
        // Only a chain with no repeaters in it measured the sender's own
        // transmission; every other chain's figure is the last repeater's link
        // into the observer.
        directSNR: hops.isEmpty ? sorted.compactMap(\.route.bestSNR).max() : nil
      )
    }
    .sorted { lhs, rhs in
      if lhs.hops.count != rhs.hops.count { return lhs.hops.count < rhs.hops.count }
      if lhs.observerCount != rhs.observerCount { return lhs.observerCount > rhs.observerCount }
      return lhs.id < rhs.id
    }
  }
}

/// The map's answer to a focus: what to draw, what to frame, and whether
/// there was anything to draw at all.
struct PacketScopeFocusGeometry {
  /// Untruncated. Arrival is the view's business, applied per frame from
  /// `arrivalKeyByLineID` — baking it in here would freeze the draw-in, and a
  /// leg seeded at progress 0 would be cut to nothing and never come back.
  let lines: [MapLine]
  let nodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)]
  /// Line id → the arrival-progress key that grows it.
  let arrivalKeyByLineID: [String: String]
  /// Links drawn at full paint. In observer focus the complement recedes to a
  /// context layer; in route focus it is dropped.
  let focusLinkIDs: Set<String>
  /// Empty when nothing should move the camera.
  let cameraCoordinates: [CLLocationCoordinate2D]
  /// The routes this focus draws, shortest first.
  let routeIDs: [String]
  /// False when the focus named something the map cannot place. The rest of
  /// the geometry is then the everything-state, verbatim.
  let isDrawable: Bool
}

/// Focus transitions that do not need a view to be tested. Main-actor like
/// the builder it ranks and formats through.
@MainActor
enum PacketScopeFocusLogic {
  /// After a poll: a focused route that vanished falls back to its path while
  /// the path survives, else to the observer while that survives, else to
  /// everything; a focused path or observer that vanished falls back to
  /// everything. An intact focus is returned as is.
  static func reconciled(
    _ focus: PacketScopeFocus,
    routeIDs: Set<String>,
    pathKeys: Set<String>,
    observerIDs: Set<String>
  ) -> PacketScopeFocus {
    switch focus {
    case .all:
      return .all
    case let .path(key):
      return pathKeys.contains(key) ? focus : .all
    case let .observer(id):
      return observerIDs.contains(id) ? focus : .all
    case let .route(observerID, routeID):
      if routeIDs.contains(routeID) { return focus }
      let key = PacketScopeFocus.pathKey(fromRouteID: routeID)
      if pathKeys.contains(key) { return .path(key) }
      return observerIDs.contains(observerID) ? .observer(observerID) : .all
    }
  }

  /// The previous (`-1`) or next (`+1`) route in the frozen ladder, wrapping
  /// into the neighbouring path's first or last route, and around the ends of
  /// the list. From a path, forward is its first route and back is the previous
  /// path's last; from everything, forward is the first route of all and back
  /// is the last. Nil when there is nothing to step to.
  static func stepped(
    _ focus: PacketScopeFocus,
    by delta: Int,
    order: PacketScopeFrozenOrder
  ) -> PacketScopeFocus? {
    let ladder = order.pathKeys.flatMap { key in
      (order.routeIDsByPath[key] ?? []).map { (pathKey: key, routeID: $0) }
    }
    guard !ladder.isEmpty, delta != 0 else { return nil }
    let step = delta > 0 ? 1 : -1
    // A focus the order does not know (a path heard after the freeze whose
    // routes were not appended, or an observer reached from the map, which sits
    // under no single path) steps from the ends, like `.all`.
    let ends = step > 0 ? 0 : ladder.count - 1

    let target: Int
    switch focus {
    case .all, .observer:
      target = ends
    case let .path(key):
      guard let first = ladder.firstIndex(where: { $0.pathKey == key }) else {
        target = ends
        break
      }
      target = step > 0 ? first : first - 1
    case let .route(_, routeID):
      guard let current = ladder.firstIndex(where: { $0.routeID == routeID }) else {
        target = ends
        break
      }
      target = current + step
    }
    let wrapped = ((target % ladder.count) + ladder.count) % ladder.count
    let entry = ladder[wrapped]
    return .route(
      observerID: PacketScopeFocus.observerID(fromRouteID: entry.routeID),
      routeID: entry.routeID
    )
  }

  /// The camera-focus id for a focus over the coordinates it frames. Canonical
  /// in coordinate order, so a poll that re-ranks an observer's routes without
  /// placing anything new does not move the camera; a newly placed hop does.
  static func cameraFocusID(for focus: PacketScopeFocus, coordinates: [CLLocationCoordinate2D]) -> String {
    let prefix = switch focus {
    case .all: "all"
    case let .path(key): "path:\(key)"
    case let .observer(id): "obs:\(id)"
    case let .route(_, routeID): "route:\(routeID)"
    }
    let digest = coordinates
      .map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
      .sorted()
      .joined(separator: ";")
    return "\(prefix)#\(digest)"
  }

  /// "1 route" / "3 routes", following the `hopOne` / `hopCount` precedent.
  static func routeCount(_ count: Int) -> String {
    count == 1 ? L10n.Localizable.PacketScope.routeOne : L10n.Localizable.PacketScope.routeCount(count)
  }

  /// "+1 hop not on the map" / "+3 hops not on the map".
  static func tailUnknown(_ count: Int) -> String {
    count == 1 ? L10n.Localizable.PacketScope.tailUnknownOne : L10n.Localizable.PacketScope.tailUnknown(count)
  }

  /// A plain-text account of the coverage for the clipboard. Built from the
  /// summary, the receptions and the resolved hop names only — the message is
  /// not an input, so its packet identifier cannot end up in the text.
  static func copySummary(
    summary: PacketScopeSummary?,
    receptions: [PacketScopeReception],
    hopNamesByRoute: [String: [String]],
    routeID: (String, PacketScopeReception.Route) -> String
  ) -> String {
    var lines: [String] = []
    if let summary {
      var parts = [L10n.Localizable.PacketScope.heardBy(summary.observerCount)]
      if let best = summary.bestDirectSNR {
        parts.append(L10n.Localizable.PacketScope.best(PacketScopeCoverageBuilder.decibels(best)))
      }
      if let hops = summary.shortestHopCount {
        parts.append(hops == 0
          ? L10n.Localizable.PacketScope.heardDirectlyInline
          : L10n.Localizable.PacketScope.shortest(routeLength(hops)))
      }
      lines.append(parts.joined(separator: " · "))
    }
    for reception in receptions {
      let ranked = PacketScopeCoverageBuilder.rankedRoutes(reception.routes)
      // Only the direct figure, for the same reason the rows show only that one.
      let signal = reception.directSNR.map(PacketScopeCoverageBuilder.decibels)
      let path: String? = ranked.first.map { route in
        if route.hops.isEmpty { return L10n.Localizable.PacketScope.heardDirectly }
        let names = hopNamesByRoute[routeID(reception.observerID, route)] ?? route.hops
        return L10n.Localizable.PacketScope.via(names.joined(separator: " › "))
      }
      lines.append([reception.observerName, signal, path].compactMap(\.self).joined(separator: "  "))
    }
    return lines.joined(separator: "\n")
  }

  static func routeLength(_ hops: Int) -> String {
    switch hops {
    case 0: L10n.Localizable.PacketScope.direct
    case 1: L10n.Localizable.PacketScope.hopOne
    default: L10n.Localizable.PacketScope.hopCount(hops)
    }
  }
}
