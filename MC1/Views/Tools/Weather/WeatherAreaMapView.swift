import MC1Services
import MeshWX
import SwiftUI

/// The national alert map (docs/MESHWX_UI.md §17): every area in the country the radio says is
/// under an alert, shaded by event.
///
/// **This screen never asks for anything on its own.** No request on appear, none on a pull, none
/// on a timer — one sweep is up to eight packets broadcast to everyone on `#meshwx`, and a screen
/// that fetched one because it was opened would spend the whole channel's airtime on a swipe. The
/// only thing that sends is a tap on the button, and the button says what the tap costs before it
/// is spent.
///
/// What it shows comes from the state the source bot's sweep was stored in
/// (`WeatherBotState.areaSweep`), complete or partial. A sweep missing two of its eight packets is
/// still most of a country and is drawn, labelled as partial.
struct WeatherAreaMapView: View {
  @Environment(\.appTheme) private var theme

  /// The page this was opened from, so the radio it names and asks is that page's
  /// (docs/MESHWX_UI.md §13).
  let screen: WeatherPageScreen

  /// How much weather the **next** map should cover. Not what the held one covers — the held one
  /// says that itself (``MeshWXAreaSweep/includesAdvisories``), and the two can differ.
  @State private var scope: WeatherAreaMapScope = .warningsAndWatches
  @State private var drawing = WeatherAreaMapDrawing()
  @State private var isShowingMap = false

  private var model: WeatherToolModel { screen.model }
  private var sweep: WeatherAreaSweepAssembly? { screen.context.sourceState?.areaSweep }
  private var request: WeatherRequest { scope.request }

  /// What to redraw on. Never the clock: an unchanged sweep is not re-shaded every 30 seconds,
  /// and re-shading a country is not cheap.
  private var drawingKey: WeatherAreaMapKey {
    WeatherAreaMapKey(
      botID: screen.snapshot.source?.botID,
      builtMinutes: sweep?.builtMinutes,
      group: sweep?.group,
      packets: sweep?.packets.keys.sorted() ?? [],
      isGeometryLoaded: screen.context.isGeometryLoaded)
  }

  var body: some View {
    List {
      mapSection
      statusSection
      alertListSection
      legendSection
      askSection
      sourceSection
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(L10n.Weather.Weather.AreaMap.title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: model, requestsOnScreen: [request])
    .weatherToolChrome()
    .navigationDestination(isPresented: $isShowingMap) {
      WeatherAreaFullMapView(screen: screen, drawing: drawing)
    }
    .task(id: drawingKey) {
      let entries = sweep?.entries ?? []
      drawing = await Task.detached(priority: .userInitiated) {
        WeatherAreaMapDrawing.make(entries: entries, tables: .shared, geometry: .shared)
      }.value
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var mapSection: some View {
    if sweep != nil {
      Section {
        // The card is a still: the map underneath it takes no gestures, and the whole row opens
        // the full map, which zooms and answers a tap on an area. `allowsHitTesting(false)` on
        // the map keeps it from eating the tap, and `contentShape` is what gives the button a
        // hit area of its own once its only content has stopped taking hits — without it the row
        // looked tappable and did nothing (docs/MESHWX_UI.md §3.1 U-32).
        Button {
          isShowingMap = true
        } label: {
          VStack(spacing: 6) {
            WeatherAlertMapView(drawing: drawing.drawing, isInteractive: false)
              .frame(height: 220)
              .clipShape(.rect(cornerRadius: 10))
              .allowsHitTesting(false)
              .accessibilityHidden(true)
            HStack(spacing: 4) {
              Text(L10n.Weather.Weather.AreaMap.open)
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Weather.Weather.AreaMap.mapLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("weather.areaMap.open")
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
      }
      .themedRowBackground(theme)
    }
  }

  @ViewBuilder
  private var statusSection: some View {
    Section {
      if let sweep {
        VStack(alignment: .leading, spacing: 4) {
          Text(WeatherAreaMapCopy.builtLine(
            sweep, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
            .font(.subheadline)
          Text(WeatherAreaMapCopy.scopeHeld(sweep))
            .font(.footnote)
            .foregroundStyle(.secondary)
          if let count = WeatherAreaMapCopy.areaCount(drawing, sweep: sweep, source: screen.sourceName) {
            Text(count)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          if let undrawn = WeatherAreaMapCopy.undrawn(drawing) {
            Text(undrawn)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          // Both are honesty about what is *not* on the map, so both are orange rather than
          // grey: a gap in a cut or partial sweep is not calm weather.
          if !sweep.isComplete {
            Text(L10n.Weather.Weather.AreaMap.partial(sweep.receivedPacketCount, Int(sweep.total)))
              .font(.footnote)
              .foregroundStyle(.orange)
          }
          if sweep.wasCut {
            Text(L10n.Weather.Weather.AreaMap.cut)
              .font(.footnote)
              .foregroundStyle(.orange)
          }
        }
        .accessibilityElement(children: .combine)
      } else {
        Text(L10n.Weather.Weather.AreaMap.empty)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .themedRowBackground(theme)
  }

  /// What the shading says, as a list — one row per alert kind, with how many areas are under it
  /// and where. The map answers "where"; a reader who wants "what" was reading colours off a
  /// legend and counting shapes (docs/MESHWX_UI.md §3.1 U-32). Tapping a kind opens its areas,
  /// and tapping an area asks the radio what it is, exactly as tapping the map does.
  @ViewBuilder
  private var alertListSection: some View {
    let groups = WeatherAreaMapList.groups(sweep?.entries ?? [], tables: .shared)
    if !groups.isEmpty {
      Section {
        WeatherCardLabel(
          title: L10n.Weather.Weather.AreaMap.list, systemImage: "list.bullet",
          trailing: String(groups.count))
        ForEach(groups) { group in
          NavigationLink {
            WeatherAreaListView(screen: screen, group: group)
          } label: {
            LabeledContent {
              Text(String(group.codes.count))
                .monospacedDigit()
            } label: {
              Label(group.name, systemImage: WeatherFormatting.symbol(for: group.event, tables: .shared))
                .labelStyle(.titleAndIcon)
            }
          }
          .accessibilityIdentifier("weather.areaMap.kind.\(group.event)")
        }
      }
      .themedRowBackground(theme)
    }
  }

  @ViewBuilder
  private var legendSection: some View {
    if !drawing.legend.isEmpty {
      Section {
        WeatherCardLabel(title: L10n.Weather.Weather.AreaMap.legend, systemImage: "paintpalette")
        ForEach(drawing.legend) { item in
          HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
              .fill(WeatherFormatting.color(for: item.tint).opacity(0.35))
              .overlay(
                RoundedRectangle(cornerRadius: 3)
                  .strokeBorder(WeatherFormatting.color(for: item.tint), lineWidth: 2))
              .frame(width: 22, height: 14)
            Text(item.name)
              .font(.subheadline)
          }
          // One element per row: the swatch is the colour the name is drawn in, and a reader who
          // cannot see it gets the name, which is the part that means anything.
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(item.name)
        }
      }
      .themedRowBackground(theme)
    }
  }

  @ViewBuilder
  private var askSection: some View {
    Section {
      Picker(L10n.Weather.Weather.AreaMap.scope, selection: $scope) {
        ForEach(WeatherAreaMapScope.allCases, id: \.self) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.segmented)
      // The cost above the button, not under it: it is what the tap is about to spend, and a
      // reader who has already tapped, or who cannot tap at all, does not need telling.
      if model.status(for: request).isAskable {
        Text(L10n.Weather.Weather.AreaMap.cost(scope.packets(lastSweep: sweep)))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      WeatherAskButton(
        screen: screen, title: L10n.Weather.Weather.AreaMap.ask, request: request,
        showsFootnotes: true)
      if sweep != nil, model.status(for: request).isAskable {
        Text(L10n.Weather.Weather.AreaMap.tapHint(screen.sourceName))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .themedRowBackground(theme)
  }

  @ViewBuilder
  private var sourceSection: some View {
    Section {
      Text(screen.snapshot.source == nil
        ? L10n.Weather.Weather.Alerts.sourceGeneric
        : L10n.Weather.Weather.Alerts.source(screen.sourceName))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .themedRowBackground(theme)
  }
}

// MARK: - The interactive map

/// The full map, where a tap on a shaded area asks the radio what is happening there.
///
/// One tap, one `>w <area>` — a single packet, not a sweep — and only for an area this map
/// actually shaded: a tap on empty land asks for nothing rather than guessing at a county.
struct WeatherAreaFullMapView: View {
  let screen: WeatherPageScreen
  let drawing: WeatherAreaMapDrawing

  @State private var picked: WeatherPickedArea?

  private var model: WeatherToolModel { screen.model }

  var body: some View {
    WeatherAlertMapView(drawing: drawing.drawing, isInteractive: true, onTap: tapped)
      .ignoresSafeArea(edges: .bottom)
      .navigationTitle(L10n.Weather.Weather.AreaMap.title)
      .navigationBarTitleDisplayMode(.inline)
      // Both bars float **over** the map rather than inset it. A safe-area inset that appears the
      // moment a tap goes out — the pending bar arriving as the hint leaves — resizes the map
      // view, and a full-bleed MapLibre view relays out its whole style when it is resized: the
      // flash the owner saw on every tap on a shaded area (docs/MESHWX_UI.md §3.1 U-33). Neither
      // bar takes touches, so the map still pans, zooms and answers a tap underneath them.
      .overlay(alignment: .top) {
        if let hint {
          Text(hint)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      }
      .overlay(alignment: .bottom) {
        WeatherPendingBar(model: model, requestsOnScreen: [])
          .allowsHitTesting(false)
      }
      .animation(.default, value: model.activeRequest)
      .navigationDestination(item: $picked) { area in
        WeatherAreaDetailView(screen: screen, area: area)
      }
  }

  /// The hint while a tap could still send something. With a request on the air the pending bar
  /// is already speaking, and with everything blocked the reason was said once on the screen this
  /// was pushed from (docs/MESHWX_UI.md §3.1 U-24) — either way the page must not tell someone to
  /// tap while nothing would go out.
  private var hint: String? {
    guard model.activeRequest == nil, screen.snapshot.requestBlock == nil else { return nil }
    return L10n.Weather.Weather.AreaMap.tapHint(screen.sourceName)
  }

  private func tapped(_ point: MeshWXCoordinate) {
    let codes = drawing.drawnCodes
    Task {
      // Both files are parsed by now — the map is drawn — but the containment sweep is over
      // thousands of boxes, which is not a main-actor job.
      let ugc = await Task.detached(priority: .userInitiated) {
        let hits = Set(MeshWXGeometry.shared.areaCodes(containing: point))
        // Sweep order is severity order, so the most severe alert covering the tap wins.
        return codes.first { hits.contains($0) }
      }.value
      guard let ugc else { return }
      // A tap used to put `>w <ugc>` on the air and show nothing at all: the answer landed in
      // state, the map never mentioned it, and the owner tapped area after area for nothing
      // (docs/MESHWX_UI.md §3.1 U-34). It opens the area's own screen instead, which already
      // knows what the sweep said about it — no airtime — and asks only when asked to.
      picked = WeatherPickedArea(ugc: ugc, event: eventForArea(ugc))
    }
  }

  /// What the sweep said about this area, for the screen the tap opens. The sweep is in severity
  /// order and `drawnCodes` follows it, so the first entry naming the area is the one shading it.
  private func eventForArea(_ ugc: String) -> UInt8? {
    let states = MeshWXTables.shared.states
    for entry in screen.context.sourceState?.areaSweep?.entries ?? []
    where entry.ugcCodes(states: states).contains(ugc) {
      return entry.event
    }
    return nil
  }
}

// MARK: - One area, and what is known about it (§3.1 U-34)

/// The area a tap landed on: its code, and the alert the sweep shaded it with.
struct WeatherPickedArea: Identifiable, Hashable {
  var ugc: String
  var event: UInt8?

  var id: String { ugc }
}

/// What the phone knows about one area, and the one request that would learn more.
///
/// The sweep already says which kind of alert covers it, which costs nothing to show. A warning
/// this phone holds for it is shown in full. Only the button spends airtime, and only on a tap.
struct WeatherAreaDetailView: View {
  @Environment(\.appTheme) private var theme

  let screen: WeatherPageScreen
  let area: WeatherPickedArea

  private var model: WeatherToolModel { screen.model }
  private var request: WeatherRequest { .warningsTouching(ugc: area.ugc) }

  /// Every alert this phone holds whose own area list names this area.
  private var held: [WeatherAlertItem] {
    let tables = MeshWXTables.shared
    return screen.snapshot.alerts.filter { item in
      tables.namedAreas(for: item.warning)
        .contains { $0.ugc.caseInsensitiveCompare(area.ugc) == .orderedSame }
    }
  }

  var body: some View {
    let alerts = held
    List {
      Section {
        WeatherCardLabel(title: L10n.Weather.Weather.AreaMap.onTheMap, systemImage: "map")
        LabeledContent {
          Text(area.ugc)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        } label: {
          Text(WeatherAreaMapList.areaName(area.ugc, tables: .shared))
        }
        if let event = area.event {
          Label(
            WeatherFormatting.eventName(event, tables: .shared),
            systemImage: WeatherFormatting.symbol(for: event, tables: .shared))
        }
      }
      .themedRowBackground(theme)

      if !alerts.isEmpty {
        Section {
          WeatherCardLabel(
            title: L10n.Weather.Weather.AreaMap.held, systemImage: "exclamationmark.triangle")
          ForEach(alerts) { item in
            NavigationLink {
              WeatherAlertDetailView(screen: screen, identity: item.identity)
            } label: {
              WeatherAlertRow(item: item, placeName: screen.placeName, now: screen.now)
                .equatable()
            }
          }
        }
        .themedRowBackground(theme)
      }

      Section {
        WeatherAskButton(
          screen: screen,
          title: alerts.isEmpty
            ? L10n.Weather.Weather.AreaMap.askArea
            : L10n.Weather.Weather.AreaMap.askAreaAgain,
          request: request, showsFootnotes: true)
      } footer: {
        Text(L10n.Weather.Weather.AreaMap.askAreaFootnote(screen.sourceName))
      }
      .themedRowBackground(theme)
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(WeatherAreaMapList.areaName(area.ugc, tables: .shared))
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: model, requestsOnScreen: [request])
    .weatherToolChrome()
  }
}

extension WeatherRequestStatus {
  /// Whether a tap on this request would put something on the air. Blocked, pending and
  /// waiting-for-another all mean no.
  var isAskable: Bool {
    switch self {
    case .idle, .settled: true
    case .pending, .waitingForOther, .blocked: false
    }
  }
}

// MARK: - Scope

/// How much of the country's weather the next map should cover (spec §7C).
enum WeatherAreaMapScope: Hashable, CaseIterable {
  /// The default. Warnings and watches only — what people open a map during a storm to see.
  case warningsAndWatches
  /// The wider one, and the more expensive: advisories as well.
  case alsoAdvisories

  var includesAdvisories: Bool { self == .alsoAdvisories }

  var request: WeatherRequest { .areaSweep(includesAdvisories: includesAdvisories) }

  /// What one tap spends, in packets, said in plain words before it is spent.
  ///
  /// Measured against the bot's live products on 2026-09-20: warnings and watches were 148 runs,
  /// four packets; with advisories 263 runs, seven. Eight is the ceiling
  /// (``MeshWXWire/maxAreaSweepPackets``) and a busy day reaches it, so the figure a phone shows
  /// is the last sweep it actually received at this scope, and these only until one arrives.
  var typicalPackets: Int { includesAdvisories ? 7 : 4 }

  /// The last sweep at this scope is the best estimate there is: it is what this bot sent for
  /// this country a few minutes ago.
  func packets(lastSweep: WeatherAreaSweepAssembly?) -> Int {
    guard let lastSweep, lastSweep.includesAdvisories == includesAdvisories, lastSweep.total > 0
    else { return typicalPackets }
    return Int(lastSweep.total)
  }

  var title: String {
    switch self {
    case .warningsAndWatches: L10n.Weather.Weather.AreaMap.scopeWarnings
    case .alsoAdvisories: L10n.Weather.Weather.AreaMap.scopeAll
    }
  }
}

/// What a redraw is keyed on: the sweep's identity and which of its packets are in, never the
/// entries themselves — a country's worth of runs is not a value to hash on every body evaluation.
struct WeatherAreaMapKey: Hashable {
  var botID: UInt16?
  var builtMinutes: UInt32?
  var group: UInt8?
  var packets: [UInt8]
  var isGeometryLoaded: Bool
}

// MARK: - Copy

/// The sentences the national map is built from, as pure functions of the sweep.
enum WeatherAreaMapCopy {
  /// "Map as of 8:02 PM · 3 h old": when the radio built it, and how long ago that was. The build
  /// time is the radio's own (spec §7C), never when this phone happened to hear the packets.
  static func builtLine(
    _ sweep: WeatherAreaSweepAssembly, now: Date, calendar: Calendar, locale: Locale
  ) -> String {
    let asOf = L10n.Weather.Weather.AreaMap.asOf(
      WeatherFormatting.clockTime(sweep.builtAt, now: now, calendar: calendar, locale: locale))
    return "\(asOf) · \(WeatherFormatting.age(sweep.builtAt, now: now))"
  }

  /// What the held map covers — read off the sweep itself, not off the button that asked for it:
  /// a radio may answer the wider request with the narrower sweep, and then this is what arrived.
  static func scopeHeld(_ sweep: WeatherAreaSweepAssembly) -> String {
    sweep.includesAdvisories
      ? L10n.Weather.Weather.AreaMap.heldAll
      : L10n.Weather.Weather.AreaMap.heldWarnings
  }

  /// How many areas are under an alert — or, for a whole map that found none, that the country is
  /// clear.
  ///
  /// **The clear sentence needs a whole map.** A sweep that was cut or is missing packets says
  /// nothing about the areas it does not name, so a partial map with no entries says only that
  /// nothing arrived, and the partial and cut lines above it are what the reader is left with.
  static func areaCount(
    _ drawing: WeatherAreaMapDrawing, sweep: WeatherAreaSweepAssembly, source: String
  ) -> String? {
    guard drawing.areaCount > 0 else {
      guard sweep.isComplete, !sweep.wasCut else { return nil }
      return L10n.Weather.Weather.AreaMap.clear(WeatherFormatting.sentenceStart(source))
    }
    return drawing.areaCount == 1
      ? L10n.Weather.Weather.AreaMap.areasOne
      : L10n.Weather.Weather.AreaMap.areas(drawing.areaCount)
  }

  /// Areas the sweep named that this bundle has no outline for. Said rather than swallowed: the
  /// UGC tables grow and the bundle is a cut in time, so the map is honestly a little smaller than
  /// the sweep, and nobody should read the difference as clear weather.
  static func undrawn(_ drawing: WeatherAreaMapDrawing) -> String? {
    switch drawing.undrawnCount {
    case 0: nil
    case 1: L10n.Weather.Weather.AreaMap.noOutlineOne
    case let count: L10n.Weather.Weather.AreaMap.noOutline(count)
    }
  }
}


// MARK: - What the map is showing, as a list (§3.1 U-32)

/// One kind of alert in a sweep: its event code, its name, and every area under it, in the
/// order the sweep sent them — most severe first, then by state.
struct WeatherAreaMapGroup: Identifiable, Hashable {
  var event: UInt8
  var name: String
  var codes: [String]

  var id: UInt8 { event }
}

enum WeatherAreaMapList {
  /// A sweep's entries collapsed to one row per event code. An area under two alerts belongs to
  /// the first that named it, which is the more severe: the sweep is in severity order and the
  /// map shades it the same way.
  static func groups(_ entries: [MeshWXAreaSweep.Entry], tables: MeshWXTables) -> [WeatherAreaMapGroup] {
    var order: [UInt8] = []
    var codesByEvent: [UInt8: [String]] = [:]
    var taken: Set<String> = []
    for entry in entries {
      for code in entry.ugcCodes(states: tables.states) where !taken.contains(code) {
        taken.insert(code)
        if codesByEvent[entry.event] == nil { order.append(entry.event) }
        codesByEvent[entry.event, default: []].append(code)
      }
    }
    return order.map { event in
      WeatherAreaMapGroup(
        event: event, name: tables.eventLabel(for: event), codes: codesByEvent[event] ?? [])
    }
  }

  /// "Travis County, TX" for a county, the zone's own name for a zone, and the bare code for an
  /// area this phone's tables do not carry — which is never nothing, because the code is what the
  /// radio would be asked about.
  static func areaName(_ ugc: String, tables: MeshWXTables) -> String {
    if let county = tables.county(ugc) {
      return L10n.Weather.Weather.AreaMap.areaIn(
        L10n.Weather.Weather.Area.county(county.name), county.state)
    }
    if let zone = tables.zone(ugc) {
      return L10n.Weather.Weather.AreaMap.areaIn(zone.name, zone.state)
    }
    return ugc
  }
}

/// Every area under one kind of alert. A tap asks the radio what that area is under, the same
/// request a tap on the map sends.
struct WeatherAreaListView: View {
  @Environment(\.appTheme) private var theme

  let screen: WeatherPageScreen
  let group: WeatherAreaMapGroup

  private var model: WeatherToolModel { screen.model }

  var body: some View {
    List {
      Section {
        ForEach(group.codes, id: \.self) { code in
          NavigationLink {
            WeatherAreaDetailView(
              screen: screen, area: WeatherPickedArea(ugc: code, event: group.event))
          } label: {
            HStack {
              Text(WeatherAreaMapList.areaName(code, tables: .shared))
              Spacer(minLength: 8)
              Text(code)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("weather.areaMap.area.\(code)")
        }
      } footer: {
        Text(L10n.Weather.Weather.AreaMap.tapHint(screen.sourceName))
      }
      .themedRowBackground(theme)
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(group.name)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: model, requestsOnScreen: [])
    .weatherToolChrome()
  }
}
