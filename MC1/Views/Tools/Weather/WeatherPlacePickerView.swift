import MC1Services
import MeshWX
import SwiftUI
import UIKit

/// Places (docs/MESHWX_UI.md §12): the one control that changes the place the screen answers
/// for. My location first with what is held for it, then the places kept on this phone, a search
/// that takes a town, a ZIP or an airport code, and — quietly, last — the places heard on the
/// channel in the last day.
///
/// `.searchable` on its own list rather than a child sheet. A pick is left on the model and
/// applied by the screen once this sheet is gone. Picking sends nothing: Update is on the screen
/// behind and says what it would ask for.
struct WeatherPlacePickerView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme
  @Environment(\.appState) private var appState
  @Environment(\.openURL) private var openURL

  let model: WeatherToolModel

  @State private var query = ""
  @State private var found = SearchResults()

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Where distances are measured from: **the user**, not the page behind the sheet
  /// (docs/MESHWX_UI.md §3.1 U-8).
  ///
  /// Opening Places from the San Juan page used to measure from San Juan, so an Austin user
  /// reading a list of Texas towns was told Llano was 3,559 km away. A distance in a list of
  /// places is how far *you* are from them. Only with no fix at all does it fall back to the page
  /// on screen, and then the sheet says which place it is measuring from.
  private var origin: MeshWXCoordinate? {
    phoneCoordinate ?? model.snapshot?.place?.coordinate ?? selectedPage?.savedPlace?.coordinate
  }

  /// The page the pager is on, from the page list rather than from a build. A page has its saved
  /// place the moment it is added and its snapshot some time later, and with location off the
  /// snapshot may never carry one at all: that was six "San Juan, PR" rows with no distances and
  /// no order between them (docs/MESHWX_UI.md §3.1 U-23).
  private var selectedPage: WeatherPage? {
    model.pages.first { $0.id == model.selectedPageID }
  }

  /// The page the distances fall back to, when there is no fix to measure from. Nil whenever the
  /// distances really are the user's own.
  private var borrowedOriginName: String? {
    guard phoneCoordinate == nil else { return nil }
    if let place = model.snapshot?.place { return WeatherFormatting.placeName(place.label) }
    guard let label = selectedPage?.savedPlace?.label else { return nil }
    return WeatherFormatting.placeName(label)
  }

  var body: some View {
    NavigationStack {
      List {
        if trimmedQuery.isEmpty {
          currentLocationSection
          deniedSection
          savedSection
          heardSection
        } else {
          Section {
            if let zip = found.zip {
              zipRow(zip)
            } else if found.places.isEmpty, found.stations.isEmpty {
              Text(L10n.Weather.Weather.Picker.noResults)
                .foregroundStyle(.secondary)
            } else {
              ForEach(found.places, id: \.self) { place in
                Button {
                  pick(.place(Self.saved(for: place)))
                } label: {
                  placeRow(
                    title: WeatherNames.placeLabel(name: place.name, state: place.state),
                    detail: distance(toLat: place.lat, lon: place.lon))
                }
                .accessibilityIdentifier(
                  "weather.places.result.\(WeatherNames.placeLabel(name: place.name, state: place.state))")
              }
            }
          }
          .themedRowBackground(theme)
          if !found.stations.isEmpty {
            Section {
              WeatherCardLabel(title: L10n.Weather.Weather.Stations.title, systemImage: "wind")
              ForEach(found.stations, id: \.self) { result in
                // An airport code opens **that station's screen and nothing else**: no page is
                // added and nothing is saved (docs/MESHWX_UI.md §3.1 U-3).
                Button {
                  pick(station: result)
                } label: {
                  placeRow(
                    title: WeatherNames.stationName(result.station.name),
                    detail: [result.station.icao, distance(toLat: result.station.lat, lon: result.station.lon)]
                      .joined(separator: " · "))
                }
                .accessibilityIdentifier("weather.places.station.\(result.station.icao)")
              }
            }
            .themedRowBackground(theme)
          }
        }
      }
      // Rows are buttons; the default style tints their labels with the accent colour.
      .buttonStyle(.plain)
      .listStyle(.insetGrouped)
      .themedCanvas(theme)
      .searchable(
        text: $query, placement: .navigationBarDrawer(displayMode: .always),
        prompt: Text(L10n.Weather.Weather.Picker.prompt))
      // Done stays put while the field is up (docs/MESHWX_UI.md §3.1 U-28). Searching used to
      // take the one button that closes the sheet away and leave a ⊗ in its place, a second one
      // beside the field's own: two ways to clear the query and no way out.
      .searchPresentationToolbarBehavior(.avoidHidingContent)
      // The search field takes the identifier of the view `.searchable` is applied to.
      .accessibilityIdentifier("weather.places.search")
      .task(id: trimmedQuery) {
        await search(trimmedQuery)
      }
      .navigationTitle(L10n.Weather.Weather.Place.places)
      .navigationBarTitleDisplayMode(.inline)
      // One button, and it closes the sheet (docs/MESHWX_UI.md §3.1 U-10). "Cancel" implied a
      // commit step that does not exist — every change here is already saved — and the filled
      // blue "Edit" capsule beside it was the loudest thing in the whole tool, for a mode that is
      // no longer needed: rows delete by swiping and reorder by dragging, with no mode at all.
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Weather.Weather.Common.done) { dismiss() }
            .accessibilityIdentifier("weather.places.done")
        }
      }
    }
  }

  // MARK: - Sections

  private var currentLocationSection: some View {
    Section {
      HStack(spacing: 12) {
        Button {
          pick(.currentLocation)
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "location.fill")
              .foregroundStyle(.tint)
              .accessibilityHidden(true)
            placeRow(
              title: L10n.Weather.Weather.Picker.yourLocation, detail: currentLocationDetail,
              reading: phoneCoordinate.map(heldReading(at:)))
            if model.searchedPlace == nil, model.snapshot?.place != nil {
              Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .accessibilityLabel(L10n.Weather.Weather.Common.selected)
            }
          }
        }
        .accessibilityIdentifier("weather.places.row.myLocation")
        bell(
          isOn: model.isMyLocationWatched,
          placeName: L10n.Weather.Weather.Notifications.myLocation
        ) {
          await model.setMyLocationWatch(!model.isMyLocationWatched)
        }
      }
    }
    .themedRowBackground(theme)
  }

  /// A bell turned on while iOS has notifications off for the app would never ring, so it is not
  /// turned on: the row says so and points at Settings (docs/MESHWX_UI.md §16).
  @ViewBuilder
  private var deniedSection: some View {
    if model.showsNotificationsDenied {
      Section {
        Text(L10n.Weather.Weather.Notifications.denied)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Button(L10n.Weather.Weather.Notifications.openSettings) {
          guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
          openURL(url)
        }
      }
      .themedRowBackground(theme)
    }
  }

  /// The bell beside a place: on means a warning covering it raises a notification, and the
  /// first one turned on is where permission is asked for.
  private func bell(
    isOn: Bool,
    placeName: String,
    action: @escaping () async -> Void
  ) -> some View {
    Button {
      Task { await action() }
    } label: {
      // 44 × 44, like every other target in the tool: the paddings that used to stand in for it
      // made a 26 × 31 pt bell (docs/MESHWX_UI.md §3.1 U-21).
      Image(systemName: isOn ? "bell.fill" : "bell")
        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isOn
      ? L10n.Weather.Weather.Notifications.stopWatching(placeName)
      : L10n.Weather.Weather.Notifications.startWatching(placeName))
    .accessibilityIdentifier("weather.places.bell.\(placeName)")
  }

  private var currentLocationDetail: String {
    let location = appState.locationService
    if location.isLocationDenied { return L10n.Weather.Weather.Picker.locationOff }
    if location.authorizationStatus == .notDetermined { return L10n.Weather.Weather.Picker.allowLocation }
    var parts: [String] = []
    if let place = model.snapshot?.place, place.kind != .searched {
      parts.append(place.label)
    } else if let label = model.currentLocationLabel {
      // A saved place is on screen: the phone's own place is not being located, it is only not
      // the one shown, so the row names it rather than claiming to be locating.
      parts.append(label)
    } else if model.placeState == .locating {
      return L10n.Weather.Weather.Header.locating
    } else {
      return L10n.Weather.Weather.Picker.noFix
    }
    return parts.joined(separator: " · ")
  }

  /// The phone's own fix, whichever place the screen is showing.
  private var phoneCoordinate: MeshWXCoordinate? {
    if let place = model.snapshot?.place, place.kind != .searched { return place.coordinate }
    return model.latestSample?.coordinate
  }

  /// The saved places, in the order the pager swipes through them: one row each, with what the
  /// phone holds for it, a bell, a **swipe to remove** and a **drag to reorder**
  /// (docs/MESHWX_UI.md §12, §3.1 U-4).
  ///
  /// Both gestures work with no mode to enter. The Edit capsule offered drag handles and, while
  /// it was on, swallowed the swipe; with it gone, `onDelete` is the standard swipe and `onMove`
  /// the standard long-press drag, and neither needs the other turned on first.
  @ViewBuilder
  private var savedSection: some View {
    if !model.savedPlaces.isEmpty {
      Section {
        WeatherCardLabel(title: L10n.Weather.Weather.Picker.saved, systemImage: "bookmark")
        ForEach(model.savedPlaces) { saved in
          HStack(spacing: 12) {
            Button {
              pick(.place(saved))
            } label: {
              placeRow(
                title: WeatherFormatting.placeName(saved.label),
                detail: distance(toLat: saved.latitude, lon: saved.longitude),
                reading: heldReading(at: saved.coordinate))
            }
            .accessibilityIdentifier("weather.places.row.\(saved.label)")
            bell(isOn: saved.isWatched, placeName: saved.label) {
              await model.setWatch(!saved.isWatched, forPlaceID: saved.id)
            }
          }
          // An explicit destructive action on the row itself, not `onDelete` on the section:
          // `onDelete` produced no Delete on a live drive, and the drag it lost to was `onMove`'s
          // (docs/MESHWX_UI.md §3.1 U-4). `swipeActions` binds the gesture to the row, so the
          // swipe is resolved here and never reaches the pager behind the sheet.
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
              model.removeSavedPlace(id: saved.id)
            } label: {
              Label(L10n.Weather.Weather.Picker.remove, systemImage: "trash")
            }
          }
        }
        .onMove { source, destination in
          model.moveSavedPlaces(fromOffsets: source, toOffset: destination)
        }
      } footer: {
        // Distances are the user's own; only with no fix at all do they borrow the page's, and
        // then they say so rather than letting a Texas list read in thousands of kilometres.
        if let borrowedOriginName {
          Text(L10n.Weather.Weather.Picker.distancesFrom(borrowedOriginName))
        }
      }
      .themedRowBackground(theme)
    }
  }

  /// Forecasts the channel carried that this phone did not ask for. Worded as what was heard,
  /// never as who asked: the phone does not record that and cannot know it.
  @ViewBuilder
  private var heardSection: some View {
    if let others = model.snapshot?.otherPlaces, !others.isEmpty {
      Section {
        WeatherCardLabel(
          title: L10n.Weather.Weather.Picker.heardOnChannel, systemImage: "antenna.radiowaves.left.and.right")
        ForEach(others) { other in
          Button {
            pick(.place(Self.saved(for: other.point)))
          } label: {
            placeRow(
              title: WeatherNames.pointLabel(other.point.name),
              detail: heardDetail(other))
          }
        }
      }
      // No "This phone can't tell who asked" footer here: it is said once, on the radio page,
      // under How it works, where the whole of how asking works is explained
      // (docs/MESHWX_UI.md §3.1 U-10).
      .themedRowBackground(theme)
    }
  }

  /// "86° Cloudy" from the nearest reading the phone holds for that place, dimmed with its age
  /// when it is stale and "—" when nothing is held (docs/MESHWX_UI.md §12).
  private func heldReading(at coordinate: MeshWXCoordinate) -> WeatherPlaceRowReading {
    WeatherPlaceRowReading.make(
      readings: model.snapshot?.readings ?? [], at: coordinate, now: model.now)
  }

  /// How far a heard forecast's point is, and — for one heard live — how long ago.
  private func heardDetail(_ other: WeatherOtherPlace) -> String {
    var parts = [distance(toLat: other.point.lat, lon: other.point.lon)]
    if let heard = heardText(other.receivedAt) { parts.append(heard) }
    return parts.joined(separator: " · ")
  }

  /// "heard 8 min ago", only for a forecast heard live: one drained from your radio's queue at
  /// connect is stamped with the drain time and would read as recent when it is not.
  private func heardText(_ receivedAt: Date) -> String? {
    guard let live = model.liveHeardAt, receivedAt <= live else { return nil }
    return L10n.Weather.Weather.Picker.heard(WeatherFormatting.ago(receivedAt, now: model.now))
  }

  /// A row: the place, what it is, and — for a place the screen can answer for — the reading the
  /// phone holds, greyed when it is old.
  private func placeRow(title: String, detail: String?, reading: WeatherPlaceRowReading? = nil) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .foregroundStyle(.primary)
        if let detail, !detail.isEmpty {
          Text(detail)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      if let reading {
        Spacer(minLength: 8)
        Text(WeatherCopy.placeRow(reading, now: model.now))
          .font(.subheadline)
          .foregroundStyle(reading.isStale || reading.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
          .multilineTextAlignment(.trailing)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }

  /// A ZIP query's one row: the ZIP, picked exactly as a town is, or a plain line saying the table
  /// does not know it.
  @ViewBuilder
  private func zipRow(_ result: ZipResult) -> some View {
    switch result {
    case let .found(zip):
      Button {
        pick(.place(Self.saved(for: zip)))
      } label: {
        placeRow(title: zip.label, detail: distance(toLat: zip.lat, lon: zip.lon))
      }
    case let .unknown(code):
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.Weather.Weather.Picker.unknownZip(code))
        Text(L10n.Weather.Weather.Picker.unknownZipHint)
          .font(.footnote)
      }
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
    }
  }

  // MARK: - Actions

  private func pick(_ action: WeatherPlacePickerAction) {
    model.pendingPlaceAction = action
    dismiss()
  }

  /// A station row: its screen, and nothing else. No page, no saved place.
  private func pick(station result: StationResult) {
    guard let index = MeshWXTables.shared.stationIndex(forICAO: result.station.icao) else { return }
    pick(.station(index: index))
  }

  private func search(_ text: String) async {
    guard !text.isEmpty else {
      found = SearchResults()
      return
    }
    try? await Task.sleep(for: .milliseconds(120))
    guard !Task.isCancelled else { return }
    let origin = origin
    // Off the main actor: 35,000 names per keystroke, and the first ZIP query reads zips.json.
    let searched = await Task.detached(priority: .userInitiated) {
      Self.results(for: text, near: origin, tables: MeshWXTables.shared)
    }.value
    guard !Task.isCancelled else { return }
    found = searched
  }

  /// What a query is searched as. A ZIP (5 digits or ZIP+4) is looked up exactly and nothing else,
  /// as the bot does; three or four letters and digits may be an airport code as well as the start
  /// of a town's name; anything else is a town.
  enum QueryKind: Sendable, Equatable {
    case zip(String)
    case townOrAirportCode
    case town
  }

  nonisolated static func queryKind(_ text: String) -> QueryKind {
    if let code = MeshWXTables.zipCode(in: text) { return .zip(code) }
    return looksLikeStationCode(text) ? .townOrAirportCode : .town
  }

  /// A ZIP query's row: the ZIP, or the five digits the table does not know.
  enum ZipResult: Sendable, Hashable {
    case found(MeshWXZip)
    case unknown(String)
  }

  /// One search's rows.
  struct SearchResults: Sendable, Equatable {
    var places: [MeshWXPlace] = []
    var stations: [StationResult] = []
    var zip: ZipResult?

    var isEmpty: Bool { places.isEmpty && stations.isEmpty && zip == nil }
  }

  /// A ZIP query gets its one ZIP row, known or not; any other query gets towns, plus stations
  /// when it looks like an airport code.
  nonisolated static func results(
    for text: String, near origin: MeshWXCoordinate?, tables: MeshWXTables
  ) -> SearchResults {
    switch queryKind(text) {
    case let .zip(code):
      return SearchResults(zip: tables.zip(code).map(ZipResult.found) ?? .unknown(code))
    case .townOrAirportCode, .town:
      // Deduplicated and ordered by the one rule for it (`WeatherPlaceSearch`): the table's
      // ranking is kept whenever there is somewhere to measure from, and two rows that read the
      // same are one row either way (docs/MESHWX_UI.md §3.1 U-22).
      return SearchResults(
        places: WeatherPlaceSearch.ordered(
          tables.searchPlaces(query: text, nearLat: origin?.latitude, lon: origin?.longitude, limit: 25),
          hasOrigin: origin != nil),
        stations: stations(matchingCode: text, near: origin, tables: tables))
    }
  }

  /// A weather station found by its airport code, with the town it is known by.
  struct StationResult: Sendable, Hashable {
    var station: MeshWXStation
    var town: MeshWXPlace?
  }

  /// "KAUS", "TJSJ", "7R5": three or four letters and digits, what an airport code looks like.
  nonisolated static func looksLikeStationCode(_ text: String) -> Bool {
    (3...4).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
  }

  /// Up to five stations whose code starts with the query, nearest first. Codes only: a name match
  /// would bury the towns under every "Municipal Airport".
  nonisolated static func stations(
    matchingCode text: String, near origin: MeshWXCoordinate?, tables: MeshWXTables
  ) -> [StationResult] {
    guard looksLikeStationCode(text) else { return [] }
    let code = text.uppercased()
    let matches = tables.stations.filter { $0.hasPrefix(code) }.compactMap { tables.station(icao: $0) }
    let ordered = matches.sorted { lhs, rhs in
      guard let origin else { return lhs.icao < rhs.icao }
      let left = MeshWXGeo.distanceKilometres(fromLat: origin.latitude, lon: origin.longitude, toLat: lhs.lat, lon: lhs.lon)
      let right = MeshWXGeo.distanceKilometres(fromLat: origin.latitude, lon: origin.longitude, toLat: rhs.lat, lon: rhs.lon)
      return left == right ? lhs.icao < rhs.icao : left < right
    }
    return ordered.prefix(5).map { StationResult(station: $0, town: tables.nearestPlace(toLat: $0.lat, lon: $0.lon, within: 15)) }
  }

  // A station found by its code is **not** a place: its row opens the station's screen and saves
  // nothing (docs/MESHWX_UI.md §3.1 U-3). The `WeatherPlace` that used to be built here is what
  // named a saved page "Eleanor Roosevelt" after picking TJSJ.

  /// A forecast point held from the channel, as a searched place.
  static func place(for point: MeshWXPoint) -> WeatherPlace {
    WeatherPlace(
      kind: .searched,
      coordinate: MeshWXCoordinate(latitude: point.lat, longitude: point.lon),
      label: WeatherNames.pointLabel(point.name),
      uncertaintyKilometres: 5,
      searchedAs: .forecastPoint)
  }

  // MARK: - Saving

  /// Every pick is kept: the list is what the sheet offers next time (docs/MESHWX_UI.md §5).
  static func saved(for place: MeshWXPlace) -> WeatherSavedPlace {
    .from(WeatherPlace.searched(place), at: Date())
  }

  static func saved(for zip: MeshWXZip) -> WeatherSavedPlace {
    .from(WeatherPlace.zip(zip), at: Date())
  }

  static func saved(for point: MeshWXPoint) -> WeatherSavedPlace {
    .from(place(for: point), at: Date())
  }

  /// How far a row is from ``origin`` — and, with nothing to measure from at all, that it is not
  /// known. A blank line was the worse answer: distance is the only thing telling one "San Juan,
  /// PR" from the next, and dropping it silently left rows that could not be told apart at all
  /// (docs/MESHWX_UI.md §3.1 U-23).
  private func distance(toLat lat: Double, lon: Double) -> String {
    guard let origin else { return L10n.Weather.Weather.Picker.distanceUnknown }
    return WeatherFormatting.kilometres(MeshWXGeo.distanceKilometres(
      fromLat: origin.latitude, lon: origin.longitude, toLat: lat, lon: lon))
  }
}
