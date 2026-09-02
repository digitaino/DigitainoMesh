import CoreLocation
import MC1Services
import SwiftUI
import UIKit

/// The observer network's view of one message's packet: which CoreScope observers
/// heard it, how strongly, and by which repeaters.
///
/// Reachable only through the message actions sheet, and only when the Packet
/// Scope opt-in is on and the message has a wire identity — the lookup is
/// user-initiated by design, never fired by rendering a conversation.
///
/// Two layouts. When anything can be placed, a full-bleed map with a floating
/// panel; otherwise the same rows as a plain list. On the map, one **focus**
/// governs everything: everything, one observer, or one route. Focus is a
/// filter, not a dimmer — what is focused draws at full strength and framed by
/// the camera, what is not is removed from the map or recessed to an unlabelled
/// pin. Where the focused thing cannot be placed (an observer with no published
/// location whose repeaters could not be placed either), the map is left
/// exactly as it was, the camera does not move, and the panel says why.
///
/// "Nobody heard it" is a real result, not an error: coverage is whatever the
/// configured instance's observers hear, so silence means the packet stayed
/// outside their range. A message can be delivered on the mesh and never
/// observed, and the empty state says exactly that.
///
/// Presented as a cover rather than a sheet, like the path and repeats screens:
/// a downward drag over the map should pan the map, not dismiss it.
struct PacketScopeDetailView: View {
  /// Panel sizing mirrors `MessagePathDetailView` so the map screens read as
  /// siblings. The budget is the whole panel's share of the screen; the list
  /// gets what the header leaves, so a focus that adds header rows never
  /// takes room from the map.
  private static let panelBudgetFraction: CGFloat = 0.45
  /// Route focus keeps the tapped row and its ladder on screen — the tap that
  /// focused it landed inside that list — while the map gains real height.
  private static let routeFocusBudgetFraction: CGFloat = 0.30
  /// The list is never handed less than this while it is shown: three 44 pt
  /// rows, so a tall header on a short phone cannot delete the tapped row
  /// from under the finger. A full map is the explicit observers toggle.
  private static let minimumListHeight: CGFloat = 132
  private static let panelCornerRadius: CGFloat = 20
  private static let panelMargin: CGFloat = 12

  /// Observers ingest over MQTT with seconds of lag and echoes keep arriving, so a
  /// just-sent message is still gaining coverage while the screen is open. Poll
  /// only inside that window, and only while the message is fresh.
  private static let livePollWindow: TimeInterval = 180
  private static let pollInterval: Duration = .seconds(6)
  /// Consecutive unchanged polls before giving up early. Coverage that has not
  /// moved in ~18s has settled; continuing would spend battery to re-learn it.
  private static let quietPollsBeforeStopping = 3
  /// Consecutive failures before the loop stops retrying. The endpoint is public,
  /// unauthenticated and Cloudflare-fronted with no server-side rate limiting, so
  /// pacing is entirely this client's responsibility — hammering it 30 times
  /// through a challenge or an outage is how an IP earns a block.
  private static let failuresBeforeStopping = 3

  /// How long a link or leg heard by a later poll takes to reach full weight or
  /// length. Short: the arrival is announced by the row's chip as much as by
  /// the map, and a poll's worth of arrivals must finish before the next poll.
  private static let arrivalDrawDuration: TimeInterval = 0.5
  private static let arrivalFrameInterval: Duration = .milliseconds(33)
  /// How long a row keeps its "New" chip after its observer first reports.
  private static let newChipLifetime: TimeInterval = 20

  /// The two link overlays are declared in every state with these constant
  /// paints; only their feature lists change. Changing a paint tears the
  /// overlay's style layers down and rebuilds them, which is a per-tap cost
  /// no selection should pay.
  private static let focusLinkPaint = MapOverlay.Paint.weightedLine(MapOverlay.WeightedLine(
    color: .systemBlue,
    width: 1.5...6,
    opacity: 0.3...0.9,
    casing: MapOverlay.Casing(extraWidth: 2.5)
  ))
  /// Context links have no casing: forty coincident white halos would
  /// composite toward the focused route's own and bury it.
  private static let contextLinkPaint = MapOverlay.Paint.weightedLine(MapOverlay.WeightedLine(
    color: .systemBlue,
    width: 1...1.5,
    opacity: 0.10...0.18,
    casing: nil
  ))

  @Environment(\.appTheme) private var theme
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  /// The route row's leading glyph box, scaled with the type it sits beside.
  @ScaledMetric(relativeTo: .caption) private var drawabilityGlyphWidth: CGFloat = 16

  let message: MessageDTO
  /// The app's own hop-name resolver — the same one the path screen uses, so a
  /// repeater is called the same thing here as everywhere else, complete with the
  /// proximity disambiguation that keeps colliding short hashes apart.
  let pathViewModel: MessagePathViewModel
  /// Reference position for that disambiguation; the host passes the same
  /// stamp-first reference the repeats map uses.
  let userLocation: CLLocation?

  /// One session for the screen's life rather than one per poll, so the
  /// connection to a Cloudflare-fronted host is reused across the live window.
  @State private var service = PacketScopeService()

  @State private var receptions: [PacketScopeReception]?
  @State private var summary: PacketScopeSummary?
  /// The instance's observer roster, fetched once per open. Where an observer
  /// publishes a position, its routes get a far end on the map.
  @State private var observers: [PacketScopeObserver] = []
  @State private var errorText: String?
  /// A fetch is in flight — the guard against overlapping requests.
  @State private var isRefreshing = false
  /// The toolbar's refresh was tapped and has not returned. Only a manual
  /// refresh touches the control; a silent poll never flickers it.
  @State private var isManualRefresh = false
  /// Consecutive failed refreshes; drives the loop's give-up and its backoff.
  @State private var consecutiveFailures = 0
  /// Whether a fetch has succeeded yet. The first result draws at once; what
  /// later polls add is what animates and gets a "New" chip.
  @State private var hasLoadedOnce = false
  /// Whether the live poll loop is running: the headline's "still arriving"
  /// versus "settled".
  @State private var isLive = false
  /// How the poll loop ended. "Settled" is a claim — coverage stopped changing —
  /// and it must not be printed when the loop gave up on failures instead
  /// (review F061); a single `isLive` flag cannot tell those apart.
  @State private var loopOutcome: LoopOutcome = .running
  /// `scenePhase` as the poll loop sees it. The loop runs in a `.task` that
  /// captured the view struct once, so reading the environment there would
  /// return the phase at appear forever; a `@State` box reads live.
  @State private var isSceneActive = true
  /// Reduce Motion, mirrored for the same reason.
  @State private var isReduceMotion = false
  /// Whether the observer roster has arrived. Until it has, no row may claim
  /// "No location" — an empty roster says nothing about any observer.
  @State private var rosterLoaded = false

  @State private var coverage: PacketScopeCoverageMap?
  /// The map's answer to the current focus: lines, pins and camera. Cached
  /// here rather than derived per body evaluation because the body
  /// re-evaluates every animation frame.
  @State private var focusGeometry: PacketScopeFocusGeometry?
  /// Pins, plus the focus's badge. Kept as state because the map diffs its
  /// point source against it.
  @State private var locatedNodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)] = []
  /// Hop display names per route id, resolved when data changes — not in the
  /// body, which re-evaluates every animation frame.
  @State private var hopNamesByRoute: [String: [String]] = [:]
  /// Links and legs mid-arrival, keyed by element id, as a 0…1 progress. An
  /// element absent here is fully drawn.
  @State private var arrivalProgress: [String: Double] = [:]
  /// Every link and leg id the map has shown, so a refresh can tell arrivals
  /// from elements it already drew.
  @State private var seenElementIDs: Set<String> = []
  @State private var seenObserverIDs: Set<String> = []
  /// When each observer first reported after the initial load; drives the
  /// "New" chip.
  @State private var observerArrivals: [String: Date] = [:]
  /// Bumped when a "New" chip should expire, so the body re-evaluates then.
  @State private var newChipTick = 0
  @State private var drawTask: Task<Void, Never>?

  @State private var focus: PacketScopeFocus = .all
  @State private var cameraFocus: MessagePathMapCanvas.CameraFocus?
  /// What the focus bar prints; rebuilt on focus and data changes, never in
  /// the body.
  @State private var focusSummary: FocusSummary?
  /// The panel's order, frozen for the life of a focus so a poll cannot move
  /// a row or re-rank a ladder under a reaching finger.
  @State private var frozenOrder: PacketScopeFrozenOrder?
  /// The rows, in display order — the live sort, or the frozen order with new
  /// observers appended.
  @State private var displayReceptions: [PacketScopeReception] = []
  @State private var sort: ObserverSort = .strongest
  /// Whether the tap-to-focus hint has done its job. Persisted, so the line
  /// costs the list a row once rather than on every message forever.
  @AppStorage(AppStorageKey.hasSeenPacketScopeFocusHint.rawValue)
  private var hasSeenFocusHint = AppStorageKey.defaultHasSeenPacketScopeFocusHint
  /// The focus bar's observers toggle: a true full-map view is its explicit
  /// second tap, remembered for the life of the focus.
  @State private var showsObserverList = true
  @State private var headerHeight: CGFloat = 0
  @State private var observerListHeight: CGFloat = 0
  @State private var panelHeight: CGFloat = 0
  @State private var scrollRequest = ScrollRequest(id: nil, anchor: .top, version: 0)
  /// Haptic triggers. Selection fires for a focus the user chose — never for
  /// a poll that reconciled one away — and a step fires its own.
  @State private var selectionTick = 0
  @State private var stepTick = 0
  @State private var copyTick = 0

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(L10n.Localizable.PacketScope.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            refreshButton
          }
          ToolbarItemGroup(placement: .topBarTrailing) {
            copyButton
            Button(L10n.Localizable.Common.done) { dismiss() }
          }
        }
        .task { await liveRefreshLoop() }
        .task { await loadObservers() }
        .onAppear {
          // An outgoing message's origin is its send-time stamp when it has
          // one; only the unstamped fallback depends on the live location, and
          // the cached fix can predate a suspend — ask for a live one then.
          if message.isOutgoing, message.userFixCoordinate == nil {
            appState.requestPhoneFixIfStale()
          }
        }
        // The actions sheet preloads the view model, but a fast tap can land
        // here with the contacts fetch still in flight — rebuild when it lands
        // so hops the phone knows do not stay unpinned.
        .onChange(of: pathViewModel.isLoading) { _, isLoading in
          guard !isLoading else { return }
          rebuildCoverage(animated: false)
        }
        // A fresh fix landed: the unstamped outgoing origin is built from it.
        .onChange(of: locationSample) { _, _ in
          guard message.isOutgoing, message.userFixCoordinate == nil else { return }
          rebuildCoverage(animated: false)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
          isSceneActive = phase == .active
        }
        .onChange(of: reduceMotion, initial: true) { _, value in
          isReduceMotion = value
        }
        .onChange(of: sort) { _, _ in
          // A sort change re-freezes around the new order and keeps the
          // focused row in view, so it is never silently relocated.
          frozenOrder = nil
          applySort()
          if focus != .all {
            frozenOrder = captureOrder()
            requestScroll(for: focus)
          }
        }
        // A cover over this screen mid-poll must not strand half-drawn
        // elements; the next rebuild starts them again.
        .onDisappear {
          drawTask?.cancel()
          drawTask = nil
          arrivalProgress = [:]
        }
        .sensoryFeedback(.selection, trigger: selectionTick)
        .sensoryFeedback(.impact(weight: .light), trigger: stepTick)
        .sensoryFeedback(.success, trigger: copyTick)
        .sensoryFeedback(.success, trigger: hasLoadedOnce)
    }
  }

  // MARK: - Toolbar

  /// One persistent control for the screen's life. Swapping it for a spinner
  /// on every poll dropped VoiceOver focus and flickered under a thumb some
  /// thirty times in the first three minutes.
  private var refreshButton: some View {
    Button {
      Task { await refresh(isManual: true) }
    } label: {
      Image(systemName: "arrow.clockwise")
        .opacity(isManualRefresh ? 0 : 1)
        .overlay {
          if isManualRefresh { ProgressView() }
        }
    }
    .disabled(isManualRefresh)
    .accessibilityLabel(L10n.Localizable.PacketScope.refresh)
    .accessibilityValue(isManualRefresh ? L10n.Localizable.PacketScope.loading : "")
  }

  /// A copy, never a send: the text is built from the summary, the rows and
  /// the resolved names, so the message — and its packet identifier — is not
  /// even in scope.
  private var copyButton: some View {
    Button {
      UIPasteboard.general.string = PacketScopeFocusLogic.copySummary(
        summary: summary,
        receptions: displayReceptions,
        hopNamesByRoute: hopNamesByRoute,
        routeID: { PacketScopeCoverageBuilder.routeID(observerID: $0, hops: $1.hops) }
      )
      copyTick += 1
    } label: {
      Image(systemName: "doc.on.doc")
    }
    .disabled(receptions?.isEmpty != false)
    .accessibilityLabel(L10n.Localizable.PacketScope.copySummary)
  }

  // MARK: - Layout

  @ViewBuilder
  private var content: some View {
    if let coverage, coverage.isPlottable {
      GeometryReader { proxy in
        MessagePathMapCanvas(
          locatedNodes: locatedNodes,
          linesOverride: visibleLines,
          overlays: overlays,
          cameraBottomSheetFraction: panelHeight / max(proxy.size.height, 1),
          cameraCoordinates: coverage.pinCoordinates,
          onPointTap: { point in
            // A repeater pin is inert by design; a tap on one is a tap on the
            // map, which pops a level rather than being swallowed.
            guard let observerID = coverage.observerIDByPinID[point.id] else {
              popFocus()
              return
            }
            toggle(observer: observerID)
          },
          onMapTap: { popFocus() },
          cameraFocus: cameraFocus,
          labelPlacement: .collide,
          onBadgeTap: { badge in
            guard let routeID = coverage.routeIDByBadgePinID[badge.id],
                  let route = coverage.routesByID[routeID],
                  focus.routeID != routeID else { return }
            setFocus(.route(observerID: route.observerID, routeID: routeID))
          },
          accessibilitySummary: mapSummary
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
          floatingPanel(listBudget: listBudget(for: proxy.size.height))
        }
      }
    } else {
      // Nothing placeable — still loading, unheard, or heard only by observers
      // and repeaters this phone cannot locate — so the rows are the screen.
      List {
        listContent
      }
      .themedCanvas(theme)
    }
  }

  /// The panel's total share of the screen, less what the header takes.
  private func listBudget(for height: CGFloat) -> CGFloat {
    guard showsObserverList else { return 0 }
    let fraction = focus.routeID != nil ? Self.routeFocusBudgetFraction : Self.panelBudgetFraction
    return max(Self.minimumListHeight, height * fraction - headerHeight)
  }

  private func floatingPanel(listBudget: CGFloat) -> some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        panelHeader
        if focus != .all {
          focusBar
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
      if showsObserverList {
        Divider()
          .padding(.horizontal, 16)
        observerList(maxHeight: listBudget)
      }
    }
    .liquidGlass(in: .rect(cornerRadius: Self.panelCornerRadius))
    .padding(.horizontal, Self.panelMargin)
    .padding(.bottom, Self.panelMargin)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
  }

  /// The count and the sort, then — only once there is one — the breadcrumb,
  /// and with nothing focused the answer line. Everything the header shows
  /// costs the list a row, so nothing sits here that is not carrying its
  /// height: with nothing focused the breadcrumb was a 44 pt row holding the
  /// inert word "All", and the hint outlived the lesson it taught.
  private var panelHeader: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text(L10n.Localizable.PacketScope.heardBy(summary?.observerCount ?? 0))
          .font(.subheadline.weight(.semibold))
        Spacer(minLength: 0)
        sortMenu
      }
      if focus != .all {
        breadcrumb
      }
      if focus == .all {
        if let line = summaryLine {
          Text(line)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        // Retired for good once the model has been used once: it teaches a
        // gesture, and a taught gesture does not need re-teaching on every
        // message for the life of the app.
        if !hasSeenFocusHint {
          Text(L10n.Localizable.PacketScope.tapHint)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      // A retry puts a *different* packet on the air each attempt, and this
      // row is stamped with whichever attempt's echo arrived first. In the
      // header, not a footer nobody scrolls to.
      if message.sendCount > 1 {
        Text(L10n.Localizable.PacketScope.retriedFooter(message.sendCount))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.top, 10)
    .padding(.bottom, focus == .all ? 10 : 2)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }

  /// `All › Observer › via hops`. Always present, each crumb a target that
  /// pops to its level; the current level is the one that is not a link.
  private var breadcrumb: some View {
    HStack(spacing: 4) {
      crumb(L10n.Localizable.PacketScope.filterAll, isCurrent: focus == .all) { clearFocus() }
      if let observerID = focus.observerID {
        crumbSeparator
        crumb(observerName(observerID), isCurrent: focus.routeID == nil) { setFocus(.observer(observerID)) }
      }
      if focus.routeID != nil, let summary = focusSummary {
        crumbSeparator
        crumb(summary.title, isCurrent: true) {}
      }
    }
    .frame(minHeight: 44)
  }

  private var crumbSeparator: some View {
    Image(systemName: "chevron.right")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.tertiary)
      .accessibilityHidden(true)
  }

  private func crumb(_ title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.caption.weight(isCurrent ? .semibold : .regular))
        .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    // Inert rather than disabled: a disabled button fades, and the current
    // level is the one crumb that should read strongest.
    .allowsHitTesting(!isCurrent)
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }

  private var sortMenu: some View {
    Menu {
      Picker(L10n.Localizable.PacketScope.sort, selection: $sort) {
        ForEach(availableSorts, id: \.self) { option in
          Text(option.title).tag(option)
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "arrow.up.arrow.down")
        Text(sort.title)
          .lineLimit(1)
      }
      .font(.caption)
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(.rect)
    }
    .accessibilityLabel(L10n.Localizable.PacketScope.sort)
    .accessibilityValue(sort.title)
  }

  /// "Farthest" is offered only when something has a distance, so it is never
  /// a control that silently does nothing.
  private var availableSorts: [ObserverSort] {
    ObserverSort.allCases.filter { $0 != .farthest || coverage?.observerDistances.isEmpty == false }
  }

  /// What is focused, as the panel prints it: the route's hops as numbered
  /// pills (or the observer's name), its figures, a caveat only when there is
  /// one, and the controls — previous, next, the observers toggle, close.
  private var focusBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let focusSummary {
        if focusSummary.hopPills.isEmpty {
          Text(focusSummary.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        } else {
          ChipFlow(spacing: 4) {
            ForEach(focusSummary.hopPills) { pill in
              hopPill(pill)
            }
          }
        }
        if !focusSummary.figures.isEmpty {
          Text(focusSummary.figures.joined(separator: " · "))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if let caveat = focusSummary.caveat {
          Label(caveat, systemImage: "mappin.slash")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 0) {
        focusControl("chevron.left", label: L10n.Localizable.PacketScope.previousRoute) { step(by: -1) }
        focusControl("chevron.right", label: L10n.Localizable.PacketScope.nextRoute) { step(by: 1) }
        Spacer(minLength: 0)
        focusControl(
          showsObserverList ? "rectangle.bottomhalf.inset.filled" : "rectangle.inset.filled",
          label: showsObserverList ? L10n.Localizable.PacketScope.hideObservers : L10n.Localizable.PacketScope.showObservers
        ) {
          withAnimation(isReduceMotion ? nil : .default) { showsObserverList.toggle() }
        }
        focusControl("xmark", label: L10n.Localizable.PacketScope.showAll) { clearFocus() }
      }
      .accessibilityElement(children: .contain)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.bottom, 6)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }

  private func focusControl(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.body.weight(.medium))
        .frame(width: 44, height: 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  private func observerList(maxHeight: CGFloat) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(displayReceptions) { reception in
            observerRow(reception, onMap: true)
              .id(reception.observerID)
          }
          Text(L10n.Localizable.PacketScope.coverageFooter)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { observerListHeight = $0 }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(height: min(observerListHeight, maxHeight))
      // `initial: true`, so a request made while the list was hidden is
      // honoured the moment it comes back.
      .onChange(of: scrollRequest, initial: true) { _, request in
        guard let id = request.id else { return }
        withAnimation(isReduceMotion ? nil : .default) {
          proxy.scrollTo(id, anchor: request.anchor)
        }
      }
    }
  }

  // MARK: - List layout

  @ViewBuilder
  private var listContent: some View {
    if let errorText {
      Section {
        Label(errorText, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      }
      .themedRowBackground(theme)
    } else if let receptions, let summary {
      if receptions.isEmpty {
        // An empty first answer is not a verdict while the loop is still asking:
        // observers ingest over MQTT seconds behind the air, which is the whole
        // reason the loop exists. Only a stopped loop may state the negative
        // (review F087).
        Section {
          if isLive {
            HStack(spacing: 10) {
              ProgressView()
              Text(L10n.Localizable.PacketScope.loading)
                .foregroundStyle(.secondary)
            }
          } else {
            Label(
              L10n.Localizable.PacketScope.notObserved,
              systemImage: "waveform.slash"
            )
            .foregroundStyle(.secondary)
          }
        } footer: {
          if !isLive {
            Text(L10n.Localizable.PacketScope.notObservedFooter)
          }
        }
        .themedRowBackground(theme)
      } else {
        summarySection(summary)
        Section {
          ForEach(displayReceptions) { reception in
            observerRow(reception, onMap: false)
          }
        } header: {
          HStack {
            Text(L10n.Localizable.PacketScope.heardBy(summary.observerCount))
            Spacer()
            sortMenu
          }
        } footer: {
          VStack(alignment: .leading, spacing: 4) {
            Text(L10n.Localizable.PacketScope.coverageFooter)
            if message.sendCount > 1 {
              Text(L10n.Localizable.PacketScope.retriedFooter(message.sendCount))
            }
          }
        }
        .themedRowBackground(theme)
      }
    } else {
      Section {
        HStack(spacing: 10) {
          ProgressView()
          Text(L10n.Localizable.PacketScope.loading)
            .foregroundStyle(.secondary)
        }
      }
      .themedRowBackground(theme)
    }
  }

  /// What the mesh as a whole did with this packet, above the per-observer detail.
  private func summarySection(_ summary: PacketScopeSummary) -> some View {
    Section {
      if let best = summary.bestSNR {
        LabeledContent(L10n.Localizable.PacketScope.bestSignal, value: PacketScopeCoverageBuilder.decibels(best))
      }
      if let hops = summary.shortestHopCount {
        LabeledContent(L10n.Localizable.PacketScope.shortestRoute, value: Self.routeLength(hops))
      }
      // Only meaningful with two or more timestamped receptions; the model returns
      // nil rather than a misleading zero.
      if let spread = summary.propagationSpread {
        LabeledContent(L10n.Localizable.PacketScope.propagation, value: Self.spread(spread))
      }
      // Receptions exceed observers whenever one observer heard the packet by more
      // than one route — that ratio is a redundancy signal worth showing plainly.
      if summary.receptionCount > summary.observerCount {
        LabeledContent(
          L10n.Localizable.PacketScope.receptions,
          value: "\(summary.receptionCount)"
        )
      }
    }
    .themedRowBackground(theme)
  }

  // MARK: - Rows

  /// One observer: signal bars, name, when it heard the packet relative to the
  /// first observer, and a line of chips. Tapping focuses it, which opens its
  /// route ladder and promotes its routes on the map.
  private func observerRow(_ reception: PacketScopeReception, onMap: Bool) -> some View {
    let quality = SNRQuality(snr: reception.bestSNR)
    let isSelected = focus.observerID == reception.observerID
    return VStack(alignment: .leading, spacing: 4) {
      // A tap target rather than a `Button`: a button's label does not receive
      // taps that land on a scroll view nested inside it.
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "cellularbars", variableValue: quality.barLevel)
          .foregroundStyle(quality.color)
          .font(.title3)
          .frame(width: 24)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(reception.observerName)
              .font(.subheadline.weight(.medium))
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            if isNew(reception.observerID) {
              chip(L10n.Localizable.PacketScope.new, tint: .accentColor)
            }
            Spacer(minLength: 4)
            if let offset = heardOffset(reception) {
              Text(offset)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.tertiary)
              .rotationEffect(.degrees(isSelected ? 90 : 0))
          }
          chipLine(reception, onMap: onMap)
        }
      }
      .contentShape(.rect)
      .onTapGesture { toggle(observer: reception.observerID) }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(reception.observerName)
      .accessibilityValue(accessibilityValue(for: reception, quality: quality, isExpanded: isSelected))
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityHint(L10n.Localizable.PacketScope.hintObserver)
      .accessibilityAction { toggle(observer: reception.observerID) }

      if isSelected {
        routeLadder(reception, onMap: onMap)
      }
    }
    .padding(.vertical, 4)
  }

  /// The numbers that matter, as chips that wrap onto a second line rather
  /// than scrolling or truncating.
  private func chipLine(_ reception: PacketScopeReception, onMap: Bool) -> some View {
    ChipFlow(spacing: 6) {
      if let snr = reception.bestSNR {
        Text(PacketScopeCoverageBuilder.decibels(snr))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      if let hops = reception.shortestHopCount {
        chip(Self.routeLength(hops))
      }
      if reception.receptionCount > 1 {
        chip(L10n.Localizable.PacketScope.timesHeard(reception.receptionCount))
      }
      if onMap, rosterLoaded, !isLocated(reception.observerID) {
        chip(L10n.Localizable.PacketScope.observerNotOnMap, systemImage: "mappin.slash")
      }
      if onMap, let distance = coverage?.observerDistances[reception.observerID] {
        chip(Self.kilometres(distance))
      }
    }
  }

  /// The observer's routes, strongest first — in the frozen order while one is
  /// held. Each row is a two-line target that states before the tap whether
  /// the map can draw it.
  private func routeLadder(_ reception: PacketScopeReception, onMap: Bool) -> some View {
    let ranked = ladderRoutes(for: reception)
    return VStack(alignment: .leading, spacing: 2) {
      if let rssi = reception.bestRSSI {
        Text(L10n.Localizable.PacketScope.rssiBest(rssi.formatted()))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
          .padding(.leading, 6)
      }
      ForEach(ranked, id: \.id) { route in
        routeRow(
          route,
          observerID: reception.observerID,
          isBest: route.id == ranked.first?.id && route.bestSNR != nil,
          onMap: onMap
        )
        .id(PacketScopeCoverageBuilder.routeID(observerID: reception.observerID, hops: route.hops))
      }
    }
    .padding(.leading, 34)
    .padding(.top, 2)
  }

  private func routeRow(_ route: PacketScopeReception.Route, observerID: String, isBest: Bool, onMap: Bool) -> some View {
    let routeID = PacketScopeCoverageBuilder.routeID(observerID: observerID, hops: route.hops)
    let isSelected = focus.routeID == routeID
    let built = coverage?.routesByID[routeID]
    let isDrawable = coverage?.drawableRouteIDs.contains(routeID) ?? false
    let names = hopNamesByRoute[routeID] ?? route.hops
    let placed = Set(built?.placedHops.map(\.position) ?? [])
    let pills = names.enumerated().map { index, name in
      HopPill(position: index + 1, name: name, isPlaced: placed.contains(index + 1))
    }
    let quality = SNRQuality(snr: route.bestSNR)
    return HStack(alignment: .top, spacing: 8) {
      // Selection is never colour alone: a leading bar and weight carry it.
      RoundedRectangle(cornerRadius: 1.5)
        .fill(isSelected ? Color.accentColor : Color.clear)
        .frame(width: 3)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .top, spacing: 6) {
          if onMap {
            // The consequence, before the tap.
            Image(systemName: isDrawable ? "mappin.and.ellipse" : "mappin.slash")
              .font(.caption)
              .foregroundStyle(isDrawable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
              .frame(width: drawabilityGlyphWidth)
              .padding(.top, 2)
          }
          if route.hops.isEmpty {
            Text(L10n.Localizable.PacketScope.heardDirectly)
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            ChipFlow(spacing: 4) {
              ForEach(pills) { pill in
                hopPill(pill)
              }
            }
          }
        }
        HStack(spacing: 6) {
          if isBest {
            chip(L10n.Localizable.PacketScope.bestRoute, tint: .yellow)
          }
          if let snr = route.bestSNR {
            Text(PacketScopeCoverageBuilder.decibels(snr))
              .font(.caption.monospacedDigit().weight(isSelected ? .semibold : .regular))
              .foregroundStyle(quality.color)
          }
          chip(Self.routeLength(route.hops.count))
          if onMap, let tail = built?.unplacedTailCount, tail > 0 {
            chip(PacketScopeFocusLogic.tailUnknown(tail), systemImage: "mappin.slash")
          }
        }
      }
    }
    .frame(minHeight: 44)
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .background(
      isSelected ? Color.accentColor.opacity(colorSchemeContrast == .increased ? 0.3 : 0.12) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .contentShape(.rect)
    .onTapGesture { toggle(route: routeID, observerID: observerID) }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { toggle(route: routeID, observerID: observerID) }
    .accessibilityLabel(
      route.hops.isEmpty
        ? L10n.Localizable.PacketScope.heardDirectly
        : L10n.Localizable.PacketScope.via(names.joined(separator: ", "))
    )
    .accessibilityValue([
      isBest ? L10n.Localizable.PacketScope.bestRoute : nil,
      route.bestSNR != nil ? quality.localizedLabel : nil,
      route.bestSNR.map(PacketScopeCoverageBuilder.decibels),
      onMap && !isDrawable ? L10n.Localizable.PacketScope.a11yNotDrawable : nil,
    ].compactMap(\.self).joined(separator: ", "))
    .accessibilityHint(L10n.Localizable.PacketScope.hintRoute)
  }

  /// A hop as the panel names it: its true path position, its name, and a
  /// mark when the builder could not place it.
  private func hopPill(_ pill: HopPill) -> some View {
    HStack(spacing: 3) {
      Text("\(pill.position)")
        .font(.caption2.weight(.bold))
        .foregroundStyle(pill.isPlaced ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
      Text(pill.name)
        .font(.caption2)
        .lineLimit(1)
        .truncationMode(.middle)
      if !pill.isPlaced {
        Image(systemName: "mappin.slash")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Color.secondary.opacity(pill.isPlaced ? 0.12 : 0.05), in: Capsule())
    .overlay {
      if !pill.isPlaced {
        Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
          .foregroundStyle(.tertiary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(pill.isPlaced
      ? "\(pill.position) \(pill.name)"
      : "\(pill.position) \(pill.name), \(L10n.Localizable.PacketScope.hopNotOnMap)")
  }

  private func chip(_ text: String, systemImage: String? = nil, tint: Color = .secondary) -> some View {
    HStack(spacing: 3) {
      if let systemImage {
        Image(systemName: systemImage)
      }
      Text(text)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .font(.caption2)
    .foregroundStyle(tint)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
  }

  // MARK: - Text

  /// "best 12.2 dB · shortest 2 hops · farthest 23 mi · 4 heard directly ·
  /// still arriving". Each figure is its own extreme — the best signal and
  /// the shortest route need not be one route — and the farthest is marked
  /// as a lower bound whenever an observer that heard the packet has no
  /// location to measure.
  private var summaryLine: String? {
    guard let summary, summary.observerCount > 0 else { return nil }
    var parts: [String] = []
    if let best = summary.bestSNR {
      parts.append(L10n.Localizable.PacketScope.best(PacketScopeCoverageBuilder.decibels(best)))
    }
    if let hops = summary.shortestHopCount {
      if hops == 0 {
        // One clause, not two. "heard directly" and "N heard directly" always
        // fired together — a shortest route of zero hops *is* a direct
        // reception — so the line said the same thing twice. The count is the
        // one that carries more, and it is only worth printing past one.
        let direct = (receptions ?? []).count { $0.routes.contains { $0.hops.isEmpty } }
        parts.append(direct > 1
          ? L10n.Localizable.PacketScope.directCount(direct)
          : L10n.Localizable.PacketScope.heardDirectlyInline)
      } else {
        parts.append(L10n.Localizable.PacketScope.shortest(Self.routeLength(hops)))
      }
    }
    if let coverage, let farthest = coverage.observerDistances.values.max() {
      let anyUnlocated = (receptions ?? []).contains { coverage.observerCoordinates[$0.observerID] == nil }
      let figure = Self.kilometres(farthest)
      parts.append(L10n.Localizable.PacketScope.farthest(
        anyUnlocated ? L10n.Localizable.PacketScope.lowerBound(figure) : figure
      ))
    }
    if isLive {
      parts.append(L10n.Localizable.PacketScope.stillArriving)
    } else if loopOutcome == .failed {
      // The loop stopped because the server stopped answering, not because
      // coverage stopped changing. Saying nothing beats saying "settled".
    } else if let spread = summary.propagationSpread {
      parts.append(L10n.Localizable.PacketScope.settledIn(
        spread.formatted(.number.precision(.fractionLength(0...1)))
      ))
    } else {
      parts.append(L10n.Localizable.PacketScope.settled)
    }
    return parts.joined(separator: " · ")
  }

  /// The sentence VoiceOver reads for the map: the focus's, or the headline.
  private var mapSummary: String {
    if let focusSummary { return focusSummary.announcement }
    return [L10n.Localizable.PacketScope.heardBy(summary?.observerCount ?? 0), summaryLine]
      .compactMap(\.self).joined(separator: ". ")
  }

  /// Seconds after the first observer, so the panel shows propagation rather
  /// than a wall-clock time that reads the same on every row. Nil for the
  /// first observer itself, and when the observer carries no timestamp.
  private func heardOffset(_ reception: PacketScopeReception) -> String? {
    guard let first = summary?.firstHeard, let heard = reception.firstHeard else { return nil }
    let offset = heard.timeIntervalSince(first)
    guard offset >= 0.05 else { return nil }
    return L10n.Localizable.PacketScope.heardOffset(offset.formatted(.number.precision(.fractionLength(0...1))))
  }

  private func accessibilityValue(for reception: PacketScopeReception, quality: SNRQuality, isExpanded: Bool) -> String {
    [
      quality.localizedLabel,
      reception.bestSNR.map(PacketScopeCoverageBuilder.decibels),
      reception.shortestHopCount.map(Self.routeLength),
      reception.receptionCount > 1 ? L10n.Localizable.PacketScope.timesHeard(reception.receptionCount) : nil,
      isNew(reception.observerID) ? L10n.Localizable.PacketScope.new : nil,
      isExpanded ? L10n.Localizable.PacketScope.a11yExpanded : L10n.Localizable.PacketScope.a11yCollapsed,
    ].compactMap(\.self).joined(separator: ", ")
  }

  private static func routeLength(_ hops: Int) -> String {
    PacketScopeFocusLogic.routeLength(hops)
  }

  private static func spread(_ seconds: TimeInterval) -> String {
    L10n.Localizable.PacketScope.spreadSeconds(
      seconds.formatted(.number.precision(.fractionLength(0...1)))
    )
  }

  private static func kilometres(_ metres: CLLocationDistance) -> String {
    Measurement(value: metres, unit: UnitLength.meters)
      .formatted(.measurement(width: .abbreviated, usage: .road))
  }

  private func observerName(_ observerID: String) -> String {
    receptions?.first { $0.observerID == observerID }?.observerName ?? observerID
  }

  /// Names the hops the way the rest of the app does.
  ///
  /// The local resolver is tried first — it is free, works offline, and matches
  /// what the path screen and repeats map call the same repeater. A name it is not
  /// certain of is marked with `~`, mirroring the app's fallback convention rather
  /// than presenting a guess as fact. Only when the phone has never heard the
  /// repeater at all does the short wire hash stand in.
  private func hopNames(for route: PacketScopeReception.Route) -> [String] {
    route.hops.enumerated().map { index, hop in
      guard let hashBytes = Data(hexString: hop) else { return hop }
      let resolution = pathViewModel.repeaterResolution(
        for: hashBytes,
        userLocation: userLocation
      )
      switch resolution.matchKind {
      case .exact:
        return resolution.displayName
      case .fallback:
        return "~\(resolution.displayName)"
      case .unresolved:
        // The server may know a repeater this phone has never heard. Its resolved
        // public key is exact where a short hash can collide, so prefer its first
        // 4 hex over the wire hash when the server had an answer for this slot —
        // it often does not (roughly a third of slots come back null).
        if index < route.resolvedHops.count,
           let pubkey = route.resolvedHops[index] {
          return String(pubkey.prefix(4)).uppercased()
        }
        return hop
      }
    }
  }

  private func isLocated(_ observerID: String) -> Bool {
    let key = observerID.lowercased()
    return observers.first { $0.id == key }?.coordinate != nil
  }

  private func isNew(_ observerID: String) -> Bool {
    _ = newChipTick
    guard let arrived = observerArrivals[observerID] else { return false }
    return Date().timeIntervalSince(arrived) < Self.newChipLifetime
  }

  // MARK: - Order

  private func sortedReceptions(by sort: ObserverSort) -> [PacketScopeReception] {
    guard let receptions else { return [] }
    switch sort {
    case .strongest:
      // The fold's order: signal, then reception count, then id.
      return receptions
    case .fewestHops:
      return receptions.sorted { lhs, rhs in
        let l = lhs.shortestHopCount ?? Int.max
        let r = rhs.shortestHopCount ?? Int.max
        if l != r { return l < r }
        if lhs.bestSNR != rhs.bestSNR { return (lhs.bestSNR ?? -.infinity) > (rhs.bestSNR ?? -.infinity) }
        return lhs.observerID < rhs.observerID
      }
    case .firstHeard:
      return receptions.sorted { lhs, rhs in
        let l = lhs.firstHeard ?? .distantFuture
        let r = rhs.firstHeard ?? .distantFuture
        if l != r { return l < r }
        return lhs.observerID < rhs.observerID
      }
    case .farthest:
      let distances = coverage?.observerDistances ?? [:]
      return receptions.sorted { lhs, rhs in
        let l = distances[lhs.observerID] ?? -1
        let r = distances[rhs.observerID] ?? -1
        if l != r { return l > r }
        return lhs.observerID < rhs.observerID
      }
    }
  }

  /// The live sort, or — while an order is frozen — that order with observers
  /// heard since appended at the tail, so the `New` chip is where the eye
  /// expects and nothing already on screen moves.
  private func applySort() {
    let live = sortedReceptions(by: sort)
    guard let frozenOrder else {
      displayReceptions = live
      return
    }
    let byID = Dictionary(live.map { ($0.observerID, $0) }, uniquingKeysWith: { first, _ in first })
    let frozen = frozenOrder.observerIDs.compactMap { byID[$0] }
    let known = Set(frozenOrder.observerIDs)
    displayReceptions = frozen + live.filter { !known.contains($0.observerID) }
  }

  private func captureOrder() -> PacketScopeFrozenOrder {
    PacketScopeFrozenOrder(
      observerIDs: displayReceptions.map(\.observerID),
      routeIDsByObserver: Dictionary(displayReceptions.map { reception in
        (reception.observerID, rankedRouteIDs(for: reception))
      }, uniquingKeysWith: { first, _ in first })
    )
  }

  private func rankedRouteIDs(for reception: PacketScopeReception) -> [String] {
    PacketScopeCoverageBuilder.rankedRoutes(reception.routes).map {
      PacketScopeCoverageBuilder.routeID(observerID: reception.observerID, hops: $0.hops)
    }
  }

  /// The ladder in the frozen order while one is held, else strongest first.
  private func ladderRoutes(for reception: PacketScopeReception) -> [PacketScopeReception.Route] {
    let ranked = PacketScopeCoverageBuilder.rankedRoutes(reception.routes)
    guard let frozenIDs = frozenOrder?.routeIDsByObserver[reception.observerID] else { return ranked }
    let byID = Dictionary(ranked.map { (PacketScopeCoverageBuilder.routeID(observerID: reception.observerID, hops: $0.hops), $0) },
                          uniquingKeysWith: { first, _ in first })
    let frozen = frozenIDs.compactMap { byID[$0] }
    let known = Set(frozenIDs)
    return frozen + ranked.filter { !known.contains(PacketScopeCoverageBuilder.routeID(observerID: reception.observerID, hops: $0.hops)) }
  }

  /// Scrolls the focused row into view: a focused route centred (its observer
  /// row and sibling routes around it), a focused observer to the top.
  private func requestScroll(for focus: PacketScopeFocus) {
    if let routeID = focus.routeID {
      scrollRequest = ScrollRequest(id: routeID, anchor: .center, version: scrollRequest.version + 1)
    } else if let observerID = focus.observerID {
      scrollRequest = ScrollRequest(id: observerID, anchor: .top, version: scrollRequest.version + 1)
    }
  }

  // MARK: - Focus

  private func toggle(observer observerID: String) {
    switch focus {
    case .observer(observerID):
      clearFocus()
    default:
      setFocus(.observer(observerID))
    }
  }

  private func toggle(route routeID: String, observerID: String) {
    if focus.routeID == routeID {
      // Symmetric with the observer row: the focused route pops to its observer.
      setFocus(.observer(observerID))
    } else {
      setFocus(.route(observerID: observerID, routeID: routeID))
    }
  }

  /// One level out. A stray tap on the map while panning one-handed costs
  /// one recoverable step, never the whole selection.
  private func popFocus() {
    guard focus != .all else { return }
    setFocus(focus.popped())
  }

  private func clearFocus() {
    guard focus != .all else { return }
    setFocus(.all)
  }

  private func step(by delta: Int) {
    let order = frozenOrder ?? captureOrder()
    guard let next = PacketScopeFocusLogic.stepped(focus, by: delta, order: order) else { return }
    setFocus(next, isStep: true)
    stepTick += 1
  }

  /// A focus the user chose. Captures the order on entering a focus,
  /// recomputes the geometry and the bar, moves the camera only when there
  /// is something to frame, scrolls the row into view, and tells VoiceOver
  /// what changed — or that nothing could.
  private func setFocus(_ next: PacketScopeFocus, isStep: Bool = false) {
    if next != .all {
      hasSeenFocusHint = true
      if frozenOrder == nil {
        frozenOrder = captureOrder()
      }
    }
    applyFocus(next, animated: true)
    if next == .all {
      applySort()
    }
    requestScroll(for: next)
    if !isStep { selectionTick += 1 }
    announce(focusSummary?.announcement ?? L10n.Localizable.PacketScope.a11yShowingAll)
  }

  /// Recomputes what the focus draws and prints, from the current coverage.
  /// Every writer of `focus` comes through here — the user's taps and the
  /// poll reconcile alike — so the resets that belong to leaving a focus
  /// (the frozen order, the observers toggle) cannot be skipped by either.
  private func applyFocus(_ next: PacketScopeFocus, animated: Bool) {
    if next == .all {
      frozenOrder = nil
      showsObserverList = true
    }
    guard let coverage else {
      focus = next
      focusGeometry = nil
      focusSummary = nil
      locatedNodes = []
      cameraFocus = nil
      return
    }
    let geometry = PacketScopeCoverageBuilder.geometry(for: next, in: coverage)
    let summary = makeFocusSummary(next, geometry: geometry, coverage: coverage)
    withAnimation(animated && !isReduceMotion ? .default : nil) {
      focus = next
      focusGeometry = geometry
      focusSummary = summary
      locatedNodes = geometry.nodes
    }
    if next == .all {
      cameraFocus = nil
    } else if geometry.isDrawable, geometry.cameraCoordinates.count >= 2 {
      // The id is a canonical digest of the framed geometry, so a poll that
      // changes nothing about this focus does not move the camera, and one
      // that finally places a hop does.
      cameraFocus = MessagePathMapCanvas.CameraFocus(
        id: PacketScopeFocusLogic.cameraFocusID(for: next, coordinates: geometry.cameraCoordinates),
        coordinates: geometry.cameraCoordinates
      )
    }
    // An undrawable target leaves the camera exactly where it was.
  }

  private func announce(_ text: String) {
    AccessibilityNotification.Announcement(text).post()
  }

  /// What the focus bar prints, computed once per focus or data change.
  private func makeFocusSummary(
    _ focus: PacketScopeFocus,
    geometry: PacketScopeFocusGeometry,
    coverage: PacketScopeCoverageMap
  ) -> FocusSummary? {
    switch focus {
    case .all:
      return nil

    case let .observer(observerID):
      let name = observerName(observerID)
      let reception = receptions?.first { $0.observerID == observerID }
      let routeCount = reception?.routes.count ?? 0
      var figures: [String] = []
      if routeCount > 0 {
        figures.append(PacketScopeFocusLogic.routeCount(routeCount))
      }
      if let best = reception?.bestSNR {
        figures.append(L10n.Localizable.PacketScope.best(PacketScopeCoverageBuilder.decibels(best)))
      }
      if let distance = coverage.observerDistances[observerID] {
        figures.append(Self.kilometres(distance))
      }
      let announcement: String = if !geometry.isDrawable {
        L10n.Localizable.PacketScope.notOnMapObserver
      } else if routeCount == 1 {
        L10n.Localizable.PacketScope.a11yShowingObserverOne(name)
      } else {
        L10n.Localizable.PacketScope.a11yShowingObserver(routeCount, name)
      }
      return FocusSummary(
        title: name,
        hopPills: [],
        figures: figures,
        caveat: geometry.isDrawable ? nil : L10n.Localizable.PacketScope.notOnMapObserver,
        announcement: announcement
      )

    case let .route(observerID, routeID):
      let name = observerName(observerID)
      let reception = receptions?.first { $0.observerID == observerID }
      let route = reception?.routes.first {
        PacketScopeCoverageBuilder.routeID(observerID: observerID, hops: $0.hops) == routeID
      }
      let built = coverage.routesByID[routeID]
      let names = hopNamesByRoute[routeID] ?? route?.hops ?? []
      let placed = Set(built?.placedHops.map(\.position) ?? [])
      let pills = names.enumerated().map { index, hopName in
        HopPill(position: index + 1, name: hopName, isPlaced: placed.contains(index + 1))
      }
      var figures: [String] = []
      if let snr = route?.bestSNR {
        figures.append(PacketScopeCoverageBuilder.decibels(snr))
      }
      if let route {
        figures.append(Self.routeLength(route.hops.count))
      }
      if let built, geometry.isDrawable {
        let metres = built.soloSegments.reduce(0.0) { $0 + PacketScopeCoverageBuilder.polylineLength($1.coordinates) }
        if metres > 0 {
          let figure = Self.kilometres(metres)
          figures.append(L10n.Localizable.PacketScope.drawn(
            built.isComplete ? figure : L10n.Localizable.PacketScope.lowerBound(figure)
          ))
        }
      }
      if let hops = route?.hops {
        let alsoHeardBy = (receptions ?? []).count { $0.routes.contains { $0.hops == hops } }
        if alsoHeardBy > 1 {
          figures.append(L10n.Localizable.PacketScope.alsoHeardBy(alsoHeardBy))
        }
      }
      if let reception, let offset = heardOffset(reception) {
        figures.append(offset)
      }
      var caveat: String?
      if !geometry.isDrawable {
        caveat = L10n.Localizable.PacketScope.notOnMapRoute
      } else if let built {
        let twins = (coverage.routeIDsByObserver[observerID] ?? [])
          .compactMap { coverage.routesByID[$0] }
          .count { $0.isDrawable && $0.drawnGeometryKey == built.drawnGeometryKey }
        if twins > 1 {
          caveat = L10n.Localizable.PacketScope.sameDrawnPath(twins)
        }
      }
      let title = names.isEmpty
        ? L10n.Localizable.PacketScope.heardDirectly
        : L10n.Localizable.PacketScope.via(names.joined(separator: " › "))
      let announcement: String = if !geometry.isDrawable {
        L10n.Localizable.PacketScope.notOnMapRoute
      } else if names.isEmpty {
        L10n.Localizable.PacketScope.a11yShowingDirect(name)
      } else {
        L10n.Localizable.PacketScope.a11yShowingRoute(name, names.joined(separator: ", "))
      }
      return FocusSummary(
        title: title,
        hopPills: pills,
        figures: figures,
        caveat: caveat,
        announcement: announcement
      )
    }
  }

  // MARK: - Map geometry

  /// Two overlays, constant paint, declared in every state so a focus change
  /// diffs feature lists only. `scope-links` is what the focus draws at full
  /// paint — everything, with nothing focused. `scope-links-context` is the
  /// rest, faint and casing-less, in observer focus; empty in route focus,
  /// where the request was to filter. A link mid-arrival stays at full paint
  /// whatever the focus, so the row's `New` chip never advertises something
  /// the map hid. Weights are per overlay, against its own busiest link.
  private var overlays: [MapOverlay] {
    guard let coverage, let geometry = focusGeometry else { return [] }
    let isRouteFocus = focus.routeID != nil
    var focused: [PacketScopeCoverageLink] = []
    var context: [PacketScopeCoverageLink] = []
    for link in coverage.links {
      if geometry.focusLinkIDs.contains(link.id) || arrivalProgress["link:\(link.id)"] != nil {
        focused.append(link)
      } else if !isRouteFocus {
        context.append(link)
      }
    }
    func features(_ links: [PacketScopeCoverageLink]) -> [MapOverlay.Feature] {
      let heaviest = Double(max(links.map(\.routeCount).max() ?? 1, 1))
      return links.map { link in
        let arrival = arrivalProgress["link:\(link.id)"].map(Self.easeOut) ?? 1
        return MapOverlay.Feature(
          id: link.id,
          geometry: .polyline([link.from, link.to]),
          weight: Double(link.routeCount) / heaviest * arrival
        )
      }
    }
    return [
      MapOverlay(id: "scope-links-context", features: features(context), paint: Self.contextLinkPaint),
      MapOverlay(id: "scope-links", features: features(focused), paint: Self.focusLinkPaint),
    ]
  }

  /// The focus's lines, each cut to how far it has arrived. An arriving leg
  /// the focus would exclude is still drawn for its ramp.
  private var visibleLines: [MapLine] {
    guard let geometry = focusGeometry else { return [] }
    var lines = geometry.lines.flatMap { line -> [MapLine] in
      guard let key = geometry.arrivalKeyByLineID[line.id],
            let progress = arrivalProgress[key] else { return [line] }
      return PacketScopeCoverageBuilder.truncated([line], toFraction: Self.easeOut(progress))
    }
    if focus != .all, let coverage {
      for leg in coverage.observerLegs where leg.id != focus.observerID {
        guard let progress = arrivalProgress["leg:\(leg.id)"] else { continue }
        lines += PacketScopeCoverageBuilder.truncated([leg.line], toFraction: Self.easeOut(progress))
      }
    }
    return lines
  }

  /// Fast out of the start, settling into the observer.
  private static func easeOut(_ t: Double) -> Double {
    let clamped = min(max(t, 0), 1)
    return 1 - (1 - clamped) * (1 - clamped)
  }

  /// The "where did it start" reference for an outgoing message — the send-time
  /// stamp when the message carries one, else the live best guess. Read live so
  /// a fresh fix moves the unstamped origin, as on the repeats map.
  private var originReference: CLLocation? {
    MessagePathMapView.receiverReference(
      for: .message(message),
      userLocation: appState.bestAvailableLocation
    )
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

  /// Rebuilds the map from the current receptions and roster. Links and legs
  /// the map has not shown before arrive animated when `animated`, and their
  /// observers get a "New" chip; a rebuild for any other reason (a fix landing,
  /// contacts loading, the roster arriving) swaps geometry in place, since
  /// nothing new was heard. The focus is reconciled against what survived.
  private func rebuildCoverage(animated: Bool) {
    guard let receptions else { return }
    let built = PacketScopeCoverageBuilder.build(
      message: message,
      receptions: receptions,
      observers: observers,
      contacts: pathViewModel.contacts,
      repeaters: pathViewModel.repeaters,
      discoveredRepeaters: pathViewModel.discoveredRepeaters,
      userLocation: originReference,
      originName: appState.connectedDevice?.nodeName ?? L10n.Chats.Chats.Path.Receiver.you
    )
    coverage = built

    var names: [String: [String]] = [:]
    for reception in receptions {
      for route in reception.routes {
        names[PacketScopeCoverageBuilder.routeID(observerID: reception.observerID, hops: route.hops)] = hopNames(for: route)
      }
    }
    hopNamesByRoute = names

    let elementIDs = Set(built.links.map { "link:\($0.id)" } + built.observerLegs.map { "leg:\($0.id)" })
    let observerIDs = Set(receptions.map(\.observerID))
    let newElements = elementIDs.subtracting(seenElementIDs)
    let newObservers = observerIDs.subtracting(seenObserverIDs)
    seenElementIDs.formUnion(elementIDs)
    seenObserverIDs.formUnion(observerIDs)
    // An element a refresh no longer returns has nothing left to grow toward.
    arrivalProgress = arrivalProgress.filter { elementIDs.contains($0.key) }

    if animated {
      if !newObservers.isEmpty {
        let now = Date()
        for id in newObservers {
          observerArrivals[id] = now
        }
        Task {
          try? await Task.sleep(for: .seconds(Self.newChipLifetime + 0.5))
          newChipTick += 1
        }
      }
      if !isReduceMotion, !newElements.isEmpty {
        for id in newElements {
          arrivalProgress[id] = 0
        }
      }
    }
    if !arrivalProgress.isEmpty {
      startDrawTaskIfNeeded()
    }

    applySort()
    // The frozen order learns of observers heard since the freeze, at the
    // tail, so the steppers can reach them.
    if let order = frozenOrder {
      frozenOrder = displayReceptions.reduce(order) { partial, reception in
        partial.appending(observerID: reception.observerID, routeIDs: rankedRouteIDs(for: reception))
      }
    }
    let previous = focus
    let reconciled = PacketScopeFocusLogic.reconciled(
      focus,
      routeIDs: Set(built.routesByID.keys),
      observerIDs: observerIDs
    )
    applyFocus(reconciled, animated: reconciled != previous)
    if reconciled != previous {
      if reconciled == .all { applySort() }
      announce(focusSummary?.announcement ?? L10n.Localizable.PacketScope.a11yShowingAll)
    }
  }

  /// One frame loop for every element mid-arrival. Reads `arrivalProgress`
  /// each frame, so arrivals from a later poll join a loop already running
  /// rather than starting a second one. Exits when nothing is left to draw;
  /// the screen closing cancels it.
  private func startDrawTaskIfNeeded() {
    guard drawTask == nil else { return }
    drawTask = Task { @MainActor in
      var last = ContinuousClock.now
      while !Task.isCancelled, !arrivalProgress.isEmpty {
        guard await (try? Task.sleep(for: Self.arrivalFrameInterval)) != nil else { break }
        let now = ContinuousClock.now
        let step = Self.seconds(last.duration(to: now)) / Self.arrivalDrawDuration
        last = now
        for (id, progress) in arrivalProgress {
          let next = progress + step
          arrivalProgress[id] = next >= 1 ? nil : next
        }
      }
      drawTask = nil
    }
  }

  private static func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }

  // MARK: - Fetching

  private func refresh(isManual: Bool = false) async {
    guard let hash = message.packetContentHash, !isRefreshing else { return }
    isRefreshing = true
    if isManual { isManualRefresh = true }
    defer {
      isRefreshing = false
      if isManual { isManualRefresh = false }
    }
    do {
      let results = try await service.observations(for: [hash])
      let observations = results[hash] ?? []
      receptions = PacketScopeFold.receptions(from: observations)
      summary = PacketScopeFold.summary(from: observations)
      errorText = nil
      consecutiveFailures = 0
      rebuildCoverage(animated: hasLoadedOnce)
      hasLoadedOnce = true
    } catch {
      consecutiveFailures += 1
      // A failed refresh never blanks data already on screen.
      if receptions == nil {
        errorText = error.localizedDescription
      }
    }
  }

  /// The roster is a courtesy, not a requirement: without it the rows still
  /// name every observer and the map still draws the repeaters. So a failure
  /// here is not an error state.
  private func loadObservers() async {
    guard let roster = try? await service.observers() else { return }
    observers = roster
    rosterLoaded = true
    rebuildCoverage(animated: false)
  }

  /// One fetch always; then, while the message is fresh enough that observers may
  /// still be ingesting it, keep polling so coverage builds in front of the reader.
  ///
  /// Stops early on three unchanged polls — coverage that has settled will not
  /// un-settle, and the alternative is 30 requests for a screen left open. Also
  /// pauses while the app is backgrounded: nobody is reading, and a poll there
  /// spends radio for a screen no one sees. Cancellation (the screen closing)
  /// exits through the sleep.
  private func liveRefreshLoop() async {
    isLive = isWithinLiveWindow
    loopOutcome = .running
    defer { isLive = false }
    await refresh()
    var quietPolls = 0
    var lastReceptionCount = summary?.receptionCount ?? 0

    while isWithinLiveWindow,
          quietPolls < Self.quietPollsBeforeStopping,
          consecutiveFailures < Self.failuresBeforeStopping {
      // Back off on failure rather than retrying at full cadence into whatever is
      // going wrong; a run of successes polls at the normal interval.
      let interval = Self.pollInterval * (1 << consecutiveFailures)
      do { try await Task.sleep(for: interval) } catch { return }
      guard isSceneActive else { continue }
      await refresh()

      let current = summary?.receptionCount ?? 0
      quietPolls = current == lastReceptionCount ? quietPolls + 1 : 0
      lastReceptionCount = current
    }
    // Recorded in the order the loop's own condition checks them: a run of
    // failures is a failure even if the window closed on the same tick.
    if consecutiveFailures >= Self.failuresBeforeStopping {
      loopOutcome = .failed
    } else if quietPolls >= Self.quietPollsBeforeStopping {
      loopOutcome = .settled
    } else {
      loopOutcome = .windowClosed
    }
  }

  /// Whether the message is new enough that observers may still be ingesting it.
  ///
  /// Clamped at both ends: `createdAt` is decoded unvalidated from backups, and a
  /// timestamp in the future would otherwise keep this loop polling for as long as
  /// the screen stayed open.
  private var isWithinLiveWindow: Bool {
    let age = Date().timeIntervalSince(message.createdAt)
    return age >= 0 && age < Self.livePollWindow
  }
}

/// How `liveRefreshLoop` ended. Only `.settled` and `.windowClosed` earn the
/// word "settled" in the headline.
private enum LoopOutcome {
  case running
  case settled
  case windowClosed
  case failed
}

/// What the focus bar prints for one focus.
private struct FocusSummary {
  let title: String
  let hopPills: [HopPill]
  let figures: [String]
  let caveat: String?
  let announcement: String
}

private struct HopPill: Identifiable {
  let position: Int
  let name: String
  let isPlaced: Bool
  var id: Int {
    position
  }
}

private struct ScrollRequest: Equatable {
  let id: String?
  let anchor: UnitPoint
  let version: Int
}

/// A left-to-right flow that wraps onto new lines, for a row's chips: short
/// labels that must all stay visible without scrolling or truncating. Children
/// are measured and placed against the container's width, so a chip wider
/// than the panel is clamped to it rather than drawn past its edge.
private struct ChipFlow: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    let childProposal = ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(childProposal)
      let width = min(size.width, maxWidth)
      if x > 0, x + width > maxWidth {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += width + spacing
      rowHeight = max(rowHeight, size.height)
      widest = max(widest, x - spacing)
    }
    let width = proposal.width.map { $0.isFinite ? $0 : widest } ?? widest
    return CGSize(width: width, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
    let childProposal = ProposedViewSize(width: bounds.width, height: nil)
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(childProposal)
      let width = min(size.width, bounds.width)
      if x > bounds.minX, x + width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(
        at: CGPoint(x: x, y: y),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: width, height: size.height)
      )
      x += width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

private enum ObserverSort: CaseIterable {
  case strongest
  case fewestHops
  case firstHeard
  case farthest

  var title: String {
    switch self {
    case .strongest: L10n.Localizable.PacketScope.sortStrongest
    case .fewestHops: L10n.Localizable.PacketScope.sortFewestHops
    case .firstHeard: L10n.Localizable.PacketScope.sortFirstHeard
    case .farthest: L10n.Localizable.PacketScope.sortFarthest
    }
  }
}

private struct LocationSample: Equatable {
  let latitude: Double
  let longitude: Double
}
