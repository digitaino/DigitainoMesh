import Foundation
import MC1Services
import MeshWX
import SwiftUI

/// The narrative products (spec §8.1): request only, never broadcast, so this section is a set
/// of buttons and whatever came back from them.
struct WeatherTextSection: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel

  /// Nil means "whatever the data suggests"; a pick sticks for the session.
  @State private var pickedState: String?
  @State private var pickedStationICAO: String?

  var body: some View {
    Section(L10n.Weather.Weather.Text.section) {
      officeButtons
      statePicker
      stationPicker
      receivedTexts
    }
    .themedRowBackground(theme)
  }

  // MARK: - Buttons

  @ViewBuilder
  private var officeButtons: some View {
    WeatherRequestButton(
      title: L10n.Weather.Weather.Text.discussion,
      systemImage: "text.alignleft",
      model: model,
      request: .forecastDiscussion(office: officeCode ?? ""),
      isEnabled: officeCode != nil
    )
    WeatherRequestButton(
      title: L10n.Weather.Weather.Text.hazardousOutlook,
      systemImage: "exclamationmark.bubble",
      model: model,
      request: .hazardousOutlook
    )
    WeatherRequestButton(
      title: L10n.Weather.Weather.Text.spaceWeather,
      systemImage: "sun.max.trianglebadge.exclamationmark",
      model: model,
      request: .spaceWeather
    )
  }

  @ViewBuilder
  private var statePicker: some View {
    if let state = effectiveState {
      VStack(alignment: .leading, spacing: 10) {
        if candidateStates.count > 1 {
          Picker(L10n.Weather.Weather.Text.state, selection: statePickerBinding(default: state)) {
            ForEach(candidateStates, id: \.self) { candidate in
              Text(candidate).tag(candidate)
            }
          }
          .pickerStyle(.segmented)
        }
        HStack(spacing: 20) {
          WeatherRequestButton(
            title: L10n.Weather.Weather.Text.stormReports,
            model: model,
            request: .stormReports(state: state)
          )
          WeatherRequestButton(
            title: L10n.Weather.Weather.Text.rainfall,
            model: model,
            request: .rainfall(state: state)
          )
        }
      }
    }
  }

  @ViewBuilder
  private var stationPicker: some View {
    if let station = effectiveStationICAO {
      VStack(alignment: .leading, spacing: 10) {
        if candidateStations.count > 1 {
          Picker(L10n.Weather.Weather.Text.station, selection: stationPickerBinding(default: station)) {
            ForEach(candidateStations, id: \.self) { icao in
              Text(icao).tag(icao)
            }
          }
          .pickerStyle(.menu)
        }
        HStack(spacing: 20) {
          WeatherRequestButton(
            title: L10n.Weather.Weather.Text.metar,
            model: model,
            request: .metar(station: station)
          )
          WeatherRequestButton(
            title: L10n.Weather.Weather.Text.taf,
            model: model,
            request: .taf(station: station)
          )
        }
      }
    }
  }

  // MARK: - Received

  @ViewBuilder
  private var receivedTexts: some View {
    ForEach(model.texts, id: \.group) { assembly in
      NavigationLink {
        WeatherTextDetailView(model: model, group: assembly.group)
      } label: {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 8) {
            Text(WeatherFormatting.subjectTitle(assembly.subject))
              .font(.headline)
            if !assembly.isComplete {
              WeatherBadge(text: L10n.Weather.Weather.Text.partial, tint: .orange)
            }
          }
          Text(assembly.lastReceivedAt.formatted(.relative(presentation: .named)))
            .font(.caption)
            .foregroundStyle(.secondary)
          if let firstLine = firstLine(of: assembly) {
            Text(firstLine)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }
    }
  }

  private func firstLine(of assembly: WeatherTextAssembly) -> String? {
    assembly.orderedChunks
      .compactMap { $0 }
      .joined()
      .split(whereSeparator: \.isNewline)
      .first
      .map(String.init)
  }

  // MARK: - Arguments
  //
  // Every one of these requests names something. Defaulting them from what the bot already
  // sent — the office of a forecast it issued, the state of the nearest station it reports —
  // is what keeps the common case to one tap instead of a form.

  private var effectiveState: String? {
    if let pickedState, candidateStates.contains(pickedState) { return pickedState }
    return defaultState ?? candidateStates.first
  }

  private func statePickerBinding(default state: String) -> Binding<String> {
    Binding(get: { state }, set: { pickedState = $0 })
  }

  /// The nearest station's state: the one the user is standing in, as far as the bot knows.
  private var defaultState: String? {
    model.observations.lazy
      .compactMap { model.tables.station(at: $0.observation.stationIndex)?.state }
      .first
  }

  /// The states the bot's office covers, plus whatever its stations are in — a storm report
  /// for a state the office does not serve is an empty answer and wasted airtime.
  private var candidateStates: [String] {
    var states: [String] = []
    if let officeCode, let office = model.tables.office(officeCode) {
      states = office.states
    }
    for stored in model.observations {
      guard let state = model.tables.station(at: stored.observation.stationIndex)?.state,
            !states.contains(state)
      else { continue }
      states.append(state)
    }
    return states
  }

  private var effectiveStationICAO: String? {
    if let pickedStationICAO, candidateStations.contains(pickedStationICAO) { return pickedStationICAO }
    return candidateStations.first
  }

  private func stationPickerBinding(default station: String) -> Binding<String> {
    Binding(get: { station }, set: { pickedStationICAO = $0 })
  }

  /// Only the stations the bot actually reports: asking for a METAR it does not carry is a
  /// Not-available message and 400 ms of everyone's airtime.
  private var candidateStations: [String] {
    model.observations.compactMap { model.tables.stationICAO($0.observation.stationIndex) }
  }

  /// The office to ask for a discussion: the one that issued a forecast the app holds, else
  /// the office nearest the bot.
  private var officeCode: String? {
    if let held = model.forecasts.lazy.compactMap({ model.tables.point(at: $0.forecast.pointIndex)?.office }).first {
      return held
    }
    guard let reference = referenceCoordinate else { return nil }
    return nearestOfficeCode(toLat: reference.latitude, lon: reference.longitude)
  }

  /// Where the bot is, or failing that where its nearest station is — either is close enough
  /// to pick the right forecast office out of a national list.
  private var referenceCoordinate: (latitude: Double, longitude: Double)? {
    if let bot = model.selectedBot, bot.hasLocation {
      return (bot.latitude, bot.longitude)
    }
    guard let station = model.observations.lazy
      .compactMap({ model.tables.station(at: $0.observation.stationIndex) })
      .first
    else { return nil }
    return (station.lat, station.lon)
  }

  /// `MeshWXTables` has no nearest-office lookup, so this walks the office list it does expose
  /// (a few hundred rows) and keeps the closest.
  private func nearestOfficeCode(toLat lat: Double, lon: Double) -> String? {
    var best: String?
    var bestDistance = Double.infinity
    for code in model.tables.offices {
      guard let office = model.tables.office(code) else { continue }
      let distance = MeshWXGeo.distanceKilometres(
        fromLat: lat, lon: lon, toLat: office.lat, lon: office.lon
      )
      if distance < bestDistance {
        bestDistance = distance
        best = code
      }
    }
    return best
  }
}
