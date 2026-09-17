import MC1Services
import MeshWX
import SwiftUI

/// One alert: colour bar, icon, event, when it ends, one line of tags, and — on the alerts
/// list — where it is.
///
/// The card these rows used to sit in is gone (docs/MESHWX_UI.md §7): on a place page one alert
/// covering the place is a banner of fixed height, and every other row lives in the alerts list on
/// the radio page.
struct WeatherAlertRow: View, Equatable {
  @ScaledMetric(relativeTo: .title3) private var iconWidth: CGFloat = 28

  let item: WeatherAlertItem
  let placeName: String?
  let now: Date
  /// "Llano County · 105 km W", for rows away from the place.
  var location: String?

  nonisolated static func == (lhs: WeatherAlertRow, rhs: WeatherAlertRow) -> Bool {
    lhs.item == rhs.item && lhs.placeName == rhs.placeName && lhs.now == rhs.now && lhs.location == rhs.location
  }

  var body: some View {
    let tables = MeshWXTables.shared
    let tint = WeatherFormatting.color(for: WeatherFormatting.tint(for: item.warning.event, tables: tables))
    let qualifier = WeatherCopy.alertQualifier(item, placeName: placeName, now: now)
    let tags = WeatherFormatting.tagLine(for: item.warning)

    HStack(alignment: .top, spacing: 10) {
      Image(systemName: WeatherFormatting.symbol(for: item.warning.event, tables: tables))
        .font(.title3)
        .foregroundStyle(tint)
        .frame(width: iconWidth)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(WeatherFormatting.eventName(item.warning.event, tables: tables))
          .font(.headline)
        if item.kind == .active {
          Text(WeatherFormatting.untilLine(
            expiresAt: item.expiresAt, now: now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
          .font(.subheadline)
        }
        if let qualifier {
          Text(qualifier)
            .font(.subheadline)
            .foregroundStyle(item.kind == .active ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }
        if let location {
          Text(location)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        if !tags.isEmpty {
          Text(tags)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
    }
    .padding(.leading, 10)
    .overlay(alignment: .leading) {
      Capsule()
        .fill(tint)
        .frame(width: 4)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
}

/// The §7.4 line, with its action and the alerts' source under it. It is on the alerts list, on
/// the radio page, and nowhere else: a place page says nothing about alerts on a quiet day (§13).
struct WeatherAlertStatusRow: View {
  let screen: WeatherPageScreen
  let line: WeatherCopy.AlertStatusLine
  let source: String
  /// The request the line's own button sends.
  let request: WeatherRequest?
  let showsAskFootnotes: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(line.text)
        .font(.subheadline)
      if let caption = line.caption {
        Text(caption)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      switch line.action {
      case .askForAlerts:
        if let request {
          WeatherAskButton(
            screen: screen, title: WeatherCopy.askAlertsTitle(for: request, tables: .shared), request: request,
            showsFootnotes: showsAskFootnotes)
        }
      case .updateLocation:
        Button(L10n.Weather.Weather.Place.updateLocation) {
          screen.model.updateLocation()
        }
        .buttonStyle(.borderless)
      case nil:
        EmptyView()
      }
      Text(source)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }
}
