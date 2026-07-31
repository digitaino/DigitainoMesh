import CoreLocation
import MapLibre
import MC1Services
import SwiftUI

/// The Signal Mapper: where *your* mesh actually reaches.
///
/// Every packet the app receives, every echo of one of your own packets coming back off a
/// repeater, and every send that was acknowledged gets bucketed into the H3 res-9 cell you
/// were standing in, and this draws those cells. Unlike the traffic map — which places
/// *other people's* nodes — nothing here needs a repeater to have a known location: the
/// coverage is measured from where the phone was.
///
/// It is the second consumer of the map's overlay API (§2.3): hexagons contributed as
/// weighted fills, no map stack of its own, zero `import MapKit`.
struct SignalMapperCoverageView: View {
  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme

  @State private var model = SignalMapperCoverageModel()
  @State private var cameraBounds: MLNCoordinateBounds?
  @State private var cameraVersion = 0
  @State private var viewportBounds: MLNCoordinateBounds?
  @State private var isStyleLoaded = false
  @State private var isCenteredOnUser = false
  @State private var hasFramedData = false
  @State private var selection: SignalMapperCoverageCell?
  @State private var showingDeleteConfirmation = false

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
      .navigationTitle(L10n.Tools.Tools.signalMapper)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) { optionsMenu }
      }
      .task(id: appState.servicesVersion) { await reload() }
      .onAppear { model.loadCaptureSetting() }
      .sheet(item: $selection) { SignalMapperCellDetailSheet(cell: $0) }
      .alert(
        L10n.Tools.Tools.SignalMapper.Delete.title,
        isPresented: $showingDeleteConfirmation
      ) {
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
        Button(L10n.Localizable.Common.delete, role: .destructive) {
          Task {
            await model.deleteAll(
              dataStore: appState.services?.dataStore,
              radioID: appState.currentRadioID
            )
            hasFramedData = false
          }
        }
      } message: {
        Text(L10n.Tools.Tools.SignalMapper.Delete.message)
      }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if model.isLoading, model.snapshot.isEmpty {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if !model.hasCoverage {
      emptyState
    } else {
      map
    }
  }

  /// The empty state doubles as the tool's front door: it is where capture gets switched
  /// on, so "there is nothing here" and "here is how to change that" are one screen rather
  /// than a dead end plus a hunt through settings.
  private var emptyState: some View {
    ScrollView {
      VStack(spacing: 24) {
        ContentUnavailableView {
          Label(L10n.Tools.Tools.SignalMapper.empty, systemImage: "hexagon")
        } description: {
          Text(L10n.Tools.Tools.SignalMapper.emptyDescription)
        }

        captureCard
          .padding(.horizontal)
      }
      .padding(.vertical)
    }
  }

  private var captureCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(L10n.Tools.Tools.SignalMapper.captureToggle, isOn: captureBinding)
        .font(.body.weight(.medium))

      Text(L10n.Tools.Tools.SignalMapper.captureExplainer)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Label {
        Text(L10n.Tools.Tools.SignalMapper.privacyNote)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "lock.shield")
          .foregroundStyle(.secondary)
      }

      // Said plainly, next to the toggle, because a user who does not know this will read
      // the hole around their home as the app failing rather than as it working. The
      // reviewable zone UI is M2; one honest sentence is what M1 owes them.
      Label {
        Text(L10n.Tools.Tools.SignalMapper.anchorNote)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "house")
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .frame(maxWidth: 520)
    .liquidGlass(in: .rect(cornerRadius: 16))
  }

  private var captureBinding: Binding<Bool> {
    Binding(
      get: { model.isCaptureEnabled },
      set: { model.setCaptureEnabled($0, appState: appState) }
    )
  }

  private var map: some View {
    ZStack(alignment: .bottom) {
      MC1MapView(
        points: [],
        lines: [],
        overlays: SignalMapperCoverageRenderer.overlays(
          for: model.snapshot,
          selected: selection
        ),
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
        onPointTap: { _, _ in },
        onMapTap: { coordinate in
          selection = SignalMapperCoverageRenderer.cell(at: coordinate, in: model.snapshot)
        },
        onCameraRegionChange: { viewportBounds = $0.toMLNCoordinateBounds() },
        isStyleLoaded: $isStyleLoaded,
        isCenteredOnUser: $isCenteredOnUser
      )
      .ignoresSafeArea()

      controls
    }
    .overlay(alignment: .top) { summaryPill }
    .overlay(alignment: .bottomLeading) { SignalMapperLegend() }
    // The map gates camera moves until its style has loaded, which usually lands after the
    // first build, so the fit is re-issued on that signal rather than left to chance.
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
    Text(L10n.Tools.Tools.SignalMapper.summary(
      model.snapshot.cells.count,
      model.snapshot.totalObservations,
      model.snapshot.dayCount
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
          L10n.Tools.Tools.SignalMapper.centerOnCoverage,
          systemImage: "arrow.up.left.and.arrow.down.right"
        ) {
          isCenteredOnUser = false
          frameData()
        }
        .mapControlButton(tint: model.hasCoverage ? .primary : .secondary)
        .disabled(!model.hasCoverage)
      }
    }
  }

  private var optionsMenu: some View {
    Menu {
      Toggle(L10n.Tools.Tools.SignalMapper.captureToggle, isOn: captureBinding)

      if model.hasCoverage {
        Section {
          Button(L10n.Tools.Tools.SignalMapper.Delete.action, systemImage: "trash", role: .destructive) {
            showingDeleteConfirmation = true
          }
        }
      }
    } label: {
      Label(L10n.Tools.Tools.SignalMapper.options, systemImage: "ellipsis.circle")
    }
    .accessibilityLabel(L10n.Tools.Tools.SignalMapper.options)
  }

  // MARK: - Actions

  private func reload() async {
    model.loadCaptureSetting()
    await model.load(
      dataStore: appState.services?.dataStore,
      radioID: appState.currentRadioID
    )
  }

  /// Frames every captured cell. The map ignores a camera whose version still matches the
  /// last applied one, so the target and the version have to move together.
  private func frameData() {
    guard let bounds = SignalMapperCoverageRenderer.cameraBounds(for: model.snapshot) else {
      return
    }
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
    cameraBounds = SignalMapperCoverageRenderer.cameraBounds(around: location.coordinate)
    cameraVersion += 1
  }
}
