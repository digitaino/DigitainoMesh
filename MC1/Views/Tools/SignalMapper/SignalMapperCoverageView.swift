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
  @State private var detailCell: SignalMapperCoverageCell?
  @State private var showingDeleteConfirmation = false
  @State private var mapLayer: SignalMapperMapLayer = .heard
  /// Menu actions never present a sheet inline: on iPad the toolbar menu is a popover
  /// and tearing it down mid-dismissal is the iOS 26 zoom-morph crash family. The flag
  /// arms a `.task(id:)` that waits out the dismissal (RadioStatusControl precedent).
  @State private var pendingFocusPicker = false
  @State private var showingFocusPicker = false
  @State private var showingPrecisePrompt = false
  @State private var showingRunDetail = false
  @State private var breadcrumb: [CLLocationCoordinate2D] = []
  /// Rendered overlays, rebuilt only when their inputs change — never inline in `body`,
  /// which the follow-me loop re-evaluates every 2 s all ride (UI review S3, thermal).
  @State private var mapOverlays: [MapOverlay] = []

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
        // Both items are always present with content varying by value — toolbar
        // structural identity is load-bearing next to the radio popover host (iOS 26).
        ToolbarItem(placement: .topBarTrailing) { layerMenu }
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
      .sheet(item: $detailCell) { SignalMapperCellDetailSheet(cell: $0) }
      .sheet(isPresented: $showingRunDetail) {
        if let session = appState.signalMapperRideSession {
          SignalMapperRunDetailSheet(
            session: session,
            onSpotCheck: { Task { await model.spotCheck(appState: appState) } },
            onEditLockOn: { showingFocusPicker = true },
            onStop: { Task { await model.stopSurvey(appState: appState) } }
          )
        }
      }
      .sheet(isPresented: $showingFocusPicker) {
        // One picker, two jobs: mid-ride it edits the lock-on set; before a ride it IS
        // the start flow (review S1 — starting should lead into lock-on, not hide it
        // behind a button discovered later).
        SignalMapperFocusPickerView(startsSurvey: !isSurveying) { targets, meta in
          Task {
            if isSurveying {
              appState.signalMapperRideSession?.focusMeta = meta
              await appState.setSurveyFocusTargets(targets)
            } else {
              await model.startSurvey(appState: appState, focusTargets: targets, focusMeta: meta)
            }
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
            showingFocusPicker = true
          }
        }
        Button(L10n.Tools.Tools.SignalMapper.Precise.startAnyway) {
          showingFocusPicker = true
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

  /// One `map` arm for both "has coverage" and "surveying", so starting a run from the
  /// empty state does not tear down and rebuild the entire MapLibre view (review S4).
  @ViewBuilder
  private var content: some View {
    if isSurveying || model.hasCoverage {
      map
    } else if model.isLoading {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      emptyState
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
      // Clear of the tab bar: without this the Start button renders half-occluded and
      // a tap on its visible sliver lands on the Map tab instead (verified in-sim).
      .padding(.bottom, 24)
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
    ZStack {
      MC1MapView(
        points: [],
        lines: breadcrumbLines,
        overlays: mapOverlays,
        mapStyle: mapStyleSelection,
        isDarkMode: mapIsDark,
        isOffline: !appState.offlineMapService.isNetworkAvailable,
        showLabels: showLabels,
        showsUserLocation: true,
        isInteractive: true,
        showsScale: !isSurveying,
        isNorthLocked: isNorthLocked,
        cameraRegion: .constant(nil),
        cameraBounds: cameraBounds,
        cameraRegionVersion: cameraVersion,
        onPointTap: { _, _ in },
        onMapTap: { coordinate in
          // Live during rides too (v1's rule): the card is inline and dismissible, so a
          // stray touch costs one ✕, while the data stays one tap away at a stop.
          withAnimation(.snappy(duration: 0.25)) {
            selection = SignalMapperCoverageRenderer.cell(
              at: coordinate, in: model.snapshot, layer: mapLayer
            )
          }
        },
        onCameraRegionChange: { viewportBounds = $0.toMLNCoordinateBounds() },
        isStyleLoaded: $isStyleLoaded,
        isCenteredOnUser: $isCenteredOnUser
      )
      .ignoresSafeArea()

      // Chrome respects the safe area (which the insets below extend), so nothing can
      // land mid-map: controls hug the top-trailing corner exactly as the v1 survey
      // screen did, and the legend keeps its bottom-leading home — visible during runs
      // too, because the Reach layer's grey cells need their key most while riding.
      controls
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      SignalMapperLegend(layer: mapLayer, summary: legendSummary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if isSurveying, let session = appState.signalMapperRideSession {
        SignalMapperLiveStrip(
          session: session,
          onDetail: { showingRunDetail = true },
          onStop: { Task { await model.stopSurvey(appState: appState) } }
        )
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      // Explicit VStack: safeAreaInset's builder Z-stacks loose siblings, and the idle
      // Start row rendered on top of the cell card (caught in-sim).
      VStack(spacing: 0) {
        bottomInset
      }
    }
    .toolbar(isSurveying ? .hidden : .visible, for: .tabBar)
    // The map gates camera moves until its style has loaded, which usually lands after the
    // first build, so the fit is re-issued on that signal rather than left to chance.
    // Both auto-frame triggers are dead during a ride: re-framing on a mid-ride store
    // reload would yank the camera off the rider (review S2).
    .onChange(of: isStyleLoaded) { _, loaded in
      guard !isSurveying else { return }
      if loaded { frameData() }
    }
    .onChange(of: model.snapshot) { _, snapshot in
      rebuildOverlays()
      if let selected = selection {
        selection = snapshot.cells.first { $0.cell == selected.cell }
      }
      guard !hasFramedData, !isSurveying else { return }
      frameData()
    }
    .onChange(of: mapLayer) { _, _ in rebuildOverlays() }
    .onChange(of: selection) { _, _ in rebuildOverlays() }
    .onAppear { rebuildOverlays() }
  }

  /// The bottom inset: focus blocks (or the lock-on hint) while riding; the v1-style
  /// control row with a labelled, self-explaining start button while idle.
  @ViewBuilder
  private var bottomInset: some View {
    if let selected = selection {
      SignalMapperCellCard(
        cell: selected,
        onDetails: { detailCell = selected },
        onClose: { withAnimation(.snappy(duration: 0.25)) { selection = nil } }
      )
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    if isSurveying, let session = appState.signalMapperRideSession {
      SignalMapperFocusBlocks(session: session) { showingFocusPicker = true }
    } else if model.hasCoverage {
      HStack {
        Button {
          startSurveyTapped()
        } label: {
          Label(
            canSurvey
              ? L10n.Tools.Tools.SignalMapper.Survey.start
              : L10n.Tools.Tools.SignalMapper.Survey.connectToStart,
            systemImage: canSurvey
              ? "dot.radiowaves.left.and.right"
              : "antenna.radiowaves.left.and.right.slash"
          )
          .fontWeight(.semibold)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSurvey)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 8)
      .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
  }

  private var legendSummary: String? {
    guard model.hasCoverage else { return nil }
    return L10n.Tools.Tools.SignalMapper.summary(
      model.snapshot.cells.count,
      model.snapshot.totalObservations,
      model.snapshot.dayCount
    )
  }

  private func rebuildOverlays() {
    mapOverlays = SignalMapperCoverageRenderer.overlays(
      for: model.snapshot,
      selected: selection,
      layer: mapLayer
    )
  }

  // MARK: - Chrome

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
  /// the ride is the difference between a fixed setting and a wasted evening. Past the
  /// pre-flight, starting leads into the lock-on picker — its confirm button starts the
  /// run with the chosen targets, or without any.
  private func startSurveyTapped() {
    if appState.locationService.isAuthorized,
       !appState.locationService.isPreciseLocationAuthorized {
      showingPrecisePrompt = true
      return
    }
    showingFocusPicker = true
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
        // Camera and breadcrumb churn are coupled to actual movement: a rider stopped
        // at a light produces zero body invalidations, which also keeps the toolbar's
        // popover host quiet (UI review, radio-pill hypothesis #2).
        if movedEnough {
          breadcrumb.append(coordinate)
          if breadcrumb.count > 5400 {
            breadcrumb.removeFirst(breadcrumb.count - 5400)
          }
          if isCenteredOnUser {
            cameraBounds = SignalMapperCoverageRenderer.cameraBounds(around: coordinate)
            cameraVersion += 1
          }
        }
      }
      try? await Task.sleep(for: .seconds(2))
    }
  }

  /// Location + the shared map-options menu only — 120 pt where the first design
  /// stacked 211 (review §1). The layer picker lives in the navigation bar (it is the
  /// tool's mode, not a map utility) and center-on-coverage in the options menu.
  private var controls: some View {
    MapControlsToolbar(
      onLocationTap: centerOnUser,
      isCenteredOnUser: isCenteredOnUser,
      isNorthLocked: $isNorthLocked,
      showLabels: $showLabels,
      mapStyleSelection: $mapStyleSelection,
      viewportBounds: viewportBounds
    ) {
      EmptyView()
    }
  }

  /// The tool's mode switch: Heard (what I hear) vs Reach (what hears me). Nav-bar
  /// resident because it changes what the whole map means, not how the map behaves.
  private var layerMenu: some View {
    Menu {
      Picker(L10n.Tools.Tools.SignalMapper.Layer.title, selection: $mapLayer) {
        Label(L10n.Tools.Tools.SignalMapper.Layer.heard, systemImage: "arrow.down.left")
          .tag(SignalMapperMapLayer.heard)
        Label(L10n.Tools.Tools.SignalMapper.Layer.reach, systemImage: "arrow.up.right")
          .tag(SignalMapperMapLayer.reach)
      }
    } label: {
      Label(
        L10n.Tools.Tools.SignalMapper.Layer.title,
        systemImage: mapLayer == .heard ? "arrow.down.left.square" : "arrow.up.right.square"
      )
    }
    .accessibilityLabel(L10n.Tools.Tools.SignalMapper.Layer.title)
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
          if model.hasCoverage {
            Button(
              L10n.Tools.Tools.SignalMapper.centerOnCoverage,
              systemImage: "arrow.up.left.and.arrow.down.right"
            ) {
              isCenteredOnUser = false
              frameData()
            }
          }
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
