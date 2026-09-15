import MC1Services
import MeshWX
import SwiftUI

/// The Alerts card (docs/MESHWX_UI.md §7.3): rows for alerts that cover or are near the place, a
/// count of the rest, and the status line saying what the card can claim, with its source.
struct WeatherAlertsSection: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel
  let snapshot: WeatherScreenSnapshot
  let showsAskFootnotes: Bool

  static func cardItems(_ snapshot: WeatherScreenSnapshot) -> [WeatherAlertItem] {
    snapshot.place == nil ? snapshot.alerts : snapshot.alerts.filter { $0.placement.isCardRow }
  }

  static func statusLine(_ snapshot: WeatherScreenSnapshot, model: WeatherToolModel) -> WeatherCopy.AlertStatusLine? {
    WeatherCopy.alertStatus(
      snapshot.alertStatus, source: model.sourceName, place: snapshot.place,
      areaName: model.context.placeCounty?.name, now: model.now, calendar: .autoupdatingCurrent,
      locale: .autoupdatingCurrent)
  }

  static func sourceLine(_ snapshot: WeatherScreenSnapshot, model: WeatherToolModel) -> String {
    snapshot.source == nil
      ? L10n.Weather.Weather.Alerts.sourceGeneric
      : L10n.Weather.Weather.Alerts.source(model.sourceName)
  }

  var body: some View {
    let tables = MeshWXTables.shared
    let items = Self.cardItems(snapshot)
    let folded = WeatherAlertFolding.fold(items, tables: tables)
    let elsewhere = snapshot.place == nil ? 0 : snapshot.alerts.filter { $0.placement == .elsewhere }.count
    let line = Self.statusLine(snapshot, model: model)
    let source = Self.sourceLine(snapshot, model: model)
    let title = WeatherCopy.alertsTitle(placeName: model.placeName)

    Section {
      ForEach(folded.rows) { item in
        NavigationLink {
          WeatherAlertDetailView(model: model, identity: item.identity)
        } label: {
          WeatherAlertRow(item: item, placeName: model.placeName, now: model.now)
            .equatable()
        }
      }
      if folded.folded > 0 {
        NavigationLink {
          WeatherAlertsListView(model: model)
        } label: {
          Text(L10n.Weather.Weather.Alerts.more(folded.folded))
            .font(.subheadline)
        }
      }
      if elsewhere > 0 {
        NavigationLink {
          WeatherAlertsListView(model: model)
        } label: {
          Text(L10n.Weather.Weather.Alerts.elsewhere(elsewhere, model.sourceName))
            .font(.subheadline)
        }
      }
      if let line {
        WeatherAlertStatusRow(
          model: model, line: line, source: source, request: model.alertsRequest(for: snapshot.alertStatus),
          showsAskFootnotes: showsAskFootnotes)
      } else {
        Text(source)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } header: {
      VStack(alignment: .leading) {
        Text(title)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(summary(title: title, items: items, elsewhere: elsewhere, line: line))
    }
    .themedRowBackground(theme)
  }

  private func summary(title: String, items: [WeatherAlertItem], elsewhere: Int, line: WeatherCopy.AlertStatusLine?) -> String {
    var parts = [title]
    if !items.isEmpty { parts.append(L10n.Weather.Weather.Alerts.Accessibility.rows(items.count)) }
    if elsewhere > 0 { parts.append(L10n.Weather.Weather.Alerts.elsewhere(elsewhere, model.sourceName)) }
    if let line { parts.append(line.text) }
    return parts.joined(separator: ". ")
  }
}

/// One alert: colour bar, icon, event, when it ends, one line of tags, and — on the alerts
/// list — where it is.
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

/// The §7.4 line, with its action and the alerts' source under it.
struct WeatherAlertStatusRow: View {
  let model: WeatherToolModel
  let line: WeatherCopy.AlertStatusLine
  let source: String
  let request: WeatherRequest
  let showsAskFootnotes: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if line.showsCheck {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .accessibilityHidden(true)
        }
        Text(line.text)
          .font(.subheadline)
      }
      if let caption = line.caption {
        Text(caption)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      switch line.action {
      case .askForAlerts:
        WeatherAskButton(
          model: model, title: L10n.Weather.Weather.Request.askAlerts, request: request,
          showsFootnotes: showsAskFootnotes)
      case .updateLocation:
        Button(L10n.Weather.Weather.Place.updateLocation) {
          model.updateLocation()
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
