import CoreLocation
import MapKit
import MapLibre
import MC1Services
import SwiftUI

/// Which path `MessagePathMapView` draws: the path recorded on a message
/// itself, or a route another user embedded in message text via Reply with
/// Route. The endpoints differ with the source: a message's own path runs
/// sender → hops → this device, while a shared route describes a reception at
/// the *sender's* device, so only its hops are plottable — pinning our
/// location or the sender's as an endpoint would assert geography the text
/// never claimed.
enum MessagePathMapSource {
  case message(MessageDTO)
  case sharedRoute(SharedRoute)

  /// Per-hop hash bytes to resolve against known repeaters. A message's own
  /// path is a flat blob chunked by its hash size; a shared route already
  /// carries per-hop bytes (sizes may vary hop to hop).
  var hopHashes: [Data] {
    switch self {
    case .message(let message):
      guard let pathNodes = message.pathNodes else { return [] }
      let size = message.pathHashSize
      return stride(from: 0, to: pathNodes.count, by: size).map { start -> Data in
        Data(pathNodes[start..<min(start + size, pathNodes.count)])
      }
    case .sharedRoute(let route):
      return route.hashBytesPerHop
    }
  }

  /// Total intermediate-hop count, including hops too ambiguous to plot. For a
  /// message's own path a `nil` `pathNodes` yields 0, which is indistinguishable
  /// between a genuine direct message and firmware that omits path data. For a
  /// shared route this is the sender's stated count, matching the card.
  var totalHopCount: Int {
    switch self {
    case .message(let message): message.pathHops.count
    case .sharedRoute(let route): route.hopCount
    }
  }
}

/// The full-screen path map: `MessagePathMapCanvas` under its own navigation
/// chrome. This is the whole path experience for a shared route, whose hops
/// are all the text claims; a message's own path gets the combined
/// `MessagePathDetailView` instead, where this canvas fills the screen under a
/// floating hop panel.
struct MessagePathMapView: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  let source: MessagePathMapSource
  let pathViewModel: MessagePathViewModel

  @State private var locatedNodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)] = []

  /// Why the map is empty. A message with no path data and a shared route whose
  /// repeaters this device doesn't know are different failures — the second one
  /// invites fixing (get the repeaters' adverts) rather than shrugging.
  private var emptyStateDescription: String {
    switch source {
    case .message: L10n.Chats.Chats.Path.Unavailable.description
    case .sharedRoute: L10n.Chats.Chats.SharedRoute.Unavailable.description
    }
  }

  var body: some View {
    NavigationStack {
      Group {
        if pathViewModel.isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if locatedNodes.isEmpty {
          ContentUnavailableView(
            L10n.Chats.Chats.Path.Unavailable.title,
            systemImage: "map",
            description: Text(emptyStateDescription)
          )
        } else {
          MessagePathMapCanvas(locatedNodes: locatedNodes)
        }
      }
      .toolbar {
        if !locatedNodes.isEmpty {
          ToolbarItem(placement: .principal) {
            PathDistanceBanner(
              hopCount: source.totalHopCount,
              totalPathDistance: locatedNodes.map(\.coordinate).totalDistance()
            )
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
      .onAppear {
        // Only a message's own path with no recorded fix plots anything from
        // the live location (the fallback receiver pin) — a stamped message is
        // anchored to its stamp and a shared route plots no endpoints — so
        // that's the one case worth waking GPS for. The cached fix can predate
        // a suspend; the sample onChange below moves the pin when a live one
        // lands.
        if needsLiveLocationFallback {
          appState.requestPhoneFixIfStale()
        }
        locatedNodes = buildLocatedNodes()
      }
      // The shared-route card presents this with the contacts fetch still in
      // flight — the `onAppear` build then runs against an empty pool and would
      // stick on the empty state forever. Rebuild when the load lands.
      .onChange(of: pathViewModel.isLoading) { _, isLoading in
        guard !isLoading else { return }
        locatedNodes = buildLocatedNodes()
      }
      // A fresh fix landed: an unstamped message path pins the receiver at it,
      // so rebuild. Inert for stamped messages (anchored to their recorded
      // fix) and shared routes (no endpoints), so those skip the churn.
      .onChange(of: locationSample) { _, _ in
        guard needsLiveLocationFallback else { return }
        locatedNodes = buildLocatedNodes()
      }
    }
  }

  /// Whether anything on this screen is actually derived from the live phone
  /// location: only a message's own path whose receiver pin lacks a recorded
  /// receive-time fix.
  private var needsLiveLocationFallback: Bool {
    if case .message(let message) = source { return message.userFixCoordinate == nil }
    return false
  }

  /// Value-typed projection of `bestAvailableLocation`, so `onChange` compares
  /// coordinates, not `CLLocation` identity (the radio-GPS fallback allocates a
  /// fresh object on every read).
  private var locationSample: LocationSample? {
    guard let location = appState.bestAvailableLocation else { return nil }
    return LocationSample(
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude
    )
  }

  private func buildLocatedNodes() -> [(point: MapPoint, coordinate: CLLocationCoordinate2D)] {
    Self.locatedNodes(
      for: source,
      contacts: pathViewModel.contacts,
      repeaters: pathViewModel.repeaters,
      discoveredRepeaters: pathViewModel.discoveredRepeaters,
      userLocation: appState.bestAvailableLocation,
      receiverName: appState.connectedDevice?.nodeName
    )
  }

  /// The one "where was the receiver" reference: the fix stamped onto the
  /// message at live receive time when it has one, else the caller's live
  /// location. Shared by the map builder below and the hop list's
  /// disambiguation (`MessagePathDetailView`) so an ambiguous hop can never be
  /// named differently in the list than it is pinned on the map.
  static func receiverReference(
    for source: MessagePathMapSource,
    userLocation: CLLocation?
  ) -> CLLocation? {
    if case .message(let message) = source, let coord = message.userFixCoordinate {
      return CLLocation(latitude: coord.latitude, longitude: coord.longitude)
    }
    return userLocation
  }

  /// Builds the plottable nodes for a path source. Static with injected inputs
  /// so the map and the Reply-with-Route composer share one resolution rule —
  /// exact-match only, deduped, endpoints only for a message's own path — and
  /// a shared distance can never disagree with the drawn polyline.
  static func locatedNodes(
    for source: MessagePathMapSource,
    contacts: [ContactDTO],
    repeaters: [ContactDTO],
    discoveredRepeaters: [DiscoveredNodeDTO],
    userLocation: CLLocation?,
    receiverName: String?
  ) -> [(point: MapPoint, coordinate: CLLocationCoordinate2D)] {
    var nodes: [(MapPoint, CLLocationCoordinate2D)] = []

    // Where the receiver *was*: everything receiver-relative — the B pin and
    // the proximity reference for ambiguous hop hashes — uses the reception's
    // own geography when the message carries it, not wherever the user
    // happens to be standing when they open this screen later. Unstamped rows
    // (backlog drains, no fresh fix at receive, legacy) fall back to the live
    // `userLocation`.
    let stampedFix: CLLocationCoordinate2D? = if case .message(let message) = source {
      message.userFixCoordinate
    } else {
      nil
    }
    let referenceLocation = receiverReference(for: source, userLocation: userLocation)

    // Sender. Only a message's own path has endpoints (see MessagePathMapSource).
    if case .message(let message) = source,
       let keyPrefix = message.senderKeyPrefix,
       let sender = contacts.first(where: { $0.publicKeyPrefix == keyPrefix }),
       sender.hasLocation {
      let coord = CLLocationCoordinate2D(latitude: sender.latitude, longitude: sender.longitude)
      nodes.append((MapPoint(
        id: sender.id,
        coordinate: coord,
        pinStyle: .pointA,
        label: sender.displayName,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil
      ), coord))
    }

    // Repeater hops. Exact-match only (see `resolvePlottableRepeater`);
    // deduped so a repeater appearing in several positions pins once.
    var seenKeys = Set<Data>()
    for (index, hashBytes) in source.hopHashes.enumerated() {
      guard let r = resolvePlottableRepeater(
        hashBytes: hashBytes,
        repeaters: repeaters,
        discoveredRepeaters: discoveredRepeaters,
        referenceLocation: referenceLocation
      ) else { continue }
      if seenKeys.insert(r.publicKey).inserted {
        let coord = CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude)
        nodes.append((MapPoint(
          id: UUID(),
          coordinate: coord,
          pinStyle: .repeaterHop,
          label: r.resolvableName,
          isClusterable: false,
          hopIndex: index + 1,
          badgeText: nil
        ), coord))
      }
    }

    // Receiver (this device). First choice is the fix stamped at receive time —
    // the pin claims "where this message arrived", and only the stamp actually
    // knows that. The fallback for unstamped rows is `bestAvailableLocation`:
    // it prefers phone GPS and only falls back to the radio's stored
    // coordinates — the radio is physically at the user's side, while its
    // *configured* location is a manually-set advert value that can be
    // arbitrarily stale. The fallback phone fix can itself be aged (cached
    // from before a suspend, blocks away), so hosts request a fresh one on
    // appear and rebuild these nodes when it lands.
    if case .message = source, let coord = stampedFix ?? userLocation?.coordinate {
      nodes.append((MapPoint(
        id: UUID(),
        coordinate: coord,
        pinStyle: .pointB,
        label: receiverName,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil
      ), coord))
    }

    return nodes
  }

  /// The one hop-hash resolution rule every path-shaped map shares: a hop is
  /// plottable only when it resolves to a single, unambiguous repeater with a
  /// location (exact match). A 1-byte path hash can't tell apart repeaters
  /// sharing a first key byte, so ambiguous hops — where several known
  /// repeaters share the hash — are skipped rather than guessed at by
  /// proximity, which is what produced the criss-crossing pile-ups.
  static func resolvePlottableRepeater(
    hashBytes: Data,
    repeaters: [ContactDTO],
    discoveredRepeaters: [DiscoveredNodeDTO],
    referenceLocation: CLLocation?
  ) -> (any RepeaterResolvable)? {
    // `RepeaterResolver` judges ambiguity within one table at a time, so a
    // contact and a discovered node sharing the hash but holding different
    // full keys would each read `.exact` in isolation. A short hash matching
    // more than one distinct key across BOTH tables is just as ambiguous as
    // within one (`NeighborNameResolver` applies the same refinement for
    // names); 6+ bytes of hash is a full prefix and can't collide. Ambiguity
    // is judged among the candidates that could still BE the hop: an expired
    // advert row — the old identity a re-keyed repeater left behind, a node
    // that moved away — must not veto its own living successor, but when
    // every candidate is stale they all stay in play (the pruning is
    // relative, shared with `RepeaterResolver.resolve`).
    let (matchedContacts, matchedNodes) = RepeaterResolver.pruneExpiredRivals(
      contacts: repeaters.filter { $0.publicKey.prefix(hashBytes.count) == hashBytes },
      discoveredNodes: discoveredRepeaters.filter { $0.publicKey.prefix(hashBytes.count) == hashBytes }
    )
    if hashBytes.count < 6 {
      let matchingKeys = Set(matchedContacts.map(\.publicKey) + matchedNodes.map(\.publicKey))
      guard matchingKeys.count <= 1 else { return nil }
    }
    let resolvedContact = RepeaterResolver.resolve(for: hashBytes, in: matchedContacts, userLocation: referenceLocation)
    let resolvedNode = RepeaterResolver.resolve(for: hashBytes, in: matchedNodes, userLocation: referenceLocation)
    // Both tables describe one node per key, so pick the first candidate
    // that can actually be plotted, contact first: a contact row that never
    // recorded a fix must not shadow the located discovered row behind the
    // same key. Discovered rows get the full `isValidFix` check — their
    // `hasLocation` skips the coordinate-range validation contacts do.
    let candidates: [(node: any RepeaterResolvable, matchKind: NodeNameMatchKind)] = [
      resolvedContact.map { ($0.node as any RepeaterResolvable, $0.matchKind) },
      resolvedNode.map { ($0.node as any RepeaterResolvable, $0.matchKind) },
    ].compactMap { $0 }
    return candidates.first {
      $0.matchKind == .exact
        && CLLocationCoordinate2D(latitude: $0.node.latitude, longitude: $0.node.longitude).isValidFix
    }?.node
  }

  /// Builds the plottable pins and per-repeat polylines for an outgoing
  /// message's heard repeats. Same construction rules as `locatedNodes` — the
  /// shared exact-match hop resolution, pins deduped by public key — plus the
  /// echo geometry: each repeat traces origin → its resolved hops in path
  /// order → back to origin, the "we heard ourselves again" round trip. A hop
  /// that can't be plotted is skipped (the drawn loop is then a lower bound,
  /// like the path screen's polyline); a repeat with no plottable hops draws
  /// nothing.
  ///
  /// Pins carry their 1-based path position as the hop number; a repeater that
  /// sits at *different* positions in different echoes keeps the plain pin —
  /// one number would be a lie.
  ///
  /// The closing leg — the repeater we actually heard the echo from, back to
  /// us — is where the row's SNR was measured, so it is drawn with the same
  /// SNR treatment the trace and neighbor maps use: an `forSNR`-styled line
  /// and a midpoint "distance · SNR dB" badge. That treatment only applies
  /// when the plotted tail sits at the path's final position; if the true
  /// tail could not be resolved, the loop closes neutrally, because the drawn
  /// leg is then not the leg the radio measured. Echoes sharing a tail are
  /// repeated measurements of the same link on coincident geometry — they fan
  /// into shallow arcs bowing to alternating sides (latest innermost, badges
  /// riding each arc's apex) so every measurement stays visible. A measured
  /// leg with no SNR value stays neutral rather than borrowing the trace
  /// map's "never measured" dashes.
  ///
  /// The origin is the send-time stamp when the message carries one, else the
  /// caller's live location. With no origin at all, resolved repeaters still
  /// pin — there is just no round trip to trace, only hop-to-hop segments.
  static func heardRepeatNodes(
    message: MessageDTO,
    repeats: [MessageRepeatDTO],
    repeaters: [ContactDTO],
    discoveredRepeaters: [DiscoveredNodeDTO],
    userLocation: CLLocation?,
    originName: String?
  ) -> (nodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)], lines: [MapLine]) {
    var nodes: [(MapPoint, CLLocationCoordinate2D)] = []
    var lines: [MapLine] = []

    let originCoord = message.userFixCoordinate ?? userLocation?.coordinate
    let referenceLocation: CLLocation? = originCoord.map {
      CLLocation(latitude: $0.latitude, longitude: $0.longitude)
    }

    if let originCoord {
      nodes.append((MapPoint(
        id: UUID(),
        coordinate: originCoord,
        pinStyle: .pointB,
        label: originName,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil
      ), originCoord))
    }

    // Pass 1: resolve every hop of every repeat, remembering each repeater's
    // path position(s) so the pins built afterwards can number themselves.
    struct PlottedHop {
      let key: Data
      let coordinate: CLLocationCoordinate2D
      /// 1-based position within its repeat's full path (unplottable hops
      /// still count — the number states where in the path this repeater sat).
      let position: Int
    }
    var plottedByRepeat: [[PlottedHop]] = []
    var pinOrder: [Data] = []
    var pinInfo: [Data: (name: String, coordinate: CLLocationCoordinate2D, positions: Set<Int>)] = [:]

    for repeatEntry in repeats {
      let hashes = repeatEntry.hopHashes
      var plotted: [PlottedHop] = []
      for (index, hashBytes) in hashes.enumerated() {
        guard let r = resolvePlottableRepeater(
          hashBytes: hashBytes,
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
      plottedByRepeat.append(plotted)
    }

    for key in pinOrder {
      guard let info = pinInfo[key] else { continue }
      nodes.append((MapPoint(
        id: UUID(),
        coordinate: info.coordinate,
        pinStyle: .repeaterHop,
        label: info.name,
        isClusterable: false,
        hopIndex: info.positions.count == 1 ? info.positions.first : nil,
        badgeText: nil
      ), info.coordinate))
    }

    // Pass 2: lines. The reception leg gets the SNR treatment only when the
    // plotted tail sits at the path's final position — otherwise the drawn
    // closing leg is not the leg the radio measured. Several echoes ending at
    // the same repeater are repeated measurements of the same tail→us link on
    // coincident geometry, so they fan into arcs bowing to alternating sides
    // (latest measurement innermost) — drawn straight they'd overdraw, and
    // layer order rather than data would pick which SNR color survives.
    struct ReceptionLeg {
      let coordinate: CLLocationCoordinate2D
      let snr: Double?
      let receivedAt: Date
    }
    var legOrder: [Data] = []
    var legsByTail: [Data: [ReceptionLeg]] = [:]

    for (index, repeatEntry) in repeats.enumerated() {
      let plotted = plottedByRepeat[index]
      guard let lastPlotted = plotted.last else { continue }
      let hopCoords = plotted.map(\.coordinate)
      let tailIsPlotted = lastPlotted.position == repeatEntry.hopHashes.count

      guard let originCoord else {
        // No origin: no round trip and no reception leg — just the surviving
        // hop-to-hop segments.
        if hopCoords.count >= 2 {
          lines.append(MapLine(
            id: "repeat-\(index)-body",
            coordinates: hopCoords,
            style: .messagePath,
            opacity: 1.0
          ))
        }
        continue
      }

      if tailIsPlotted {
        // Outbound body up to the tail; the reception leg home is emitted
        // after the loop, merged per tail. A one-hop echo IS its reception
        // leg — no body to draw under it.
        if hopCoords.count >= 2 {
          lines.append(MapLine(
            id: "repeat-\(index)-body",
            coordinates: [originCoord] + hopCoords,
            style: .messagePath,
            opacity: 1.0
          ))
        }
        if legsByTail[lastPlotted.key] == nil {
          legOrder.append(lastPlotted.key)
        }
        legsByTail[lastPlotted.key, default: []].append(ReceptionLeg(
          coordinate: lastPlotted.coordinate,
          snr: repeatEntry.snr,
          receivedAt: repeatEntry.receivedAt
        ))
      } else {
        // The measured leg's repeater is unplottable — close neutrally.
        lines.append(MapLine(
          id: "repeat-\(index)-body",
          coordinates: [originCoord] + hopCoords + [originCoord],
          style: .messagePath,
          opacity: 1.0
        ))
      }
    }

    if let originCoord {
      for key in legOrder {
        guard let legs = legsByTail[key] else { continue }
        let tailID = key.prefix(4).map { String(format: "%02x", $0) }.joined()
        // Latest measurement first so it takes the innermost arc; ties keep
        // collection order (Swift's sort is not guaranteed stable).
        let ranked = legs.enumerated().sorted {
          if $0.element.receivedAt != $1.element.receivedAt {
            return $0.element.receivedAt > $1.element.receivedAt
          }
          return $0.offset < $1.offset
        }.map(\.element)
        for (rank, leg) in ranked.enumerated() {
          let arc = Self.legArcCoordinates(
            from: leg.coordinate,
            to: originCoord,
            offsetStep: Self.arcOffsetStep(rank: rank, of: ranked.count)
          )
          // A measured-but-SNR-less echo keeps the neutral style: the trace
          // map's dashed-gray "untraced" reads as *never measured*, which
          // this leg was — it just carries no number to color by (no badge).
          lines.append(MapLine(
            id: "rx-\(tailID)-\(rank)",
            coordinates: arc,
            style: leg.snr != nil ? .forSNR(leg.snr) : .messagePath,
            opacity: 1.0
          ))
          if let snr = leg.snr {
            let badge: MapPoint
            if arc.count == 2 {
              // Straight leg: the house chord-midpoint badge. (Its "apex"
              // would be arc[1] — the origin pin itself.)
              badge = MapLine.snrBadge(id: UUID(), from: leg.coordinate, to: originCoord, snr: snr)
            } else {
              // Fanned leg: the badge rides its own arc's apex, so coincident
              // legs spread their readouts apart instead of stacking them.
              // Distance stays the straight link distance, not arc length.
              let distance = CLLocation(latitude: leg.coordinate.latitude, longitude: leg.coordinate.longitude)
                .distance(from: CLLocation(latitude: originCoord.latitude, longitude: originCoord.longitude))
              let apex = arc[arc.count / 2]
              badge = MapPoint(
                id: UUID(),
                coordinate: apex,
                pinStyle: .badge,
                label: nil,
                isClusterable: false,
                hopIndex: nil,
                badgeText: MapLine.snrBadgeText(distance: distance, snr: snr)
              )
            }
            nodes.append((badge, badge.coordinate))
          }
        }
      }
    }

    return (nodes, lines)
  }

  /// Which side and how far the `rank`-th coincident reception leg bows:
  /// 0 for a lone leg (straight), else +1, -1, +2, -2… — symmetric pairs
  /// fanning outward, the latest measurement hugging the true line closest.
  static func arcOffsetStep(rank: Int, of count: Int) -> Int {
    guard count > 1 else { return 0 }
    let magnitude = rank / 2 + 1
    return rank.isMultiple(of: 2) ? magnitude : -magnitude
  }

  /// Samples a shallow quadratic arc between two coordinates, bowing
  /// perpendicular to the chord by `offsetStep` steps of a fraction of its
  /// length. Step 0 is the straight two-point segment. Computed on a local
  /// equirectangular plane — these are city-scale mesh links, not
  /// transoceanic routes, so no antimeridian handling.
  static func legArcCoordinates(
    from: CLLocationCoordinate2D,
    to: CLLocationCoordinate2D,
    offsetStep: Int,
    samples: Int = 20
  ) -> [CLLocationCoordinate2D] {
    guard offsetStep != 0 else { return [from, to] }

    let cosLat = cos((from.latitude + to.latitude) / 2 * .pi / 180)
    // Local plane: x in cos(lat)-scaled longitude degrees, y in latitude degrees.
    let p0 = (x: from.longitude * cosLat, y: from.latitude)
    let p2 = (x: to.longitude * cosLat, y: to.latitude)
    let dx = p2.x - p0.x
    let dy = p2.y - p0.y
    let length = (dx * dx + dy * dy).squareRoot()
    guard length > 0 else { return [from, to] }

    // Control-point offset of 8% of the chord per step; the rendered apex
    // deviates half that (~4% per step) — enough to read a two-leg lens
    // without flinging outer arcs of a deep stack across the map.
    let bulge = length * 0.08 * Double(offsetStep)
    let control = (
      x: (p0.x + p2.x) / 2 + (-dy / length) * bulge,
      y: (p0.y + p2.y) / 2 + (dx / length) * bulge
    )

    return (0...samples).map { i in
      let t = Double(i) / Double(samples)
      let mt = 1 - t
      let x = mt * mt * p0.x + 2 * mt * t * control.x + t * t * p2.x
      let y = mt * mt * p0.y + 2 * mt * t * control.y + t * t * p2.y
      return CLLocationCoordinate2D(latitude: y, longitude: x / cosLat)
    }
  }
}

private struct LocationSample: Equatable {
  let latitude: Double
  let longitude: Double
}

/// The path map itself — pins, polyline, camera and map controls — with no
/// navigation chrome, so it embeds identically full-screen (shared routes) and
/// above the hop list on `MessagePathDetailView`. The caller owns building
/// `locatedNodes` and keeping the array's identity stable across body
/// evaluations; the canvas re-fits its camera when the node count changes.
struct MessagePathMapCanvas: View {
  /// Span used when the path resolves to a single node, with no bounding box to fit.
  private static let singleNodeSpanDelta: CLLocationDegrees = 0.05
  /// A small breathing margin around the multi-node bounding box. With no host
  /// panel the fit passes `cameraBottomSheetFraction: 0`, so
  /// `setVisibleCoordinateBounds` already insets by the safe-area padding that
  /// clears the nav bar and controls;
  /// anything much above 1 double-margins that and leaves the path filling a
  /// fraction of the screen (matching `NodeLocationMapView`'s rationale).
  private static let pathBoundingPaddingMultiplier: Double = 1.3
  /// How long after the style loads before the one settle re-fit. A fit issued
  /// while the sheet is still animating in measures inflated map bounds and
  /// frames far too wide; by now the presentation has settled.
  private static let settleRefitDelay: Duration = .milliseconds(600)

  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme

  let locatedNodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)]
  /// Explicit, pre-styled polylines to draw instead of the default single
  /// line threading `locatedNodes` in order. The heard-repeats screen passes
  /// its per-echo loops (with SNR-styled reception legs); the path screens
  /// leave it nil. Every coordinate should be one of `locatedNodes`' — the
  /// camera fit frames the pins only.
  var linesOverride: [MapLine]?
  /// Share of the screen a panel covers at the bottom, so a camera fit frames
  /// the path in the space left above it. The map ignores the safe area, so its
  /// own `safeAreaInsets` can't report a SwiftUI inset — the host states it.
  /// 0 (the default) is a canvas with nothing on top of it.
  var cameraBottomSheetFraction: CGFloat = 0

  @State private var cameraRegion: MKCoordinateRegion?
  @State private var cameraRegionVersion = 0
  @State private var mapStyle: MapStyleSelection = .standard
  @AppStorage(AppStorageKey.mapNorthLocked.rawValue) private var isNorthLocked = AppStorageKey.defaultMapNorthLocked
  @State private var showLabels = true
  @State private var isStyleLoaded = false
  @State private var isCenteredOnUser = false
  @State private var hasInitiallyFit = false

  private var mapPoints: [MapPoint] {
    locatedNodes.map(\.point)
  }

  private var mapLines: [MapLine] {
    if let linesOverride {
      return linesOverride
    }
    let coords = locatedNodes.map(\.coordinate)
    guard coords.count >= 2 else { return [] }
    return [MapLine(id: "message-path", coordinates: coords, style: .messagePath, opacity: 1.0)]
  }

  /// Value key over the plotted coordinates, for the re-fit `onChange`.
  private var pathSignature: [Double] {
    locatedNodes.flatMap { [$0.coordinate.latitude, $0.coordinate.longitude] }
  }

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      MC1MapView(
        points: mapPoints,
        lines: mapLines,
        mapStyle: mapStyle,
        isDarkMode: colorScheme == .dark,
        showLabels: showLabels,
        // Gated on existing authorization: MapLibre prompts for permission itself
        // when the puck is enabled while status is undetermined, and opening a
        // message's path hasn't earned a system dialog. The explicit locate tap
        // below is where prompting belongs; a grant there flips this on.
        showsUserLocation: appState.locationService.isAuthorized,
        isInteractive: true,
        showsScale: true,
        isNorthLocked: isNorthLocked,
        cameraRegion: $cameraRegion,
        cameraRegionVersion: cameraRegionVersion,
        cameraBottomSheetFraction: cameraBottomSheetFraction,
        onPointTap: nil,
        onMapTap: nil,
        onCameraRegionChange: { cameraRegion = $0 },
        isStyleLoaded: $isStyleLoaded,
        isCenteredOnUser: $isCenteredOnUser
      )
      .ignoresSafeArea()

      VStack {
        Spacer()
        HStack {
          Spacer()
          MapControlsToolbar(
            onLocationTap: centerOnUserLocation,
            isCenteredOnUser: isCenteredOnUser,
            isNorthLocked: $isNorthLocked,
            showLabels: $showLabels,
            mapStyleSelection: $mapStyle,
            viewportBounds: cameraRegion?.toMLNCoordinateBounds()
          ) {
            if !locatedNodes.isEmpty {
              Button(L10n.Chats.Chats.Path.centerOnPath, systemImage: "arrow.up.left.and.arrow.down.right") {
                isCenteredOnUser = false
                fitCameraToPath()
              }
              .mapControlButton(tint: .primary)
            }
          }
        }
      }
    }
    // The nodes changed under a live map — the contacts load landed after
    // presentation, or a fresh phone fix moved the receiver pin. Keyed on the
    // coordinates rather than the count, because the fix landing *moves* a pin
    // without adding one. Re-fit unless the user has taken the camera somewhere.
    .onChange(of: pathSignature) {
      guard isStyleLoaded, !isCenteredOnUser else { return }
      fitCameraToPath()
    }
    .onChange(of: isStyleLoaded) { _, loaded in
      guard loaded, !hasInitiallyFit else { return }
      hasInitiallyFit = true
      // A locate tap can resolve before a slow style load; don't wipe it out.
      guard !isCenteredOnUser else { return }
      fitCameraToPath()
      // One settle re-fit: the style can finish loading while the presentation
      // is still inflating the map's bounds, and a fit measured then frames far
      // wider than the path. Skipped if the user has already taken the camera
      // somewhere themselves.
      Task {
        try? await Task.sleep(for: Self.settleRefitDelay)
        guard !isCenteredOnUser else { return }
        fitCameraToPath()
      }
    }
  }

  private func fitCameraToPath() {
    let coords = locatedNodes.map(\.coordinate)
    if coords.count == 1 {
      cameraRegion = MKCoordinateRegion(
        center: coords[0],
        span: MKCoordinateSpan(
          latitudeDelta: Self.singleNodeSpanDelta,
          longitudeDelta: Self.singleNodeSpanDelta
        )
      )
    } else if let region = coords.boundingRegion(paddingMultiplier: Self.pathBoundingPaddingMultiplier) {
      cameraRegion = region
    }
    cameraRegionVersion += 1
  }

  private func centerOnUserLocation() {
    Task {
      // A locate tap means "where am I *now*": fetch a live fix (prompting for
      // permission if undetermined) rather than centering on whatever fix is
      // cached — that one can predate a suspend and sit blocks away. Centers
      // only on success (the Line-of-Sight pattern): any fallback here could be
      // the very stale spot the tap is trying to escape, and jumping there
      // while claiming "centered on user" restores the original bug.
      guard let location = try? await appState.locationService.requestCurrentLocation() else { return }
      isCenteredOnUser = true
      cameraRegion = MKCoordinateRegion(
        center: location.coordinate,
        span: MKCoordinateSpan(
          latitudeDelta: Self.singleNodeSpanDelta,
          longitudeDelta: Self.singleNodeSpanDelta
        )
      )
      cameraRegionVersion += 1
    }
  }
}
