import CoreLocation
import MapLibre
import MC1Services
import SwiftUI

/// The traffic map: where the mesh's packets actually went.
///
/// Every hop of every packet in the RX log is resolved to a node and drawn twice over — as a
/// bubble under the node's pin, sized by how much it relayed and tinted by how well we hear it,
/// and as a link to the hop beside it, thickened by how many packets crossed it. It is the
/// first consumer of the map's overlay API (§2.3): the pins are upstream's, the weighted
/// geometry is contributed.
struct TrafficHeatmapView: View {
  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme

  @State private var model = TrafficHeatmapModel()
  @State private var cameraBounds: MLNCoordinateBounds?
  @State private var cameraVersion = 0
  @State private var viewportBounds: MLNCoordinateBounds?
  @State private var isStyleLoaded = false
  @State private var isCenteredOnUser = false
  @State private var hasFramedData = false
  @State private var selection: TrafficNodeSelection?
  @State private var selectionAnchor: CGPoint?

  @AppStorage(AppStorageKey.mapStyleSelection.rawValue)
  private var mapStyleSelection: MapStyleSelection = .standard
  @AppStorage(AppStorageKey.mapShowLabels.rawValue)
  private var showLabels = AppStorageKey.defaultMapShowLabels
  @AppStorage(AppStorageKey.mapNorthLocked.rawValue)
  private var isNorthLocked = AppStorageKey.defaultMapNorthLocked
  @AppStorage(AppStorageKey.mapColorSchemePreference.rawValue)
  private var mapColorSchemeRaw = AppStorageKey.defaultMapColorSchemePreference

  private var mapIsDark: Bool {
    let preference = AppColorSchemePreference(rawValue: mapColorSchemeRaw) ?? .system
    return resolvedMapIsDark(preference: preference, colorScheme: colorScheme)
  }

  var body: some View {
    content
      .navigationTitle(L10n.Tools.Tools.trafficMap)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if model.hasPlacedNodes || model.hasEntries {
          ToolbarItem(placement: .topBarTrailing) { timeWindowMenu }
        }
      }
      .task(id: appState.servicesVersion) { await reload() }
      .onChange(of: model.window) { _, _ in
        hasFramedData = false
        Task { await reload() }
      }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if appState.services?.dataStore == nil {
      ContentUnavailableView {
        Label(L10n.Tools.Tools.TrafficMap.notConnected, systemImage: "antenna.radiowaves.left.and.right.slash")
      } description: {
        Text(L10n.Tools.Tools.TrafficMap.notConnectedDescription)
      }
    } else if model.isLoading, model.snapshot.isEmpty {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if !model.hasEntries {
      ContentUnavailableView {
        Label(L10n.Tools.Tools.TrafficMap.noData, systemImage: "map")
      } description: {
        Text(L10n.Tools.Tools.TrafficMap.noDataDescription)
      }
    } else if !model.hasPlacedNodes {
      ContentUnavailableView {
        Label(L10n.Tools.Tools.TrafficMap.noPlacedNodes, systemImage: "mappin.slash")
      } description: {
        Text(L10n.Tools.Tools.TrafficMap.noPlacedNodesDescription)
      }
    } else {
      map
    }
  }

  private var map: some View {
    ZStack(alignment: .bottom) {
      MC1MapView(
        points: TrafficHeatmapRenderer.points(for: model.snapshot),
        lines: [],
        overlays: TrafficHeatmapRenderer.overlays(for: model.snapshot),
        mapStyle: mapStyleSelection,
        isDarkMode: mapIsDark,
        isOffline: !appState.offlineMapService.isNetworkAvailable,
        showLabels: showLabels,
        showsUserLocation: true,
        isInteractive: true,
        showsScale: true,
        isNorthLocked: isNorthLocked,
        cameraRegion: .constant(nil),
        cameraBounds: cameraBounds,
        cameraRegionVersion: cameraVersion,
        onPointTap: { point, anchor in
          selection = model.snapshot.nodes
            .first { TrafficHeatmapRenderer.pointID(for: $0.publicKey) == point.id }
            .map(TrafficNodeSelection.init)
          selectionAnchor = anchor
        },
        onMapTap: { _ in selection = nil },
        onCameraRegionChange: { viewportBounds = $0.toMLNCoordinateBounds() },
        isStyleLoaded: $isStyleLoaded,
        isCenteredOnUser: $isCenteredOnUser
      )
      .ignoresSafeArea()

      controls
    }
    .overlay(alignment: .top) { summaryPill }
    .overlay(alignment: .bottomLeading) { TrafficHeatmapLegend() }
    .popover(
      item: $selection,
      attachmentAnchor: .rect(.rect(CGRect(
        origin: selectionAnchor ?? .zero,
        size: CGSize(width: 1, height: 1)
      ))),
      arrowEdge: .bottom
    ) { selection in
      TrafficNodeCallout(node: selection.node)
        .presentationCompactAdaptation(.popover)
    }
    // The map gates camera moves until its style has loaded, which usually lands after the
    // first aggregation, so the fit is re-issued on that signal rather than left to chance.
    .onChange(of: isStyleLoaded) { _, loaded in
      if loaded { frameData() }
    }
    .onChange(of: model.snapshot) { _, _ in
      guard !hasFramedData else { return }
      frameData()
    }
  }

  // MARK: - Chrome

  private var summaryPill: some View {
    Text(L10n.Tools.Tools.TrafficMap.summary(
      model.snapshot.nodes.count,
      model.snapshot.segments.count,
      model.snapshot.analyzedEntryCount
    ))
    .font(.subheadline.weight(.medium))
    .lineLimit(1)
    .minimumScaleFactor(0.7)
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .liquidGlass(in: .capsule)
    .safeAreaPadding(.top)
    .accessibilityElement(children: .combine)
  }

  private var controls: some View {
    HStack {
      Spacer()
      MapControlsToolbar(
        onLocationTap: centerOnUser,
        isCenteredOnUser: isCenteredOnUser,
        isNorthLocked: $isNorthLocked,
        showLabels: $showLabels,
        mapStyleSelection: $mapStyleSelection,
        viewportBounds: viewportBounds
      ) {
        Button(
          L10n.Tools.Tools.TrafficMap.centerOnTraffic,
          systemImage: "arrow.up.left.and.arrow.down.right"
        ) {
          isCenteredOnUser = false
          frameData()
        }
        .mapControlButton(tint: model.hasPlacedNodes ? .primary : .secondary)
        .disabled(!model.hasPlacedNodes)
      }
    }
  }

  private var timeWindowMenu: some View {
    Menu {
      Picker(L10n.Tools.Tools.TrafficMap.timeWindow, selection: $model.window) {
        ForEach(model.availableWindows) { window in
          Text(window.label).tag(window)
        }
      }
    } label: {
      Label(L10n.Tools.Tools.TrafficMap.timeWindow, systemImage: "clock")
    }
    .accessibilityLabel(L10n.Tools.Tools.TrafficMap.timeWindow)
    .accessibilityValue(model.window.label)
  }

  // MARK: - Actions

  private func reload() async {
    await model.load(
      dataStore: appState.services?.dataStore,
      radioID: appState.currentRadioID,
      origin: appState.bestAvailableLocation
    )
  }

  /// Frames every placed node. The map ignores a camera whose version still matches the last
  /// applied one, so the target and the version have to move together.
  private func frameData() {
    guard let bounds = TrafficHeatmapRenderer.cameraBounds(for: model.snapshot) else { return }
    hasFramedData = true
    cameraBounds = bounds
    cameraVersion += 1
  }

  private func centerOnUser() {
    guard let location = appState.bestAvailableLocation else {
      appState.locationService.requestLocation()
      isCenteredOnUser = false
      return
    }
    isCenteredOnUser = true
    cameraBounds = TrafficHeatmapRenderer.cameraBounds(around: location.coordinate)
    cameraVersion += 1
  }
}

// MARK: - Selection

/// The node whose callout is open. Identified by public key so re-aggregating while the callout
/// is up does not reopen it somewhere else.
struct TrafficNodeSelection: Identifiable {
  let node: TrafficNodeLoad

  var id: Data {
    node.publicKey
  }

  init(_ node: TrafficNodeLoad) {
    self.node = node
  }
}

// MARK: - Time window labels

extension TrafficTimeWindow {
  /// The localized name of the window. The service layer owns the ladder; the app owns its words.
  var label: String {
    switch self {
    case .minutes15: L10n.Tools.Tools.TrafficMap.Window.minutes15
    case .minutes30: L10n.Tools.Tools.TrafficMap.Window.minutes30
    case .hour1: L10n.Tools.Tools.TrafficMap.Window.hour1
    case .hours3: L10n.Tools.Tools.TrafficMap.Window.hours3
    case .hours6: L10n.Tools.Tools.TrafficMap.Window.hours6
    case .hours12: L10n.Tools.Tools.TrafficMap.Window.hours12
    case .day1: L10n.Tools.Tools.TrafficMap.Window.day1
    case .days3: L10n.Tools.Tools.TrafficMap.Window.days3
    case .days7: L10n.Tools.Tools.TrafficMap.Window.days7
    case .all: L10n.Tools.Tools.TrafficMap.Window.all
    }
  }
}
