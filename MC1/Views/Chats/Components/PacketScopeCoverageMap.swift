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

/// One observer route as drawable geometry, for the focus state where a single
/// observer's routes are shown in full.
struct PacketScopeCoverageRoute: Identifiable {
  /// Observer id plus the hop sequence — stable across refreshes.
  let id: String
  let observerID: String
  /// Polylines in travel order, split wherever a hop could not be placed: a
  /// gap in the path is left as a gap rather than bridged with a link that
  /// nothing in the data says exists. The measured leg into the observer, when
  /// its tail hop is placed, is the last segment.
  let segments: [MapLine]
  /// The measured leg's "distance · SNR" readout, for the focus state.
  let badge: MapPoint?
}

/// The observer network's view of one packet, as map geometry.
struct PacketScopeCoverageMap {
  /// Origin (pin A), hop repeaters (numbered hop pins) and located observers
  /// (pin B). Ids are derived from what the pin stands for, so a poll that
  /// changes nothing re-sources nothing.
  let nodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)]
  let links: [PacketScopeCoverageLink]
  let observerLegs: [PacketScopeObserverLeg]
  let routes: [PacketScopeCoverageRoute]
  /// Straight-line distance from the origin to each located observer, keyed by
  /// observer id as the receptions carry it. Empty without an origin.
  let observerDistances: [String: CLLocationDistance]

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
/// geometry at all — its row says so — because a route ending on a repeater
/// pin would only restate what the pin already shows.
@MainActor
enum PacketScopeCoverageBuilder {
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
        id: stableID("origin"),
        coordinate: origin.coordinate,
        pinStyle: .pointA,
        label: origin.name,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil
      ), origin.coordinate))
    }

    // Pass 1: place every hop of every route, remembering each repeater's
    // path position(s) so its pin can number itself, and which observers can
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
    var pinInfo: [Data: (name: String, coordinate: CLLocationCoordinate2D, positions: Set<Int>)] = [:]
    var observerPinOrder: [String] = []
    var observerPins: [String: (name: String, coordinate: CLLocationCoordinate2D, snr: Double?)] = [:]
    var observerDistances: [String: CLLocationDistance] = [:]

    for reception in receptions {
      let observerKey = reception.observerID.lowercased()
      let observerCoordinate = observersByID[observerKey]?.coordinate
      if let observerCoordinate {
        if observerPins[observerKey] == nil {
          observerPinOrder.append(observerKey)
          observerPins[observerKey] = (reception.observerName, observerCoordinate, reception.bestSNR)
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
          let position = index + 1
          plotted.append(PlottedHop(key: r.publicKey, coordinate: coord, position: position))
          if var info = pinInfo[r.publicKey] {
            info.positions.insert(position)
            pinInfo[r.publicKey] = info
          } else {
            pinOrder.append(r.publicKey)
            pinInfo[r.publicKey] = (r.resolvableName, coord, [position])
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
          id: "\(reception.observerID)|\(route.hops.joined(separator: ","))",
          observerID: reception.observerID,
          hopCount: route.hops.count,
          plotted: plotted,
          observerCoordinate: observerCoordinate,
          snr: route.bestSNR,
          measuredFrom: measuredFrom
        ))
      }
    }

    for key in pinOrder {
      guard let info = pinInfo[key] else { continue }
      nodes.append((MapPoint(
        id: stableID(hopKey(key)),
        coordinate: info.coordinate,
        pinStyle: .repeaterHop,
        label: info.name,
        isClusterable: false,
        hopIndex: info.positions.count == 1 ? info.positions.first : nil,
        badgeText: nil
      ), info.coordinate))
    }
    for key in observerPinOrder {
      guard let pin = observerPins[key] else { continue }
      // The pin label carries the observer's best signal: one pill where the
      // reader looks, instead of a name pill plus a badge per route.
      let label = pin.snr.map { "\(pin.name) · \(Self.decibels($0))" } ?? pin.name
      nodes.append((MapPoint(
        id: stableID("obs:\(key)"),
        coordinate: pin.coordinate,
        pinStyle: .pointB,
        label: label,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil
      ), pin.coordinate))
    }

    // Pass 2: links. Only between points that are adjacent in the path —
    // origin → hop 1, hop i → hop i+1, placed tail → observer, or origin →
    // observer when heard directly. A gap where a hop could not be placed
    // stays a gap.
    var linkOrder: [String] = []
    var linkInfo: [String: (from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, count: Int)] = [:]
    func countLink(_ fromKey: String, _ from: CLLocationCoordinate2D, _ toKey: String, _ to: CLLocationCoordinate2D) {
      let id = "\(fromKey)>\(toKey)"
      if var info = linkInfo[id] {
        info.count += 1
        linkInfo[id] = info
      } else {
        linkOrder.append(id)
        linkInfo[id] = (from, to, 1)
      }
    }

    for plan in plans {
      var previous: (key: String, coordinate: CLLocationCoordinate2D, position: Int)? =
        origin.map { ("origin", $0.coordinate, 0) }
      for hop in plan.plotted {
        if let previous, hop.position == previous.position + 1 {
          countLink(previous.key, previous.coordinate, hopKey(hop.key), hop.coordinate)
        }
        previous = (hopKey(hop.key), hop.coordinate, hop.position)
      }
      if let observerCoordinate = plan.observerCoordinate, let from = plan.measuredFrom {
        countLink(from.key, from.coordinate, "obs:\(plan.observerID.lowercased())", observerCoordinate)
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

    // Pass 4: full per-route geometry for the focus state. Measured legs that
    // share a tail into the same observer are repeated measurements of one
    // link on coincident geometry; they fan into arcs bowing to alternating
    // sides, the strongest route hugging the true line, so every readout
    // stays visible.
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

    var legLines: [Int: (line: MapLine, badge: MapPoint?)] = [:]
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
        let line = MapLine(
          id: "scope-\(plan.id)-rx",
          coordinates: arc,
          style: plan.snr != nil ? .forSNR(plan.snr) : .messagePath,
          opacity: 1.0
        )
        var badge: MapPoint?
        if let snr = plan.snr {
          if arc.count == 2 {
            badge = MapLine.snrBadge(id: stableID("badge:\(plan.id)"), from: leg.from, to: leg.to, snr: snr)
          } else {
            // Fanned leg: the badge rides its own arc's apex. Distance stays
            // the straight link distance, not arc length.
            let distance = CLLocation(latitude: leg.from.latitude, longitude: leg.from.longitude)
              .distance(from: CLLocation(latitude: leg.to.latitude, longitude: leg.to.longitude))
            badge = MapPoint(
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
        legLines[leg.planIndex] = (line, badge)
      }
    }

    var routes: [PacketScopeCoverageRoute] = []
    for (index, plan) in plans.enumerated() {
      var segments: [MapLine] = []
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
          segments.append(MapLine(id: "scope-\(plan.id)-body-\(runIndex)", coordinates: run, style: .messagePath, opacity: 1.0))
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
      if let leg { segments.append(leg.line) }
      guard !segments.isEmpty else { continue }
      routes.append(PacketScopeCoverageRoute(
        id: plan.id,
        observerID: plan.observerID,
        segments: segments,
        badge: leg?.badge
      ))
    }

    return PacketScopeCoverageMap(
      nodes: nodes,
      links: links,
      observerLegs: observerLegs,
      routes: routes,
      observerDistances: observerDistances
    )
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

  /// Route ranking for "strongest": higher SNR first, an unmeasured route last,
  /// then fewer hops, then id — total, so a poll returning the same data never
  /// swaps which route is an observer's headline.
  private static func outranks(_ lhs: some RoutePlanLike, _ rhs: some RoutePlanLike) -> Bool {
    switch (lhs.snr, rhs.snr) {
    case let (l?, r?) where l != r: return l > r
    case (.some, .none): return true
    case (.none, .some): return false
    default: break
    }
    if lhs.hopCount != rhs.hopCount { return lhs.hopCount < rhs.hopCount }
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
    "\(snr.formatted(.number.precision(.fractionLength(0...1)))) dB"
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
