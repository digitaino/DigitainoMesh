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
            if results.isEmpty {
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
      return
    }
    try? await Task.sleep(for: .milliseconds(120))
    guard !Task.isCancelled else { return }
    let origin = origin
    let found = await Task.detached(priority: .userInitiated) {
      MeshWXTables.shared.searchPlaces(query: text, nearLat: origin?.latitude, lon: origin?.longitude, limit: 25)
    }.value
    guard !Task.isCancelled else { return }
    results = found
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
