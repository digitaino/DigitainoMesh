import Foundation
import MC1Services
import MeshWX
import SwiftUI

/// Current conditions at the METAR stations in the bot's coverage, nearest first (spec §6).
struct WeatherObservationsSection: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel

  var body: some View {
    Section {
      if model.observations.isEmpty {
        Text(L10n.Weather.Weather.Now.none)
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.observations, id: \.observation.stationIndex) { stored in
          WeatherObservationRow(stored: stored, tables: model.tables, now: model.now)
        }
      }
    } header: {
      HStack {
        Text(L10n.Weather.Weather.Now.section)
        if let observedAt {
          Text(observedAt.formatted(date: .omitted, time: .shortened))
            .foregroundStyle(.secondary)
        }
        Spacer()
        WeatherRequestButton(
          title: L10n.Weather.Weather.Now.refresh,
          model: model,
          request: .observations
        )
      }
      .textCase(nil)
    }
    .themedRowBackground(theme)
  }

  /// The batch time, which is the newest observation in it — staleness is judged for the whole
  /// batch from this one number (spec §10.3).
  private var observedAt: Date? {
    model.botState?.latestObservationMinutes.map { Date(unixMinutes: $0) }
  }
}

/// One station's reading.
///
/// Nothing here invents a value: a field the station did not report is absent, never a zero.
/// "0 mph, 0% humidity" is a plausible-looking lie, and on a weather screen that is worse than
/// a gap.
struct WeatherObservationRow: View {
  let stored: WeatherStoredObservation
  let tables: MeshWXTables
  let now: Date

  private var observation: MeshWXStationObservation { stored.observation }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: MeshWXPresentation.symbolName(for: observation.sky, isNight: isNight))
        .font(.title3)
        .frame(width: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(stationName)
            .font(.headline)
          if stored.isStale(at: now) {
            WeatherBadge(text: L10n.Weather.Weather.Now.stale, tint: .orange)
          }
        }
        Text(icaoLine)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(conditionsLine)
          .font(.subheadline)
        if !detailLine.isEmpty {
          Text(detailLine)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: - Lines

  private var station: MeshWXStation? {
    tables.station(at: observation.stationIndex)
  }

  private var stationName: String {
    guard let station else { return tables.stationLabel(observation.stationIndex) }
    return WeatherFormatting.stationName(station.name)
  }

  private var icaoLine: String {
    guard let station else { return "" }
    return "\(station.icao) · \(station.state)"
  }

  /// Temperature, apparent temperature and wind — the three a person reads first.
  private var conditionsLine: String {
    var parts: [String] = []
    if let tempF = observation.tempF {
      parts.append(WeatherFormatting.temperature(fahrenheit: Int(tempF)))
      if observation.feelsDeltaF != 0, let feelsLike = observation.feelsLikeF {
        parts.append(
          L10n.Weather.Weather.Now.feelsLike(WeatherFormatting.temperature(fahrenheit: feelsLike))
        )
      }
    } else {
      parts.append(L10n.Weather.Weather.Common.unknownValue)
    }
    parts.append(
      WeatherFormatting.wind(MeshWXWindReading(observation: observation))
        ?? L10n.Weather.Weather.Common.unknownValue
    )
    return parts.joined(separator: " · ")
  }

  private var detailLine: String {
    var parts: [String] = []
    if let humidity = observation.humidityPercent {
      parts.append(L10n.Weather.Weather.Now.humidity(Int(humidity)))
    }
    if let pressure = observation.pressureInHg {
      parts.append(L10n.Weather.Weather.Now.pressure(WeatherFormatting.pressure(inchesOfMercury: pressure)))
    }
    if let visibility = observation.visibilityMiles {
      parts.append(
        L10n.Weather.Weather.Now.visibility(WeatherFormatting.visibility(miles: visibility))
      )
    }
    if let dewpoint = observation.dewpointF {
      parts.append(
        L10n.Weather.Weather.Now.dewpoint(WeatherFormatting.temperature(fahrenheit: Int(dewpoint)))
      )
    }
    return parts.joined(separator: " · ")
  }

  /// `sun.max` on an overnight reading is the kind of detail that makes an app look wrong at a
  /// glance, so the icon follows the hour the observation was taken.
  private var isNight: Bool {
    let hour = Calendar.autoupdatingCurrent.component(.hour, from: stored.observedAt)
    return hour < 6 || hour >= 19
  }
}
