import MC1Services
import MeshWX
import SwiftUI

/// Every alert in the source bot's area (docs/MESHWX_UI.md §12): a map, the alerts by where they
/// are relative to the place, the status line, and what the alert list named but never arrived.
struct WeatherAlertsListView: View {
  @Environment(\.appTheme) private var theme

  /// The page this list was opened from: the placements ("here", "near", "elsewhere") and the
  /// map's framing are relative to that place.
  let screen: WeatherPageScreen

  @State private var drawing = WeatherMapDrawing()
  /// The full map, pushed from the header. A `NavigationLink` would put a disclosure chevron over
  /// the corner of the map itself, which is a row's affordance stuck on something that is not a
  /// row (docs/MESHWX_UI.md §3.1 U-17).
  @State private var isShowingMap = false

  private var title: String {
    L10n.Weather.Weather.AlertsList.title(screen.sourceName)
  }

  private var drawingKey: WeatherMapKey {
    WeatherMapKey(
      warnings: screen.snapshot.alerts.map(\.warning), place: screen.place,
      isGeometryLoaded: screen.context.isGeometryLoaded)
  }

  var body: some View {
    List {
      content(screen.snapshot)
    }
    .listStyle(.insetGrouped)
    .weatherReadableWidth()
    .themedCanvas(theme)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .weatherPendingBar(model: screen.model, requestsOnScreen: requestsOnScreen)
    .weatherAskBar(screen: screen, ask: barAsk)
    .weatherToolChrome()
    .navigationDestination(isPresented: $isShowingMap) {
      WeatherAlertFullMapView(screen: screen, drawing: drawing, title: title)
    }
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
    let snapshot = screen.snapshot
    let line = statusLine(snapshot)
    let status = line?.action == .askForAlerts ? screen.alertsRequest(for: snapshot.alertStatus) : nil
    let missing = screen.missingWarnings.isEmpty ? nil : screen.missingWarningsRequest
    return Set([status, missing].compactMap { $0 })
  }

  /// The one ask the bar carries (docs/MESHWX_UI.md §3.1 U-51): the status line's, when the line
  /// says the list needs asking for, else the next missing warning's. Both used to be buttons at
  /// the foot of the list, under every alert in it — the longest list in the tool on exactly the
  /// night it matters — while what they changed was at the top.
  private var barAsk: WeatherBarAsk? {
    let snapshot = screen.snapshot
    if statusLine(snapshot)?.action == .askForAlerts {
      let request = screen.alertsRequest(for: snapshot.alertStatus)
      return WeatherBarAsk(title: WeatherCopy.askAlertsTitle(for: request, tables: .shared), request: request)
    }
    if !screen.missingWarnings.isEmpty, let request = screen.missingWarningsRequest {
      return WeatherBarAsk(title: WeatherCopy.askAlertsTitle(for: request, tables: .shared), request: request)
    }
    return nil
  }

  /// The §7.4 line, which lives here now that the card is gone: this screen is where the alert
  /// list is accounted for, and the place page says nothing about it at all (§13).
  private func statusLine(_ snapshot: WeatherScreenSnapshot) -> WeatherCopy.AlertStatusLine? {
    WeatherCopy.alertStatus(
      snapshot.alertStatus, source: screen.sourceName, place: snapshot.place,
      areaName: screen.context.placeCounty?.name, now: screen.now, calendar: .autoupdatingCurrent,
      locale: .autoupdatingCurrent)
  }

  /// When the held sweep was built, or that nobody has asked for one — which is the usual answer,
  /// because nothing in the app asks for a sweep without a tap.
  private var areaMapDetail: String {
    guard let sweep = screen.context.sourceState?.newestAreaSweep else {
      return L10n.Weather.Weather.AreaMap.never
    }
    return WeatherAreaMapCopy.builtLine(
      sweep, now: screen.now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
  }

  private func sourceLine(_ snapshot: WeatherScreenSnapshot) -> String {
    snapshot.source == nil
      ? L10n.Weather.Weather.Alerts.sourceGeneric
      : L10n.Weather.Weather.Alerts.source(screen.sourceName)
  }

  @ViewBuilder
  private func content(_ snapshot: WeatherScreenSnapshot) -> some View {
    let line = statusLine(snapshot)
    let alertsRequest = screen.alertsRequest(for: snapshot.alertStatus)
    let statusAsks = line?.action == .askForAlerts
    let missingRequest = screen.missingWarningsRequest

    Section {
      Button {
        isShowingMap = true
      } label: {
        WeatherAlertMapView(drawing: drawing, isInteractive: false)
          .frame(height: 200)
          .clipShape(.rect(cornerRadius: 10))
          .allowsHitTesting(false)
          .accessibilityHidden(true)
          // The map has stopped taking hits, so the button needs a hit area of its own or the
          // preview looks tappable and does nothing — the alert map's U-32 fix, missed here.
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(L10n.Weather.Weather.AlertsList.openMap)
      .accessibilityAddTraits(.isButton)
      .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
      // The top of the answer: the capsule's Show scrolls back here.
      .weatherAskResult()

      // The whole country, one screen away (docs/MESHWX_UI.md §17). A row rather than anything
      // that loads: opening it asks for nothing, and the map it shows is whatever sweep the
      // channel has already carried.
      NavigationLink {
        WeatherAreaMapView(screen: screen)
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.Weather.Weather.AreaMap.title)
          Text(areaMapDetail)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .themedRowBackground(theme)

    // Whether the list is whole comes **before** the list (docs/MESHWX_UI.md §3.1 U-51): it was
    // the last thing on the screen, under every alert, so the line that says "this list may be
    // missing something" was read — if at all — after the list it qualifies.
    Section {
      if let line {
        WeatherAlertStatusRow(
          screen: screen, line: line, source: sourceLine(snapshot),
          request: alertsRequest)
      } else {
        Text(sourceLine(snapshot))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .themedRowBackground(theme)

    if !screen.missingWarnings.isEmpty {
      let notAvailable = screen.missingNotAvailable
      Section {
        WeatherCardLabel(
          title: L10n.Weather.Weather.AlertsList.listedHeader, systemImage: "exclamationmark.triangle")
        ForEach(screen.missingWarnings, id: \.self) { identity in
          VStack(alignment: .leading, spacing: 2) {
            Text(WeatherFormatting.eventName(identity.event, tables: .shared))
              .font(.headline)
            Text(notAvailable.contains(identity)
              ? L10n.Weather.Weather.AlertsList.notAvailable(screen.sourceName)
              : L10n.Weather.Weather.AlertsList.notReceived)
              .font(.subheadline)
              .foregroundStyle(.orange)
          }
          .accessibilityElement(children: .combine)
        }
        // One warning per tap, named on the bar's button, so each tap visibly asks for the next
        // one. Only when the bar is busy with the status line's ask does this one keep a button
        // of its own.
        if let missingRequest {
          if statusAsks, missingRequest != alertsRequest {
            WeatherAskButton(
              screen: screen, title: WeatherCopy.askAlertsTitle(for: missingRequest, tables: .shared),
              request: missingRequest, showsFootnotes: false)
          } else if !statusAsks {
            WeatherAskStatusRow(screen: screen, request: missingRequest)
          }
        }
      }
      .themedRowBackground(theme)
    }

    if snapshot.place == nil {
      alertSection(L10n.Weather.Weather.AlertsList.all(screen.sourceName), snapshot.alerts, showsLocation: true)
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
  }

  @ViewBuilder
  private func alertSection(_ title: String, _ items: [WeatherAlertItem], showsLocation: Bool = false) -> some View {
    if !items.isEmpty {
      Section {
        WeatherCardLabel(title: title, systemImage: "exclamationmark.triangle")
        ForEach(items) { item in
          NavigationLink {
            WeatherAlertDetailView(screen: screen, identity: item.identity)
          } label: {
            WeatherAlertRow(
              item: item, placeName: screen.placeName, now: screen.now,
              location: showsLocation
                ? WeatherCopy.alertLocation(item.warning, place: screen.place, tables: .shared)
                : nil)
            .equatable()
          }
        }
      }
      .themedRowBackground(theme)
    }
  }
}
