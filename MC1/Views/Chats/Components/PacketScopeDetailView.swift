import CoreLocation
import MC1Services
import SwiftUI

/// The observer network's view of one message's packet: which CoreScope observers
/// heard it, how strongly, and by which repeaters.
///
/// Reachable only through the message actions sheet, and only when the Packet
/// Scope opt-in is on and the message has a wire identity — the lookup is
/// user-initiated by design, never fired by rendering a conversation.
///
/// Two layouts. When anything can be placed, a full-bleed map with a floating
/// panel: the map's substrate is every link the packet crossed, drawn once and
/// weighted by how many routes used it, with one SNR-coloured leg per located
/// observer on top; the panel is one two-line row per observer. Selecting an
/// observer — its row or its pin — promotes its routes: they draw in full with
/// their fanned measured legs and readouts while everything else dims, and the
/// row opens into a ladder of its routes, strongest first. Otherwise the same
/// rows as a plain list.
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
  /// siblings.
  private static let panelMaxHeightFraction: CGFloat = 0.45
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
  private static let dimmedOpacity = 0.2

  @Environment(\.appTheme) private var theme
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
  @State private var isRefreshing = false
  /// Consecutive failed refreshes; drives the loop's give-up and its backoff.
  @State private var consecutiveFailures = 0
  /// Whether a fetch has succeeded yet. The first result draws at once; what
  /// later polls add is what animates and gets a "New" chip.
  @State private var hasLoadedOnce = false
  /// Whether the live poll loop is running: the headline's "still arriving"
  /// versus "settled".
  @State private var isLive = false
  /// `scenePhase` as the poll loop sees it. The loop runs in a `.task` that
  /// captured the view struct once, so reading the environment there would
  /// return the phase at appear forever; a `@State` box reads live.
  @State private var isSceneActive = true
  /// Whether the observer roster has arrived. Until it has, no row may claim
  /// "No location" — an empty roster says nothing about any observer.
  @State private var rosterLoaded = false

  @State private var coverage: PacketScopeCoverageMap?
  /// Pins, plus the readout badges of whatever is selected. Kept as state
  /// rather than derived per body evaluation because the map diffs its point
  /// source against it.
  @State private var locatedNodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)] = []
  /// Observer id behind each observer pin, for pin taps.
  @State private var observerIDByPinID: [UUID: String] = [:]
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

  @State private var selectedObserverID: String?
  @State private var selectedRouteID: String?
  @State private var sort: ObserverSort = .strongest
  @State private var observerListHeight: CGFloat = 0
  @State private var panelHeight: CGFloat = 0

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(L10n.Localizable.PacketScope.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button(L10n.Localizable.Common.done) { dismiss() }
          }
          ToolbarItem(placement: .topBarLeading) {
            if isRefreshing {
              ProgressView()
            } else {
              Button {
                Task { await refresh() }
              } label: {
                Image(systemName: "arrow.clockwise")
              }
              .accessibilityLabel(L10n.Localizable.PacketScope.refresh)
            }
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
        .onDisappear { drawTask?.cancel() }
    }
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
            guard let observerID = observerIDByPinID[point.id] else { return }
            select(observer: observerID)
          },
          onMapTap: { clearSelection() }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
          floatingPanel(maxListHeight: proxy.size.height * Self.panelMaxHeightFraction)
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

  private func floatingPanel(maxListHeight: CGFloat) -> some View {
    VStack(spacing: 0) {
      panelHeader
      Divider()
        .padding(.horizontal, 16)
      observerList(maxHeight: maxListHeight)
    }
    .liquidGlass(in: .rect(cornerRadius: Self.panelCornerRadius))
    .padding(.horizontal, Self.panelMargin)
    .padding(.bottom, Self.panelMargin)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
  }

  /// The answer first: how many heard it, the best signal, the shortest
  /// route, and whether more is still coming — then the retry caveat where it
  /// cannot be missed, and the selection's escape hatch.
  private var panelHeader: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        Text(L10n.Localizable.PacketScope.heardBy(summary?.observerCount ?? 0))
          .font(.subheadline.weight(.semibold))
        Spacer(minLength: 0)
        if selectedObserverID != nil {
          Button(L10n.Localizable.PacketScope.showAll) { clearSelection() }
            .font(.caption.weight(.medium))
            .buttonStyle(.borderless)
        }
        sortMenu
      }
      if let line = summaryLine {
        Text(line)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
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
    .padding(.vertical, 10)
  }

  private var sortMenu: some View {
    Menu {
      Picker(L10n.Localizable.PacketScope.sort, selection: $sort) {
        ForEach(ObserverSort.allCases, id: \.self) { option in
          Text(option.title).tag(option)
        }
      }
    } label: {
      Image(systemName: "arrow.up.arrow.down")
        .font(.caption)
    }
    .accessibilityLabel(L10n.Localizable.PacketScope.sort)
  }

  private func observerList(maxHeight: CGFloat) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(sortedReceptions) { reception in
          observerRow(reception, onMap: true)
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
        Section {
          Label(
            L10n.Localizable.PacketScope.notObserved,
            systemImage: "waveform.slash"
          )
          .foregroundStyle(.secondary)
        } footer: {
          Text(L10n.Localizable.PacketScope.notObservedFooter)
        }
        .themedRowBackground(theme)
      } else {
        summarySection(summary)
        Section {
          ForEach(sortedReceptions) { reception in
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
  /// first observer, and a line of chips. Tapping selects it, which opens its
  /// route ladder and promotes its routes on the map.
  private func observerRow(_ reception: PacketScopeReception, onMap: Bool) -> some View {
    let quality = SNRQuality(snr: reception.bestSNR)
    let isSelected = selectedObserverID == reception.observerID
    return VStack(alignment: .leading, spacing: 4) {
      // A tap target rather than a `Button`: a button's label does not receive
      // taps that land on a scroll view nested inside it, and the ladder's hop
      // strips scroll.
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
              .lineLimit(1)
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
      .accessibilityValue(accessibilityValue(for: reception, quality: quality))
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { toggle(observer: reception.observerID) }

      if isSelected {
        routeLadder(reception)
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

  /// The observer's routes, strongest first, each as its hops in path order
  /// with the measured signal pinned at the trailing edge so a long path can
  /// never push it out of view. Tapping a route focuses it on the map.
  private func routeLadder(_ reception: PacketScopeReception) -> some View {
    let ranked = PacketScopeCoverageBuilder.rankedRoutes(reception.routes)
    return VStack(alignment: .leading, spacing: 2) {
      if let rssi = reception.bestRSSI {
        Text("RSSI \(rssi) dBm")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
          .padding(.leading, 6)
      }
      ForEach(ranked, id: \.id) { route in
        routeRow(
          route,
          observerID: reception.observerID,
          isBest: route.id == ranked.first?.id && route.bestSNR != nil
        )
      }
    }
    .padding(.leading, 34)
    .padding(.top, 2)
  }

  private func routeRow(_ route: PacketScopeReception.Route, observerID: String, isBest: Bool) -> some View {
    let routeID = Self.routeID(observerID: observerID, route: route)
    let isSelected = selectedRouteID == routeID
    let names = hopNamesByRoute[routeID] ?? hopNames(for: route)
    return HStack(spacing: 6) {
      Image(systemName: "star.fill")
        .font(.system(size: 8))
        .foregroundStyle(.yellow)
        .opacity(isBest ? 1 : 0)
        .accessibilityHidden(true)
      if route.hops.isEmpty {
        Text(L10n.Localizable.PacketScope.heardDirectly)
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 3) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
              if index > 0 {
                Image(systemName: "chevron.right")
                  .font(.system(size: 7, weight: .bold))
                  .foregroundStyle(.tertiary)
              }
              Text(name)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
          }
          // The strip is a scroll view, so it takes its own tap: a tap on a
          // pill selects the route just as a tap beside it does.
          .contentShape(.rect)
          .onTapGesture { toggle(route: routeID) }
        }
      }
      Spacer(minLength: 6)
      if let snr = route.bestSNR {
        Text(PacketScopeCoverageBuilder.decibels(snr))
          .font(.caption.monospacedDigit())
          .foregroundStyle(SNRQuality(snr: snr).color)
      }
    }
    .padding(.vertical, 3)
    .padding(.horizontal, 6)
    .background(
      isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .contentShape(.rect)
    .onTapGesture { toggle(route: routeID) }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { toggle(route: routeID) }
    .accessibilityLabel(
      route.hops.isEmpty
        ? L10n.Localizable.PacketScope.heardDirectly
        : L10n.Localizable.PacketScope.via(names.joined(separator: ", "))
    )
    .accessibilityValue([
      isBest ? L10n.Localizable.PacketScope.bestRoute : nil,
      route.bestSNR.map(PacketScopeCoverageBuilder.decibels),
    ].compactMap(\.self).joined(separator: ", "))
  }

  private func chip(_ text: String, systemImage: String? = nil, tint: Color = .secondary) -> some View {
    HStack(spacing: 3) {
      if let systemImage {
        Image(systemName: systemImage)
      }
      Text(text)
    }
    .font(.caption2)
    .foregroundStyle(tint)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
  }

  // MARK: - Text

  /// "best 12.2 dB · shortest 2 hops · still arriving". Each figure is its own
  /// extreme — the best signal and the shortest route need not be one route.
  private var summaryLine: String? {
    guard let summary, summary.observerCount > 0 else { return nil }
    var parts: [String] = []
    if let best = summary.bestSNR {
      parts.append(L10n.Localizable.PacketScope.best(PacketScopeCoverageBuilder.decibels(best)))
    }
    if let hops = summary.shortestHopCount {
      parts.append(hops == 0
        ? L10n.Localizable.PacketScope.heardDirectly.lowercased()
        : L10n.Localizable.PacketScope.shortest(Self.routeLength(hops)))
    }
    if isLive {
      parts.append(L10n.Localizable.PacketScope.stillArriving)
    } else if let spread = summary.propagationSpread {
      parts.append(L10n.Localizable.PacketScope.settledIn(
        spread.formatted(.number.precision(.fractionLength(0...1)))
      ))
    } else {
      parts.append(L10n.Localizable.PacketScope.settled)
    }
    return parts.joined(separator: " · ")
  }

  /// Seconds after the first observer, so the panel shows propagation rather
  /// than a wall-clock time that reads the same on every row. Nil for the
  /// first observer itself, and when the observer carries no timestamp.
  private func heardOffset(_ reception: PacketScopeReception) -> String? {
    guard let first = summary?.firstHeard, let heard = reception.firstHeard else { return nil }
    let offset = heard.timeIntervalSince(first)
    guard offset >= 0.05 else { return nil }
    return "+\(offset.formatted(.number.precision(.fractionLength(0...1)))) s"
  }

  private func accessibilityValue(for reception: PacketScopeReception, quality: SNRQuality) -> String {
    [
      quality.localizedLabel,
      reception.bestSNR.map(PacketScopeCoverageBuilder.decibels),
      reception.shortestHopCount.map(Self.routeLength),
      reception.receptionCount > 1 ? L10n.Localizable.PacketScope.timesHeard(reception.receptionCount) : nil,
      isNew(reception.observerID) ? L10n.Localizable.PacketScope.new : nil,
    ].compactMap(\.self).joined(separator: ", ")
  }

  private static func routeLength(_ hops: Int) -> String {
    switch hops {
    case 0: L10n.Localizable.PacketScope.direct
    case 1: L10n.Localizable.PacketScope.hopOne
    default: L10n.Localizable.PacketScope.hopCount(hops)
    }
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

  private static func routeID(observerID: String, route: PacketScopeReception.Route) -> String {
    "\(observerID)|\(route.hops.joined(separator: ","))"
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

  // MARK: - Sorting and selection

  private var sortedReceptions: [PacketScopeReception] {
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
    }
  }

  private func toggle(observer observerID: String) {
    if selectedObserverID == observerID {
      clearSelection()
    } else {
      select(observer: observerID)
    }
  }

  private func select(observer observerID: String) {
    withAnimation(reduceMotion ? nil : .default) {
      selectedObserverID = observerID
      selectedRouteID = nil
    }
    refreshLocatedNodes()
  }

  private func toggle(route routeID: String) {
    withAnimation(reduceMotion ? nil : .default) {
      selectedRouteID = selectedRouteID == routeID ? nil : routeID
    }
    refreshLocatedNodes()
  }

  private func clearSelection() {
    guard selectedObserverID != nil || selectedRouteID != nil else { return }
    withAnimation(reduceMotion ? nil : .default) {
      selectedObserverID = nil
      selectedRouteID = nil
    }
    refreshLocatedNodes()
  }

  // MARK: - Map geometry

  /// The substrate: every link at least one route crossed, once, weighted by
  /// how many routes crossed it — the same paint the traffic heatmap gives its
  /// links, so the two screens read as one system. Dimmed while an observer is
  /// selected, so its promoted routes are what the eye lands on.
  private var overlays: [MapOverlay] {
    guard let coverage, !coverage.links.isEmpty else { return [] }
    let heaviest = Double(max(coverage.maxLinkRouteCount, 1))
    let dimmed = selectedObserverID != nil
    return [MapOverlay(
      id: "scope-links",
      features: coverage.links.map { link in
        let arrival = arrivalProgress["link:\(link.id)"].map(Self.easeOut) ?? 1
        return MapOverlay.Feature(
          id: link.id,
          geometry: .polyline([link.from, link.to]),
          weight: Double(link.routeCount) / heaviest * arrival
        )
      },
      paint: .weightedLine(MapOverlay.WeightedLine(
        color: .systemBlue,
        width: 1.5...6,
        opacity: dimmed ? 0.08...0.2 : 0.3...0.9,
        casing: dimmed ? nil : MapOverlay.Casing(extraWidth: 2.5)
      ))
    )]
  }

  /// Default: one measured leg per located observer, a leg still arriving cut
  /// to how far it has grown. Selected: that observer's routes in full, the
  /// other observers' legs dimmed; with a route selected, the observer's other
  /// routes dim too.
  private var visibleLines: [MapLine] {
    guard let coverage else { return [] }
    guard let selectedObserverID else {
      return coverage.observerLegs.flatMap { leg -> [MapLine] in
        guard let progress = arrivalProgress["leg:\(leg.id)"] else { return [leg.line] }
        return PacketScopeCoverageBuilder.truncated([leg.line], toFraction: Self.easeOut(progress))
      }
    }
    var lines: [MapLine] = []
    for leg in coverage.observerLegs where leg.id != selectedObserverID {
      lines.append(Self.line(leg.line, opacity: Self.dimmedOpacity))
    }
    for route in coverage.routes where route.observerID == selectedObserverID {
      let dim = selectedRouteID != nil && selectedRouteID != route.id
      lines += route.segments.map { dim ? Self.line($0, opacity: Self.dimmedOpacity) : $0 }
    }
    return lines
  }

  private static func line(_ line: MapLine, opacity: Double) -> MapLine {
    MapLine(id: line.id, coordinates: line.coordinates, style: line.style, opacity: opacity)
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
  /// nothing new was heard.
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
    var pinOwners: [UUID: String] = [:]
    for reception in receptions {
      for route in reception.routes {
        names[Self.routeID(observerID: reception.observerID, route: route)] = hopNames(for: route)
      }
      pinOwners[PacketScopeCoverageBuilder.stableID("obs:\(reception.observerID.lowercased())")] = reception.observerID
    }
    hopNamesByRoute = names
    observerIDByPinID = pinOwners

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
      if !reduceMotion, !newElements.isEmpty {
        for id in newElements {
          arrivalProgress[id] = 0
        }
        startDrawTaskIfNeeded()
      }
    }

    if let selectedObserverID, !observerIDs.contains(selectedObserverID) {
      self.selectedObserverID = nil
      selectedRouteID = nil
    }
    if let selectedRouteID, !names.keys.contains(selectedRouteID) {
      self.selectedRouteID = nil
    }
    refreshLocatedNodes()
  }

  /// Pins, plus the readouts of the selected observer's routes — or of the one
  /// selected route. Badges never enter the camera fit.
  private func refreshLocatedNodes() {
    guard let coverage else {
      locatedNodes = []
      return
    }
    var nodes = coverage.nodes
    if let selectedObserverID {
      for route in coverage.routes where route.observerID == selectedObserverID {
        if let selectedRouteID, selectedRouteID != route.id { continue }
        if let badge = route.badge { nodes.append((badge, badge.coordinate)) }
      }
    }
    locatedNodes = nodes
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

  private func refresh() async {
    guard let hash = message.packetContentHash, !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
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

/// A left-to-right flow that wraps onto new lines, for a row's chips: short
/// labels that must all stay visible without scrolling or truncating.
private struct ChipFlow: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > maxWidth {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      widest = max(widest, x - spacing)
    }
    let width = proposal.width.map { $0.isFinite ? $0 : widest } ?? widest
    return CGSize(width: width, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

private enum ObserverSort: CaseIterable {
  case strongest
  case fewestHops
  case firstHeard

  var title: String {
    switch self {
    case .strongest: L10n.Localizable.PacketScope.sortStrongest
    case .fewestHops: L10n.Localizable.PacketScope.sortFewestHops
    case .firstHeard: L10n.Localizable.PacketScope.sortFirstHeard
    }
  }
}

private struct LocationSample: Equatable {
  let latitude: Double
  let longitude: Double
}
