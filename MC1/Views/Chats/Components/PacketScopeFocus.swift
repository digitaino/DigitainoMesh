import CoreLocation
import Foundation

/// What the Network View is showing: everything, one observer's routes, or
/// one route. One value, so "a route selected under no observer" cannot be
/// represented, and every entry point — a row, a pin, a badge, a crumb, the
/// step buttons — writes the same thing.
///
/// Observer ids are carried **as the receptions carry them** (original case).
/// Only the map's pin-id hash and link ids lowercase; see the builder.
enum PacketScopeFocus: Equatable {
  case all
  case observer(String)
  /// `routeID` is the builder's `"observerID|hops"`.
  case route(observerID: String, routeID: String)

  var observerID: String? {
    switch self {
    case .all: nil
    case let .observer(id): id
    case let .route(id, _): id
    }
  }

  var routeID: String? {
    if case let .route(_, routeID) = self { return routeID }
    return nil
  }

  /// One level out: a route to its observer, an observer to everything.
  func popped() -> PacketScopeFocus {
    switch self {
    case .all: .all
    case .observer: .all
    case let .route(observerID, _): .observer(observerID)
    }
  }
}

/// The panel's order, frozen for the life of a focus so a poll cannot move a
/// row or re-rank a ladder under a reaching finger. Observers first heard
/// after the freeze append at the tail.
struct PacketScopeFrozenOrder: Equatable {
  let observerIDs: [String]
  let routeIDsByObserver: [String: [String]]
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
  /// The routes this focus draws, strongest first.
  let routeIDs: [String]
  /// False when the focus named something the map cannot place. The rest of
  /// the geometry is then the everything-state, verbatim.
  let isDrawable: Bool
}

/// Focus transitions that do not need a view to be tested. Main-actor like
/// the builder it ranks and formats through.
@MainActor
enum PacketScopeFocusLogic {
  /// After a poll: a focused route that vanished falls back to its observer
  /// while the observer survives, else to everything; a focused observer that
  /// vanished falls back to everything. An intact focus is returned as is.
  static func reconciled(
    _ focus: PacketScopeFocus,
    routeIDs: Set<String>,
    observerIDs: Set<String>
  ) -> PacketScopeFocus {
    switch focus {
    case .all:
      return .all
    case let .observer(id):
      return observerIDs.contains(id) ? focus : .all
    case let .route(observerID, routeID):
      if routeIDs.contains(routeID) { return focus }
      return observerIDs.contains(observerID) ? .observer(observerID) : .all
    }
  }

  /// The previous (`-1`) or next (`+1`) route in the frozen ladder, wrapping
  /// into the neighbouring observer's first or last route, and around the
  /// ends of the list. From an observer, forward is its first route and back
  /// is the previous observer's last; from everything, forward is the first
  /// route of all and back is the last. Nil when there is nothing to step to.
  static func stepped(
    _ focus: PacketScopeFocus,
    by delta: Int,
    order: PacketScopeFrozenOrder
  ) -> PacketScopeFocus? {
    let ladder = order.observerIDs.flatMap { observerID in
      (order.routeIDsByObserver[observerID] ?? []).map { (observerID: observerID, routeID: $0) }
    }
    guard !ladder.isEmpty, delta != 0 else { return nil }
    let step = delta > 0 ? 1 : -1

    let target: Int
    switch focus {
    case .all:
      target = step > 0 ? 0 : ladder.count - 1
    case let .observer(observerID):
      let first = ladder.firstIndex { $0.observerID == observerID } ?? 0
      target = step > 0 ? first : first - 1
    case let .route(_, routeID):
      let current = ladder.firstIndex { $0.routeID == routeID } ?? -1
      target = current + step
    }
    let wrapped = ((target % ladder.count) + ladder.count) % ladder.count
    let entry = ladder[wrapped]
    return .route(observerID: entry.observerID, routeID: entry.routeID)
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
      if let best = summary.bestSNR {
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
      let signal = reception.bestSNR.map(PacketScopeCoverageBuilder.decibels)
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
