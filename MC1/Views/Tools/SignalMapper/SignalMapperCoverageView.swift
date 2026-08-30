import CoreLocation
import MapLibre
import MC1Services
import SurveyKit
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
  /// The hexagon the rider is standing in. During a run its card is on screen without
  /// anyone tapping anything — the third field test's "I still don't see any data".
  @State private var liveCell: H3Cell?
  /// Set when the rider dismisses the live cell's card, cleared the moment they cross
  /// into a different hexagon, so the ✕ means what it says without hiding the ride.
  @State private var dismissedLiveCell: H3Cell?
  /// Which repeater the cell card is filtered to (v1's `selectedRelayFilter`): tapping a
  /// chip re-computes the card from that repeater's observations alone.
  @State private var repeaterFilter: String?
  @State private var detailCell: SignalMapperCoverageCell?
  @State private var showingDeleteConfirmation = false
  @State private var mapLayer: SignalMapperMapLayer = .heard
  /// Menu actions never present a sheet inline: on iPad the toolbar menu is a popover
  /// and tearing it down mid-dismissal is the iOS 26 zoom-morph crash family. The flag
  /// arms a `.task(id:)` that waits out the dismissal (RadioStatusControl precedent).
  @State private var pendingFocusPicker = false
  @State private var showingFocusPicker = false
  /// Seeds the lock-on picker's search field when it is opened from a repeater chip.
  @State private var focusPickerSeed = ""
  @State private var showingPrecisePrompt = false
  /// Menu-launched like the picker, so it waits out the menu's own dismissal.
  @State private var pendingTransmitSheet = false
  @State private var showingTransmitSheet = false
  @State private var showingRunDetail = false
  @State private var pendingRunDetailAction: SignalMapperRunDetailSheet.PendingAction?
  @State private var breadcrumb: [CLLocationCoordinate2D] = []
  /// Rendered overlays, rebuilt only when their inputs change — never inline in `body`,
  /// which the follow-me loop re-evaluates every 2 s all ride (UI review S3, thermal).
  @State private var mapOverlays: [MapOverlay] = []
  /// Height of the bottom inset, measured rather than guessed: the camera has to keep the
  /// rider above it, or a ride centres the map on a dot hidden behind the cell card
  /// (UI review P0-1).
  @State private var bottomInsetHeight: CGFloat = 0
  /// Same measurement for the live strip, so the camera's top padding is not a constant
  /// that drifts with Dynamic Type (UI review P2-11).
  @State private var topInsetHeight: CGFloat = 0

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
      // Passive capture keeps folding while this screen is open; without a refresh the
      // card's "Last Heard" drifts minutes behind the radio pill's repeater list.
      .task(id: appState.servicesVersion) { await model.autoRefresh(appState: appState) }
      // Re-subscribes the HUD to each new engine generation: the run outlives BLE
      // rewires, the engines (and their snapshot streams) do not.
      .task(id: appState.signalMapperRideSession?.engineGeneration ?? -1) {
        await model.attachSurveyStream(appState: appState)
      }
      .task(id: isSurveying) { await followRider() }
      // Both deferrals clear their flag on cancellation too. A `.task(id:)` that returns
      // with its flag still true can never be restarted by setting that flag true again,
      // and the menu item that sets it is dead for the rest of the session — the same
      // latch that killed the radio pill (field report, 2026-08-30).
      .task(id: pendingFocusPicker) {
        guard pendingFocusPicker else { return }
        // A sheet binding left true by a dropped presentation — five `.sheet` modifiers
        // share one presentation chain here — makes every later request a no-op. Clearing
        // first means the set below is always a change; the settle delay separates them.
        showingFocusPicker = false
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else {
          pendingFocusPicker = false
          return
        }
        pendingFocusPicker = false
        showingFocusPicker = true
      }
      .task(id: pendingTransmitSheet) {
        guard pendingTransmitSheet else { return }
        showingTransmitSheet = false
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else {
          pendingTransmitSheet = false
          return
        }
        pendingTransmitSheet = false
        showingTransmitSheet = true
      }
      .onAppear { model.loadCaptureSetting() }
      .sheet(item: $detailCell) { SignalMapperCellDetailSheet(cell: $0) }
      // The run sheet's actions run on *its* dismissal, never from inside it: both of
      // them present another sheet (UI review P0-4).
      .sheet(isPresented: $showingRunDetail, onDismiss: runPendingRunDetailAction) {
        if let session = appState.signalMapperRideSession {
          SignalMapperRunDetailSheet(
            session: session,
            onSpotCheck: { Task { await model.spotCheck(appState: appState) } },
            pendingAction: $pendingRunDetailAction
          )
        }
      }
      .sheet(isPresented: $showingTransmitSheet) {
        SignalMapperTransmitSheet(model: model)
      }
      .sheet(isPresented: $showingFocusPicker) {
        // One picker, two jobs: mid-ride it edits the lock-on set; before a ride it IS
        // the start flow (review S1 — starting should lead into lock-on, not hide it
        // behind a button discovered later).
        SignalMapperFocusPickerView(startsSurvey: !isSurveying, initialSearch: focusPickerSeed) { targets, meta in
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
        cameraEdgePadding: cameraPadding,
        onPointTap: { _, _ in },
        onMapTap: { coordinate in mapTapped(at: coordinate) },
        onCameraRegionChange: { viewportBounds = $0.toMLNCoordinateBounds() },
        isStyleLoaded: $isStyleLoaded,
        isCenteredOnUser: $isCenteredOnUser
      )
      .ignoresSafeArea()

      // Chrome respects the safe area (which the insets below extend), so nothing can
      // land mid-map: controls hug the top-trailing corner exactly as the v1 survey
      // screen did. The legend used to live bottom-leading in here and shared that band
      // with nothing but the map — until the bottom inset grew and squeezed the band to
      // 138 pt, at which point the legend and the controls column overlapped by 34 pt
      // (UI review P0-3). It is part of the bottom stack now.
      controls
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if isSurveying, let session = appState.signalMapperRideSession {
        SignalMapperLiveStrip(
          session: session,
          onDetail: { showingRunDetail = true },
          onStop: { Task { await model.stopSurvey(appState: appState) } }
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topInsetHeight = $0 }
      }
    }
    // One container owns the gutter, the spacing and the clock. Four surfaces with their
    // own margins, radii and animations is what read as "disjointed" and as things
    // sitting on top of each other (UI review P0-2, P2-12).
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        bottomInset
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.bottom, 8)
      // The gutters either side of the panel are live map: without this, reaching for the
      // leftmost repeater chip lands on the map and swaps the whole card for another
      // hexagon's (UI review P2-13).
      .background(Color.clear.contentShape(.rect).onTapGesture {})
      .animation(.snappy(duration: 0.25), value: displayedCell?.cell)
      .animation(.snappy(duration: 0.25), value: showsFocusStrip)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noteBottomInset($0) }
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
      // The detail sheet is a value copy; without this its numbers freeze the moment it
      // opens, which during a ride is the one place they should not (UI review P2-33).
      if let open = detailCell {
        detailCell = snapshot.cells.first { $0.cell == open.cell }
      }
      if let repeaterFilter,
         displayedCell?.repeaters.contains(where: { $0.hexID == repeaterFilter }) != true {
        self.repeaterFilter = nil
      }
      guard !hasFramedData, !isSurveying else { return }
      frameData()
    }
    // The map only re-applies its camera when the version moves, so a card appearing
    // (or growing) has to ask for the re-frame that keeps the rider clear of it.
    .onChange(of: bottomInsetHeight) { _, _ in
      guard isSurveying, isCenteredOnUser, cameraBounds != nil else { return }
      cameraVersion += 1
    }
    .onChange(of: mapLayer) { _, _ in rebuildOverlays() }
    .onChange(of: selection) { _, _ in rebuildOverlays() }
    .onAppear { rebuildOverlays() }
  }

  /// The cell whose card is on screen: the tapped one, else — while riding — the one the
  /// rider is standing in. The ride shows its own data without being asked (field report,
  /// 2026-08-30).
  private var displayedCell: SignalMapperCoverageCell? {
    if let selection { return selection }
    guard isSurveying, let liveCell, dismissedLiveCell != liveCell else { return nil }
    return model.snapshot.cells.first { $0.cell == liveCell }
  }

  private var focusHexIDs: Set<String> {
    Set(appState.signalMapperRideSession?.focusTargets.map(\.id.hex) ?? [])
  }

  /// The live lock-on strip earns its place when it says something the card does not:
  /// a locked-on target's probe state, or — with no card yet on a hexagon the rider has
  /// just entered — who is answering at all. Otherwise it repeats the card's chips
  /// (field report, 2026-08-30).
  private var showsFocusStrip: Bool {
    guard isSurveying else { return false }
    return !focusHexIDs.isEmpty || displayedCell == nil
  }

  /// The bottom inset: **one** panel holding the live lock-on rows and the cell card,
  /// with the idle start button below it. Three separately backgrounded, separately
  /// padded blocks stacked in a column read as floating cards colliding with each other
  /// rather than as one readout (field report, 2026-08-30).
  @ViewBuilder
  private var bottomInset: some View {
    if showsFocusStrip || displayedCell != nil {
      VStack(spacing: 0) {
        panelContent
      }
      .background(Color(.secondarySystemBackground).opacity(0.96))
      .clipShape(.rect(cornerRadius: 18))
      .padding(.horizontal, 12)
      .padding(.top, 8)
    }
    if !isSurveying, model.hasCoverage {
      startRow
    }
  }

  @ViewBuilder
  private var panelContent: some View {
    if showsFocusStrip, let session = appState.signalMapperRideSession {
      SignalMapperFocusBlocks(
        session: session,
        onLockOn: {
          focusPickerSeed = ""
          showingFocusPicker = true
        },
        onUnlock: { id in
          let remaining = session.focusTargets.filter { $0.id != id }
          Task { await appState.setSurveyFocusTargets(remaining) }
        }
      )
      if displayedCell != nil {
        Divider().padding(.leading, 14)
      }
    }
    if let displayed = displayedCell {
      SignalMapperCellCard(
        cell: displayed,
        layer: mapLayer,
        focusHexIDs: focusHexIDs,
        isLiveCell: selection == nil,
        repeaterFilter: $repeaterFilter,
        onDetails: { detailCell = displayed },
        onLockOn: { repeater in
          focusPickerSeed = repeater.name ?? repeater.hexID
          showingFocusPicker = true
        },
        onClose: {
          withAnimation(.snappy(duration: 0.25)) {
            if selection != nil {
              selection = nil
            } else {
              dismissedLiveCell = liveCell
            }
            repeaterFilter = nil
          }
        }
      )
      // A new hexagon is a new card, not the old one's digits rolling into new values:
      // `contentTransition(.numericText())` would otherwise animate "you moved" as
      // "this number changed" (UI review P2-12).
      .id(displayed.cell)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  private var startRow: some View {
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
    .padding(.top, 8)
    .padding(.bottom, 8)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
    focusPickerSeed = ""
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
      liveCell = nil
      dismissedLiveCell = nil
      return
    }
    isCenteredOnUser = true
    while !Task.isCancelled, isSurveying {
      if let location = appState.locationService.currentLocation {
        let coordinate = location.coordinate
        // Which hexagon the card follows. Cheap enough to re-derive every tick, and it
        // has to be: crossing a boundary while stopped at a light still changes the cell.
        let here = SurveyGrid.cell(
          containing: GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
        if here != liveCell {
          withAnimation(.snappy(duration: 0.25)) {
            liveCell = here
            // A new hexagon is new data: a card dismissed in the last one does not carry.
            dismissedLiveCell = nil
            repeaterFilter = nil
          }
        }
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
            focusPickerSeed = ""
            pendingFocusPicker = true
          }
          Button(L10n.Tools.Tools.SignalMapper.Transmit.title, systemImage: "dot.radiowaves.right") {
            pendingTransmitSheet = true
          }
          Button(L10n.Tools.Tools.SignalMapper.Survey.stop, systemImage: "stop.circle") {
            Task { await model.stopSurvey(appState: appState) }
          }
        } else {
          Button(L10n.Tools.Tools.SignalMapper.Survey.start, systemImage: "dot.radiowaves.left.and.right") {
            startSurveyTapped()
          }
          .disabled(!canSurvey)
          Button(L10n.Tools.Tools.SignalMapper.Transmit.title, systemImage: "dot.radiowaves.right") {
            pendingTransmitSheet = true
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

  /// A tap on the map picks that hexagon's card. Live during rides too (v1's rule): the
  /// card is inline and dismissible, so a stray touch costs one ✕, while the data stays
  /// one tap away at a stop. Tapping the hexagon you are already in returns to following
  /// it rather than pinning a second, identical card.
  /// Keeps the rider clear of the chrome: the camera is padded by what the HUD actually
  /// measures, top and bottom.
  private var cameraPadding: UIEdgeInsets {
    UIEdgeInsets(top: topInsetHeight, left: 0, bottom: bottomInsetHeight, right: 0)
  }

  /// Quantized to 8 pt: the inset breathes by a point or two as rows swap text, and every
  /// change re-animates the camera to the same bounds (UI review P2-10).
  private func noteBottomInset(_ height: CGFloat) {
    let stepped = (height / 8).rounded() * 8
    guard stepped != bottomInsetHeight else { return }
    bottomInsetHeight = stepped
  }

  private func runPendingRunDetailAction() {
    guard let action = pendingRunDetailAction else { return }
    pendingRunDetailAction = nil
    switch action {
    case .editLockOn:
      focusPickerSeed = ""
      pendingFocusPicker = true
    case .stop:
      Task { await model.stopSurvey(appState: appState) }
    }
  }

  private func mapTapped(at coordinate: CLLocationCoordinate2D) {
    let tapped = SignalMapperCoverageRenderer.cell(
      at: coordinate, in: model.snapshot, layer: mapLayer
    )
    let isLive: Bool = if let tapped { tapped.cell == liveCell } else { false }
    withAnimation(.snappy(duration: 0.25)) {
      selection = isLive ? nil : tapped
      if isLive {
        dismissedLiveCell = nil
      }
      repeaterFilter = nil
    }
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
