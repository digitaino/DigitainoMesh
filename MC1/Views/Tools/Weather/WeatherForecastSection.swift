import MC1Services
import MeshWX
import SwiftUI

/// The forecast (docs/MESHWX_UI.md §9): the forecast for the point nearest the place, one row per
/// day or day-and-night, labelled against now.
///
/// It is a card on the place's page, not a card that opens one. Its label carries the one time it
/// has — "FORECAST · ISSUED 4:02 PM" — and its last line names the point the rows are for, and
/// how far that is from the place. The place is named by the screen, not repeated here. Nothing
/// here asks the radio: a missing or stale forecast is what the pull and Update plan for (§11).
struct WeatherForecastSection: View {
  @Environment(\.appTheme) private var theme

  /// The page this forecast answers for.
  let screen: WeatherPageScreen

  private var snapshot: WeatherScreenSnapshot { screen.snapshot }

  var body: some View {
    let title = L10n.Weather.Weather.Forecast.titleGeneric
    Section {
      WeatherCardLabel(
        title: title, systemImage: "calendar", trailing: issuedText,
        accessibilityLabel: summaryLabel(title: title))
      switch snapshot.forecast {
      case .noPlace:
        Text(L10n.Weather.Weather.Place.choosePrompt)
          .font(.subheadline)
      case .noPointNearby:
        // No point close enough to speak for the place: nothing worth asking for.
        Text(WeatherCopy.noForecastPoint(placeName: screen.placeName ?? ""))
          .font(.subheadline)
      case let .missing(point, kilometres):
        Text(WeatherCopy.forecastMissing(placeName: screen.placeName ?? "", point: point, kilometres: kilometres))
          .font(.subheadline)
          .padding(.vertical, 2)
      case let .forecast(summary):
        ForEach(summary.rows) { row in
          WeatherForecastRowView(row: row)
            .equatable()
        }
        // **The card names its point** (docs/MESHWX_UI.md §3.1 U-9). A forecast is for a point,
        // and two towns twenty kilometres apart share one: Round Rock and Austin showed the same
        // seven rows with nothing on either page to say they were one Camp Mabry forecast rather
        // than two forecasts that happened to agree. And "heard on #meshwx" for one this phone
        // never asked for (§3.1 U-14).
        Text(pointLine(summary))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .listRowSeparator(.hidden)
      }
    }
    .themedRowBackground(theme)
  }

  /// "issued 4:02 PM", or "issued 14 h ago" once it is stale. Nothing until there is a forecast.
  private var issuedText: String? {
    guard case let .forecast(summary) = snapshot.forecast else { return nil }
    let issuedAt = summary.stored.issuedAt
    return summary.isStale
      ? L10n.Weather.Weather.Forecast.issued(WeatherFormatting.ago(issuedAt, now: screen.now))
      : L10n.Weather.Weather.Forecast.issued(WeatherFormatting.clockTime(
        issuedAt, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
  }

  /// "Austin Camp Mabry · 6 km", the distance left out when the point is the place, and
  /// "· heard on #meshwx" when somebody else on the channel asked for it.
  private func pointLine(_ summary: WeatherForecastCard.Summary) -> String {
    var parts = [WeatherNames.pointLabel(summary.point.name)]
    if summary.kilometres >= 1 { parts.append(WeatherFormatting.kilometres(summary.kilometres)) }
    if !summary.isOwn { parts.append(L10n.Weather.Weather.Reports.overheard) }
    return parts.joined(separator: " · ")
  }

  private func summaryLabel(title: String) -> String {
    guard case let .forecast(summary) = snapshot.forecast else { return title }
    return [title, issuedText, pointLine(summary),
            L10n.Weather.Weather.Forecast.Accessibility.rows(summary.rows.count)]
      .compactMap { $0 }
      .joined(separator: ". ")
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
