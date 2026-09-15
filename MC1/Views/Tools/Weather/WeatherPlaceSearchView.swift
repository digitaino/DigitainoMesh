import CoreLocation
import Foundation
import MC1Services
import MeshWX
import SwiftUI

/// Search for a place to forecast (spec §11).
///
/// The bot forecasts for *points*, not for places, so picking "Round Rock, TX" sends the index
/// of the nearest bundled point. The row says which point that is and how far off it sits
/// before the tap, rather than letting the answer come back with a name the user did not ask
/// for.
struct WeatherPlaceSearchView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel
  let origin: CLLocationCoordinate2D?

  @State private var query = ""

  var body: some View {
    NavigationStack {
      List {
        Section {
          if results.isEmpty {
            Text(query.isEmpty
              ? L10n.Weather.Weather.PlaceSearch.prompt
              : L10n.Weather.Weather.PlaceSearch.empty)
              .foregroundStyle(.secondary)
          } else {
            ForEach(results, id: \.self) { place in
              Button {
                pick(place)
              } label: {
                row(for: place)
              }
              .buttonStyle(.plain)
            }
          }
        }
        .themedRowBackground(theme)
      }
      .listStyle(.insetGrouped)
      .themedCanvas(theme)
      .searchable(text: $query, prompt: Text(L10n.Weather.Weather.PlaceSearch.prompt))
      .navigationTitle(L10n.Weather.Weather.PlaceSearch.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(L10n.Weather.Weather.Common.cancel) { dismiss() }
        }
      }
    }
  }

  private func row(for place: MeshWXPlace) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(L10n.Weather.Weather.PlaceSearch.place(place.name, place.state))
          .font(.headline)
        Spacer(minLength: 8)
        if let distance = distanceFromUser(to: place) {
          Text(distance)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      if let point = nearestPoint(to: place) {
        Text(L10n.Weather.Weather.PlaceSearch.point(
          point.name,
          WeatherFormatting.distance(metres: metres(from: place, to: point))
        ))
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var results: [MeshWXPlace] {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    return model.tables.searchPlaces(
      query: query,
      nearLat: origin?.latitude,
      lon: origin?.longitude,
      limit: 25
    )
  }

  private func nearestPoint(to place: MeshWXPlace) -> MeshWXPoint? {
    model.tables.nearestPoint(toLat: place.lat, lon: place.lon)
  }

  private func metres(from place: MeshWXPlace, to point: MeshWXPoint) -> Double {
    MeshWXGeo.distanceKilometres(
      fromLat: place.lat, lon: place.lon, toLat: point.lat, lon: point.lon
    ) * 1000
  }

  private func distanceFromUser(to place: MeshWXPlace) -> String? {
    guard let origin else { return nil }
    let kilometres = MeshWXGeo.distanceKilometres(
      fromLat: origin.latitude, lon: origin.longitude, toLat: place.lat, lon: place.lon
    )
    return WeatherFormatting.distance(metres: kilometres * 1000)
  }

  private func pick(_ place: MeshWXPlace) {
    guard let point = nearestPoint(to: place) else { return }
    dismiss()
    Task { await model.send(.forecast(point: point.index)) }
  }
}
