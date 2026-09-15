import MC1Services
import MeshWX
import SwiftUI

/// Every alert in the source bot's area (docs/MESHWX_UI.md §12): a map, the alerts by where they
/// are relative to the place, the status line, and what the alert list named but never arrived.
struct WeatherAlertsListView: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel

  @State private var drawing = WeatherMapDrawing()

  private var title: String {
    L10n.Weather.Weather.AlertsList.title(model.sourceName)
  }

  private var drawingKey: WeatherMapKey {
    WeatherMapKey(
      warnings: model.snapshot?.alerts.map(\.warning) ?? [], place: model.snapshot?.place,
      isGeometryLoaded: model.context.isGeometryLoaded)
  }

  var body: some View {
    List {
      if let snapshot = model.snapshot {
        content(snapshot)
      }
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: model, requestsOnScreen: requestsOnScreen)
    .task(id: drawingKey) {
      let key = drawingKey
      // Area fills only once the outlines are loaded; the model loads them when needed.
      drawing = await Task.detached(priority: .userInitiated) {
        WeatherMapDrawing.make(
          warnings: key.warnings, place: key.place, framesPlace: true, loadOutlines: false,
          tables: .shared, geometry: .shared)
      }.value
    }
  }

  private var requestsOnScreen: Set<WeatherRequest> {
    guard let snapshot = model.snapshot else { return [] }
    let line = WeatherAlertsSection.statusLine(snapshot, model: model)
    let status = line?.action == .askForAlerts ? model.alertsRequest(for: snapshot.alertStatus) : nil
    let missing = model.missingWarnings.isEmpty ? nil : model.missingWarningsRequest
    return Set([status, missing].compactMap { $0 })
  }

  @ViewBuilder
  private func content(_ snapshot: WeatherScreenSnapshot) -> some View {
    let line = WeatherAlertsSection.statusLine(snapshot, model: model)
    let alertsRequest = model.alertsRequest(for: snapshot.alertStatus)
    let statusAsks = line?.action == .askForAlerts
    let missingRequest = model.missingWarningsRequest

    Section {
      NavigationLink {
        WeatherAlertFullMapView(drawing: drawing, title: title)
      } label: {
        WeatherAlertMapView(drawing: drawing, isInteractive: false)
          .frame(height: 200)
          .clipShape(.rect(cornerRadius: 10))
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .accessibilityLabel(L10n.Weather.Weather.AlertsList.openMap)
    }
    .themedRowBackground(theme)

    if snapshot.place == nil {
      alertSection(L10n.Weather.Weather.AlertsList.all(model.sourceName), snapshot.alerts, showsLocation: true)
    } else {
      alertSection(L10n.Weather.Weather.AlertsList.here, snapshot.alerts.filter { $0.placement == .here })
      alertSection(L10n.Weather.Weather.AlertsList.unsure, snapshot.alerts.filter {
        $0.placement == .checking || $0.placement == .unplaced
      })
      alertSection(L10n.Weather.Weather.AlertsList.near, snapshot.alerts.filter {
        if case .near = $0.placement { return true }
        return false
      })
      alertSection(
        L10n.Weather.Weather.AlertsList.elsewhere, snapshot.alerts.filter { $0.placement == .elsewhere },
        showsLocation: true)
    }

    Section {
      if let line {
        WeatherAlertStatusRow(
          model: model, line: line, source: WeatherAlertsSection.sourceLine(snapshot, model: model),
          request: alertsRequest, showsAskFootnotes: statusAsks)
      } else {
        Text(WeatherAlertsSection.sourceLine(snapshot, model: model))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .themedRowBackground(theme)

    if !model.missingWarnings.isEmpty {
      Section {
        ForEach(model.missingWarnings, id: \.self) { identity in
          VStack(alignment: .leading, spacing: 2) {
            Text(WeatherFormatting.eventName(identity.event, tables: .shared))
              .font(.headline)
            Text(L10n.Weather.Weather.AlertsList.notReceived)
              .font(.subheadline)
              .foregroundStyle(.orange)
          }
          .accessibilityElement(children: .combine)
        }
        if let missingRequest {
          WeatherAskButton(
            model: model, title: L10n.Weather.Weather.Request.askAlerts, request: missingRequest,
            showsFootnotes: !statusAsks)
        }
      } header: {
        Text(L10n.Weather.Weather.AlertsList.listedHeader)
      }
      .themedRowBackground(theme)
    }
  }

  @ViewBuilder
  private func alertSection(_ title: String, _ items: [WeatherAlertItem], showsLocation: Bool = false) -> some View {
    if !items.isEmpty {
      Section(title) {
        ForEach(items) { item in
          NavigationLink {
            WeatherAlertDetailView(model: model, identity: item.identity)
          } label: {
            WeatherAlertRow(
              item: item, placeName: model.placeName, now: model.now,
              location: showsLocation
                ? WeatherCopy.alertLocation(item.warning, place: model.snapshot?.place, tables: .shared)
                : nil)
            .equatable()
          }
        }
      }
      .themedRowBackground(theme)
    }
  }
}
