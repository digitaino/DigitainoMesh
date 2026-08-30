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
  @State private var mapLayer: SignalMapperMapLayer = .heard
  /// Menu actions never present a sheet inline: on iPad the toolbar menu is a popover
  /// and tearing it down mid-dismissal is the iOS 26 zoom-morph crash family. The flag
  /// arms a `.task(id:)` that waits out the dismissal (RadioStatusControl precedent).
  @State private var pendingFocusPicker = false
  @State private var showingFocusPicker = false
  @State private var showingPrecisePrompt = false
  @State private var breadcrumb: [CLLocationCoordinate2D] = []

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
      // Re-subscribes the HUD to each new engine generation: the run outlives BLE
      // rewires, the engines (and their snapshot streams) do not.
      .task(id: appState.signalMapperRideSession?.engineGeneration ?? -1) {
        await model.attachSurveyStream(appState: appState)
      }
      .task(id: isSurveying) { await followRider() }
      .task(id: pendingFocusPicker) {
        guard pendingFocusPicker else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        pendingFocusPicker = false
        showingFocusPicker = true
      }
      .onAppear { model.loadCaptureSetting() }
      .sheet(item: $selection) { SignalMapperCellDetailSheet(cell: $0) }
      .sheet(isPresented: $showingFocusPicker) {
        SignalMapperFocusPickerView { targets, meta in
          Task {
            appState.signalMapperRideSession?.focusMeta = meta
            await appState.setSurveyFocusTargets(targets)
          }
        }
      }
      .sheet(isPresented: surveySummaryBinding) {
        if let summary = model.surveySummary {
          SignalMapperSessionSummarySheet(
            summary: summary,
            runID: model.lastCompletedRunID,
            rawLogStore: appState.mapperRawLogStore
          )
        }
      }
      .alert(
        L10n.Tools.Tools.SignalMapper.Precise.title,
        isPresented: $showingPrecisePrompt
      ) {
        Button(L10n.Tools.Tools.SignalMapper.Precise.enable) {
          Task {
            await appState.locationService.requestTemporaryFullAccuracy(purposeKey: "RideSurvey")
            await model.startSurvey(appState: appState)
          }
        }
        Button(L10n.Tools.Tools.SignalMapper.Precise.startAnyway) {
          Task { await model.startSurvey(appState: appState) }
        }
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      } message: {
        Text(L10n.Tools.Tools.SignalMapper.Precise.message)
      }
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

  private var isSurveying: Bool {
    appState.signalMapperRideSession != nil
  }

  @ViewBuilder
  private var content: some View {
    if isSurveying {
      // A running ride always shows the map + HUD, even before the first cell folds —
      // the empty state has no live readout and the rider cannot navigate back to one.
      map
    } else if model.isLoading, model.snapshot.isEmpty {
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

        // A survey is the fastest way out of the empty state: one ride, first hexagons.
        // The map (with the ride HUD) takes over the moment a session starts.
        if canSurvey {
          Button(L10n.Tools.Tools.SignalMapper.Survey.start, systemImage: "dot.radiowaves.left.and.right") {
            startSurveyTapped()
          }
          .buttonStyle(.borderedProminent)
        }
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

  private var surveySummaryBinding: Binding<Bool> {
    Binding(
      get: { model.surveySummary != nil },
      set: { if !$0 { model.surveySummary = nil } }
    )
  }

  /// Whether a survey can start: probes need a connected radio to transmit through.
  private var canSurvey: Bool {
    appState.services != nil
  }

  private var map: some View {
    ZStack(alignment: .bottom) {
      MC1MapView(
        points: [],
        lines: breadcrumbLines,
        overlays: SignalMapperCoverageRenderer.overlays(
          for: model.snapshot,
          selected: selection,
          layer: mapLayer
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
          // While riding, the map is a display, not a control surface: capacitive
          // touches through a jersey pocket must not cover the HUD with a sheet.
          guard !isSurveying else { return }
          selection = SignalMapperCoverageRenderer.cell(
            at: coordinate, in: model.snapshot, layer: mapLayer
          )
        },
        onCameraRegionChange: { viewportBounds = $0.toMLNCoordinateBounds() },
        isStyleLoaded: $isStyleLoaded,
        isCenteredOnUser: $isCenteredOnUser
      )
      .ignoresSafeArea()

      VStack(spacing: 8) {
        if isSurveying, let session = appState.signalMapperRideSession {
          SignalMapperRideHUD(
            session: session,
            onSpotCheck: { Task { await model.spotCheck(appState: appState) } },
            onLockOn: { showingFocusPicker = true }
          )
          .padding(.horizontal, 12)
        }
        controls
      }
    }
    .overlay(alignment: .top) {
      if !isSurveying {
        summaryPill
      }
    }
    .overlay(alignment: .bottomLeading) {
      if !isSurveying {
        SignalMapperLegend(layer: mapLayer)
      }
    }
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

  /// The ride's own track, threading the live fixes in time order — where you have
  /// actually been, even where the mesh was silent.
  private var breadcrumbLines: [MapLine] {
    guard isSurveying, breadcrumb.count >= 2 else { return [] }
    return [MapLine(
      id: "mapper-ride-breadcrumb",
      coordinates: breadcrumb,
      style: .locationTrail,
      opacity: 0.8
    )]
  }

  /// The Precise Location pre-flight (review 7b): with it off, every fix fails the 50 m
  /// accuracy gate and the whole ride records nothing, silently. Surfacing it *before*
  /// the ride is the difference between a fixed setting and a wasted evening.
  private func startSurveyTapped() {
    if appState.locationService.isAuthorized,
       !appState.locationService.isPreciseLocationAuthorized {
      showingPrecisePrompt = true
      return
    }
    Task { await model.startSurvey(appState: appState) }
  }

  /// Follow-me + breadcrumbs while riding: every 2 s, thread the live fix onto the trail
  /// and keep the camera on the rider (review 7a: without this, the map shows the
  /// neighbourhood you left two minutes ago, at full render cost, all night).
  private func followRider() async {
    guard isSurveying else {
      breadcrumb = []
      return
    }
    isCenteredOnUser = true
    while !Task.isCancelled, isSurveying {
      if let location = appState.locationService.currentLocation {
        let coordinate = location.coordinate
        let last = breadcrumb.last
        let movedEnough = last.map {
          CLLocation(latitude: $0.latitude, longitude: $0.longitude)
            .distance(from: location) >= 5
        } ?? true
        if movedEnough {
          breadcrumb.append(coordinate)
          if breadcrumb.count > 5400 {
            breadcrumb.removeFirst(breadcrumb.count - 5400)
          }
        }
        if isCenteredOnUser {
          cameraBounds = SignalMapperCoverageRenderer.cameraBounds(around: coordinate)
          cameraVersion += 1
        }
      }
      try? await Task.sleep(for: .seconds(2))
    }
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
        // A Picker inside a Menu is the map-control column's idiom for a choice
        // (MapControlsToolbar's own style menu); a segmented control fits neither the
        // 44-point column nor the iOS 26 toolbar rules.
        Menu {
          Picker(L10n.Tools.Tools.SignalMapper.Layer.title, selection: $mapLayer) {
            Label(L10n.Tools.Tools.SignalMapper.Layer.heard, systemImage: "arrow.down.left")
              .tag(SignalMapperMapLayer.heard)
            Label(L10n.Tools.Tools.SignalMapper.Layer.reach, systemImage: "arrow.up.right")
              .tag(SignalMapperMapLayer.reach)
          }
        } label: {
          Image(systemName: mapLayer == .heard ? "arrow.down.left.square" : "arrow.up.right.square")
        }
        .mapControlButton(tint: .primary)
        .accessibilityLabel(L10n.Tools.Tools.SignalMapper.Layer.title)

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

      Section {
        if isSurveying {
          Button(L10n.Tools.Tools.SignalMapper.Ride.lockOn, systemImage: "scope") {
            pendingFocusPicker = true
          }
          Button(L10n.Tools.Tools.SignalMapper.Survey.stop, systemImage: "stop.circle") {
            Task { await model.stopSurvey(appState: appState) }
          }
        } else {
          Button(L10n.Tools.Tools.SignalMapper.Survey.start, systemImage: "dot.radiowaves.left.and.right") {
            startSurveyTapped()
          }
          .disabled(!canSurvey)
        }
      }

      // Delete-all sits one mis-tap from Stop; it disappears entirely while a run is
      // recording (review 6b).
      if model.hasCoverage, !isSurveying {
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
