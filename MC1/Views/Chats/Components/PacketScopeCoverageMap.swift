import CoreLocation
import CryptoKit
import MC1Services
import SwiftUI

/// One directed link of the mesh that at least one observer route traversed,
/// with how many routes did. The coverage map's substrate: drawn once, weighted
/// by traversal, so the trunk everyone heard through reads fat and a one-off
/// spur reads thin — instead of the same stroke stacked once per route.
struct PacketScopeCoverageLink: Identifiable, Equatable {
  let id: String
  let from: CLLocationCoordinate2D
  let to: CLLocationCoordinate2D
  let routeCount: Int

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.routeCount == rhs.routeCount
      && lhs.from.latitude == rhs.from.latitude && lhs.from.longitude == rhs.from.longitude
      && lhs.to.latitude == rhs.to.latitude && lhs.to.longitude == rhs.to.longitude
  }
}

/// The one leg per located observer that carries the SNR treatment in the
/// default state: the measured leg of its strongest route, drawn straight.
struct PacketScopeObserverLeg: Identifiable {
  /// The observer id, as the receptions carry it.
  let id: String
  let line: MapLine
  let snr: Double?
}

/// A hop the builder could place: the pin it stands on, and where in the
/// route's full path it sat (1-based, counting the hops that could not be
/// placed too, so a gap in the numbers marks exactly where one could not be).
struct PacketScopeCoveragePlacedHop: Equatable {
  let pinID: UUID
  let position: Int
}

/// One observer route as drawable geometry, in both the shapes the focus
/// states need.
struct PacketScopeCoverageRoute: Identifiable {
  /// Observer id plus the hop sequence — stable across refreshes.
  let id: String
  /// The observer id as the receptions carry it.
  let observerID: String
  let hopCount: Int
  /// Polylines in travel order for observer focus, split wherever a hop could
  /// not be placed: a gap in the path is left as a gap rather than bridged
  /// with a link that nothing in the data says exists. The measured leg into
  /// the observer, when its tail hop is placed, is the last segment — fanned
  /// into an arc when sibling routes share the same tail.
  let segments: [MapLine]
  /// The fanned leg's "distance · SNR" readout.
  let badge: MapPoint?
  /// The same bodies with the measured leg drawn straight, for single-route
  /// focus: the one link the reader asked to see is its true bearing.
  let soloSegments: [MapLine]
  /// The straight leg's readout at its chord midpoint — or, when no leg can be
  /// drawn but a body can, the route's signal at the last body segment's end,
  /// so two routes that differ only in their unplaceable tails still read
  /// differently.
  let soloBadge: MapPoint?
  let placedHops: [PacketScopeCoveragePlacedHop]
  /// Hops after the last placed one; 0 when the tail is placed.
  let unplacedTailCount: Int
  /// Whether the leg into the observer is drawn — the observer is located and
  /// the tail hop (or the origin, for a direct reception) is placed.
  let hasMeasuredLeg: Bool
  /// Link ids (`"<from>><to>"`) this route traversed.
  let linkIDs: Set<String>
  /// The pins this route passes through: origin, placed hops, observer.
  let participantPinIDs: Set<UUID>
  /// Rounded digest of `segments`, so two routes that draw identical pixels
  /// can be reported as such rather than pretending the map answered.
  let drawnGeometryKey: String
  /// Origin, placed hops and observer, for the camera.
  let coordinates: [CLLocationCoordinate2D]

  var isDrawable: Bool {
    !segments.isEmpty
  }

  /// Every hop placed and the leg drawn: the drawn length is the route's
  /// length rather than a lower bound.
  var isComplete: Bool {
    hasMeasuredLeg && placedHops.count == hopCount
  }
}

/// The observer network's view of one packet, as map geometry.
struct PacketScopeCoverageMap {
  /// Origin (pin A), hop repeaters (named hop pins) and located observers
  /// (pin B). Ids are derived from what the pin stands for, so a poll that
  /// changes nothing re-sources nothing.
  let nodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)]
  let links: [PacketScopeCoverageLink]
  let observerLegs: [PacketScopeObserverLeg]
  /// Every route of every reception, drawable or not, so the panel's ladder
  /// and the map can never disagree about what exists.
  let routes: [PacketScopeCoverageRoute]
  /// Straight-line distance from the origin to each located observer, keyed by
  /// observer id as the receptions carry it. Empty without an origin.
  let observerDistances: [String: CLLocationDistance]

  let routesByID: [String: PacketScopeCoverageRoute]
  /// Route ids per observer (as the receptions carry the id), shortest first.
  let routeIDsByObserver: [String: [String]]
  /// Route ids per repeater chain, keyed by ``PacketScopeFocus/pathKey(hops:)``
  /// — every observer that heard the packet by exactly those repeaters. The
  /// panel's list is a list of these.
  let routeIDsByPath: [String: [String]]
  let drawableRouteIDs: Set<String>
  /// Observers with at least one drawable route.
  let drawableObserverIDs: Set<String>
  /// Observer pin id → the observer id as the receptions carry it.
  let observerIDByPinID: [UUID: String]
  /// Badge pin id → the route it reads out, for badge taps.
  let routeIDByBadgePinID: [UUID: String]
  let originCoordinate: CLLocationCoordinate2D?
  /// Located observers' coordinates, keyed as the receptions carry the id.
  let observerCoordinates: [String: CLLocationCoordinate2D]

  /// Whether there is anything to look at beyond the origin pin.
  var isPlottable: Bool {
    nodes.contains { $0.point.pinStyle != .pointA }
  }

  var maxLinkRouteCount: Int {
    links.map(\.routeCount).max() ?? 0
  }

  /// The pins' coordinates — what the camera frames. Badges never move the camera.
  var pinCoordinates: [CLLocationCoordinate2D] {
    nodes.map(\.coordinate)
  }
}

/// Builds the coverage map: the packet's origin, every repeater it was heard
/// through, every located observer, the links between them weighted by how
/// many routes used each, and each observer's strongest measured leg.
///
/// Same placement rules as the heard-repeats map (`MessagePathMapView.
/// heardRepeatNodes`): a hop pins only when it resolves to one unambiguous
/// located repeater, pins dedupe by key, and the SNR treatment goes only on the
/// leg the observer actually measured — the final hop into the observer.
/// Nothing in the data says how well any earlier hop heard the packet, so
/// links are weighted by use, never coloured by signal (the traffic heatmap
/// draws the same distinction).
///
/// Two things this map has that the repeats map does not. The server's
/// resolved public keys are exact, so a hop the phone could only resolve
/// ambiguously by its short hash pins when the server names the repeater and
/// this phone knows where it is. And the far end of a route is an observer
/// rather than this device: an observer without a published location gets no
/// leg — its row says so — because a route ending on a repeater pin would only
/// restate what the pin already shows.
///
/// **Id casing.** Observer ids are carried as the receptions carry them in
/// every index a caller reads (`routeIDsByObserver`, `observerCoordinates`,
/// `observerDistances`, route ids). Only the pin-id hash and the link id use
/// the lowercased form, because the roster reports ids uppercase and the
/// observations lowercase; `observerIDByPinID` maps back.
@MainActor
enum PacketScopeCoverageBuilder {
  static let originPinID = stableID("origin")

  static func build(
    message: MessageDTO,
    receptions: [PacketScopeReception],
    observers: [PacketScopeObserver],
    contacts: [ContactDTO],
    repeaters: [ContactDTO],
    discoveredRepeaters: [DiscoveredNodeDTO],
    userLocation: CLLocation?,
    originName: String?
  ) -> PacketScopeCoverageMap {
    // Where the packet started. An outgoing message started here — the
    // send-time stamp when it carries one, else the caller's live location. An
    // incoming one started at its sender, pinned only when the sender resolves
    // to one located contact (the path screen's pin A rule).
    let origin: (coordinate: CLLocationCoordinate2D, name: String?)? = {
      if message.isOutgoing {
        return (message.userFixCoordinate ?? userLocation?.coordinate).map { ($0, originName) }
      }
      guard let sender = MessagePathViewModel.locatedSender(for: message, contacts: contacts) else { return nil }
      return (CLLocationCoordinate2D(latitude: sender.latitude, longitude: sender.longitude), sender.displayName)
    }()
    let referenceLocation = origin.map { CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
      ?? userLocation

    let observersByID = Dictionary(observers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    var nodes: [(MapPoint, CLLocationCoordinate2D)] = []
    if let origin {
      nodes.append((MapPoint(
        id: originPinID,
        coordinate: origin.coordinate,
        pinStyle: .pointA,
        label: origin.name,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil,
        // Never dropped in a collision: it is where everything starts.
        labelPriority: 0
      ), origin.coordinate))
    }

    // Pass 1: place every hop of every route, remembering which observers can
    // be placed.
    struct PlottedHop {
      let key: Data
      let coordinate: CLLocationCoordinate2D
      /// 1-based position within the route's full path; unplottable hops still
      /// count, so the number states where in the path this repeater sat.
      let position: Int
    }
    struct RoutePlan: RoutePlanLike {
      let id: String
      let observerID: String
      let hopCount: Int
      let plotted: [PlottedHop]
      let observerCoordinate: CLLocationCoordinate2D?
      let snr: Double?
      /// The measured leg's start when it can be drawn: the placed tail hop, or
      /// the origin for a direct reception.
      let measuredFrom: (key: String, coordinate: CLLocationCoordinate2D)?
    }

    var plans: [RoutePlan] = []
    var pinOrder: [Data] = []
    var pinInfo: [Data: (name: String, coordinate: CLLocationCoordinate2D)] = [:]
    var observerPinOrder: [String] = []
    var observerPins: [String: (name: String, coordinate: CLLocationCoordinate2D)] = [:]
    var observerDistances: [String: CLLocationDistance] = [:]
    var observerCoordinates: [String: CLLocationCoordinate2D] = [:]
    var observerIDByPinID: [UUID: String] = [:]

    for reception in receptions {
      let observerKey = reception.observerID.lowercased()
      let observerCoordinate = observersByID[observerKey]?.coordinate
      let observerPinID = stableID("obs:\(observerKey)")
      if observerIDByPinID[observerPinID] == nil {
        observerIDByPinID[observerPinID] = reception.observerID
      }
      if let observerCoordinate {
        observerCoordinates[reception.observerID] = observerCoordinate
        if observerPins[observerKey] == nil {
          observerPinOrder.append(observerKey)
          observerPins[observerKey] = (reception.observerName, observerCoordinate)
        }
        if let origin {
          observerDistances[reception.observerID] = CLLocation(latitude: origin.coordinate.latitude, longitude: origin.coordinate.longitude)
            .distance(from: CLLocation(latitude: observerCoordinate.latitude, longitude: observerCoordinate.longitude))
        }
      }

      for route in reception.routes {
        var plotted: [PlottedHop] = []
        for (index, hop) in route.hops.enumerated() {
          let resolvedKey = index < route.resolvedHops.count ? route.resolvedHops[index] : nil
          guard let r = resolveHop(
            shortHash: hop,
            resolvedKey: resolvedKey,
            repeaters: repeaters,
            discoveredRepeaters: discoveredRepeaters,
            referenceLocation: referenceLocation
          ) else { continue }
          let coord = CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude)
          plotted.append(PlottedHop(key: r.publicKey, coordinate: coord, position: index + 1))
          if pinInfo[r.publicKey] == nil {
            pinOrder.append(r.publicKey)
            pinInfo[r.publicKey] = (r.resolvableName, coord)
          }
        }
        let measuredFrom: (String, CLLocationCoordinate2D)? = if route.hops.isEmpty {
          origin.map { ("origin", $0.coordinate) }
        } else if let last = plotted.last, last.position == route.hops.count {
          (hopKey(last.key), last.coordinate)
        } else {
          nil
        }
        plans.append(RoutePlan(
          id: routeID(observerID: reception.observerID, hops: route.hops),
          observerID: reception.observerID,
          hopCount: route.hops.count,
          plotted: plotted,
          observerCoordinate: observerCoordinate,
          snr: route.bestSNR,
          measuredFrom: measuredFrom
        ))
      }
    }

    // Repeater pins keep their name and carry no number: a repeater sits at
    // different positions in different routes, so a global number would be
    // wrong for all but one of them. Numbering is a property of a focus.
    for key in pinOrder {
      guard let info = pinInfo[key] else { continue }
      nodes.append((MapPoint(
        id: stableID(hopKey(key)),
        coordinate: info.coordinate,
        pinStyle: .repeaterHop,
        label: info.name,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil
      ), info.coordinate))
    }
    // Observer pins carry the name alone; the signal lives in the row and on
    // the leg's badge, and a label that changed with every poll would mint a
    // new sprite and re-source every pin each time. Receptions arrive
    // strongest first, so the pill priority follows that order.
    for (rank, key) in observerPinOrder.enumerated() {
      guard let pin = observerPins[key] else { continue }
      nodes.append((MapPoint(
        id: stableID("obs:\(key)"),
        coordinate: pin.coordinate,
        pinStyle: .pointB,
        label: pin.name,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil,
        labelPriority: 10 + rank
      ), pin.coordinate))
    }

    // Pass 2: links. Only between points that are adjacent in the path —
    // origin → hop 1, hop i → hop i+1, placed tail → observer, or origin →
    // observer when heard directly. A gap where a hop could not be placed
    // stays a gap.
    var linkOrder: [String] = []
    var linkInfo: [String: (from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, count: Int)] = [:]
    var planLinkIDs: [Set<String>] = Array(repeating: [], count: plans.count)
    func countLink(_ fromKey: String, _ from: CLLocationCoordinate2D, _ toKey: String, _ to: CLLocationCoordinate2D) -> String {
      let id = "\(fromKey)>\(toKey)"
      if var info = linkInfo[id] {
        info.count += 1
        linkInfo[id] = info
      } else {
        linkOrder.append(id)
        linkInfo[id] = (from, to, 1)
      }
      return id
    }

    for (index, plan) in plans.enumerated() {
      var previous: (key: String, coordinate: CLLocationCoordinate2D, position: Int)? =
        origin.map { ("origin", $0.coordinate, 0) }
      for hop in plan.plotted {
        if let previous, hop.position == previous.position + 1 {
          planLinkIDs[index].insert(countLink(previous.key, previous.coordinate, hopKey(hop.key), hop.coordinate))
        }
        previous = (hopKey(hop.key), hop.coordinate, hop.position)
      }
      if let observerCoordinate = plan.observerCoordinate, let from = plan.measuredFrom {
        planLinkIDs[index].insert(countLink(from.key, from.coordinate, "obs:\(plan.observerID.lowercased())", observerCoordinate))
      }
    }
    let links = linkOrder.compactMap { id -> PacketScopeCoverageLink? in
      guard let info = linkInfo[id] else { return nil }
      return PacketScopeCoverageLink(id: id, from: info.from, to: info.to, routeCount: info.count)
    }

    // Pass 3: each located observer's strongest measured leg, straight. Routes
    // whose measured leg cannot be drawn do not compete; an observer with none
    // keeps its pin and nothing else.
    var observerLegs: [PacketScopeObserverLeg] = []
    var legOrder: [String] = []
    var bestPlanByObserver: [String: RoutePlan] = [:]
    for plan in plans {
      guard plan.observerCoordinate != nil, plan.measuredFrom != nil else { continue }
      if let current = bestPlanByObserver[plan.observerID] {
        if Self.outranks(plan, current) { bestPlanByObserver[plan.observerID] = plan }
      } else {
        legOrder.append(plan.observerID)
        bestPlanByObserver[plan.observerID] = plan
      }
    }
    for observerID in legOrder {
      guard let plan = bestPlanByObserver[observerID],
            let from = plan.measuredFrom, let to = plan.observerCoordinate else { continue }
      observerLegs.append(PacketScopeObserverLeg(
        id: observerID,
        line: MapLine(
          id: "scope-leg-\(observerID)",
          coordinates: [from.coordinate, to],
          style: plan.snr != nil ? .forSNR(plan.snr) : .messagePath,
          opacity: 1.0
        ),
        snr: plan.snr
      ))
    }

    // Pass 4: full per-route geometry for the focus states. Measured legs that
    // share a tail into the same observer are repeated measurements of one
    // link on coincident geometry; for observer focus they fan into arcs
    // bowing to alternating sides, the strongest route hugging the true line,
    // so every readout stays visible. For single-route focus the same leg is
    // drawn straight, with its readout at the chord midpoint.
    struct Leg {
      let planIndex: Int
      let from: CLLocationCoordinate2D
      let to: CLLocationCoordinate2D
    }
    var legLinkOrder: [String] = []
    var legsByLink: [String: [Leg]] = [:]
    for (index, plan) in plans.enumerated() {
      guard let observerCoordinate = plan.observerCoordinate, let from = plan.measuredFrom else { continue }
      let link = "\(from.key)>\(plan.observerID)"
      if legsByLink[link] == nil { legLinkOrder.append(link) }
      legsByLink[link, default: []].append(Leg(planIndex: index, from: from.coordinate, to: observerCoordinate))
    }

    struct LegLines {
      let fanned: MapLine
      let fannedBadge: MapPoint?
      let solo: MapLine
      let soloBadge: MapPoint?
    }
    var legLines: [Int: LegLines] = [:]
    for link in legLinkOrder {
      guard let legs = legsByLink[link] else { continue }
      let ranked = legs.sorted { Self.outranks(plans[$0.planIndex], plans[$1.planIndex]) }
      for (rank, leg) in ranked.enumerated() {
        let plan = plans[leg.planIndex]
        let arc = MessagePathMapView.legArcCoordinates(
          from: leg.from,
          to: leg.to,
          offsetStep: MessagePathMapView.arcOffsetStep(rank: rank, of: ranked.count)
        )
        // A measured leg with no SNR value stays neutral — the trace map's
        // dashed "untraced" reads as never measured, which this was; it just
        // carries no number to colour by (and earns no badge).
        let style: MapLine.LineStyle = plan.snr != nil ? .forSNR(plan.snr) : .messagePath
        let fanned = MapLine(id: "scope-\(plan.id)-rx", coordinates: arc, style: style, opacity: 1.0)
        let solo = MapLine(id: "scope-\(plan.id)-rx-solo", coordinates: [leg.from, leg.to], style: style, opacity: 1.0)
        var fannedBadge: MapPoint?
        var soloBadge: MapPoint?
        if let snr = plan.snr {
          soloBadge = MapLine.snrBadge(id: stableID("solo-badge:\(plan.id)"), from: leg.from, to: leg.to, snr: snr)
          if arc.count == 2 {
            fannedBadge = MapLine.snrBadge(id: stableID("badge:\(plan.id)"), from: leg.from, to: leg.to, snr: snr)
          } else {
            // Fanned leg: the badge rides its own arc's apex. Distance stays
            // the straight link distance, not arc length.
            let distance = CLLocation(latitude: leg.from.latitude, longitude: leg.from.longitude)
              .distance(from: CLLocation(latitude: leg.to.latitude, longitude: leg.to.longitude))
            fannedBadge = MapPoint(
              id: stableID("badge:\(plan.id)"),
              coordinate: arc[arc.count / 2],
              pinStyle: .badge,
              label: nil,
              isClusterable: false,
              hopIndex: nil,
              badgeText: MapLine.snrBadgeText(distance: distance, snr: snr)
            )
          }
        }
        legLines[leg.planIndex] = LegLines(fanned: fanned, fannedBadge: fannedBadge, solo: solo, soloBadge: soloBadge)
      }
    }

    var routes: [PacketScopeCoverageRoute] = []
    var routeIDByBadgePinID: [UUID: String] = [:]
    for (index, plan) in plans.enumerated() {
      var bodies: [MapLine] = []
      // The body, as runs of path-adjacent placed points; each run of two or
      // more is one segment.
      var run: [CLLocationCoordinate2D] = []
      var runPosition = -1
      if let origin {
        run = [origin.coordinate]
        runPosition = 0
      }
      var runIndex = 0
      func flushRun() {
        if run.count >= 2 {
          bodies.append(MapLine(id: "scope-\(plan.id)-body-\(runIndex)", coordinates: run, style: .messagePath, opacity: 1.0))
          runIndex += 1
        }
        run = []
        runPosition = -1
      }
      for hop in plan.plotted {
        if hop.position != runPosition + 1 { flushRun() }
        run.append(hop.coordinate)
        runPosition = hop.position
      }
      flushRun()

      let leg = legLines[index]
      let segments = bodies + (leg.map { [$0.fanned] } ?? [])
      let soloSegments = bodies + (leg.map { [$0.solo] } ?? [])
      var soloBadge = leg?.soloBadge
      if leg == nil, let last = bodies.last, let snr = plan.snr,
         last.coordinates.count >= 2 {
        // No measured leg to carry the number, but a body to hang it on: the
        // route's signal at the end of what could be drawn. The body keeps
        // its neutral colour — nothing measured that hop.
        let from = last.coordinates[last.coordinates.count - 2]
        let to = last.coordinates[last.coordinates.count - 1]
        soloBadge = MapPoint(
          id: stableID("solo-badge:\(plan.id)"),
          coordinate: MapLine.midpoint(from: from, to: to),
          pinStyle: .badge,
          label: nil,
          isClusterable: false,
          hopIndex: nil,
          badgeText: decibels(snr)
        )
      }
      if let badge = leg?.fannedBadge { routeIDByBadgePinID[badge.id] = plan.id }
      if let soloBadge { routeIDByBadgePinID[soloBadge.id] = plan.id }

      let placedHops = plan.plotted.map { PacketScopeCoveragePlacedHop(pinID: stableID(hopKey($0.key)), position: $0.position) }
      var participants = Set(placedHops.map(\.pinID))
      var coordinates = plan.plotted.map(\.coordinate)
      if let origin {
        participants.insert(originPinID)
        coordinates.insert(origin.coordinate, at: 0)
      }
      if let observerCoordinate = plan.observerCoordinate {
        participants.insert(stableID("obs:\(plan.observerID.lowercased())"))
        coordinates.append(observerCoordinate)
      }

      routes.append(PacketScopeCoverageRoute(
        id: plan.id,
        observerID: plan.observerID,
        hopCount: plan.hopCount,
        segments: segments,
        badge: leg?.fannedBadge,
        soloSegments: soloSegments,
        soloBadge: soloBadge,
        placedHops: placedHops,
        unplacedTailCount: plan.hopCount - (plan.plotted.last?.position ?? 0),
        hasMeasuredLeg: leg != nil,
        linkIDs: planLinkIDs[index],
        participantPinIDs: participants,
        drawnGeometryKey: geometryKey(soloSegments),
        coordinates: coordinates
      ))
    }

    // The ladder order: strongest first, by the same rule as the headline leg.
    var routeIDsByObserver: [String: [String]] = [:]
    for plan in plans.sorted(by: { outranks($0, $1) }) {
      routeIDsByObserver[plan.observerID, default: []].append(plan.id)
    }
    var routeIDsByPath: [String: [String]] = [:]
    for route in routes {
      // Derived from the id rather than re-threading the hops: the id is built
      // from exactly `observerID` and `hops`, so this cannot drift from it.
      routeIDsByPath[PacketScopeFocus.pathKey(fromRouteID: route.id), default: []].append(route.id)
    }
    let routesByID = Dictionary(routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let drawableRouteIDs = Set(routes.filter(\.isDrawable).map(\.id))
    let drawableObserverIDs = Set(routes.filter(\.isDrawable).map(\.observerID))

    return PacketScopeCoverageMap(
      nodes: nodes,
      links: links,
      observerLegs: observerLegs,
      routes: routes,
      observerDistances: observerDistances,
      routesByID: routesByID,
      routeIDsByObserver: routeIDsByObserver,
      routeIDsByPath: routeIDsByPath,
      drawableRouteIDs: drawableRouteIDs,
      drawableObserverIDs: drawableObserverIDs,
      observerIDByPinID: observerIDByPinID,
      routeIDByBadgePinID: routeIDByBadgePinID,
      originCoordinate: origin?.coordinate,
      observerCoordinates: observerCoordinates
    )
  }

  /// The route id the panel and the map share: observer id as the receptions
  /// carry it, plus the hop sequence.
  ///
  /// Read back apart by ``PacketScopeFocus/pathKey(fromRouteID:)`` and
  /// ``PacketScopeFocus/observerID(fromRouteID:)``, which split on the first
  /// separator. Keep the separator out of both halves.
  static func routeID(observerID: String, hops: [String]) -> String {
    "\(observerID)|\(hops.joined(separator: ","))"
  }

  /// The hop rule: the server's resolved public key first, when this phone
  /// knows a located repeater by exactly that key — a full key cannot collide,
  /// so it escapes the short-hash ambiguity that would otherwise leave the hop
  /// unpinned. Otherwise the shared exact-match short-hash resolution every
  /// path-shaped map uses.
  static func resolveHop(
    shortHash: String,
    resolvedKey: String?,
    repeaters: [ContactDTO],
    discoveredRepeaters: [DiscoveredNodeDTO],
    referenceLocation: CLLocation?
  ) -> (any RepeaterResolvable)? {
    if let resolvedKey, let key = Data(hexString: resolvedKey), key.count == 32 {
      let candidates: [any RepeaterResolvable] =
        repeaters.filter { $0.publicKey == key }.map { $0 as any RepeaterResolvable }
          + discoveredRepeaters.filter { $0.publicKey == key }.map { $0 as any RepeaterResolvable }
      if let located = candidates.first(where: {
        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude).isValidFix
      }) {
        return located
      }
    }
    guard let hashBytes = Data(hexString: shortHash), !hashBytes.isEmpty else { return nil }
    return MessagePathMapView.resolvePlottableRepeater(
      hashBytes: hashBytes,
      repeaters: repeaters,
      discoveredRepeaters: discoveredRepeaters,
      referenceLocation: referenceLocation
    )
  }

  /// Route ranking: fewer hops first, then higher SNR, then id — total, so a
  /// poll returning the same data never swaps which route is an observer's
  /// headline.
  ///
  /// Hops lead because the SNR does not measure what the ranking was being read
  /// as. Each figure is taken at the observer on its last leg, so ranking a
  /// 3-hop route above a direct one for its stronger number ranked a repeater's
  /// link to that observer above the sender's own. SNR still breaks ties, where
  /// the compared routes are at least the same length.
  private static func outranks(_ lhs: some RoutePlanLike, _ rhs: some RoutePlanLike) -> Bool {
    if lhs.hopCount != rhs.hopCount { return lhs.hopCount < rhs.hopCount }
    switch (lhs.snr, rhs.snr) {
    case let (l?, r?) where l != r: return l > r
    case (.some, .none): return true
    case (.none, .some): return false
    default: break
    }
    return lhs.id < rhs.id
  }

  private static func hopKey(_ publicKey: Data) -> String {
    "hop:" + publicKey.map { String(format: "%02x", $0) }.joined()
  }

  /// A pin id derived from what the pin stands for, so an unchanged pin keeps
  /// its identity across rebuilds and the map's point source diffs to nothing.
  static func stableID(_ key: String) -> UUID {
    let digest = SHA256.hash(data: Data(key.utf8))
    let bytes = Array(digest.prefix(16))
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }

  static func decibels(_ snr: Double) -> String {
    "\(snr.formatted(.number.precision(.fractionLength(0...1)))) \(L10n.RemoteNodes.RemoteNodes.Status.snrBadgeUnit)"
  }

  /// A rounded digest of drawn geometry: routes with the same key draw the
  /// same pixels.
  private static func geometryKey(_ segments: [MapLine]) -> String {
    segments.flatMap(\.coordinates)
      .map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
      .joined(separator: ";")
  }

  // MARK: - Focus

  /// What the map draws for a focus. Pure of arrival: every line comes back
  /// untruncated, with the arrival key that grows it, and the view applies
  /// the per-frame cut — baking it in here would freeze the draw-in.
  ///
  /// A focus the map cannot place (an observer with no location whose hops
  /// could not be placed either) returns the everything-state verbatim with
  /// `isDrawable == false` and no camera coordinates: the map is never
  /// blanked to promote something that is not there.
  static func geometry(for focus: PacketScopeFocus, in map: PacketScopeCoverageMap) -> PacketScopeFocusGeometry {
    switch focus {
    case .all:
      return everything(in: map, isDrawable: true)

    case let .path(key):
      let routes = (map.routeIDsByPath[key] ?? [])
        .compactMap { map.routesByID[$0] }
        .filter(\.isDrawable)
      guard !routes.isEmpty else { return everything(in: map, isDrawable: false) }
      var arrivalKeys: [String: String] = [:]
      for route in routes where route.hasMeasuredLeg {
        arrivalKeys["scope-\(route.id)-rx"] = "leg:\(route.observerID)"
      }
      // Every route here traverses the same repeaters in the same order, so a
      // repeater has exactly one position and the pills can be numbered however
      // many observers heard it — which is not true of observer focus.
      let numbering = routes.first.map(hopNumbering) ?? [:]
      let participants = routes.reduce(into: Set<UUID>()) { $0.formUnion($1.participantPinIDs) }
      var coordinates: [CLLocationCoordinate2D] = []
      for route in routes {
        coordinates += route.coordinates
      }
      return PacketScopeFocusGeometry(
        lines: routes.flatMap(\.segments),
        nodes: focusedNodes(
          in: map,
          participants: participants,
          numbering: numbering,
          // One badge only where one route can own it; several observers off
          // the same chain would each claim the same readout.
          badge: routes.count == 1 ? (routes[0].badge ?? routes[0].soloBadge) : nil
        ),
        arrivalKeyByLineID: arrivalKeys,
        focusLinkIDs: routes.reduce(into: Set<String>()) { $0.formUnion($1.linkIDs) },
        cameraCoordinates: dedupe(coordinates),
        routeIDs: routes.map(\.id),
        isDrawable: true
      )

    case let .observer(observerID):
      let routes = (map.routeIDsByObserver[observerID] ?? [])
        .compactMap { map.routesByID[$0] }
        .filter(\.isDrawable)
      guard !routes.isEmpty else { return everything(in: map, isDrawable: false) }
      var arrivalKeys: [String: String] = [:]
      for route in routes where route.hasMeasuredLeg {
        arrivalKeys["scope-\(route.id)-rx"] = "leg:\(observerID)"
      }
      // With one drawable route the hops number themselves as in route focus;
      // with several, a repeater can sit at different positions and stays plain.
      let numbering = routes.count == 1 ? hopNumbering(routes[0]) : [:]
      let participants = routes.reduce(into: Set<UUID>()) { $0.formUnion($1.participantPinIDs) }
      var coordinates: [CLLocationCoordinate2D] = []
      for route in routes {
        coordinates += route.coordinates
      }
      return PacketScopeFocusGeometry(
        lines: routes.flatMap(\.segments),
        nodes: focusedNodes(in: map, participants: participants, numbering: numbering, badge: routes.first.flatMap { $0.badge ?? $0.soloBadge }),
        arrivalKeyByLineID: arrivalKeys,
        focusLinkIDs: routes.reduce(into: Set<String>()) { $0.formUnion($1.linkIDs) },
        cameraCoordinates: dedupe(coordinates),
        routeIDs: routes.map(\.id),
        isDrawable: true
      )

    case let .route(observerID, routeID):
      guard let route = map.routesByID[routeID], route.isDrawable else {
        return everything(in: map, isDrawable: false)
      }
      var arrivalKeys: [String: String] = [:]
      if route.hasMeasuredLeg {
        arrivalKeys["scope-\(route.id)-rx-solo"] = "leg:\(observerID)"
      }
      return PacketScopeFocusGeometry(
        lines: route.soloSegments,
        nodes: focusedNodes(in: map, participants: route.participantPinIDs, numbering: hopNumbering(route), badge: route.soloBadge),
        arrivalKeyByLineID: arrivalKeys,
        focusLinkIDs: route.linkIDs,
        cameraCoordinates: dedupe(route.coordinates),
        routeIDs: [route.id],
        isDrawable: true
      )
    }
  }

  private static func everything(in map: PacketScopeCoverageMap, isDrawable: Bool) -> PacketScopeFocusGeometry {
    PacketScopeFocusGeometry(
      lines: map.observerLegs.map(\.line),
      nodes: map.nodes,
      arrivalKeyByLineID: Dictionary(map.observerLegs.map { ($0.line.id, "leg:\($0.id)") }, uniquingKeysWith: { first, _ in first }),
      focusLinkIDs: Set(map.links.map(\.id)),
      cameraCoordinates: isDrawable ? map.pinCoordinates : [],
      routeIDs: [],
      isDrawable: isDrawable
    )
  }

  /// Pin id → the hop's true path position, for the focus ring sprite. A
  /// repeater at two positions in one route keeps the first.
  private static func hopNumbering(_ route: PacketScopeCoverageRoute) -> [UUID: Int] {
    var numbering: [UUID: Int] = [:]
    for hop in route.placedHops where numbering[hop.pinID] == nil {
      numbering[hop.pinID] = hop.position
    }
    return numbering
  }

  /// Every pin of the map, promoted or recessed: participants keep their
  /// label and never lose a collision; a numbered participant takes the ring
  /// sprite with its path position; everything else recedes to the one
  /// recessed emphasis, unlabelled. Then the focus's one badge.
  private static func focusedNodes(
    in map: PacketScopeCoverageMap,
    participants: Set<UUID>,
    numbering: [UUID: Int],
    badge: MapPoint?
  ) -> [(point: MapPoint, coordinate: CLLocationCoordinate2D)] {
    var nodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)] = map.nodes.map { node in
      let point = node.point
      if participants.contains(point.id) {
        let position = numbering[point.id]
        return (MapPoint(
          id: point.id,
          coordinate: point.coordinate,
          pinStyle: position != nil ? .repeaterRingWhite : point.pinStyle,
          label: point.label,
          isClusterable: false,
          hopIndex: position,
          badgeText: nil,
          emphasis: 1,
          labelPriority: 0
        ), node.coordinate)
      }
      return (MapPoint(
        id: point.id,
        coordinate: point.coordinate,
        pinStyle: point.pinStyle,
        label: nil,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil,
        emphasis: MapPoint.recessedEmphasis,
        labelPriority: point.labelPriority
      ), node.coordinate)
    }
    if let badge { nodes.append((badge, badge.coordinate)) }
    return nodes
  }

  private static func dedupe(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    var seen = Set<String>()
    return coordinates.filter { seen.insert("\($0.latitude),\($0.longitude)").inserted }
  }

  // MARK: - Partial draws

  /// The leading `fraction` of a run of segments by length, so a leg can be
  /// drawn growing from its start toward the observer. Whole segments before
  /// the cut are kept as they are; the segment the cut lands in is shortened to
  /// the cut point; everything after is dropped.
  static func truncated(_ segments: [MapLine], toFraction fraction: Double) -> [MapLine] {
    guard fraction > 0 else { return [] }
    guard fraction < 1 else { return segments }
    let lengths = segments.map { polylineLength($0.coordinates) }
    let total = lengths.reduce(0, +)
    // Degenerate geometry (every point coincident) has nothing to grow along.
    guard total > 0 else { return segments }

    var remaining = fraction * total
    var visible: [MapLine] = []
    for (segment, length) in zip(segments, lengths) {
      if remaining >= length {
        visible.append(segment)
        remaining -= length
        continue
      }
      if let partial = prefix(of: segment, length: remaining) {
        visible.append(partial)
      }
      break
    }
    return visible
  }

  static func polylineLength(_ coordinates: [CLLocationCoordinate2D]) -> Double {
    guard coordinates.count >= 2 else { return 0 }
    return zip(coordinates, coordinates.dropFirst()).reduce(0) { sum, pair in
      sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
        .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
    }
  }

  /// The first `length` metres of a polyline, ending at an interpolated point.
  /// Linear in latitude/longitude — these are city-scale links. Nil when the
  /// prefix would be a single point, which is not a line.
  private static func prefix(of segment: MapLine, length: Double) -> MapLine? {
    guard length > 0, segment.coordinates.count >= 2 else { return nil }
    var kept: [CLLocationCoordinate2D] = [segment.coordinates[0]]
    var remaining = length
    for (from, to) in zip(segment.coordinates, segment.coordinates.dropFirst()) {
      let step = CLLocation(latitude: from.latitude, longitude: from.longitude)
        .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
      if remaining >= step {
        kept.append(to)
        remaining -= step
        continue
      }
      let t = step > 0 ? remaining / step : 0
      kept.append(CLLocationCoordinate2D(
        latitude: from.latitude + (to.latitude - from.latitude) * t,
        longitude: from.longitude + (to.longitude - from.longitude) * t
      ))
      break
    }
    guard kept.count >= 2 else { return nil }
    return MapLine(id: segment.id, coordinates: kept, style: segment.style, opacity: segment.opacity)
  }
}

/// The fields route ranking needs, so the builder's private plan type and any
/// caller's own route model rank by one rule.
protocol RoutePlanLike {
  var id: String { get }
  var hopCount: Int { get }
  var snr: Double? { get }
}

extension PacketScopeReception.Route: RoutePlanLike {
  var id: String {
    hops.joined(separator: ",")
  }

  var hopCount: Int {
    hops.count
  }

  var snr: Double? {
    bestSNR
  }
}

extension PacketScopeCoverageBuilder {
  /// Strongest route first, by the builder's rule, so the panel's ladder and
  /// the map's headline leg agree on which route is best.
  static func rankedRoutes(_ routes: [PacketScopeReception.Route]) -> [PacketScopeReception.Route] {
    routes.sorted { outranks($0, $1) }
  }
}
