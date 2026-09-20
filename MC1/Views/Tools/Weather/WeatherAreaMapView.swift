import MC1Services
import MeshWX
import SwiftUI

/// The alert map (docs/MESHWX_UI.md §17): every area the radio says is under an alert, shaded by
/// event — for the whole country, or for the states somebody asked about.
///
/// **This screen never asks for anything on its own.** No request on appear, none on a pull, none
/// on a timer — a sweep is up to eight packets broadcast to everyone on `#meshwx`, and a screen
/// that fetched one because it was opened would spend the whole channel's airtime on a swipe. The
/// only thing that sends is a tap on a button, and every button says what the tap costs before it
/// is spent.
///
/// Revision 10 made the map **several sweeps at once** (`WeatherAlertMapPicture`). The owner's
/// third ask: *can we go from national alert map to just alert map, and have a way for the user to
/// select which areas they want to request the warnings for. One, a few, or all. That way we don't
/// default to sending everything.* A phone can now hold the country from 13:20 and Texas from
/// 13:40, and the status card is where that stops being a lie: one line per part, each with its
/// own age, its own breadth and its own holes — and, for a part missing packets, the ask that
/// fills them (the owner's first ask: *should allow me to re-request the missing data*).
struct WeatherAreaMapView: View {
  @Environment(\.appTheme) private var theme

  /// The page this was opened from, so the radio it names and asks is that page's, and so is the
  /// state the selection defaults to (docs/MESHWX_UI.md §13).
  let screen: WeatherPageScreen

  /// How much weather the **next** map should cover. Not what the held parts cover — each part
  /// says that itself, and they can differ from each other as well as from this.
  @State private var level: WeatherAreaMapScope = .warningsAndWatches
  @State private var drawing = WeatherAreaMapDrawing()
  @State private var isShowingMap = false

  private var model: WeatherToolModel { screen.model }
  private var picture: WeatherAlertMapPicture { model.areaPicture(forPageID: screen.pageID) }
  private var selection: WeatherAreaSelection { model.areaSelection(forPageID: screen.pageID) }
  private var request: WeatherRequest { selection.request(includesAdvisories: level.includesAdvisories) }

  /// What to redraw on: which sweeps are held and which of their packets are in. Never the clock —
  /// an unchanged map is not re-shaded every 30 seconds, and re-shading a country is not cheap.
  private var drawingKey: WeatherAreaMapKey {
    WeatherAreaMapKey(
      botID: screen.snapshot.source?.botID,
      parts: (screen.context.sourceState?.areaSweeps ?? []).map {
        WeatherAreaMapKey.Part(
          group: $0.group, builtMinutes: $0.builtMinutes, packets: $0.packets.keys.sorted())
      },
      isGeometryLoaded: screen.context.isGeometryLoaded)
  }

  var body: some View {
    let picture = picture
    List {
      mapSection(picture)
      statusSection(picture)
      alertListSection(picture)
      legendSection
      askSection(picture)
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
      // The resolved picture, not the raw sweeps: where a newer scoped part has replaced a
      // state's entries, the older ones must not be laid down under it.
      let entries = picture.entries.map(\.entry)
      drawing = await Task.detached(priority: .userInitiated) {
        WeatherAreaMapDrawing.make(entries: entries, tables: .shared, geometry: .shared)
      }.value
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private func mapSection(_ picture: WeatherAlertMapPicture) -> some View {
    if !picture.parts.isEmpty {
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

  /// One row per part, then what the map as a whole does and does not speak for.
  @ViewBuilder
  private func statusSection(_ picture: WeatherAlertMapPicture) -> some View {
    Section {
      if picture.parts.isEmpty {
        Text(L10n.Weather.Weather.AreaMap.empty)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        ForEach(picture.parts) { part in
          partRow(part, picture: picture)
        }
        // With nothing national held the map speaks for the states its parts name and for no
        // others, and an unshaded state outside them is unknown rather than clear.
        if !picture.coversWholeCountry, let covered = WeatherAreaMapCopy.coveredStates(picture) {
          VStack(alignment: .leading, spacing: 4) {
            Text(L10n.Weather.Weather.AreaMap.covers(covered))
              .font(.footnote)
              .foregroundStyle(.secondary)
            Text(L10n.Weather.Weather.AreaMap.notAsked)
              .font(.footnote)
              .foregroundStyle(.orange)
          }
          .accessibilityElement(children: .combine)
        }
        VStack(alignment: .leading, spacing: 4) {
          if let count = WeatherAreaMapCopy.areaCount(drawing, picture: picture, source: screen.sourceName) {
            Text(count)
          }
          if let undrawn = WeatherAreaMapCopy.undrawn(drawing) {
            Text(undrawn)
          }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
      }
    }
    .themedRowBackground(theme)
  }

  /// "Texas, Oklahoma · as of 1:40 PM · 2 min old", its breadth, and the two kinds of hole a part
  /// can have — both orange, because a gap in a cut or partial sweep is not calm weather.
  @ViewBuilder
  private func partRow(_ part: WeatherAlertMapPicture.Part, picture: WeatherAlertMapPicture) -> some View {
    let offer = model.areaPartsOffer(forPageID: screen.pageID, part: part)
    VStack(alignment: .leading, spacing: 4) {
      Text(WeatherAreaMapCopy.partLine(
        part, picture: picture, now: screen.now, calendar: .autoupdatingCurrent,
        locale: .autoupdatingCurrent, tables: .shared))
        .font(.subheadline)
      Text(WeatherAreaMapCopy.level(part))
        .font(.footnote)
        .foregroundStyle(.secondary)
      if WeatherAreaMapCopy.isReplaced(part) {
        Text(L10n.Weather.Weather.AreaMap.partReplaced)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if part.wasCut {
        Text(L10n.Weather.Weather.AreaMap.cut)
          .font(.footnote)
          .foregroundStyle(.orange)
      }
      if !part.missingIndexes.isEmpty {
        Text(L10n.Weather.Weather.AreaMap.partsArrived(part.receivedPackets, part.totalPackets))
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    }
    .accessibilityElement(children: .combine)

    // The ask is a row of its own, never folded into the combined line above: it is a button, and
    // the offer comes and goes with the fifteen-second and ten-minute rules (`WeatherPartsOffer`)
    // while the lines above it stay (docs/MESHWX_UI.md §3.1 U-35).
    if let offer {
      VStack(alignment: .leading, spacing: 2) {
        WeatherAskButton(screen: screen, title: WeatherAreaMapCopy.askPartsTitle(offer), request: offer)
        Text(WeatherAreaMapCopy.packets(WeatherAreaMapCopy.packetCount(offer)))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("weather.areaMap.askParts.\(part.group)")
    }
  }

  /// What the shading says, as a list — one row per alert kind, with how many areas are under it
  /// and where. The map answers "where"; a reader who wants "what" was reading colours off a
  /// legend and counting shapes (docs/MESHWX_UI.md §3.1 U-32). Tapping a kind opens its areas,
  /// and tapping an area opens what the phone knows about it.
  @ViewBuilder
  private func alertListSection(_ picture: WeatherAlertMapPicture) -> some View {
    let groups = WeatherAreaMapList.groups(picture.entries.map(\.entry), tables: .shared)
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

  /// What the next map covers, what it costs, and the tap that spends it.
  @ViewBuilder
  private func askSection(_ picture: WeatherAlertMapPicture) -> some View {
    let selection = selection
    Section {
      NavigationLink {
        WeatherAreaPickerView(screen: screen)
      } label: {
        LabeledContent(L10n.Weather.Weather.AreaMap.areasToAsk) {
          Text(WeatherAreaMapCopy.selectionName(selection))
        }
      }
      .accessibilityIdentifier("weather.areaMap.areasToAsk")

      Picker(L10n.Weather.Weather.AreaMap.scope, selection: $level) {
        ForEach(WeatherAreaMapScope.allCases, id: \.self) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.segmented)

      // Said **before** the tap, not after it: somebody who picked twenty states and got the
      // country back is owed the sentence in advance (`WeatherAreaSelection.asksWholeCountry`).
      if selection.isAskingWholeCountryByOverflow {
        Text(L10n.Weather.Weather.AreaMap.tooManyStates(MeshWXWire.maxSweepScopeStates))
          .font(.footnote)
          .foregroundStyle(.orange)
      }
      // The cost above the button, not under it: it is what the tap is about to spend, and a
      // reader who has already tapped, or who cannot tap at all, does not need telling.
      if model.status(for: request).isAskable {
        Text(WeatherAreaMapCopy.cost(WeatherAreaSweepCost.packets(
          for: selection, advisories: level.includesAdvisories, held: picture)))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      WeatherAskButton(
        screen: screen, title: WeatherAreaMapCopy.askTitle(selection), request: request,
        showsFootnotes: true)
      if !picture.parts.isEmpty, model.status(for: request).isAskable {
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

// MARK: - Which areas to ask about (§17)

/// The states the next map should cover: search, the whole country first, then every state with a
/// checkmark — the page's own state at the top, because that is the one somebody opening the map
/// from their own town almost always wants.
///
/// **Pushed, and saved as it changes.** There is no Done and nothing to commit: the selection is
/// one value in one store (`WeatherAreaSelectionStore`), and the back chevron is the only way out
/// this tool has ever offered from a pushed screen (docs/MESHWX_UI.md §3.1 U-11).
struct WeatherAreaPickerView: View {
  @Environment(\.appTheme) private var theme

  let screen: WeatherPageScreen

  @State private var search = ""

  private var model: WeatherToolModel { screen.model }

  var body: some View {
    let selection = model.areaSelection(forPageID: screen.pageID)
    let home = screen.context.placeStateCode?.uppercased()
    let all = WeatherReferenceNames.requestableStates(from: MeshWXTables.shared.states)
    let matching = all.filter { WeatherAreaPickerView.matches($0, search: search) }
    let pageState = home.flatMap { code in matching.first { $0 == code } }
    let rest = matching.filter { $0 != pageState }

    List {
      Section {
        row(
          title: L10n.Weather.Weather.AreaMap.pickerWholeCountry,
          isSelected: selection.isWholeCountry,
          identifier: "weather.areaMap.picker.wholeCountry"
        ) {
          var updated = selection
          updated.isWholeCountry = true
          model.setAreaSelection(updated)
        }
      } footer: {
        if !selection.states.isEmpty {
          Text(L10n.Weather.Weather.AreaMap.pickerSelected(selection.states.count))
        }
      }
      .themedRowBackground(theme)

      if let pageState {
        Section {
          stateRow(pageState, selection: selection)
        } header: {
          Text(L10n.Weather.Weather.AreaMap.pickerYourState)
        }
        .themedRowBackground(theme)
      }

      Section {
        if rest.isEmpty, pageState == nil {
          Text(L10n.Weather.Weather.AreaMap.pickerNoMatches)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          ForEach(rest, id: \.self) { code in
            stateRow(code, selection: selection)
          }
        }
      } header: {
        if !rest.isEmpty {
          Text(L10n.Weather.Weather.AreaMap.pickerEveryState)
        }
      }
      .themedRowBackground(theme)
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .searchable(text: $search, prompt: L10n.Weather.Weather.AreaMap.pickerSearch)
    .navigationTitle(L10n.Weather.Weather.AreaMap.areasToAsk)
    .navigationBarTitleDisplayMode(.inline)
    .weatherToolChrome()
  }

  /// A state code matches its own letters or its name, so "tex", "TX" and "Texas" all find Texas.
  static func matches(_ code: String, search: String) -> Bool {
    let query = search.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return true }
    if code.localizedCaseInsensitiveContains(query) { return true }
    return WeatherReferenceNames.stateName(code).localizedCaseInsensitiveContains(query)
  }

  /// Picking a state turns the whole country off: the two are one answer to one question, and a
  /// picker that left both on would send a request nobody chose.
  private func stateRow(_ code: String, selection: WeatherAreaSelection) -> some View {
    let isSelected = !selection.isWholeCountry && selection.states.contains(code)
    return row(
      title: WeatherReferenceNames.stateName(code), isSelected: isSelected,
      identifier: "weather.areaMap.picker.\(code)"
    ) {
      var states = Set(selection.states)
      if isSelected { states.remove(code) } else { states.insert(code) }
      model.setAreaSelection(
        WeatherAreaSelection(isWholeCountry: false, states: Array(states)))
    }
  }

  private func row(
    title: String, isSelected: Bool, identifier: String, tapped: @escaping () -> Void
  ) -> some View {
    Button(action: tapped) {
      HStack {
        Text(title)
          .foregroundStyle(.primary)
        Spacer(minLength: 8)
        if isSelected {
          Image(systemName: "checkmark")
            .foregroundStyle(.tint)
            .accessibilityLabel(L10n.Weather.Weather.Common.selected)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

// MARK: - The interactive map

/// The full map, where a tap on a shaded area opens what the phone knows about it.
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
      // knows what the map said about it — no airtime — and asks only when asked to.
      picked = WeatherPickedArea(ugc: ugc)
    }
  }
}

// MARK: - One area, and what is known about it (§17.3)

/// The area a tap landed on. Its code and nothing else: what the map said about it is read from
/// the page's own picture, so the screen says the same thing however it was reached.
struct WeatherPickedArea: Identifiable, Hashable {
  var ugc: String

  var id: String { ugc }
}

/// What the map says about one area: the event shading it, and when the part that shaded it was
/// built (which is the "as of" the row carries, on the radio's clock).
struct WeatherAreaMapWord: Hashable {
  var event: UInt8
  var asOf: Date
}

/// What the phone knows about one area, in **one card**, and the one request that would learn more
/// (docs/MESHWX_UI.md §17.3, §3.1 U-36).
///
/// The owner's second ask: *this "on the map" vs "what the phone holds" is weird.* It was two
/// cards saying one thing twice — the map's event on top, the alerts this phone holds underneath —
/// and a reader had to work out for themselves that they were the same alert. They are one list
/// now: the held alerts as ordinary rows, and a row for the map's own event **only when that event
/// is not among them**, which is the one case the two cards were ever telling apart.
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
    let unheld = WeatherAreaMapCopy.unheldMapWord(
      model.areaOnMap(forPageID: screen.pageID, ugc: area.ugc),
      heldEvents: alerts.map(\.warning.event))

    List {
      Section {
        WeatherCardLabel(
          title: WeatherAreaMapList.areaName(area.ugc, tables: .shared), trailing: area.ugc)
        ForEach(alerts) { item in
          NavigationLink {
            WeatherAlertDetailView(screen: screen, identity: item.identity)
          } label: {
            WeatherAlertRow(item: item, placeName: screen.placeName, now: screen.now)
              .equatable()
          }
        }
        if let unheld {
          VStack(alignment: .leading, spacing: 2) {
            Label(
              WeatherFormatting.eventName(unheld.event, tables: .shared),
              systemImage: WeatherFormatting.symbol(for: unheld.event, tables: .shared))
            Text(L10n.Weather.Weather.AreaMap.onMapAsOf(WeatherFormatting.clockTime(
              unheld.asOf, now: screen.now, calendar: .autoupdatingCurrent,
              locale: .autoupdatingCurrent)))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("weather.areaMap.onMapOnly")
        }
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

// MARK: - Level

/// How much of a state's weather the next map should carry (spec §7C). The *breadth* of the ask;
/// ``WeatherAreaSelection`` is its reach.
enum WeatherAreaMapScope: Hashable, CaseIterable {
  /// The default. Warnings and watches only — what people open a map during a storm to see.
  case warningsAndWatches
  /// The wider one, and the more expensive: advisories as well.
  case alsoAdvisories

  var includesAdvisories: Bool { self == .alsoAdvisories }

  var title: String {
    switch self {
    case .warningsAndWatches: L10n.Weather.Weather.AreaMap.scopeWarnings
    case .alsoAdvisories: L10n.Weather.Weather.AreaMap.scopeAll
    }
  }
}

extension WeatherAreaSelection {
  /// The selection names more states than a forty-byte request can carry, so the tap will ask for
  /// the country. The screen says so before it is tapped, never after.
  var isAskingWholeCountryByOverflow: Bool {
    !isWholeCountry && states.count > MeshWXWire.maxSweepScopeStates
  }
}

/// What a redraw is keyed on: which sweeps are held and which of their packets are in, never the
/// entries themselves — a country's worth of runs is not a value to hash on every body evaluation.
struct WeatherAreaMapKey: Hashable {
  /// One held sweep's identity, for the same reason.
  struct Part: Hashable {
    var group: UInt8
    var builtMinutes: UInt32
    var packets: [UInt8]
  }

  var botID: UInt16?
  var parts: [Part]
  var isGeometryLoaded: Bool
}

// MARK: - Copy

/// The sentences the alert map is built from, as pure functions of the picture and the selection.
enum WeatherAreaMapCopy {
  /// How many states a line names before it gives up and counts them. Three is what fits on one
  /// line of a status card at the largest text size the tool is read at; past that the names are
  /// a wall and the number is the fact.
  static let maxNamedStates = 3

  /// "Map as of 8:02 PM · 3 h old": when the radio built it, and how long ago that was. The build
  /// time is the radio's own (spec §7C), never when this phone happened to hear the packets.
  ///
  /// The alerts list's row still leads with the newest sweep this way; the map's own card names
  /// each part separately (``partLine(_:picture:now:calendar:locale:tables:)``).
  static func builtLine(
    _ sweep: WeatherAreaSweepAssembly, now: Date, calendar: Calendar, locale: Locale
  ) -> String {
    let asOf = L10n.Weather.Weather.AreaMap.asOf(
      WeatherFormatting.clockTime(sweep.builtAt, now: now, calendar: calendar, locale: locale))
    return "\(asOf) · \(WeatherFormatting.age(sweep.builtAt, now: now))"
  }

  /// "Texas, Oklahoma · as of 1:40 PM · 2 min old" — what this part is the word on, when the radio
  /// built it, and how old that makes it.
  static func partLine(
    _ part: WeatherAlertMapPicture.Part,
    picture: WeatherAlertMapPicture,
    now: Date,
    calendar: Calendar,
    locale: Locale,
    tables: MeshWXTables
  ) -> String {
    [partName(part, picture: picture, tables: tables),
     L10n.Weather.Weather.AreaMap.partAsOf(
       WeatherFormatting.clockTime(part.builtAt, now: now, calendar: calendar, locale: locale)),
     WeatherFormatting.age(part.builtAt, now: now)]
      .joined(separator: " · ")
  }

  /// What a part is the word on.
  ///
  /// A national part is "the whole country" until something scoped and newer takes states off it,
  /// and then it is honestly "the rest of the country". A scoped part is named by the states it
  /// **asked for**, not by the ones it kept: a part every one of whose states a newer sweep now
  /// covers is still the part that asked for them, and the line under it says what happened.
  static func partName(
    _ part: WeatherAlertMapPicture.Part, picture: WeatherAlertMapPicture, tables: MeshWXTables
  ) -> String {
    guard part.isScoped else {
      let replaced = picture.parts.contains { $0.isScoped && !$0.stateCodes.isEmpty }
      return replaced
        ? L10n.Weather.Weather.AreaMap.restOfCountry
        : L10n.Weather.Weather.AreaMap.wholeCountry
    }
    let codes = scopeCodes(part, tables: tables)
    guard let codes, !codes.isEmpty else {
      // Scoped, and the packet carrying the scope never arrived. Its entries are real and are
      // drawn; which states it was asked for is not in what came (spec revision 10, §1.2).
      return L10n.Weather.Weather.AreaMap.partStatesUnknown
    }
    return stateList(codes)
  }

  /// The state codes a scoped part names, or nil when its scope has not arrived.
  static func scopeCodes(
    _ part: WeatherAlertMapPicture.Part, tables: MeshWXTables
  ) -> [String]? {
    guard let scope = part.scope else { return nil }
    let states = tables.states
    return scope.compactMap { Int($0) < states.count ? states[Int($0)] : nil }.sorted()
  }

  /// Every state a newer part has taken off this one: it asked for them and no longer speaks for
  /// any of them.
  static func isReplaced(_ part: WeatherAlertMapPicture.Part) -> Bool {
    part.isScoped && !(part.scope ?? []).isEmpty && part.stateCodes.isEmpty
  }

  /// What one part covers — read off the sweep itself, not off the button that asked for it: a
  /// radio may answer the wider request with the narrower sweep, and then this is what arrived.
  static func level(_ part: WeatherAlertMapPicture.Part) -> String {
    part.includesAdvisories
      ? L10n.Weather.Weather.AreaMap.heldAll
      : L10n.Weather.Weather.AreaMap.heldWarnings
  }

  /// What the held map covers when no part of it is national, for "This map covers %@." Nil when
  /// not one part can name a state, which is the case where the sentence would say nothing.
  static func coveredStates(
    _ picture: WeatherAlertMapPicture, tables: MeshWXTables = .shared
  ) -> String? {
    var codes: Set<String> = []
    for part in picture.parts {
      codes.formUnion(scopeCodes(part, tables: tables) ?? [])
    }
    guard !codes.isEmpty else { return nil }
    return stateList(codes.sorted())
  }

  /// "Texas", "Texas and Oklahoma", "Texas, Oklahoma and New Mexico", "6 states".
  ///
  /// The design writes both joins out ("Texas, Oklahoma · as of 13:40" and "Ask for Texas and
  /// Oklahoma"), so the comma folds every pair but the last and the last takes the word. Past
  /// ``maxNamedStates`` the count is the fact and the names are a wall.
  static func stateList(_ codes: [String]) -> String {
    let names = codes.map(WeatherReferenceNames.stateName)
    guard names.count <= maxNamedStates else {
      return L10n.Weather.Weather.AreaMap.stateCount(names.count)
    }
    guard let last = names.last else { return "" }
    guard names.count > 1 else { return last }
    let head = names.dropLast().reduce(into: "") { joined, name in
      joined = joined.isEmpty ? name : L10n.Weather.Weather.AreaMap.listJoin(joined, name)
    }
    return L10n.Weather.Weather.AreaMap.listJoinAnd(head, last)
  }

  /// What the "Areas to ask for" row shows beside itself: the choice, never what the request will
  /// be turned into. Somebody who picked twenty states sees twenty states, and the orange line
  /// under the picker says what that will actually send.
  static func selectionName(_ selection: WeatherAreaSelection) -> String {
    selection.isWholeCountry || selection.states.isEmpty
      ? L10n.Weather.Weather.AreaMap.wholeCountry
      : stateList(selection.states)
  }

  /// The ask button's own title, which names what the tap will ask for.
  static func askTitle(_ selection: WeatherAreaSelection) -> String {
    selection.asksWholeCountry
      ? L10n.Weather.Weather.AreaMap.askWholeCountry
      : L10n.Weather.Weather.AreaMap.askStates(stateList(selection.askedStates))
  }

  /// "Ask for the 3 missing parts" (spec revision 10, §1.1).
  static func askPartsTitle(_ request: WeatherRequest, isReport: Bool = false) -> String {
    let count = packetCount(request)
    if isReport {
      return count == 1
        ? L10n.Weather.Weather.Reports.askPartsOne
        : L10n.Weather.Weather.Reports.askParts(count)
    }
    return count == 1
      ? L10n.Weather.Weather.AreaMap.askPartsOne
      : L10n.Weather.Weather.AreaMap.askParts(count)
  }

  /// How many packets a parts request asks for — which is exactly what it costs, because the bot
  /// resends the bytes it transmitted rather than rebuilding the answer.
  static func packetCount(_ request: WeatherRequest) -> Int {
    guard case let .parts(_, indexes, _) = request else { return 0 }
    return indexes.count
  }

  static func packets(_ count: Int) -> String {
    count == 1
      ? L10n.Weather.Weather.AreaMap.packetsOne
      : L10n.Weather.Weather.AreaMap.packets(count)
  }

  /// "About 4 packets on the shared channel." — what one tap on the sweep will spend, before it
  /// is spent. One state is often one packet, which is the whole point of the owner's third ask,
  /// so the sentence has a singular.
  static func cost(_ packets: Int) -> String {
    packets == 1
      ? L10n.Weather.Weather.AreaMap.costOne
      : L10n.Weather.Weather.AreaMap.cost(packets)
  }

  /// The one extra row the tapped-area card can carry: the map's own event for the area, **only**
  /// when this phone holds no alert of that kind for it (docs/MESHWX_UI.md §17.3, §3.1 U-36).
  ///
  /// The owner's second ask: *this "on the map" vs "what the phone holds" is weird.* It was two
  /// cards, and for the ordinary case — the map shades Travis County red and the phone holds the
  /// Tornado Warning that did it — both said the same thing, one of them in full and one of them
  /// as a coloured word. This is the only case the two cards were ever telling apart.
  static func unheldMapWord(
    _ word: WeatherAreaMapWord?, heldEvents: [UInt8]
  ) -> WeatherAreaMapWord? {
    guard let word, !heldEvents.contains(word.event) else { return nil }
    return word
  }

  /// How many areas are under an alert — or, for a map that speaks for the whole country with no
  /// hole in it and found none, that the country is clear.
  ///
  /// **The clear sentence needs a whole map.** A part that was cut or is missing packets says
  /// nothing about the areas it does not name, and a map with no national part says nothing about
  /// the states nobody asked for — so either one silences the sentence, and the orange lines above
  /// are what the reader is left with.
  static func areaCount(
    _ drawing: WeatherAreaMapDrawing, picture: WeatherAlertMapPicture, source: String
  ) -> String? {
    guard drawing.areaCount > 0 else {
      guard picture.coversWholeCountry, picture.parts.allSatisfy(\.isWhole) else { return nil }
      return L10n.Weather.Weather.AreaMap.clear(WeatherFormatting.sentenceStart(source))
    }
    return drawing.areaCount == 1
      ? L10n.Weather.Weather.AreaMap.areasOne
      : L10n.Weather.Weather.AreaMap.areas(drawing.areaCount)
  }

  /// Areas the map named that this bundle has no outline for. Said rather than swallowed: the
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

/// One kind of alert on the map: its event code, its name, and every area under it, in the
/// order the sweep sent them — most severe first, then by state.
struct WeatherAreaMapGroup: Identifiable, Hashable {
  var event: UInt8
  var name: String
  var codes: [String]

  var id: UInt8 { event }
}

enum WeatherAreaMapList {
  /// The map's entries collapsed to one row per event code. An area under two alerts belongs to
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

/// Every area under one kind of alert. A tap opens what the phone knows about that area, the same
/// screen a tap on the map opens.
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
            WeatherAreaDetailView(screen: screen, area: WeatherPickedArea(ugc: code))
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
