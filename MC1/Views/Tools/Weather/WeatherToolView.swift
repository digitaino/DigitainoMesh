import MC1Services
import MeshWX
import SwiftUI
import UIKit

/// The Weather tool: one place, and what the weather radios on `#meshwx` say about it
/// (docs/MESHWX_UI.md §4).
///
/// This view only connects to the visit's model in `WeatherModelStore`, so rotating an iPhone
/// between the tab and sidebar shells does not start the screen over.
struct WeatherToolView: View {
  @Environment(\.appState) private var appState

  private var store: WeatherModelStore { .shared }

  var body: some View {
    Group {
      if let model = store.model {
        WeatherToolScreen(model: model)
      } else {
        Color.clear
      }
    }
    .navigationTitle(L10n.Weather.Weather.title)
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      store.rootAppeared { [appState] in appState.navigation.selectedTool == .weather }
    }
    .onDisappear {
      store.rootDisappeared()
    }
  }
}

/// An inset-grouped list whose sections read as cards: header, at most one banner, Alerts, Now,
/// Forecast, and the text reports. Everything drills in; nothing asks the radio without a tap.
private struct WeatherToolScreen: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL

  let model: WeatherToolModel

  @State private var isShowingPlacePicker = false
  @State private var isShowingAbout = false
  @State private var isConfirmingChannel = false
  @State private var addsChannelAfterAlert = false

  var body: some View {
    list
      .background {
        WeatherAppObserver(model: model)
      }
      .sheet(isPresented: $isShowingPlacePicker, onDismiss: applyPlaceAction) {
        WeatherPlacePickerView(model: model)
      }
      .sheet(isPresented: $isShowingAbout) {
        WeatherAboutView(model: model)
      }
      .alert(L10n.Weather.Weather.Channel.Alert.title, isPresented: $isConfirmingChannel) {
        Button(L10n.Weather.Weather.Channel.Alert.add) {
          addsChannelAfterAlert = true
        }
        Button(L10n.Weather.Weather.Common.cancel, role: .cancel) {}
      } message: {
        Text(L10n.Weather.Weather.Channel.Alert.message)
      }
      .onChange(of: isConfirmingChannel) { _, isShowing in
        // The write waits for the alert to be gone: the banner it came from disappears with it.
        guard !isShowing, addsChannelAfterAlert else { return }
        addsChannelAfterAlert = false
        Task { await model.addChannel() }
      }
      .errorAlert(Binding(get: { model.errorMessage }, set: { model.errorMessage = $0 }))
      .task(id: appState.servicesVersion) {
        await model.attach(appState: appState)
      }
      .onAppear {
        model.appear(appState: appState)
        // A pick made in a sheet the shell swap tore down: apply it, but never start a
        // permission prompt from here.
        if !isShowingPlacePicker, model.pendingPlaceAction != nil {
          _ = model.applyPendingPlaceAction(isLocationAuthorized: appState.locationService.isAuthorized)
        }
      }
      .onChange(of: appState.contactsVersion) {
        model.contactsChanged()
      }
      .onChange(of: scenePhase, initial: true) { _, phase in
        model.scenePhaseChanged(phase)
      }
  }

  private var list: some View {
    List {
      if let snapshot = model.snapshot {
        content(snapshot)
      } else {
        Section {
          HStack(spacing: 10) {
            ProgressView()
            Text(L10n.Weather.Weather.loading)
              .foregroundStyle(.secondary)
          }
        }
        .themedRowBackground(theme)
      }
    }
    .listStyle(.insetGrouped)
    .themedCanvas(theme)
    .weatherPendingBar(model: model, requestsOnScreen: requestsOnScreen)
  }

  @ViewBuilder
  private func content(_ snapshot: WeatherScreenSnapshot) -> some View {
    let asks = asks(snapshot)

    WeatherHeaderSection(
      model: model,
      snapshot: snapshot,
      onChoosePlace: { isShowingPlacePicker = true },
      onAbout: { isShowingAbout = true },
      onOpenSettings: openSettings)

    if let banner = snapshot.banner {
      WeatherBannerSection(model: model, banner: banner) {
        isConfirmingChannel = true
      }
    }

    WeatherAlertsSection(model: model, snapshot: snapshot, showsAskFootnotes: asks.alerts != nil)

    WeatherNowSection(
      model: model, snapshot: snapshot, showsAskFootnotes: asks.alerts == nil && asks.now != nil,
      onUseMyLocation: useMyLocation, onSearch: { isShowingPlacePicker = true })

    WeatherForecastSection(
      model: model, snapshot: snapshot,
      showsAskFootnotes: asks.alerts == nil && asks.now == nil && asks.forecast != nil,
      onUseMyLocation: useMyLocation, onSearch: { isShowingPlacePicker = true })

    Section {
      NavigationLink {
        WeatherReportsView(model: model)
      } label: {
        Label(L10n.Weather.Weather.Reports.title, systemImage: "doc.plaintext")
      }
    }
    .themedRowBackground(theme)
  }

  private func asks(_ snapshot: WeatherScreenSnapshot) -> (alerts: WeatherRequest?, now: WeatherRequest?, forecast: WeatherRequest?) {
    let line = WeatherAlertsSection.statusLine(snapshot, model: model)
    return (
      line?.action == .askForAlerts ? model.alertsRequest(for: snapshot.alertStatus) : nil,
      WeatherNowSection.askRequest(snapshot, context: model.context),
      WeatherForecastSection.askRequest(snapshot)
    )
  }

  private var requestsOnScreen: Set<WeatherRequest> {
    guard let snapshot = model.snapshot else { return [] }
    let asks = asks(snapshot)
    return Set([asks.alerts, asks.now, asks.forecast].compactMap { $0 })
  }

  // MARK: - Actions

  private func useMyLocation() {
    if appState.locationService.isLocationDenied {
      openSettings()
    } else {
      Task { await model.useMyLocation() }
    }
  }

  private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    openURL(url)
  }

  /// Runs after the picker's sheet is gone, so a permission prompt never lands on a sheet that is
  /// dismissing — and only for the visit's live model.
  private func applyPlaceAction() {
    guard WeatherModelStore.shared.isCurrent(model) else {
      model.pendingPlaceAction = nil
      return
    }
    if model.applyPendingPlaceAction(isLocationAuthorized: appState.locationService.isAuthorized) {
      useMyLocation()
    }
  }
}

/// Watches the app values the screen reacts to, in a view of its own: reading the phone fix in
/// the screen's body would re-render the whole list on every location update.
private struct WeatherAppObserver: View {
  @Environment(\.appState) private var appState

  let model: WeatherToolModel

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onChange(of: WeatherToolModel.sample(appState.locationService.currentLocation)) { _, sample in
        model.locationSampleChanged(sample)
      }
      .onChange(of: appState.locationService.authorizationStatus) {
        model.authorizationChanged()
      }
      // Contacts, then channels, then messages: past the channel phase the channel table is real.
      .onChange(of: appState.canRunSettingsStartupReads, initial: true) { _, isDone in
        model.channelSyncChanged(isDone: isDone)
      }
  }
}

#Preview {
  NavigationStack {
    WeatherToolView()
  }
  .environment(\.appState, AppState())
}
