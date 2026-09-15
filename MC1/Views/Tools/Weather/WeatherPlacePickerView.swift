import MC1Services
import MeshWX
import SwiftUI

/// Choose the place the screen answers for (docs/MESHWX_UI.md §12): your location, a searched
/// town, or a place somebody else on the mesh asked about.
///
/// `.searchable` on its own list rather than a child sheet. A pick is left on the model and
/// applied by the screen once this sheet is gone.
struct WeatherPlacePickerView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme
  @Environment(\.appState) private var appState

  let model: WeatherToolModel

  @State private var query = ""
  @State private var results: [MeshWXPlace] = []
  @State private var stationResults: [StationResult] = []

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Where distances are measured from: the place on screen.
  private var origin: MeshWXCoordinate? {
    model.snapshot?.place?.coordinate
  }

  var body: some View {
    NavigationStack {
      List {
        if trimmedQuery.isEmpty {
          currentLocationSection
          otherPlacesSection
        } else {
          Section {
            if results.isEmpty, stationResults.isEmpty {
              Text(L10n.Weather.Weather.Picker.noResults)
                .foregroundStyle(.secondary)
            } else {
              ForEach(results, id: \.self) { place in
                Button {
                  pick(.place(WeatherPlace.searched(place)))
                } label: {
                  placeRow(
                    title: WeatherNames.placeLabel(name: place.name, state: place.state),
                    detail: distance(toLat: place.lat, lon: place.lon))
                }
              }
            }
          }
          .themedRowBackground(theme)
          if !stationResults.isEmpty {
            Section(L10n.Weather.Weather.Stations.title) {
              ForEach(stationResults, id: \.self) { result in
                Button {
                  pick(.place(Self.place(for: result)))
                } label: {
                  placeRow(
                    title: WeatherNames.stationName(result.station.name),
                    detail: [result.station.icao, distance(toLat: result.station.lat, lon: result.station.lon)]
                      .compactMap { $0 }.joined(separator: " · "))
                }
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
      .task(id: trimmedQuery) {
        await search(trimmedQuery)
      }
      .navigationTitle(L10n.Weather.Weather.Picker.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Weather.Weather.Common.cancel) { dismiss() }
        }
      }
    }
  }

  // MARK: - Sections

  private var currentLocationSection: some View {
    Section {
      Button {
        pick(.currentLocation)
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "location.fill")
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
          placeRow(title: L10n.Weather.Weather.Picker.yourLocation, detail: currentLocationDetail)
          if model.searchedPlace == nil, model.snapshot?.place != nil {
            Image(systemName: "checkmark")
              .foregroundStyle(.tint)
              .accessibilityLabel(L10n.Weather.Weather.Common.selected)
          }
        }
      }
    }
    .themedRowBackground(theme)
  }

  private var currentLocationDetail: String {
    let location = appState.locationService
    if location.isLocationDenied { return L10n.Weather.Weather.Picker.locationOff }
    if location.authorizationStatus == .notDetermined { return L10n.Weather.Weather.Picker.allowLocation }
    if let place = model.snapshot?.place, place.kind != .searched { return place.label }
    return L10n.Weather.Weather.Header.locating
  }

  @ViewBuilder
  private var otherPlacesSection: some View {
    if let others = model.snapshot?.otherPlaces, !others.isEmpty {
      Section {
        ForEach(others) { other in
          Button {
            pick(.place(Self.place(for: other.point)))
          } label: {
            placeRow(
              title: WeatherFormatting.pointLabel(other.point.name),
              detail: [
                distance(toLat: other.point.lat, lon: other.point.lon),
                heardText(other.receivedAt)
              ].compactMap { $0 }.joined(separator: " · "))
          }
        }
      } header: {
        Text(L10n.Weather.Weather.Picker.others(model.sourceName))
      } footer: {
        Text(L10n.Weather.Weather.Picker.othersFooter(model.sourceName))
      }
      .themedRowBackground(theme)
    }
  }

  /// "heard 8 min ago", only for a forecast heard live: one drained from your radio's queue at
  /// connect is stamped with the drain time and would read as recent when it is not.
  private func heardText(_ receivedAt: Date) -> String? {
    guard let live = model.liveHeardAt, receivedAt <= live else { return nil }
    return L10n.Weather.Weather.Picker.heard(WeatherFormatting.ago(receivedAt, now: model.now))
  }

  private func placeRow(title: String, detail: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .foregroundStyle(.primary)
      if let detail, !detail.isEmpty {
        Text(detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }

  // MARK: - Actions

  private func pick(_ action: WeatherPlacePickerAction) {
    model.pendingPlaceAction = action
    dismiss()
  }

  private func search(_ text: String) async {
    guard !text.isEmpty else {
      results = []
      stationResults = []
      return
    }
    try? await Task.sleep(for: .milliseconds(120))
    guard !Task.isCancelled else { return }
    let origin = origin
    let found = await Task.detached(priority: .userInitiated) { () -> ([MeshWXPlace], [StationResult]) in
      let tables = MeshWXTables.shared
      let places = tables.searchPlaces(query: text, nearLat: origin?.latitude, lon: origin?.longitude, limit: 25)
      return (places, Self.stations(matchingCode: text, near: origin, tables: tables))
    }.value
    guard !Task.isCancelled else { return }
    results = found.0
    stationResults = found.1
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

  /// A station found by its code, as a searched place: named by its town when one is close.
  static func place(for result: StationResult) -> WeatherPlace {
    let label = result.town.map { WeatherNames.placeLabel(name: $0.name, state: $0.state) }
      ?? WeatherNames.placeLabel(name: WeatherNames.stationName(result.station.name), state: result.station.state)
    return WeatherPlace(
      kind: .searched,
      coordinate: MeshWXCoordinate(latitude: result.station.lat, longitude: result.station.lon),
      label: label,
      uncertaintyKilometres: 5)
  }

  private func distance(toLat lat: Double, lon: Double) -> String? {
    guard let origin else { return nil }
    return WeatherFormatting.kilometres(MeshWXGeo.distanceKilometres(
      fromLat: origin.latitude, lon: origin.longitude, toLat: lat, lon: lon))
  }

  /// Somebody else's forecast point, as a searched place for this visit.
  static func place(for point: MeshWXPoint) -> WeatherPlace {
    WeatherPlace(
      kind: .searched,
      coordinate: MeshWXCoordinate(latitude: point.lat, longitude: point.lon),
      label: WeatherFormatting.pointLabel(point.name),
      uncertaintyKilometres: 5)
  }
}
