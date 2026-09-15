import CoreLocation
import Foundation
import MC1Services
import MeshWX
import SwiftUI

/// Point forecasts (spec §7), most recently received first, so the answer to the last request
/// is on top.
struct WeatherForecastSection: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel
  let userLocation: CLLocationCoordinate2D?
  let onFindPlace: () -> Void

  var body: some View {
    Section(L10n.Weather.Weather.Forecast.section) {
      if model.forecasts.isEmpty {
        Text(L10n.Weather.Weather.Forecast.none)
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.forecasts, id: \.forecast.pointIndex) { stored in
          forecastHeader(stored)
          ForEach(Array(stored.forecast.periods.enumerated()), id: \.offset) { offset, period in
            WeatherForecastPeriodRow(
              period: period,
              periodID: stored.forecast.firstPeriod &+ UInt8(truncatingIfNeeded: offset),
              issuedAt: stored.issuedAt
            )
          }
        }
      }

      requestButtons
    }
    .themedRowBackground(theme)
  }

  // MARK: - Header

  private func forecastHeader(_ stored: WeatherStoredForecast) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        Text(pointName(stored))
          .font(.headline)
        if stored.isStale(at: model.now) {
          WeatherBadge(text: L10n.Weather.Weather.Forecast.stale, tint: .orange)
        }
      }
      Text(L10n.Weather.Weather.Forecast.issued(stored.issuedAt.formatted(date: .abbreviated, time: .shortened)))
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  /// A forecast the bot resolved from a place string carries no point name on the wire, so the
  /// request text is the only label there is — and it is labelled as approximate, because the
  /// answer is for the nearest point, not for the place asked about (spec §7, §11).
  private func pointName(_ stored: WeatherStoredForecast) -> String {
    if let point = model.tables.point(at: stored.forecast.pointIndex) {
      return point.name
    }
    if let requestLabel = stored.requestLabel {
      return L10n.Weather.Weather.Forecast.nearestPoint(requestLabel)
    }
    return L10n.Weather.Weather.Forecast.point(Int(stored.forecast.pointIndex))
  }

  // MARK: - Requests

  private var requestButtons: some View {
    VStack(alignment: .leading, spacing: 12) {
      WeatherRequestButton(
        title: L10n.Weather.Weather.Forecast.home,
        systemImage: "house",
        model: model,
        request: .homeForecast
      )
      WeatherRequestButton(
        title: L10n.Weather.Weather.Forecast.myLocation,
        systemImage: "location",
        model: model,
        request: .forecast(point: nearestPointIndex ?? 0),
        isEnabled: nearestPointIndex != nil
      )
      Button {
        onFindPlace()
      } label: {
        Label(L10n.Weather.Weather.Forecast.findPlace, systemImage: "magnifyingglass")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(canFindPlace ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
      .disabled(!canFindPlace)
    }
  }

  private var canFindPlace: Bool {
    model.canSendRequests && !model.hasPendingRequest
  }

  /// The nearest bundled point to the phone: "forecast here" is `>f <index>`, never a
  /// coordinate — the bot has no way to forecast for a point it does not hold (spec §11).
  private var nearestPointIndex: UInt16? {
    guard let userLocation else { return nil }
    return model.tables
      .nearestPoint(toLat: userLocation.latitude, lon: userLocation.longitude)?
      .index
  }
}

/// One forecast period: when, what it looks like, the one temperature the period carries, the
/// chance of rain and the wind.
struct WeatherForecastPeriodRow: View {
  let period: MeshWXForecastPeriod
  let periodID: UInt8
  let issuedAt: Date

  private var slot: MeshWXPeriodSlot { MeshWXPeriodSlot(periodID: periodID) }

  var body: some View {
    HStack(spacing: 12) {
      icon
        .frame(width: 34, alignment: .leading)
        .accessibilityHidden(true)

      Text(WeatherFormatting.periodLabel(periodID: periodID, issuedAt: issuedAt))
        .font(.subheadline)

      Spacer(minLength: 8)

      Text(trailingText)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
  }

  /// Wind is an accent rather than a replacement: "windy and raining" still has to read as
  /// rain (`MeshWXConditionIcon`).
  private var icon: some View {
    let condition = MeshWXPresentation.icon(for: period, isNight: slot.isNight)
    return HStack(spacing: 2) {
      Image(systemName: condition.symbolName)
      if condition.showsWindAccent {
        Image(systemName: "wind")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// A day period carries a high and a night period a low; showing the missing one as a dash
  /// would suggest the bot sent something it did not.
  private var trailingText: String {
    var parts: [String] = []
    if let highF = period.highF {
      parts.append(L10n.Weather.Weather.Forecast.high(WeatherFormatting.temperature(fahrenheit: Int(highF))))
    } else if let lowF = period.lowF {
      parts.append(L10n.Weather.Weather.Forecast.low(WeatherFormatting.temperature(fahrenheit: Int(lowF))))
    }
    if let pop = period.popPercent {
      parts.append(L10n.Weather.Weather.Forecast.pop(Int(pop)))
    }
    if let wind = WeatherFormatting.wind(MeshWXWindReading(period: period)) {
      parts.append(wind)
    }
    return parts.joined(separator: " · ")
  }
}
