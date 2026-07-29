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

struct MessagePathMapView: View {
  /// Span used when the path resolves to a single node, with no bounding box to fit.
  private static let singleNodeSpanDelta: CLLocationDegrees = 0.05
  /// A small breathing margin around the multi-node bounding box. The fit passes
  /// `cameraBottomSheetFraction: 0`, so `setVisibleCoordinateBounds` already
  /// insets by the safe-area padding that clears the nav bar and controls;
  /// anything much above 1 double-margins that and leaves the path filling a
  /// fraction of the screen (matching `NodeLocationMapView`'s rationale).
  private static let pathBoundingPaddingMultiplier: Double = 1.3
  /// How long after the style loads before the one settle re-fit. A fit issued
  /// while the sheet is still animating in measures inflated map bounds and
  /// frames far too wide; by now the presentation has settled.
  private static let settleRefitDelay: Duration = .milliseconds(600)

  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  let source: MessagePathMapSource
  let pathViewModel: MessagePathViewModel

  @State private var cameraRegion: MKCoordinateRegion?
  @State private var cameraRegionVersion = 0
  @State private var mapStyle: MapStyleSelection = .standard
  @AppStorage(AppStorageKey.mapNorthLocked.rawValue) private var isNorthLocked = AppStorageKey.defaultMapNorthLocked
  @State private var showLabels = true
  @State private var isStyleLoaded = false
  @State private var isCenteredOnUser = false
  @State private var hasInitiallyFit = false
  @State private var locatedNodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)] = []

  private var mapPoints: [MapPoint] {
    locatedNodes.map(\.point)
  }

  private var mapLines: [MapLine] {
    let coords = locatedNodes.map(\.coordinate)
    guard coords.count >= 2 else { return [] }
    return [MapLine(id: "message-path", coordinates: coords, style: .messagePath, opacity: 1.0)]
  }

  /// Length of the drawn path, over only the nodes we could place. Nil until at
  /// least two nodes resolve to coordinates, so the pill's distance always
  /// matches the polyline in `mapLines`.
  private var totalPathDistance: CLLocationDistance? {
    locatedNodes.map(\.coordinate).totalDistance()
  }

  private var hopCount: Int {
    source.totalHopCount
  }

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
          ZStack(alignment: .bottomTrailing) {
            MC1MapView(
              points: mapPoints,
              lines: mapLines,
              mapStyle: mapStyle,
              isDarkMode: colorScheme == .dark,
              showLabels: showLabels,
              showsUserLocation: false,
              isInteractive: true,
              showsScale: true,
              isNorthLocked: isNorthLocked,
              cameraRegion: $cameraRegion,
              cameraRegionVersion: cameraRegionVersion,
              cameraBottomSheetFraction: 0,
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
        }
      }
      .toolbar {
        if !locatedNodes.isEmpty {
          ToolbarItem(placement: .principal) {
            PathDistanceBanner(
              hopCount: hopCount,
              totalPathDistance: totalPathDistance
            )
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
      .onAppear {
        locatedNodes = buildLocatedNodes()
      }
      // The actions sheet preloads the view model before this map appears, but the
      // shared-route card presents it with the contacts fetch still in flight — the
      // `onAppear` build then runs against an empty pool and would stick on the empty
      // state forever. Rebuild when the load lands, and refit if the map beat it here.
      .onChange(of: pathViewModel.isLoading) { _, isLoading in
        guard !isLoading else { return }
        locatedNodes = buildLocatedNodes()
        if isStyleLoaded {
          fitCameraToPath()
        }
      }
      .onChange(of: isStyleLoaded) { _, loaded in
        guard loaded, !hasInitiallyFit else { return }
        hasInitiallyFit = true
        fitCameraToPath()
        // One settle re-fit: this sheet's style can finish loading while the
        // presentation is still inflating the map's bounds, and a fit measured
        // then frames far wider than the path. Skipped if the user has already
        // taken the camera somewhere themselves.
        Task {
          try? await Task.sleep(for: Self.settleRefitDelay)
          guard !isCenteredOnUser else { return }
          fitCameraToPath()
        }
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
    guard let location = appState.bestAvailableLocation else {
      appState.locationService.requestLocation()
      return
    }
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

    // Repeater hops. A 1-byte path hash can't tell apart repeaters sharing a
    // first key byte, so only plot hops that resolve to a single, unambiguous
    // repeater (exact match). Ambiguous hops — where several known repeaters
    // share the hash — are skipped rather than guessed at by proximity, which
    // is what produced the criss-crossing pile-ups.
    var seenKeys = Set<Data>()
    for (index, hashBytes) in source.hopHashes.enumerated() {
      let hopNumber = index + 1
      let resolvedContact = RepeaterResolver.resolve(for: hashBytes, in: repeaters, userLocation: userLocation)
      let resolvedNode = RepeaterResolver.resolve(for: hashBytes, in: discoveredRepeaters, userLocation: userLocation)
      let resolved: (node: any RepeaterResolvable, matchKind: NodeNameMatchKind)? =
        resolvedContact.map { ($0.node, $0.matchKind) } ?? resolvedNode.map { ($0.node, $0.matchKind) }
      guard let resolved, resolved.matchKind == .exact else { continue }
      let r = resolved.node
      if r.hasLocation, seenKeys.insert(r.publicKey).inserted {
        let coord = CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude)
        nodes.append((MapPoint(
          id: UUID(),
          coordinate: coord,
          pinStyle: .repeaterHop,
          label: r.resolvableName,
          isClusterable: false,
          hopIndex: hopNumber,
          badgeText: nil
        ), coord))
      }
    }

    // Receiver (this device). `bestAvailableLocation` prefers phone GPS and only falls
    // back to the radio's stored coordinates — the radio is physically at the user's
    // side, while its *configured* location is a manually-set advert value that can be
    // arbitrarily stale (a radio set up on a trip keeps reporting that spot forever).
    if case .message = source, let loc = userLocation {
      let coord = loc.coordinate
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
}
