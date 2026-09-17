import MC1Services
import MeshWX
import SwiftUI

/// One alert in full (docs/MESHWX_UI.md §12): the ground it covers, whether that includes the
/// place, when it ends, who issued it, its narrative on request, its tags and areas.
///
/// Read from the page's build by identity rather than held as a value, so an update or a cancel
/// that arrives while the screen is open shows here.
struct WeatherAlertDetailView: View {
  @Environment(\.appTheme) private var theme

  /// The page this alert was opened from. "Covers Austin" and the map's framing are that
  /// place's — including for an alert a notification opened, which named the place it watched.
  let screen: WeatherPageScreen
  let identity: MeshWXWarningIdentity

  private var model: WeatherToolModel { screen.model }

  @State private var drawing = WeatherMapDrawing()
  @State private var isWide = false

  /// Side by side only when the column itself is wide: an iPad split column can be narrow while
  /// the size class says regular.
  nonisolated static let sideBySideWidth: CGFloat = 700

  private struct DrawingKey: Hashable {
    var map: WeatherMapKey
    var framesPlace: Bool
  }

  private var item: WeatherAlertItem? {
    screen.snapshot.alerts.first { $0.identity == identity }
  }

  private var eventName: String {
    WeatherFormatting.eventName(identity.event, tables: .shared)
  }

  private var identityString: String? {
    WeatherAlertRequests.identityString(identity, tables: .shared)
  }

  var body: some View {
    Group {
      if let item {
        if isWide {
          HStack(spacing: 0) {
            WeatherAlertMapView(drawing: drawing, isInteractive: true)
            Divider()
            details(item)
              .frame(maxWidth: 440)
          }
        } else {
          VStack(spacing: 0) {
            WeatherAlertMapView(drawing: drawing, isInteractive: true)
              .containerRelativeFrame(.vertical) { height, _ in height * 0.4 }
            details(item)
          }
        }
      } else {
        ContentUnavailableView(L10n.Weather.Weather.AlertDetail.gone, systemImage: "tray")
      }
    }
    .onGeometryChange(for: Bool.self) { proxy in
      proxy.size.width >= Self.sideBySideWidth
    } action: { wide in
      isWide = wide
    }
    .navigationTitle(eventName)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: model, requestsOnScreen: Set([identityString.map { WeatherRequest.warningText(identity: $0) }].compactMap { $0 }))
    .weatherToolChrome()
    .task(id: drawingKey) {
      guard let key = drawingKey else { return }
      // The outlines are a large parse on a cold cache; never on the main actor.
      drawing = await Task.detached(priority: .userInitiated) {
        WeatherMapDrawing.make(
          warnings: key.map.warnings, place: key.map.place, framesPlace: key.framesPlace, loadOutlines: true,
          tables: .shared, geometry: .shared)
      }.value
    }
  }

  private var drawingKey: DrawingKey? {
    guard let item else { return nil }
    let framesPlace = switch item.placement {
    case .here, .near: true
    case .checking, .unplaced, .elsewhere: false
    }
    return DrawingKey(
      map: WeatherMapKey(warnings: [item.warning], place: screen.place, isGeometryLoaded: screen.context.isGeometryLoaded),
      framesPlace: framesPlace)
  }

  private func details(_ item: WeatherAlertItem) -> some View {
    let tables = MeshWXTables.shared
    let tags = WeatherFormatting.tagTexts(for: item.warning)
    let areas = WeatherFormatting.uniqueAreas(tables.namedAreas(for: item.warning))

    return List {
      Section {
        headline(item)
      }
      .themedRowBackground(theme)

      if let identityString {
        Section {
          WeatherCardLabel(title: L10n.Weather.Weather.AlertDetail.fullText)
          WeatherAskButton(
            screen: screen, title: L10n.Weather.Weather.Request.askFullText,
            request: .warningText(identity: identityString), showsFootnotes: true)
          if let narrative = narrative(identityString) {
            Text(WeatherReportText.body(narrative.assembly))
              .font(.system(.footnote, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        .themedRowBackground(theme)
      }

      if !tags.isEmpty {
        Section {
          WeatherCardLabel(title: L10n.Weather.Weather.AlertDetail.details)
          ForEach(tags, id: \.self) { tag in
            Text(tag)
          }
        }
        .themedRowBackground(theme)
      }

      if !areas.isEmpty {
        Section {
          WeatherCardLabel(title: L10n.Weather.Weather.AlertDetail.areas, systemImage: "map")
          ForEach(areas, id: \.ugc) { area in
            LabeledContent(WeatherFormatting.areaName(area)) {
              Text(area.isCounty ? L10n.Weather.Weather.AlertDetail.county : L10n.Weather.Weather.AlertDetail.zone)
            }
          }
        }
        .themedRowBackground(theme)
      }
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
  }

  private func headline(_ item: WeatherAlertItem) -> some View {
    let tables = MeshWXTables.shared
    let tint = WeatherFormatting.color(for: WeatherFormatting.tint(for: item.warning.event, tables: tables))
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Image(systemName: WeatherFormatting.symbol(for: item.warning.event, tables: tables))
          .font(.title2)
          .foregroundStyle(tint)
          .accessibilityHidden(true)
        Text(eventName)
          .font(.title3.weight(.semibold))
      }
      if let placeName = screen.placeName {
        Text(WeatherCopy.coversLine(item.placement, placeName: placeName))
          .font(.subheadline.weight(.medium))
      }
      switch item.kind {
      case .active:
        Text(WeatherFormatting.untilLine(
          expiresAt: item.expiresAt, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent))
        .font(.subheadline)
      case .upgradedAwaitingReplacement, .expiredRecently:
        if let qualifier = WeatherCopy.alertQualifier(item, placeName: nil, now: screen.now) {
          Text(qualifier)
            .font(.subheadline)
            .foregroundStyle(.orange)
        }
      }
      // Since revision 5 the wire carries when NWS issued the warning, and that is the time worth
      // showing: a radio out of range for three hours still says *issued 1:29 PM*. Receipt is the
      // fallback, for a bot older than revision 5 and for an issue time the wire had to saturate,
      // which is a ceiling rather than a time (spec §3).
      Text(timeLine(item))
        .font(.footnote)
        .foregroundStyle(.secondary)
      if let office = tables.officeCode(item.warning.office) {
        Text(L10n.Weather.Weather.AlertDetail.issuedBy(WeatherReferenceNames.officeName(office)))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  /// "issued 1:29 PM" when the wire carried the issue time, "received 1:28 AM" when it did not.
  /// The two are different claims: one is when the Weather Service said it, the other is when
  /// this radio happened to be in range — and only the first is the warning's own age.
  private func timeLine(_ item: WeatherAlertItem) -> String {
    func time(_ date: Date) -> String {
      WeatherFormatting.clockTime(date, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
    }
    // A saturated field is a ceiling, not a time (spec §3): the receipt time is the honest one.
    if let issuedAt = screen.context.warningIssuedAt[item.identity], !item.warning.isIssueTimeSaturated {
      return L10n.Weather.Weather.AlertDetail.issued(time(issuedAt))
    }
    return L10n.Weather.Weather.AlertDetail.received(time(item.receivedAt))
  }

  /// The narrative, only when it answered this phone's request for this identity: a text reply
  /// names its subject and nothing else.
  private func narrative(_ identityString: String) -> WeatherTextItem? {
    screen.snapshot.texts.first { $0.assembly.request == .warningText(identity: identityString) }
  }
}
