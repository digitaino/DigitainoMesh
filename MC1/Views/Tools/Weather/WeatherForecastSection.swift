import MC1Services
import MeshWX
import SwiftUI

/// The Forecast card (docs/MESHWX_UI.md §9): the forecast for the point nearest the place, one
/// row per day or day-and-night, labelled against now.
struct WeatherForecastSection: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel
  let snapshot: WeatherScreenSnapshot
  let showsAskFootnotes: Bool
  let onUseMyLocation: () -> Void
  let onSearch: () -> Void

  static func askRequest(_ snapshot: WeatherScreenSnapshot) -> WeatherRequest? {
    WeatherToolModel.forecastRequest(for: snapshot.forecast)
  }

  var body: some View {
    let title = model.placeName.map { L10n.Weather.Weather.Forecast.title($0) } ?? L10n.Weather.Weather.Forecast.titleGeneric
    Section {
      switch snapshot.forecast {
      case .noPlace:
        WeatherPlacePrompt(onUseMyLocation: onUseMyLocation, onSearch: onSearch)
      case .noPointNearby:
        // No point close enough to speak for the place: nothing worth asking for.
        Text(WeatherCopy.noForecastPoint(placeName: model.placeName ?? ""))
          .font(.subheadline)
      case let .missing(point, kilometres):
        VStack(alignment: .leading, spacing: 8) {
          Text(WeatherCopy.forecastMissing(placeName: model.placeName ?? "", point: point, kilometres: kilometres))
            .font(.subheadline)
          WeatherAskButton(
            model: model, title: L10n.Weather.Weather.Request.askForecast, request: .forecast(point: point.index),
            showsFootnotes: showsAskFootnotes)
        }
        .padding(.vertical, 2)
      case let .forecast(summary):
        issuedRow(summary)
        ForEach(summary.rows) { row in
          WeatherForecastRowView(row: row)
            .equatable()
        }
      }
    } header: {
      VStack(alignment: .leading) {
        Text(title)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(summaryLabel(title: title))
    }
    .themedRowBackground(theme)
  }

  private func issuedText(_ summary: WeatherForecastCard.Summary) -> String {
    let issuedAt = summary.stored.issuedAt
    return summary.isStale
      ? L10n.Weather.Weather.Forecast.issued(WeatherFormatting.ago(issuedAt, now: model.now))
      : L10n.Weather.Weather.Forecast.issued(WeatherFormatting.clockTime(
        issuedAt, now: model.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
  }

  private func summaryLabel(title: String) -> String {
    guard case let .forecast(summary) = snapshot.forecast else { return title }
    return [title, issuedText(summary), L10n.Weather.Weather.Forecast.Accessibility.rows(summary.rows.count)]
      .joined(separator: ". ")
  }

  private func issuedRow(_ summary: WeatherForecastCard.Summary) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(issuedText(summary))
        .font(.subheadline)
        .foregroundStyle(summary.isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
      if case let .nearbyPoint(kilometres) = summary.source {
        Text(L10n.Weather.Weather.Forecast.nearbyPoint(
          WeatherNames.pointName(summary.point.name), WeatherFormatting.kilometres(kilometres)))
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      if summary.isStale {
        WeatherAskButton(
          model: model, title: L10n.Weather.Weather.Request.askForecast,
          request: .forecast(point: summary.point.index), showsFootnotes: showsAskFootnotes)
      }
    }
  }
}

/// One forecast row: label, icon, temperatures, rain chance, hazards.
struct WeatherForecastRowView: View, Equatable {
  @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 36

  let row: WeatherForecastRow

  nonisolated static func == (lhs: WeatherForecastRowView, rhs: WeatherForecastRowView) -> Bool {
    lhs.row == rhs.row
  }

  var body: some View {
    let icon = MeshWXPresentation.icon(
      for: MeshWXForecastPeriod(
        highF: row.highF, lowF: row.lowF, popPercent: row.popPercent, sky: row.sky, thunder: row.thunder,
        wintry: row.wintry, windy: row.windy, fog: row.fog, windDirection: row.windDirection, windMph: row.windMph),
      isNight: row.isNightIcon)
    let label = WeatherCopy.rowLabel(row.label, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)

    HStack(alignment: .center, spacing: 12) {
      HStack(spacing: 2) {
        Image(systemName: icon.symbolName)
          .symbolRenderingMode(.multicolor)
        if icon.showsWindAccent {
          Image(systemName: "wind")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .frame(minWidth: iconWidth, alignment: .leading)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.body)
        if let hazards = WeatherCopy.hazards(row) {
          Text(hazards)
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        if let temperatures = WeatherCopy.temperatures(highF: row.highF, lowF: row.lowF) {
          Text(temperatures)
            .font(.body)
            .monospacedDigit()
        }
        if let rain = WeatherCopy.rainChance(row) {
          Text(rain)
            .font(.footnote)
            .foregroundStyle(.blue)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}
