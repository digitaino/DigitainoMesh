import MC1Services
import MeshWX
import SwiftUI
import UIKit

/// The Weather tool: one page per place, swiped sideways with dots, and what the weather radios on
/// `#meshwx` say about the one on screen (docs/MESHWX_UI.md §4).
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
    .onAppear {
      store.rootAppeared { [appState] in appState.navigation.selectedTool == .weather }
    }
    .onDisappear {
      store.rootDisappeared()
    }
  }
}

/// The pager and the tool's chrome. Each page is its own scrolling list, top to bottom, with no
/// cards that open pages: the only drill-ins are detail screens — a station, an alert, a text
/// report, the radio page.
///
/// **The chrome is the system's** (docs/MESHWX_UI.md §4). The place's name is the title, and the
/// title is a menu: tapping it lists the places and opens Places, which is the answer to "how do
/// I change the place" that a bare list glyph in a corner never was. The tool's controls live in
/// a bottom toolbar of the system's own — **Places · the page dots · Update** — the way Apple
/// Weather lays out its bottom edge, and the app's tab bar is off the screen while the tool is
/// up, the way it is inside a conversation. A glass capsule of the tool's own floating above the
/// app's glass tab bar was two bars stacked at the foot of every page.
private struct WeatherToolScreen: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL

  let model: WeatherToolModel

  @State private var isShowingPlaces = false
  @State private var isConfirmingChannel = false
  @State private var addsChannelAfterAlert = false
  /// What the pager pushed: a station Places asked for by airport code or the source line named,
  /// the alert a tapped notification asked for (docs/MESHWX_UI.md §16), or the radio page. One
  /// destination, not three `isPresented` flags that could all be true at once.
  @State private var pushed: Push?

  /// A screen pushed over the pager, from the page it was opened on.
  ///
  /// **Everything reachable from a place page pushes** (docs/MESHWX_UI.md §3.1 U-11). The radio
  /// row used to open a sheet while every other row on the same page pushed, so one list of rows
  /// had two navigation grammars and the way back was "Done" on one row and "‹ Austin" on the
  /// next. Places is the only sheet in the tool, because it is the one screen that is about the
  /// tool rather than about the place.
  ///
  /// Every case carries **the page it was opened from**, and the destination is built from that
  /// page's own build (§3.1 U-18). Reading `model.screen` here — "the page the pager is on" — was
  /// the last of the one-snapshot bugs §3.1 P-1 set out to remove: a tapped notification selects
  /// its page and names its alert in the same turn, so the destination could be built against the
  /// page being left, and "Covers Austin" would then be about Round Rock.
  private enum Push: Hashable {
    case station(pageID: String, index: UInt16)
    case alert(pageID: String, identity: MeshWXWarningIdentity)
    case radio(pageID: String)

    var pageID: String {
      switch self {
      case let .station(pageID, _), let .alert(pageID, _), let .radio(pageID): pageID
      }
    }
  }

  var body: some View {
    pager
      .background {
        WeatherAppObserver(model: model)
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      // The title is where places are switched and added (docs/MESHWX_UI.md §4): the place on
      // screen is picked in the list, and the last item opens Places for adding, removing and
      // reordering. Nothing else of the tool's is in the navigation bar; the app's radio status
      // pill has the trailing slot (§3.1 U-7).
      .toolbarTitleMenu {
        titleMenu
      }
      // Opened before location permission was ever granted: the list is where a place comes from,
      // and nothing is asked of the phone until the user taps My location or adds one (§5).
      .task {
        guard appState.locationService.authorizationStatus == .notDetermined,
              model.savedPlaces.isEmpty
        else { return }
        isShowingPlaces = true
      }
      .sheet(isPresented: $isShowingPlaces, onDismiss: applyPlaceAction) {
        WeatherPlacePickerView(model: model)
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
        if !isShowingPlaces, model.pendingPlaceAction != nil {
          _ = model.applyPendingPlaceAction(isLocationAuthorized: appState.locationService.isAuthorized)
        }
      }
      .onChange(of: appState.contactsVersion) {
        model.contactsChanged()
      }
      .onChange(of: scenePhase, initial: true) { _, phase in
        model.scenePhaseChanged(phase)
      }
      // An airport code names a station, and so does the line under the temperature. Both carry
      // the page they came from.
      .onChange(of: model.stationToOpen) { _, target in
        guard let target else { return }
        model.stationToOpen = nil
        pushed = .station(pageID: target.pageID, index: target.index)
      }
      // A tapped alert notification: the tool opens the alert it named as soon as it is on
      // screen, against the page the notification was raised for — which the target names, rather
      // than the pager being asked what page it is on mid-switch.
      .onChange(of: model.alertToOpen, initial: true) { _, target in
        guard let target else { return }
        model.alertToOpen = nil
        pushed = .alert(pageID: target.pageID, identity: target.identity)
      }
  }

  /// The page the pager is on, as its own screen. Nil only until its first build lands.
  private var screen: WeatherPageScreen? { model.screen }

  /// The place on screen names the screen, by the one label function every other screen uses
  /// (`WeatherFormatting.placeName`). The pages carry no headline of their own: the title bar
  /// says where you are, and the page gets on with the weather.
  private var title: String {
    guard let page = model.pages.first(where: { $0.id == model.selectedPageID }) else {
      return L10n.Weather.Weather.title
    }
    if let label = page.label { return WeatherFormatting.placeName(label) }
    guard let place = screen?.place else { return L10n.Weather.Weather.Picker.yourLocation }
    return WeatherFormatting.placeName(place.label)
  }

  private var selection: Binding<String> {
    Binding(
      get: { WeatherPages.selection(model.selectedPageID, in: model.pages) },
      set: { model.showPage($0) })
  }

  /// The title's menu: every page, the one on screen ticked, and the way into Places.
  @ViewBuilder
  private var titleMenu: some View {
    Picker(L10n.Weather.Weather.Place.places, selection: selection) {
      ForEach(model.pages) { page in
        if page.id == WeatherPage.myLocationID {
          Label(L10n.Weather.Weather.Picker.yourLocation, systemImage: "location.fill")
            .tag(page.id)
        } else {
          Text(WeatherFormatting.placeName(page.label ?? ""))
            .tag(page.id)
        }
      }
    }
    .pickerStyle(.inline)
    Divider()
    Button(L10n.Weather.Weather.Place.manage, systemImage: "list.bullet") {
      isShowingPlaces = true
    }
  }

  private var pager: some View {
    TabView(selection: selection) {
      ForEach(model.pages) { page in
        WeatherPlacePageView(
          model: model,
          page: page,
          onOpenRadio: { pushed = .radio(pageID: page.id) },
          onAddChannel: { isConfirmingChannel = true },
          onOpenSettings: openSettings,
          onUseMyLocation: useMyLocation)
          .tag(page.id)
      }
    }
    // The dots are drawn in the bottom toolbar, outside the scroll, so they never sit on top of
    // the last row of a page (docs/MESHWX_UI.md §3.1 U-7).
    .tabViewStyle(.page(indexDisplayMode: .never))
    // The pager itself, named for the UI tests that swipe it (docs/Testing.md).
    .accessibilityIdentifier("weather.pager")
    // The pager takes every point it is given. In a regular-width shell it used to size itself to
    // its content and leave half the column blank with the dots floating in the gap (landscape
    // iPhone, iPad).
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .themedCanvas(theme)
    .weatherPendingBar(model: model, requestsOnScreen: requestsOnScreen)
    // A pull the radio cannot answer says so here, for a few seconds, rather than doing nothing
    // at all (docs/MESHWX_UI.md §3.1 U-6). An overlay, not an inset: the list must not jump for
    // four seconds of notice.
    .overlay(alignment: .bottom) {
      if let notice = model.blockedPullNotice {
        Text(notice)
          .font(.footnote)
          .foregroundStyle(.orange)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .liquidGlass(in: .capsule)
          .padding(.horizontal, 24)
          .padding(.bottom, 8)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .accessibilityAddTraits(.updatesFrequently)
      }
    }
    .animation(.default, value: model.blockedPullNotice)
    .sensoryFeedback(.warning, trigger: model.blockedPullCount)
    .weatherToolChrome()
    .modifier(WeatherBottomToolbar(model: model, screen: screen, onOpenPlaces: { isShowingPlaces = true }))
    // One destination, driven by what was pushed: two `isPresented` destinations on one view can
    // both be true, and then the stack has two ideas about what is on top of it.
    .navigationDestination(item: $pushed) { push in
      // The page the push came from, never the page the pager has since landed on.
      if let screen = model.screen(for: push.pageID) {
        switch push {
        case let .station(_, index):
          WeatherStationDetailView(screen: screen, index: index)
        case let .alert(_, identity):
          WeatherAlertDetailView(screen: screen, identity: identity)
        case .radio:
          WeatherRadioView(screen: screen)
        }
      } else {
        // A tapped notification can open the tool straight onto its alert, before the page it
        // was raised for has a build. Waiting is the honest screen; "this alert is no longer
        // active" would not be.
        ProgressView()
          .controlSize(.large)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .themedCanvas(theme)
          .weatherToolChrome()
      }
    }
  }

  /// What the Update control on this screen speaks for: what it would send, and what the last
  /// tap or pull did send. The bottom bar is for a request neither of them shows.
  private var requestsOnScreen: Set<WeatherRequest> {
    guard let screen else { return [] }
    return Set(screen.plan.requests).union(screen.updateRequests)
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

  /// Runs after Places is gone, so a permission prompt never lands on a sheet that is dismissing —
  /// and only for the visit's live model.
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

/// The tool's bottom toolbar (docs/MESHWX_UI.md §4): **Places · the page dots · Update**, in the
/// same three positions on every page, in the system's own bar.
///
/// On iOS 26 the three are three glass elements — two buttons, and the dots floating bare over
/// the page between them, which is Apple Weather's own bottom edge. A `ToolbarItemGroup` there
/// would have put all three inside one long capsule, which is the bar this replaces. Before iOS
/// 26 the group is the system's plain bottom bar. The branch is on the OS, fixed for the life
/// of the process, so no toolbar item ever changes identity (`RadioStatusControl`).
private struct WeatherBottomToolbar: ViewModifier {
  let model: WeatherToolModel
  let screen: WeatherPageScreen?
  let onOpenPlaces: () -> Void

  func body(content: Content) -> some View {
    let plan = model.plan(for: model.selectedPageID)
    if #available(iOS 26, *) {
      content.toolbar {
        ToolbarItem(placement: .bottomBar) { places }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) { dots }
          .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
          WeatherUpdateControl(screen: screen, plan: plan)
        }
      }
    } else {
      content.toolbar {
        ToolbarItemGroup(placement: .bottomBar) {
          places
          Spacer()
          dots
          Spacer()
          WeatherUpdateControl(screen: screen, plan: plan)
        }
      }
    }
  }

  /// A word, not a glyph: the list icon in a corner was the control the owner could not find.
  private var places: some View {
    Button(action: onOpenPlaces) {
      Text(L10n.Weather.Weather.Place.places)
    }
    .accessibilityLabel(L10n.Weather.Weather.Place.places)
    .accessibilityIdentifier("weather.places.button")
  }

  private var dots: some View {
    WeatherPageDots(pages: model.pages, selectedID: model.selectedPageID)
  }
}

/// The pager's dots, drawn rather than borrowed from `TabView`'s index view so they can live in
/// the toolbar. One dot per page, the page on screen filled — and My location is the arrow, as it
/// is in Apple Weather, so the first dot says what the first page is.
private struct WeatherPageDots: View {
  let pages: [WeatherPage]
  let selectedID: String

  var body: some View {
    HStack(spacing: 9) {
      ForEach(pages) { page in
        let isOn = page.id == selectedID
        Group {
          if page.id == WeatherPage.myLocationID {
            Image(systemName: "location.fill")
              .font(.system(size: 10, weight: .bold))
          } else {
            Circle()
              .frame(width: 7, height: 7)
          }
        }
        .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
      }
    }
    .frame(minHeight: 44)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.Weather.Weather.Place.pageOf(
      (pages.firstIndex { $0.id == selectedID } ?? 0) + 1, pages.count))
    .accessibilityIdentifier("weather.pageDots")
  }
}

/// Watches the app values the screen reacts to, in a view of its own: reading the phone fix in
/// the screen's body would re-render the whole pager on every location update.
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
