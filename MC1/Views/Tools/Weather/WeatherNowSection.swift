import MC1Services
import MeshWX
import SwiftUI

/// The Now card (docs/MESHWX_UI.md §8): one station's reading, the nearest fresh one to the
/// place, with every field from that station and a line naming it. No section header, so the card
/// sits higher on a storm night.
struct WeatherNowSection: View {
  @Environment(\.appTheme) private var theme
  @ScaledMetric(relativeTo: .largeTitle) private var temperatureSize: CGFloat = 52

  let model: WeatherToolModel
  let snapshot: WeatherScreenSnapshot
  let showsAskFootnotes: Bool
  let onUseMyLocation: () -> Void
  let onSearch: () -> Void

  /// The request the card's button sends, when it shows one.
  static func askRequest(_ snapshot: WeatherScreenSnapshot, context: WeatherScreenContext) -> WeatherRequest? {
    switch snapshot.primaryStation {
    case .noObservations: .observations
    case let .reading(reading) where reading.isStale: WeatherToolModel.observationsRequest(for: reading)
    // No held reading near the place, but a station is: ask for that one station.
    case .noneNearby: context.nearbyStation.map { .observation(station: $0.icao) }
    case .reading, .noPlace: nil
    }
  }

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 0) {
        card
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(L10n.Weather.Weather.Now.summary)

      if !snapshot.readings.isEmpty {
        NavigationLink {
          WeatherStationsView(model: model)
        } label: {
          Text(WeatherCopy.stationLink(
            inArea: snapshot.readings.filter(\.isInFootprint).count, total: snapshot.readings.count,
            source: model.sourceName))
          .font(.subheadline)
        }
      }
    }
    .themedRowBackground(theme)
  }

  @ViewBuilder
  private var card: some View {
    switch snapshot.primaryStation {
    case let .reading(reading):
      if reading.isStale {
        staleRow(reading)
      } else {
        readingRow(reading)
      }
    case let .noneNearby(nearest):
      if let station = model.context.nearbyStation {
        VStack(alignment: .leading, spacing: 8) {
          Text(WeatherCopy.stationNotHeard(
            placeName: model.placeName ?? "", stationName: station.name, kilometres: station.kilometres))
          .font(.subheadline)
          WeatherAskButton(
            model: model, title: L10n.Weather.Weather.Request.askConditions,
            request: .observation(station: station.icao), showsFootnotes: showsAskFootnotes)
        }
        .padding(.vertical, 2)
      } else {
        Text(WeatherCopy.noStationNearby(
          placeName: model.placeName ?? "",
          nearestTown: model.context.nearestStationTown ?? WeatherNames.stationName(nearest.station.name),
          kilometres: nearest.distanceKilometres))
        .font(.subheadline)
      }
    case .noObservations:
      VStack(alignment: .leading, spacing: 8) {
        Text(L10n.Weather.Weather.Now.empty(WeatherFormatting.sentenceStart(model.sourceName)))
          .font(.subheadline)
        WeatherAskButton(
          model: model, title: L10n.Weather.Weather.Request.askConditions, request: .observations,
          showsFootnotes: showsAskFootnotes)
      }
      .padding(.vertical, 2)
    case .noPlace:
      WeatherPlacePrompt(onUseMyLocation: onUseMyLocation, onSearch: onSearch)
    }
  }

  // MARK: - Rows

  private func readingRow(_ reading: WeatherStationReading) -> some View {
    let observation = reading.stored.observation
    let calendar = Calendar.autoupdatingCurrent
    let symbol = MeshWXPresentation.symbolName(
      for: observation.sky, isNight: WeatherFormatting.isNight(reading.stored.observedAt, calendar: calendar))

    return VStack(alignment: .leading, spacing: 6) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 14) { headline(observation, symbol: symbol) }
        VStack(alignment: .leading, spacing: 6) { headline(observation, symbol: symbol) }
      }
      if let details = details(observation) {
        Text(details)
          .font(.subheadline)
      }
      Text(source(reading))
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func headline(_ observation: MeshWXStationObservation, symbol: String) -> some View {
    if let tempF = observation.tempF {
      Text(WeatherFormatting.temperature(fahrenheit: Int(tempF)))
        .font(.system(size: temperatureSize, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    Image(systemName: symbol)
      .font(.system(size: temperatureSize * 0.6))
      .symbolRenderingMode(.multicolor)
      .accessibilityHidden(true)
    VStack(alignment: .leading, spacing: 2) {
      if let condition = WeatherFormatting.condition(observation.sky) {
        Text(condition)
          .font(.title3)
      }
      if observation.feelsDeltaF != 0, let feelsLike = observation.feelsLikeF {
        Text(L10n.Weather.Weather.Now.feelsLike(WeatherFormatting.temperature(fahrenheit: feelsLike)))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func details(_ observation: MeshWXStationObservation) -> String? {
    var parts: [String] = []
    if let wind = WeatherFormatting.wind(MeshWXWindReading(observation: observation)) {
      parts.append(L10n.Weather.Weather.Now.wind(wind))
    }
    if let humidity = observation.humidityPercent {
      parts.append(L10n.Weather.Weather.Now.humidity(Int(humidity)))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func source(_ reading: WeatherStationReading) -> String {
    WeatherCopy.stationSource(
      stationName: WeatherNames.stationName(reading.station.name),
      kilometres: reading.distanceKilometres,
      direction: reading.direction,
      botName: model.botName(reading.botID),
      reportedAt: reading.stored.observedAt,
      now: model.now,
      calendar: .autoupdatingCurrent,
      locale: .autoupdatingCurrent)
  }

  /// No fresh station within 80 km: the nearest reading, small, with its age.
  private func staleRow(_ reading: WeatherStationReading) -> some View {
    let observation = reading.stored.observation
    var parts: [String] = []
    if let tempF = observation.tempF {
      parts.append(WeatherFormatting.temperature(fahrenheit: Int(tempF)))
    }
    parts.append(WeatherNames.stationName(reading.station.name))
    parts.append(WeatherFormatting.age(reading.stored.observedAt, now: model.now))

    return VStack(alignment: .leading, spacing: 8) {
      Text(parts.joined(separator: " · "))
        .font(.subheadline)
        .foregroundStyle(.orange)
      WeatherAskButton(
        model: model, title: L10n.Weather.Weather.Request.askConditions,
        request: WeatherToolModel.observationsRequest(for: reading), showsFootnotes: showsAskFootnotes)
    }
    .padding(.vertical, 2)
  }
}
