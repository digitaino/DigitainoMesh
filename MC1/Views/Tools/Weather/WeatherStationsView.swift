import MC1Services
import MeshWX
import SwiftUI

/// The airport stations whose readings the phone holds (docs/MESHWX_UI.md §12), nearest to the
/// place first: the bot's scheduled batch, then single-station answers to other people.
struct WeatherStationsView: View {
  @Environment(\.appTheme) private var theme
  @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

  let model: WeatherToolModel

  var body: some View {
    List {
      if let snapshot = model.snapshot {
        let footprint = snapshot.readings.filter(\.isInFootprint)
        let others = snapshot.readings.filter { !$0.isInFootprint }

        Section {
          Text(L10n.Weather.Weather.Stations.intro(WeatherFormatting.sentenceStart(model.sourceName)))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .themedRowBackground(theme)

        if !footprint.isEmpty {
          Section {
            ForEach(footprint) { reading in
              row(reading)
            }
          }
          .themedRowBackground(theme)
        }
        if !others.isEmpty {
          Section(L10n.Weather.Weather.Stations.others) {
            ForEach(others) { reading in
              row(reading)
            }
          }
          .themedRowBackground(theme)
        }
      }
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(L10n.Weather.Weather.Stations.title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: model, requestsOnScreen: [])
  }

  private func row(_ reading: WeatherStationReading) -> some View {
    let observation = reading.stored.observation
    let isNight = WeatherFormatting.isNight(reading.stored.observedAt, calendar: .autoupdatingCurrent)
    var meta: [String] = []
    if let kilometres = reading.distanceKilometres {
      meta.append(WeatherFormatting.distance(kilometres, direction: reading.direction))
    }
    meta.append(reading.isStale
      ? WeatherFormatting.age(reading.stored.observedAt, now: model.now)
      : L10n.Weather.Weather.Stations.asOf(WeatherFormatting.clockTime(
        reading.stored.observedAt, now: model.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)))

    return NavigationLink {
      WeatherStationDetailView(model: model, index: reading.index)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: MeshWXPresentation.symbolName(for: observation.sky, isNight: isNight))
          .symbolRenderingMode(.multicolor)
          .frame(width: iconWidth)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(WeatherNames.stationName(reading.station.name))
            .font(.headline)
          Text(meta.joined(separator: " · "))
            .font(.footnote)
            .foregroundStyle(reading.isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        Spacer(minLength: 8)
        if let tempF = observation.tempF {
          Text(WeatherFormatting.temperature(fahrenheit: Int(tempF)))
            .font(.title3)
            .monospacedDigit()
        }
      }
      .accessibilityElement(children: .combine)
    }
  }
}

/// One station's reading in full, and its coded airport reports on request.
struct WeatherStationDetailView: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel
  let index: UInt16

  private var reading: WeatherStationReading? {
    model.snapshot?.readings.first { $0.index == index }
  }

  var body: some View {
    List {
      if let reading {
        summary(reading)
        values(reading)
        airportReports(reading)
      }
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(reading.map { WeatherNames.stationName($0.station.name) } ?? L10n.Weather.Weather.Stations.title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: model, requestsOnScreen: reading.map {
      [.metar(station: $0.station.icao), .taf(station: $0.station.icao)]
    } ?? [])
  }

  private func summary(_ reading: WeatherStationReading) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Text(WeatherNames.stationName(reading.station.name))
          .font(.headline)
        Text("\(reading.station.icao) · \(reading.station.state)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text(WeatherCopy.stationSource(
          stationName: reading.station.icao,
          kilometres: reading.distanceKilometres.map { min($0, 25) },
          direction: reading.direction,
          botName: model.botName(reading.botID),
          reportedAt: reading.stored.observedAt,
          now: model.now,
          calendar: .autoupdatingCurrent,
          locale: .autoupdatingCurrent))
        .font(.footnote)
        .foregroundStyle(.secondary)
        if let kilometres = reading.distanceKilometres, let placeName = model.placeName {
          Text(L10n.Weather.Weather.Stations.fromPlace(
            WeatherFormatting.distance(kilometres, direction: reading.direction), placeName))
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        if reading.isStale {
          Text(WeatherFormatting.age(reading.stored.observedAt, now: model.now))
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      }
      .accessibilityElement(children: .combine)
    }
    .themedRowBackground(theme)
  }

  private func values(_ reading: WeatherStationReading) -> some View {
    let observation = reading.stored.observation
    return Section {
      if let tempF = observation.tempF {
        LabeledContent(L10n.Weather.Weather.Station.temperature, value: WeatherFormatting.temperature(fahrenheit: Int(tempF)))
      }
      if observation.feelsDeltaF != 0, let feelsLike = observation.feelsLikeF {
        LabeledContent(L10n.Weather.Weather.Station.feelsLike, value: WeatherFormatting.temperature(fahrenheit: feelsLike))
      }
      if let condition = WeatherFormatting.condition(observation.sky) {
        LabeledContent(L10n.Weather.Weather.Station.sky, value: condition)
      }
      if let wind = WeatherFormatting.wind(MeshWXWindReading(observation: observation)) {
        LabeledContent(L10n.Weather.Weather.Station.wind, value: wind)
      }
      if let humidity = observation.humidityPercent {
        LabeledContent(L10n.Weather.Weather.Station.humidity, value: L10n.Weather.Weather.Station.percent(Int(humidity)))
      }
      if let dewpointF = observation.dewpointF {
        LabeledContent(L10n.Weather.Weather.Station.dewPoint, value: WeatherFormatting.temperature(fahrenheit: Int(dewpointF)))
      }
      if let pressure = observation.pressureInHg {
        LabeledContent(
          L10n.Weather.Weather.Station.pressure,
          value: L10n.Weather.Weather.Station.inchesOfMercury(WeatherFormatting.pressure(inchesOfMercury: pressure)))
      }
      if let visibility = observation.visibilityMiles {
        LabeledContent(L10n.Weather.Weather.Station.visibility, value: WeatherFormatting.visibility(miles: visibility))
      }
    }
    .themedRowBackground(theme)
  }

  private func airportReports(_ reading: WeatherStationReading) -> some View {
    let icao = reading.station.icao
    return Section {
      WeatherAskButton(
        model: model, title: L10n.Weather.Weather.Request.askMetar, request: .metar(station: icao), showsFootnotes: true)
      ownText(.metar(station: icao))
      WeatherAskButton(model: model, title: L10n.Weather.Weather.Request.askTaf, request: .taf(station: icao))
      ownText(.taf(station: icao))
    } header: {
      Text(L10n.Weather.Weather.Station.airportReports)
    }
    .themedRowBackground(theme)
  }

  @ViewBuilder
  private func ownText(_ request: WeatherRequest) -> some View {
    if let item = model.snapshot?.texts.first(where: { $0.assembly.request == request }) {
      VStack(alignment: .leading, spacing: 4) {
        Text(WeatherReportText.body(item.assembly))
          .font(.system(.footnote, design: .monospaced))
          .textSelection(.enabled)
        Text(L10n.Weather.Weather.Reports.received(WeatherFormatting.clockTime(
          item.assembly.lastReceivedAt, now: model.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)))
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}
