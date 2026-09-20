import CoreLocation
import Foundation
import MC1Services
import MeshWX
import OSLog
import SwiftUI
import UserNotifications

/// Long-lived tasks the model owns. Cancelled when the model goes, which is when the visit to the
/// tool ends (`WeatherModelStore`).
final class WeatherTaskHolder {
  private var tasks: [String: Task<Void, Never>] = [:]

  func replace(_ key: String, with task: Task<Void, Never>) {
    tasks[key]?.cancel()
    tasks[key] = task
  }

  func cancel(_ key: String) {
    tasks[key]?.cancel()
    tasks[key] = nil
  }

  deinit {
    for task in tasks.values {
      task.cancel()
    }
  }
}

/// What Places asked for, applied once its sheet has gone.
enum WeatherPlacePickerAction: Equatable {
  case place(WeatherSavedPlace)
  case currentLocation
  /// A weather station found by its airport code: it opens **that station's screen and nothing
  /// else** (docs/MESHWX_UI.md §12, §3.1 U-3).
  ///
  /// It used to do three things at once — push the station, save a place, and make that place a
  /// page — so typing KAUS produced a second page called "Austin" beside the one already there,
  /// and TJSJ produced a page called "Eleanor Roosevelt". An airport code is a question about a
  /// station, not a place someone wants to keep.
  case station(index: UInt16)
}

/// A station screen to push, **and the page it was asked for from** (docs/MESHWX_UI.md §13).
///
/// The page travels with the request. Without it the pager pushed whatever page it happened to be
/// on by the time the destination was built, which for a notification tap is the page being
/// switched *away* from: the tap selects the alert's own page and sets the alert in the same
/// turn, so a destination that reads "the page the pager is on" can be one page behind.
struct WeatherStationTarget: Equatable {
  let pageID: String
  let index: UInt16
}

/// An alert to push, and the page it is to be judged against — "Covers Austin" is a sentence
/// about one place, and the map is framed on it.
struct WeatherAlertTarget: Equatable {
  let pageID: String
  let identity: MeshWXWarningIdentity
}

/// One page's own screen: the build made for that page, and the model behind it
/// (docs/MESHWX_UI.md §13).
///
/// Every screen reached from a page is handed one of these rather than the model, so what it
/// shows is the place it was opened from and never whichever page the pager has since landed on.
/// The build is read back by page id while the model still holds it, so an answer that arrives
/// with a detail screen open shows on it.
@MainActor
struct WeatherPageScreen {
  let model: WeatherToolModel
  /// The build this screen was opened with, and what it falls back to if the page's build is
  /// evicted from under a pushed screen.
  let opened: WeatherPageBuild

  var pageID: String { opened.pageID }
  var build: WeatherPageBuild { model.build(for: pageID) ?? opened }
  var snapshot: WeatherScreenSnapshot { build.snapshot }
  var context: WeatherScreenContext { build.context }
  var place: WeatherPlace? { snapshot.place }
  var now: Date { model.now }

  /// The place's name, "Austin, TX" — the one label every screen uses (§3.1 U-12).
  var placeName: String? {
    snapshot.place.map { WeatherFormatting.placeName($0.label) }
  }

  /// The bot **this page** would ask. What a screen shows may have come from another one, and
  /// then it is named from the item (`WeatherToolModel.botName`), not from here.
  var sourceName: String {
    guard let source = snapshot.source else { return L10n.Weather.Weather.Bot.generic }
    return WeatherFormatting.botName(botID: source.botID, bot: source.bot)
  }

  // MARK: - Update (§11), per page

  var plan: WeatherUpdatePlan { model.plan(for: pageID) }
  var isUpdating: Bool { model.isUpdating(pageID: pageID) }
  var updateRequests: Set<WeatherRequest> { model.updateRequests(pageID: pageID) }
  var updateStatusText: String? { model.updateStatusText(pageID: pageID) }

  // MARK: - Requests derived from this page's place

  /// The state storm reports and rainfall ask for on this page.
  var reportState: String? { model.reportState(for: pageID) }

  func alertsRequest(for status: WeatherAlertStatus) -> WeatherRequest {
    model.alertsRequest(for: status, in: context)
  }

  var missingWarnings: [MeshWXWarningIdentity] { context.sourceState?.missingFromDigest ?? [] }
  var missingWarningsRequest: WeatherRequest? { model.missingWarningsRequest(in: context) }
  var missingNotAvailable: Set<MeshWXWarningIdentity> { model.missingNotAvailable(in: context) }
}

/// The Weather tool's model: gathers the inputs, builds one `WeatherScreenSnapshot` **per page**
/// off the main actor on defined triggers, and holds what the service does not — the place,
/// request outcomes, and the transient notices.
///
/// Owned by `WeatherModelStore` for the visit. `init` allocates nothing; `attach` and `appear`
/// start the work, idempotently.
@Observable
@MainActor
final class WeatherToolModel {
  // MARK: - Published

  /// One build per page, keyed by page id: the page the pager is on and the two it can be swiped
  /// to next (docs/MESHWX_UI.md §13). Nothing beyond those is kept — a page further away cannot
  /// be reached without passing one of them, and it is rebuilt by the time it is.
  private(set) var builds: [String: WeatherPageBuild] = [:]
  private(set) var placeState: WeatherPlaceState = .needsPermission
  private(set) var searchedPlace: WeatherPlace?
  /// The places kept in Places, in the order Places holds them. Held on the phone, not for the
  /// visit (docs/MESHWX_UI.md §5); each is a page of the pager, after My location.
  private(set) var savedPlaces: [WeatherSavedPlace] = []
  /// The page the pager is on. Kept for the visit, so a pushed screen, a rotation and the
  /// compact/regular shell swap all come back to the place the user was looking at.
  private(set) var selectedPageID = WeatherPage.myLocationID
  /// Whose Update run is on the air and what each page's last one asked for. One run at a time,
  /// and the spinner and the caption belong to the page that started it.
  private(set) var updateRuns = WeatherUpdateRuns()
  /// A station screen Places asked to open, pushed once the sheet has gone. Set by picking an
  /// airport code, which names a station rather than a town (docs/MESHWX_UI.md §12).
  var stationToOpen: WeatherStationTarget?
  /// An alert screen a tapped notification asked for, pushed the same way (docs/MESHWX_UI.md
  /// §16).
  var alertToOpen: WeatherAlertTarget?
  /// Which warnings the phone is to be told about, and whether its own position is watched.
  /// Nothing is on until the user turns a bell on.
  private(set) var subscriptions = WeatherAlertSubscriptions()
  /// Set by a bell tapped while iOS has notifications turned off for the app, so the screen can
  /// say so and offer Settings rather than turning on a bell that would never ring.
  var showsNotificationsDenied = false
  /// When this visit saw the radio go: the notifications screen says since when nothing can
  /// arrive, and only when it actually knows.
  private(set) var radioDisconnectedAt: Date?
  /// The label last resolved for the phone's own place. Kept while a searched place is on screen,
  /// so the picker's "Your location" row can name it instead of saying the phone is locating when
  /// nothing is (docs/MESHWX_UI.md §12).
  private(set) var currentLocationLabel: String?
  /// Requests on the air, as the service's events report them. Builds never write this.
  private(set) var pending: [WeatherPendingRequest] = []
  /// Requests between the tap and the service's answer to `send`, so a second tap in that window
  /// finds the button already disabled.
  private(set) var inFlight: Set<WeatherRequest> = []
  private(set) var outcomes: [WeatherRequest: WeatherSettledOutcome] = [:]
  private(set) var answerNotes: [WeatherRequest: WeatherAnswerNote] = [:]
  /// What this phone has put on the air, newest first, and how each request ended
  /// (docs/MESHWX_UI.md §12). Kept on the phone across visits: the answers were broadcast to
  /// everyone, so only the asking is this app's to remember.
  private(set) var requestLog: [WeatherRequestLogEntry] = []
  /// The request refused inside the five-second spacing, while its notice shows.
  private(set) var rateLimitedRequest: WeatherRequest?
  private(set) var preferredBotID: UInt16?
  /// The link the weather transport provides of its own, when it has one. Only the DEBUG bridge
  /// to a real bot does (`WeatherTransportLink`): it is a live connection to that one bot with
  /// no radio in it at all, so while it is there the radio reads as connected and the bot it
  /// names is announced, though no contact carries its advert. Nil over a radio, always.
  @ObservationIgnored private(set) var transportLink: WeatherTransportLink?
  private(set) var isAddingChannel = false
  /// The connect-time channel sync has finished for the connected radio. Until then the app's
  /// channel table may be empty, and "#meshwx isn't set up" would be a guess.
  private(set) var isChannelSyncDone = false
  private(set) var now = Date(timeIntervalSince1970: 0)
  var errorMessage: String?
  /// The state storm reports and rainfall ask for, per page, when the user changed it this visit.
  /// Picking Texas on one page never sends `>storm TX` for another place's page.
  private(set) var reportStateOverrides: [String: String] = [:]
  /// A pick from the place picker, applied when its sheet has closed.
  var pendingPlaceAction: WeatherPlacePickerAction?
  /// Where the saved list lives. One store, read and written through
  /// `WeatherSavedPlacesStore.apply`, so every edit lands on the list the phone actually holds
  /// (docs/MESHWX_UI.md §3.1 U-1). Injectable so a test gets its own defaults suite rather than
  /// the user's.
  @ObservationIgnored let savedPlacesStore: WeatherSavedPlacesStore
  /// Which states the next alert map should cover, kept on the phone (`weather.areaSelection`).
  /// Injectable for the same reason.
  @ObservationIgnored let areaSelectionStore: WeatherAreaSelectionStore
  /// What this phone heard and sent on the weather slot, oldest first — the channel traffic
  /// timeline's rows (docs/MESHWX_UI.md §12). Empty until that screen asks for them.
  private(set) var traffic: [WeatherTrafficEntry] = []
  /// The choice made on this phone, or nil while nobody has made one. Nil is not the whole
  /// country: the default depends on the page's own place, which the store knows nothing about.
  private(set) var chosenAreas: WeatherAreaSelection?

  init(
    savedPlacesStore: WeatherSavedPlacesStore = WeatherSavedPlacesStore(),
    areaSelectionStore: WeatherAreaSelectionStore = WeatherAreaSelectionStore()
  ) {
    self.savedPlacesStore = savedPlacesStore
    self.areaSelectionStore = areaSelectionStore
  }
  /// Why the pull that just happened sent nothing, while it is worth saying
  /// (docs/MESHWX_UI.md §3.1 U-6). A gesture that silently does nothing reads as broken.
  private(set) var blockedPullNotice: String?
  /// Bumped with every blocked pull, so the haptic fires again on a second one.
  private(set) var blockedPullCount = 0

  // MARK: - Private

  struct Fingerprint {
    let token: UUID
    let value: Int?
    let kind: WeatherAnswerNote.Kind
  }

  @ObservationIgnored private weak var appState: AppState?
  @ObservationIgnored private var holder: WeatherTaskHolder?
  @ObservationIgnored private var hasSubscribed = false
  @ObservationIgnored private var subscribedServices: ObjectIdentifier?
  @ObservationIgnored private var placeSample: WeatherLocationSample?
  /// The phone's own newest fix, whatever place is on screen: Places names it and shows what is
  /// held for it even while a saved place is showing.
  @ObservationIgnored private(set) var latestSample: WeatherLocationSample?
  @ObservationIgnored private var locatingUntil: Date?
  @ObservationIgnored private var isSceneActive = true
  @ObservationIgnored private var isRebuildScheduled = false
  @ObservationIgnored private var isBuilding = false
  @ObservationIgnored private var isBuildingNeighbours = false
  @ObservationIgnored private var needsAnotherBuild = false
  @ObservationIgnored private var hasRequestedGeometry = false
  @ObservationIgnored private(set) var fingerprints: [WeatherRequest: Fingerprint] = [:]

  // Caches, so the 30-second rebuild reads no database, no disk and no 35,000-place table.
  @ObservationIgnored private var cachedContacts: [ContactDTO]?
  @ObservationIgnored private var cachedChannels: [ChannelDTO]?
  @ObservationIgnored private var cachedOfflineStates: [UInt16: WeatherBotState]?
  @ObservationIgnored private var cachedRadioID: UUID?
  /// Per page, so swiping back does not repeat the 35,000-place label lookup, the area codes,
  /// the nearest station and the state code for a place that has not moved.
  @ObservationIgnored private var placeFacts: [String: WeatherPlaceFacts] = [:]
  @ObservationIgnored private var stationTowns: [UInt16: String] = [:]

  private static let logger = Logger(subsystem: "com.mc1", category: "WeatherToolModel")
  static let debounce: Duration = .milliseconds(150)
  static let tick: Duration = .seconds(30)
  /// How old a neighbour's build may be before the next build of the page on screen refreshes it
  /// too. Short enough that a swipe lands on current ages, long enough that a busy channel does
  /// not rebuild three pages a second.
  static let neighbourFreshFor: TimeInterval = 15
  static let locatingWindow: TimeInterval = 5
  /// A fix older than this is refreshed on "Back to my location".
  static let staleFixAge: TimeInterval = 5 * 60
  /// How many of this phone's own requests the radio page lists before it stops and offers the
  /// rest behind a row (docs/MESHWX_UI.md §3.1 U-39).
  nonisolated static let newestRequestCount = 3

  // MARK: - Derived

  /// One page's build, while it is held.
  func build(for pageID: String) -> WeatherPageBuild? { builds[pageID] }

  /// One page as a screen: what every drill-in is handed. Nil until that page's first build lands.
  func screen(for pageID: String) -> WeatherPageScreen? {
    builds[pageID].map { WeatherPageScreen(model: self, opened: $0) }
  }

  /// The page the pager is on, as a screen.
  var screen: WeatherPageScreen? { screen(for: selectedPageID) }

  /// The page the pager is on. For the screens that are about the *visit* rather than about a
  /// page — Places and the notifications screen — and for the pending bar, which speaks for the
  /// one radio. A screen reached from a page reads its own `WeatherPageScreen` instead.
  var snapshot: WeatherScreenSnapshot? { builds[selectedPageID]?.snapshot }
  var context: WeatherScreenContext { builds[selectedPageID]?.context ?? WeatherScreenContext() }

  /// The bot the page the pager is on would ask.
  var sourceName: String {
    guard let source = snapshot?.source else { return L10n.Weather.Weather.Bot.generic }
    return WeatherFormatting.botName(botID: source.botID, bot: source.bot)
  }

  /// The name of the bot something actually came from: an item carries its own `botID`, and a
  /// screen that shows somebody's item names that bot rather than the one this page would ask.
  func botName(_ botID: UInt16) -> String {
    let bots = builds[selectedPageID]?.context.bots ?? builds.values.first?.context.bots ?? []
    return WeatherFormatting.botName(botID: botID, bot: bots.first { $0.botID == botID })
  }

  /// The place's short name, "Austin", for the page the pager is on.
  var placeName: String? {
    snapshot?.place.map { WeatherFormatting.placeName($0.label) }
  }

  var isRadioConnected: Bool { appState?.services != nil }

  /// The request the pending bar speaks for: one on the air, else one being sent.
  var activeRequest: WeatherRequest? {
    pending.first?.request ?? inFlight.first
  }

  /// The last time any weather radio was heard live, not drained from your radio's queue.
  var liveHeardAt: Date? {
    context.botRows.compactMap(\.lastLiveHeardAt).max()
  }

  /// A complete reply to this very request, owned by this phone and under five minutes old: asking
  /// again would have the bot rebuild the same reply on everyone's airtime (spec §13), so the
  /// answer stands in for the button.
  func freshOwnedReply(for request: WeatherRequest) -> WeatherTextItem? {
    guard case .text = request.expectedReply else { return nil }
    return snapshot?.texts.first { Self.isFreshOwnedReply($0.assembly, for: request, now: now) }
  }

  nonisolated static func isFreshOwnedReply(_ assembly: WeatherTextAssembly, for request: WeatherRequest, now: Date) -> Bool {
    assembly.request == request && assembly.isComplete
      && now.timeIntervalSince(assembly.lastReceivedAt) < WeatherService.recentAnswerWindow
  }

  // MARK: - Lifecycle

  /// Binds to the current services. Called from `.task(id: servicesVersion)`: safe to repeat,
  /// and never undone by a disappearance.
  func attach(appState: AppState) async {
    start(appState)
    let services = appState.services
    // Only a disconnection this visit is dated: with the tool opened after one, the phone does
    // not know when the radio went, and the row says so without inventing a time.
    if services == nil, hasSubscribed, radioDisconnectedAt == nil {
      radioDisconnectedAt = Date()
    } else if services != nil {
      radioDisconnectedAt = nil
    }
    let identity = services.map(ObjectIdentifier.init)
    if !hasSubscribed || identity != subscribedServices {
      hasSubscribed = true
      subscribedServices = identity
      cachedContacts = nil
      cachedChannels = nil
      cachedOfflineStates = nil
      subscribe(to: services?.weatherService)
      pending = await services?.weatherService.pendingRequests() ?? []
      // Asked once per set of services, before the first build: a transport that is its own
      // link says so from the start, so the tool is never briefly "connect your radio" over a
      // bridge that is up.
      transportLink = await services?.weatherService.transportLink()
    }
    scheduleRebuild()
  }

  /// The place is decided on arrival: a searched place stays; otherwise the phone's fix, or up to
  /// five seconds of "Locating…" when authorized with no fix yet. Coming back from a pushed screen
  /// keeps the place unless the phone has a meaningfully newer fix.
  func appear(appState: AppState) {
    start(appState)
    let location = appState.locationService
    latestSample = Self.sample(location.currentLocation)
    if searchedPlace == nil {
      if let latest = latestSample, placeSample.map({ Self.isMeaningfulChange(from: $0, to: latest) }) ?? true {
        placeSample = latest
      }
      if location.isAuthorized {
        appState.requestPhoneFixIfStale()
        if placeSample == nil { startLocating(for: Self.locatingWindow) }
      }
    }
    takeTappedAlert()
    updatePlaceState()
    scheduleRebuild()
  }

  /// The alert a tapped notification asked for, if the tap is recent and this is the screen it
  /// was waiting for (docs/MESHWX_UI.md §16).
  ///
  /// The notification was raised for one watched place, and it says so: the pager goes to that
  /// place's page first, so "Covers Austin" and the map's framing are computed for the place the
  /// warning was matched against rather than for whatever page happened to be open.
  private func takeTappedAlert() {
    guard let target = WeatherAlertNotificationTap.shared.take() else { return }
    let wanted = WeatherPages.pageID(forWatchedPlaceID: target.placeID)
    let pageID = pages.contains { $0.id == wanted } ? wanted : selectedPageID
    if pageID != selectedPageID { showPage(pageID) }
    // The page goes with the alert. Selecting the page and naming the alert happen in one turn,
    // so a destination that read "the page the pager is on" could be built against the page being
    // left (docs/MESHWX_UI.md §3.1 U-18).
    alertToOpen = WeatherAlertTarget(pageID: pageID, identity: target.identity)
  }

  private func start(_ appState: AppState) {
    self.appState = appState
    guard holder == nil else { return }
    holder = WeatherTaskHolder()
    preferredBotID = WeatherPreferenceStore().selectedBotID
    adopt(savedPlacesStore.places)
    subscriptions = DefaultsWeatherAlertWatchStore().subscriptions
    requestLog = WeatherRequestLogStore().entries
    chosenAreas = areaSelectionStore.selection
    now = Date()
    // Warm the tables where the first-touch cost is invisible.
    Task.detached(priority: .utility) { _ = MeshWXTables.shared }
    startTicking()
  }

  private func startTicking() {
    holder?.replace("tick", with: Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.tick)
        guard !Task.isCancelled else { return }
        self?.tickFired()
      }
    })
  }

  private func tickFired() {
    now = Date()
    scheduleRebuild()
    refreshTransportLinkIfNeeded()
  }

  /// Asks again for the transport's own link while there is none: the DEBUG bridge may have
  /// come up after this visit started, and its bot is what the tool would then ask. Over a
  /// radio the answer is nil every time and costs one hop to the service.
  private func refreshTransportLinkIfNeeded() {
    guard transportLink == nil, let service = appState?.services?.weatherService else { return }
    holder?.replace("transportLink", with: Task { [weak self] in
      let link = await service.transportLink()
      guard !Task.isCancelled, let self, link != nil else { return }
      transportLink = link
      scheduleRebuild()
    })
  }

  /// No tick while the scene is inactive; a refresh as soon as it is active again.
  func scenePhaseChanged(_ phase: ScenePhase) {
    guard holder != nil else { return }
    let active = phase == .active
    guard active != isSceneActive else { return }
    isSceneActive = active
    if active {
      now = Date()
      // A notification tapped while the tool was already open foregrounds the app without
      // bringing this root back.
      takeTappedAlert()
      startTicking()
      scheduleRebuild()
    } else {
      holder?.cancel("tick")
    }
  }

  func contactsChanged() {
    cachedContacts = nil
    scheduleRebuild()
  }

  func channelSyncChanged(isDone: Bool) {
    guard isDone != isChannelSyncDone else { return }
    isChannelSyncDone = isDone
    cachedChannels = nil
    scheduleRebuild()
  }

  // MARK: - Events

  private func subscribe(to service: WeatherService?) {
    guard let holder else { return }
    guard let service else {
      holder.cancel("events")
      return
    }
    let events = service.events()
    holder.replace("events", with: Task { [weak self] in
      for await event in events {
        guard let model = self else { return }
        await model.handle(event, from: service)
      }
    })
  }

  private func handle(_ event: WeatherEvent, from service: WeatherService) async {
    // The channel traffic timeline follows the wire, so it is refreshed by every event that
    // could have put a row in the log — but only while somebody is looking at it, because a
    // busy channel would otherwise copy three hundred rows out of the actor per datagram.
    if isShowingTraffic { await refreshTraffic(from: service) }
    switch event {
    case .stateLoaded, .received:
      scheduleRebuild()
    case let .requestSent(entry), let .requestReceivedByBotRadio(entry):
      pending.removeAll { $0.id == entry.id }
      pending.append(entry)
      pending = await service.pendingRequests()
    case let .requestSettled(request, outcome):
      now = Date()
      pending.removeAll { $0.id == request.id }
      outcomes[request.request] = WeatherSettledOutcome(outcome: outcome, at: now)
      settleRequestLog(id: request.id, outcome: outcome)
      if case .answered = outcome, let before = fingerprints.removeValue(forKey: request.request) {
        let after = Self.fingerprint(request.request, sourceBotID: request.botID, states: await service.allStates())
        answerNotes[request.request] = after?.value == before.value ? .unchanged(before.kind) : .changed
      }
      pending = await service.pendingRequests()
      announce(request.request)
      scheduleRebuild()
    }
  }

  private func announce(_ request: WeatherRequest) {
    guard let text = statusText(for: request) else { return }
    AccessibilityNotification.Announcement(text).post()
  }

  // MARK: - Rebuild

  /// Coalesces a burst of triggers into one build 150 ms later; a trigger during a build runs
  /// one more build after it.
  func scheduleRebuild() {
    guard let holder else { return }
    if isBuilding {
      needsAnotherBuild = true
      return
    }
    guard !isRebuildScheduled else { return }
    isRebuildScheduled = true
    holder.replace("rebuild", with: Task { [weak self] in
      try? await Task.sleep(for: Self.debounce)
      guard !Task.isCancelled else { return }
      await self?.rebuild()
    })
  }

  /// Builds the page the pager is on, then its neighbours. Drains a trigger that arrived during
  /// the build on **every** exit, including the ones that build nothing: a rebuild asked for
  /// while the model had no `appState` would otherwise never happen.
  private func rebuild() async {
    isRebuildScheduled = false
    defer {
      isBuilding = false
      if needsAnotherBuild {
        needsAnotherBuild = false
        scheduleRebuild()
      }
    }
    guard let appState else { return }
    isBuilding = true
    // The page as it is now: the user can swipe while the build runs, and the snapshot that comes
    // back belongs to the page it was asked about, not to wherever the pager has since landed.
    let pageID = selectedPageID
    let request = buildRequest(appState, pageID: pageID)
    let result = await Task.detached(priority: .userInitiated) {
      await WeatherScreenBuilder.build(request)
    }.value
    apply(result, for: request, isSelected: pageID == selectedPageID)
    buildNeighbours(appState)
  }

  /// The two pages a swipe can reach next, built at idle priority so the page they are swiped to
  /// is already there. This is what closes the window in which the title named one place and the
  /// screen still held another's (docs/MESHWX_UI.md §13).
  private func buildNeighbours(_ appState: AppState) {
    // One neighbour run at a time, never cancelled and restarted: a busy channel rebuilds the
    // page on screen several times a second, and a pre-build that was started over every time
    // would never finish. What it misses, the next rebuild picks up.
    guard !isBuildingNeighbours else { return }
    let wanted = WeatherPages.neighbours(of: selectedPageID, in: pages).filter { pageID in
      guard let built = builds[pageID] else { return true }
      // Kept fresh as well as warm: a neighbour built ten minutes ago and swiped to would show
      // ten-minute-old ages for as long as its rebuild takes.
      return now.timeIntervalSince(built.snapshot.now) >= Self.neighbourFreshFor
    }
    guard !wanted.isEmpty else { return }
    let requests = wanted.map { buildRequest(appState, pageID: $0) }
    isBuildingNeighbours = true
    holder?.replace("neighbours", with: Task { [weak self] in
      defer { self?.isBuildingNeighbours = false }
      for request in requests {
        guard !Task.isCancelled else { return }
        let result = await Task.detached(priority: .utility) {
          await WeatherScreenBuilder.build(request)
        }.value
        guard !Task.isCancelled, let self else { return }
        apply(result, for: request, isSelected: false)
      }
    })
  }

  /// What one page is built from. Everything but the place is the visit's; the place is the
  /// page's own, which is why a build can be asked for a page the pager is not on.
  private func buildRequest(_ appState: AppState, pageID: String) -> WeatherBuildRequest {
    let services = appState.services
    let device = appState.connectedDevice
    let radioID = device?.radioID ?? appState.currentRadioID
    if radioID != cachedRadioID {
      cachedRadioID = radioID
      cachedContacts = nil
      cachedChannels = nil
    }
    return WeatherBuildRequest(
      weatherService: services?.weatherService,
      contactService: services?.contactService,
      dataStore: services?.dataStore ?? appState.offlineDataStore,
      radioID: radioID,
      preferredBotID: preferredBotID,
      pageID: pageID,
      place: placeInput(for: pageID),
      isRadioConnected: services != nil,
      // With a link of its own the transport is the connection, whatever Bluetooth is doing:
      // the build treats the radio as connected and the link's bot as announced.
      transportLink: transportLink,
      isChannelSyncDone: isChannelSyncDone,
      firmwareSupportsWeather: device?.supportsChannelDatagrams,
      firmwareVersion: device?.firmwareVersionString ?? "",
      now: Date(),
      calendar: .autoupdatingCurrent,
      contacts: cachedContacts,
      channels: cachedChannels,
      offlineStates: services == nil ? cachedOfflineStates : nil,
      placeFacts: placeFacts[pageID],
      stationTowns: stationTowns)
  }

  /// The place a page answers for: the saved place it *is*, or the phone's own fix for My
  /// location. Read from the pages rather than from `searchedPlace`, so a page the pager is not
  /// on can be built.
  private func placeInput(for pageID: String) -> WeatherBuildRequest.PlaceInput {
    if let saved = savedPlaces.first(where: { $0.id == pageID }) { return .searched(saved.place) }
    if pageID == WeatherPage.myLocationID, let placeSample { return .location(placeSample) }
    if pageID == selectedPageID, let searchedPlace { return .searched(searchedPlace) }
    return .none
  }

  /// - Parameter isSelected: this build is the page the pager is on. Only that one moves the
  ///   clock, the place state and the label Places shows for the phone's own position; a
  ///   neighbour built in the background changes nothing the user is looking at.
  private func apply(_ result: WeatherBuildResult, for request: WeatherBuildRequest, isSelected: Bool) {
    builds[request.pageID] = result.page
    evictDistantBuilds()
    if isSelected { now = result.page.snapshot.now }
    if request.radioID == cachedRadioID {
      cachedContacts = result.contacts
      cachedChannels = result.channels
    }
    if request.weatherService == nil, appState?.services == nil {
      cachedOfflineStates = result.offlineStates
    }
    placeFacts[request.pageID] = result.placeFacts
    if case .location = request.place, let label = result.placeFacts.label {
      currentLocationLabel = label
    }
    stationTowns = result.stationTowns
    if isSelected { updatePlaceState() }

    if result.page.context.needsGeometry, !hasRequestedGeometry {
      hasRequestedGeometry = true
      holder?.replace("geometry", with: Task { [weak self] in
        await Task.detached(priority: .utility) {
          await MeshWXGeometry.shared.preload()
        }.value
        guard !Task.isCancelled else { return }
        self?.scheduleRebuild()
      })
    }
  }

  /// Three builds are kept: the page on screen and the two a swipe can reach. The place facts are
  /// kept for every page — they are small, they are what makes swiping back free, and they are
  /// keyed by the place they were computed for, so a place that moves recomputes them anyway.
  private func evictDistantBuilds() {
    var keep = Set(WeatherPages.neighbours(of: selectedPageID, in: pages))
    keep.insert(selectedPageID)
    builds = builds.filter { keep.contains($0.key) }
  }

  // MARK: - Place

  func locationSampleChanged(_ sample: WeatherLocationSample?) {
    guard holder != nil else { return }
    latestSample = sample
    guard searchedPlace == nil, let sample else { return }
    if let current = placeSample, !Self.isMeaningfulChange(from: current, to: sample) { return }
    placeSample = sample
    endLocating()
    scheduleRebuild()
  }

  func authorizationChanged() {
    guard let appState, holder != nil else { return }
    if appState.locationService.isAuthorized, searchedPlace == nil, placeSample == nil {
      appState.requestPhoneFixIfStale()
      startLocating(for: Self.locatingWindow)
    }
    updatePlaceState()
  }

  // MARK: - Pages (§4)

  /// The pages the pager swipes through: My location, then the saved places in Places' order.
  var pages: [WeatherPage] { WeatherPages.make(saved: savedPlaces) }

  /// The page on screen, swiped to or picked in Places.
  ///
  /// It never reorders the list: pages moving under a swiping finger is exactly what a "newest
  /// first" sort would do. Changing page sends nothing — Update and the pull say what they would
  /// ask for (docs/MESHWX_UI.md §3.1 O-1, overturned).
  func showPage(_ id: String) {
    let pages = pages
    let resolved = WeatherPages.selection(id, in: pages)
    let page = pages.first { $0.id == resolved } ?? .myLocation
    let wasOn = selectedPageID
    selectedPageID = resolved
    if let saved = page.savedPlace {
      guard wasOn != resolved || searchedPlace != saved.place else { return }
      searchedPlace = saved.place
      endLocating()
    } else {
      guard wasOn != resolved || searchedPlace != nil else { return }
      searchedPlace = nil
      if let latestSample { placeSample = latestSample }
      // Swiping back to My location never asks for permission: only a tap does (§16).
      if let appState, appState.locationService.isAuthorized {
        appState.requestPhoneFixIfStale()
        if placeSample == nil { startLocating(for: Self.locatingWindow) }
      }
      updatePlaceState()
    }
    scheduleRebuild()
  }

  /// A place from Places: kept on the phone, and shown.
  ///
  /// A place already on the list **keeps its position** (`WeatherSavedPlaces.remember`). Tapping
  /// Round Rock to look at it is not a request to reorder the pager, and moving it to the front
  /// silently overwrote an order the user had dragged into place (docs/MESHWX_UI.md §3.1 U-4).
  func pick(_ saved: WeatherSavedPlace) {
    var chosen = saved
    chosen.chosenAt = Date()
    write(.remember(chosen))
    showPage(chosen.id)
  }

  /// Swiped away in Places. Its page goes with it — and its bell: they are one row.
  func removeSavedPlace(id: String) {
    write(.remove(id: id))
    if selectedPageID == id { showPage(WeatherPage.myLocationID) }
  }

  /// Dragged in Places. The pages follow the list, so the dots and the sheet always agree.
  ///
  /// The drag is turned into the order it produced, **by id**: the list on the phone may hold a
  /// place this sheet was never shown, and an index would then move somebody else's row.
  func moveSavedPlaces(fromOffsets source: IndexSet, toOffset destination: Int) {
    let moved = WeatherSavedPlaces.moving(
      fromOffsets: source, toOffset: destination, in: savedPlaces)
    write(.reorder(ids: moved.map(\.id)))
  }

  /// The one way the saved list changes (docs/MESHWX_UI.md §3.1 U-1).
  ///
  /// The edit is **applied to the list the store holds**, never to this model's copy. The model's
  /// copy is empty until `start` has read the store, and a pick in that window used to persist a
  /// one-place list over everything saved: on a real phone four places became one, renamed and
  /// moved to an airport's coordinates. `WeatherSavedPlacesStore.apply` also refuses any write
  /// that would drop a place nobody asked to drop.
  private func write(_ edit: WeatherSavedPlaces.Edit) {
    adopt(savedPlacesStore.apply(edit))
  }

  /// The saved list as the pages now stand.
  ///
  /// Every path that changes it comes through here — a bell, a removal, a drag, a pick, and the
  /// re-read the notifications screen does on every appearance. A selection left pointing at a
  /// page that is gone is a page that can never be built, which is a spinner that never ends on
  /// *every* page until the next swipe.
  private func adopt(_ places: [WeatherSavedPlace]) {
    guard places != savedPlaces else { return }
    savedPlaces = places
    healSelection()
  }

  /// Resolves the selection through the pages and writes it back. Nothing else ever leaves
  /// `selectedPageID` naming a page that is not there.
  private func healSelection() {
    let resolved = WeatherPages.selection(selectedPageID, in: pages)
    guard resolved != selectedPageID else { return }
    showPage(resolved)
  }

  // MARK: - Alert notifications (§16)

  /// The phone's own position is watched. The position itself is whatever fix the app last took,
  /// which can be hours old; every row that shows it shows its age.
  var isMyLocationWatched: Bool { subscriptions.watchesMyLocation }
  /// The saved places with their bell on, newest choice first.
  var watchedPlaces: [WeatherSavedPlace] { savedPlaces.filter(\.isWatched) }
  var isWatchingAnything: Bool { isMyLocationWatched || !watchedPlaces.isEmpty }
  /// The last position the app knows, read back from where the notifier reads it.
  private(set) var myLocationPosition: WeatherLastPosition?
  private(set) var notificationsAuthorization: UNAuthorizationStatus = .notDetermined

  func isWatched(placeID id: String) -> Bool {
    savedPlaces.first { $0.id == id }?.isWatched ?? false
  }

  /// Turns one saved place's bell on or off. It adds and removes no row: the pages are exactly
  /// what they were before the tap.
  func setWatch(_ isOn: Bool, forPlaceID id: String) async {
    if isOn, await !ensureNotificationPermission() { return }
    write(.watch(isOn, id: id))
  }

  /// Turns the bell on My location on or off. The fix the tool already holds is written as the
  /// starting position: the store keeps one only while this is on, so there is none to read.
  func setMyLocationWatch(_ isOn: Bool) async {
    if isOn, await !ensureNotificationPermission() { return }
    var updated = subscriptions
    updated.watchesMyLocation = isOn
    apply(updated)
    if isOn, let sample = latestSample ?? placeSample {
      WeatherLastPositionStore().record(
        latitude: sample.latitude, longitude: sample.longitude,
        horizontalAccuracy: sample.horizontalAccuracy, timestamp: sample.timestamp)
    }
    myLocationPosition = isOn ? WeatherLastPositionStore().position : nil
  }

  func setOtherWarnings(_ isOn: Bool) {
    var updated = subscriptions
    updated.notifiesOtherWarnings = isOn
    apply(updated)
  }

  func setTornadoNearby(_ isOn: Bool) {
    var updated = subscriptions
    updated.notifiesTornadoNearby = isOn
    apply(updated)
  }

  private func apply(_ updated: WeatherAlertSubscriptions) {
    subscriptions = updated
    DefaultsWeatherAlertWatchStore().subscriptions = updated
  }

  /// Re-reads what is watched and what iOS allows: the screens that show it are opened and left,
  /// and permission can change in Settings while the app is away.
  func refreshWatchState() async {
    subscriptions = DefaultsWeatherAlertWatchStore().subscriptions
    // Through the same door as every other change: the re-read can bring back a list this visit
    // has already changed, and the page on screen must survive it.
    adopt(savedPlacesStore.places)
    myLocationPosition = subscriptions.watchesMyLocation ? WeatherLastPositionStore().position : nil
    notificationsAuthorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    if notificationsAuthorization != .denied { showsNotificationsDenied = false }
  }

  /// The one moment notification permission is asked for: the user turning on their first bell
  /// (docs/MESHWX_UI.md §16). Never on opening the tool, and a bell that iOS would silence is
  /// not turned on — the screen says so and offers Settings instead.
  private func ensureNotificationPermission() async -> Bool {
    let center = UNUserNotificationCenter.current()
    let status = await center.notificationSettings().authorizationStatus
    notificationsAuthorization = status
    switch status {
    case .authorized, .provisional, .ephemeral:
      return true
    case .notDetermined:
      let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
      notificationsAuthorization = granted ? .authorized : .denied
      showsNotificationsDenied = !granted
      return granted
    default:
      showsNotificationsDenied = true
      return false
    }
  }

  /// Back to the phone's location; a stale fix is refreshed, with "Locating…" meanwhile.
  func backToMyLocation() {
    guard let appState else { return }
    selectedPageID = WeatherPage.myLocationID
    searchedPlace = nil
    if let latestSample { placeSample = latestSample }
    let location = appState.locationService
    if location.isAuthorized {
      let isStale = placeSample.map { Date().timeIntervalSince($0.timestamp) > Self.staleFixAge } ?? true
      if isStale {
        appState.requestPhoneFixIfStale()
        startLocating(for: Self.locatingWindow)
      }
    }
    updatePlaceState()
    scheduleRebuild()
  }

  /// Applies the picker's pick. Returns true when it needs "Use my location", which may ask for
  /// permission: the caller decides whether that is safe now.
  func applyPendingPlaceAction(isLocationAuthorized: Bool) -> Bool {
    guard let action = pendingPlaceAction else { return false }
    pendingPlaceAction = nil
    switch action {
    case let .place(saved):
      pick(saved)
      return false
    case .currentLocation:
      guard isLocationAuthorized else { return true }
      backToMyLocation()
      return false
    case let .station(index):
      // The station's screen, over the page the user was already on. No page is added, the pager
      // does not move, and nothing is saved (docs/MESHWX_UI.md §3.1 U-3).
      stationToOpen = WeatherStationTarget(pageID: selectedPageID, index: index)
      return false
    }
  }

  /// A pull the radio cannot answer: the reason, in the bar at the bottom, for a few seconds.
  ///
  /// Long enough to read and short enough not to become furniture — the reason is already in the
  /// caption at the top of the list, and this is only the gesture admitting it did nothing.
  func noteBlockedPull(_ reason: String) {
    blockedPullNotice = reason
    blockedPullCount += 1
    let count = blockedPullCount
    holder?.replace("blockedPull", with: Task { [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled, let self, blockedPullCount == count else { return }
      blockedPullNotice = nil
    })
  }

  /// The one path that may ask for location permission: the user's tap.
  func useMyLocation() async {
    guard let appState else { return }
    let location = appState.locationService
    selectedPageID = WeatherPage.myLocationID
    searchedPlace = nil
    if let latestSample { placeSample = latestSample }
    startLocating(for: 45)
    scheduleRebuild()
    do {
      let fix = try await location.requestCurrentLocation(timeout: .seconds(10))
      if let sample = Self.sample(fix) {
        latestSample = sample
        if searchedPlace == nil { placeSample = sample }
      }
    } catch {
      Self.logger.info("Weather location request ended: \(error.localizedDescription)")
    }
    endLocating()
    scheduleRebuild()
  }

  /// "Update location" for a last-known place.
  func updateLocation() {
    guard let appState, appState.locationService.isAuthorized else { return }
    appState.locationService.requestLocation()
    startLocating(for: Self.locatingWindow)
  }

  private func startLocating(for seconds: TimeInterval) {
    locatingUntil = Date().addingTimeInterval(seconds)
    updatePlaceState()
    holder?.replace("locating", with: Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.endLocating()
    })
  }

  private func endLocating() {
    locatingUntil = nil
    holder?.cancel("locating")
    updatePlaceState()
  }

  private func updatePlaceState() {
    guard let location = appState?.locationService else { return }
    if searchedPlace != nil {
      placeState = .resolved
    } else if let locatingUntil, locatingUntil > Date() {
      placeState = .locating
    } else if placeSample != nil {
      placeState = snapshot?.place != nil ? .resolved : .locating
    } else if location.isLocationDenied {
      placeState = .denied
    } else if location.authorizationStatus == .notDetermined {
      placeState = .needsPermission
    } else {
      placeState = .unavailable
    }
  }

  nonisolated static func sample(_ location: CLLocation?) -> WeatherLocationSample? {
    guard let location, CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
    return WeatherLocationSample(
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude,
      horizontalAccuracy: location.horizontalAccuracy,
      timestamp: location.timestamp)
  }

  /// A new fix replaces the place's only when it says something new: a minute newer, half a
  /// kilometre away, or far more accurate. A survey stream delivering a fix a second would
  /// otherwise rebuild the screen every second.
  nonisolated static func isMeaningfulChange(from old: WeatherLocationSample, to new: WeatherLocationSample) -> Bool {
    if new.timestamp.timeIntervalSince(old.timestamp) >= 60 { return true }
    let moved = MeshWXGeo.distanceKilometres(
      fromLat: old.latitude, lon: old.longitude, toLat: new.latitude, lon: new.longitude)
    if moved >= 0.5 { return true }
    return new.horizontalAccuracy >= 0 && (old.horizontalAccuracy < 0 || new.horizontalAccuracy < old.horizontalAccuracy / 2)
  }

  // MARK: - Requests

  func status(for request: WeatherRequest) -> WeatherRequestStatus {
    Self.status(for: request, snapshot: snapshot, pending: pending, inFlight: inFlight, outcomes: outcomes, now: now)
  }

  /// A request's status from the model's parts. Only a missing snapshot means no bot is known yet:
  /// a snapshot whose `requestBlock` is nil can be asked.
  nonisolated static func status(
    for request: WeatherRequest,
    snapshot: WeatherScreenSnapshot?,
    pending: [WeatherPendingRequest],
    inFlight: Set<WeatherRequest>,
    outcomes: [WeatherRequest: WeatherSettledOutcome],
    now: Date
  ) -> WeatherRequestStatus {
    var effective = pending
    for sending in inFlight where !pending.contains(where: { $0.request == sending }) {
      effective.append(WeatherPendingRequest(request: sending, botID: 0, botPublicKey: Data(), sentAt: now))
    }
    let block: WeatherRequestBlock? = snapshot == nil ? .noBot : snapshot?.requestBlock
    return WeatherRequestStatus.resolve(request: request, block: block, pending: effective, outcomes: outcomes, now: now)
  }

  /// - Parameter source: the bot the screen asking is talking to. The page the pager is on by
  ///   default, which is what the pending bar speaks for; a screen with a page of its own names
  ///   that page's bot.
  func statusText(for request: WeatherRequest, source: String? = nil) -> String? {
    if rateLimitedRequest == request { return L10n.Weather.Weather.Request.rateLimited }
    return WeatherCopy.requestStatus(
      status(for: request), source: source ?? sourceName, request: request, answer: answerNotes[request],
      now: now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
  }

  /// - Parameter queued: part of an Update run. The one-at-a-time rule is for buttons a user
  ///   taps; a planned run keeps its own five-second spacing and would otherwise refuse every
  ///   step after the first while the first is still on the air.
  func send(_ request: WeatherRequest, queued: Bool = false) async {
    guard let service = appState?.services?.weatherService, let bot = snapshot?.source?.bot else { return }
    switch status(for: request) {
    case .idle, .settled: break
    case .waitingForOther where queued: break
    case .pending, .waitingForOther, .blocked: return
    }
    beginRequest(request)
    let token = UUID()
    if let before = Self.fingerprint(request, sourceBotID: bot.botID, states: await service.allStates()) {
      recordFingerprint(Fingerprint(token: token, value: before.value, kind: before.kind), for: request)
    }
    do {
      if let entry = try await service.send(request, to: bot) {
        if !pending.contains(where: { $0.id == entry.id }) { pending.append(entry) }
        recordRequest(id: entry.id, request: request, botID: bot.botID, at: entry.sentAt)
      } else {
        clearFingerprint(for: request, token: token)
      }
    } catch let error as WeatherRequestError {
      clearFingerprint(for: request, token: token)
      switch error {
      case .rateLimited:
        rateLimitedRequest = request
        holder?.replace("rateLimit", with: Task { [weak self] in
          try? await Task.sleep(for: .seconds(5))
          guard !Task.isCancelled, self?.rateLimitedRequest == request else { return }
          self?.rateLimitedRequest = nil
        })
      case let .transport(message):
        Self.logger.error("Weather request failed: \(message)")
        now = Date()
        outcomes[request] = WeatherSettledOutcome(outcome: .failed(message), at: now)
        // Nothing reached the air, but the user did ask: the log says the radio would not send it.
        recordRequest(id: UUID(), request: request, botID: bot.botID, at: now, outcome: .refused)
      }
    } catch {
      clearFingerprint(for: request, token: token)
      now = Date()
      outcomes[request] = WeatherSettledOutcome(outcome: .failed(error.localizedDescription), at: now)
    }
    endRequest(request)
  }

  /// Marks a request as being sent, before the first suspension, and clears what its button last
  /// said.
  func beginRequest(_ request: WeatherRequest) {
    inFlight.insert(request)
    outcomes[request] = nil
    answerNotes[request] = nil
    rateLimitedRequest = nil
  }

  func endRequest(_ request: WeatherRequest) {
    inFlight.remove(request)
  }

  // MARK: - Request log (§12)

  /// Records a request this phone has just put on the air. Only what actually went out: an answer
  /// the five-minute rule served from the channel spent no airtime and was nobody's request.
  private func recordRequest(
    id: UUID,
    request: WeatherRequest,
    botID: UInt16,
    at sentAt: Date,
    outcome: WeatherRequestLogEntry.Outcome? = nil
  ) {
    requestLog = WeatherRequestLog.recording(
      WeatherRequestLogEntry(id: id, request: request, botID: botID, sentAt: sentAt, outcome: outcome),
      in: requestLog, now: Date())
    WeatherRequestLogStore().entries = requestLog
  }

  /// Fills in how a request ended. `alreadyReceived` never gets here with a logged id: nothing
  /// was sent, so nothing was recorded.
  private func settleRequestLog(id: UUID, outcome: WeatherRequestOutcome) {
    let settled: WeatherRequestLogEntry.Outcome
    switch outcome {
    case .answered: settled = .answered
    case .timedOut: settled = .noAnswer
    case .notAvailable: settled = .notAvailable
    case .failed: settled = .refused
    case .alreadyReceived: return
    }
    let updated = WeatherRequestLog.settling(id: id, outcome: settled, in: requestLog)
    guard updated != requestLog else { return }
    requestLog = updated
    WeatherRequestLogStore().entries = updated
  }

  /// The newest few requests and how many there are in all, for the radio page's *Your requests*
  /// (docs/MESHWX_UI.md §12, §3.1 U-39).
  ///
  /// The owner's fifth ask: *Your requests is way too long of a list.* Forty rows of a ledger on
  /// a page whose other nine sections are one row each. It is three rows and a way in now, and
  /// the log itself is untouched — what was wrong was the page, not the record.
  var requestLogSplit: (newest: [WeatherRequestLogEntry], total: Int) {
    Self.requestLogSplit(requestLog)
  }

  nonisolated static func requestLogSplit(
    _ log: [WeatherRequestLogEntry], newest: Int = newestRequestCount
  ) -> (newest: [WeatherRequestLogEntry], total: Int) {
    (Array(log.prefix(newest)), log.count)
  }

  func recordFingerprint(_ fingerprint: Fingerprint, for request: WeatherRequest) {
    fingerprints[request] = fingerprint
  }

  /// Clears a fingerprint only if it is the one this call recorded.
  func clearFingerprint(for request: WeatherRequest, token: UUID) {
    guard fingerprints[request]?.token == token else { return }
    fingerprints[request] = nil
  }

  /// What an answer to a request would replace, to tell an answer that changed nothing from one
  /// that did. Nil for a request whose answer the phone does not keep in a comparable form.
  nonisolated static func fingerprint(
    _ request: WeatherRequest,
    sourceBotID: UInt16,
    states: [UInt16: WeatherBotState]
  ) -> (value: Int?, kind: WeatherAnswerNote.Kind)? {
    func hash(_ build: (inout Hasher) -> Bool) -> Int? {
      var hasher = Hasher()
      return build(&hasher) ? hasher.finalize() : nil
    }
    switch request {
    case let .forecast(point):
      return (states.values.compactMap { $0.forecasts[point]?.forecast.issuedMinutes }.max().map(Int.init), .forecast)
    case .observations:
      // What a batch would replace: the newest scheduled batch held, whatever single-station
      // answers have since landed on top of individual stations.
      let newest = states.values.flatMap { $0.observations.values.compactMap(\.lastBatchMinutes) }.max()
      return (newest.map(Int.init), .readings)
    case let .observation(station):
      guard let index = MeshWXTables.shared.stationIndex(forICAO: station) else { return nil }
      return (states.values.compactMap { $0.observations[index]?.timestampMinutes }.max().map(Int.init), .readings)
    case .digest:
      return (states[sourceBotID]?.digest.map { Int($0.digest.nowMinutes) }, .other)
    case .activeWarnings, .warning, .warningsTouching:
      let value = hash { hasher in
        let held = states.values.flatMap(\.warnings.values)
          .sorted { ($0.identity.event, $0.identity.office, $0.identity.etn) < ($1.identity.event, $1.identity.office, $1.identity.etn) }
        for stored in held {
          hasher.combine(stored.identity)
          hasher.combine(stored.warning.expiresMinutes)
          hasher.combine(stored.updateCount)
        }
        hasher.combine(states.values.map(\.pendingUpgrades.count).reduce(0, +))
        return true
      }
      return (value, .other)
    default:
      guard case .text = request.expectedReply else { return nil }
      // Only replies that answered this request: somebody else's reply on the same subject is
      // not an answer to this phone.
      let texts = states.flatMap { botID, state in
        state.texts.values.filter { $0.request == request }.map { (botID, $0) }
      }.sorted { ($0.0, $0.1.group) < ($1.0, $1.1.group) }
      let value = texts.isEmpty ? nil : hash { hasher in
        for (botID, assembly) in texts {
          hasher.combine(botID)
          hasher.combine(assembly.group)
          hasher.combine(assembly.chunks.count)
          hasher.combine(assembly.total)
        }
        return true
      }
      return (value, .other)
    }
  }

  // MARK: - Request arguments (derived from the place, never from held data)

  /// "Ask for alerts" for the status the card shows, chosen from the source bot's own state.
  ///
  /// Every one of these takes the page's own context: a `>w <county>` for the county the *page*
  /// is in, never for the county of whatever page the pager last built.
  func alertsRequest(for status: WeatherAlertStatus, in context: WeatherScreenContext) -> WeatherRequest {
    guard case .missedMessages = status, let source = context.sourceState else { return .digest }
    return WeatherAlertRequests.missedMessages(
      source: source, placeCountyUGC: context.placeCounty?.ugc, placeOffice: context.placeOffice,
      notAvailable: missingNotAvailable(in: context), tables: .shared)
  }

  /// The request for the warnings the list named that never arrived ("Listed, not received ·
  /// Ask"): one warning per tap, the most important the bot has not already said it lacks.
  func missingWarningsRequest(in context: WeatherScreenContext) -> WeatherRequest? {
    context.sourceState.flatMap {
      WeatherAlertRequests.missingWarnings(
        source: $0, placeOffice: context.placeOffice, notAvailable: missingNotAvailable(in: context),
        tables: .shared)
    }
  }

  /// Missing warnings the source bot answered "not available" for since its current list arrived.
  func missingNotAvailable(in context: WeatherScreenContext) -> Set<MeshWXWarningIdentity> {
    Self.notAvailableIdentities(outcomes: outcomes, since: context.sourceState?.digest?.receivedAt)
  }

  /// The identities of `>w <identity>` requests refused as not available at or after `since`, the
  /// arrival of the list that named them: a newer list can name one again, and then it is asked
  /// for again.
  nonisolated static func notAvailableIdentities(
    outcomes: [WeatherRequest: WeatherSettledOutcome],
    since listedAt: Date?
  ) -> Set<MeshWXWarningIdentity> {
    Set(outcomes.compactMap { request, settled in
      guard case let .warning(identity) = request, case .notAvailable = settled.outcome,
            settled.at >= (listedAt ?? .distantPast)
      else { return nil }
      return WeatherAlertRequests.identity(from: identity, tables: .shared)
    })
  }

  // MARK: - Update (§11)

  /// What one tap on Update on **that page** would ask for, from what the phone is actually
  /// missing for that place.
  ///
  /// Empty until the page has a build, which is what disables the button in the swipe window: a
  /// tap there would otherwise send the previous place's requests under the new place's name.
  func plan(for pageID: String) -> WeatherUpdatePlan {
    guard let build = builds[pageID] else { return .empty }
    let context = build.context
    return WeatherUpdatePlan.make(
      snapshot: build.snapshot,
      sourceState: context.sourceState,
      placeCountyUGC: context.placeCounty?.ugc,
      placeZoneUGC: context.placeZoneUGC,
      placeOffice: context.placeOffice,
      nearbyStation: context.nearbyStation,
      notAvailable: missingNotAvailable(in: context),
      coverageAlreadyAsked: hasAskedCoverage,
      tables: .shared,
      now: now)
  }

  /// Whether this phone has already asked what the bot covers on this visit, however that ended.
  /// One packet: a statement never goes stale, and a bot that did not answer must not be asked
  /// again on every tap (docs/MESHWX_UI.md §11.1).
  var hasAskedCoverage: Bool {
    outcomes[.coverage] != nil || inFlight.contains(.coverage)
      || pending.contains { $0.request == .coverage }
  }

  /// The same, for one station's own screen, from the page that screen was opened from.
  func updatePlan(forStation index: UInt16, in snapshot: WeatherScreenSnapshot) -> WeatherUpdatePlan {
    WeatherUpdatePlan.make(
      stationReading: snapshot.readings.first { $0.index == index },
      icao: MeshWXTables.shared.station(at: index)?.icao,
      now: now)
  }

  /// The requests one page's last run put on the air, and whether that run is still going. Both
  /// are per page: one place's requests never narrate another place's caption, and a page being
  /// swiped past does not spin because its neighbour is asking for something.
  func updateRequests(pageID: String) -> Set<WeatherRequest> {
    updateRuns.requests(pageID: pageID)
  }

  func isUpdating(pageID: String) -> Bool { updateRuns.isRunning(pageID: pageID) }

  /// What that page's Update control says about the run it started: the request on the air, else
  /// the last of that run's requests to settle. Nil once every outcome has aged out.
  func updateStatusText(pageID: String) -> String? {
    let requests = updateRequests(pageID: pageID)
    guard !requests.isEmpty else { return nil }
    if let limited = rateLimitedRequest, requests.contains(limited) { return statusText(for: limited) }
    let live = pending.first { requests.contains($0.request) }?.request
      ?? inFlight.first { requests.contains($0) }
    if let live { return statusText(for: live) }
    let settled = requests
      .compactMap { request in outcomes[request].map { (request: request, at: $0.at) } }
      .max { $0.at < $1.at }
    guard let settled, now.timeIntervalSince(settled.at) < WeatherRequestStatus.outcomeLifetime else { return nil }
    return statusText(for: settled.request)
  }

  /// One tap sends that page's plan, five seconds apart.
  func update(_ plan: WeatherUpdatePlan, pageID: String) {
    startUpdate(plan, pageID: pageID)
  }

  /// Pull-to-refresh: the same planner as the button, awaited so the pull's own spinner lasts as
  /// long as the run (docs/MESHWX_UI.md §11.1). With nothing to ask for it sends nothing, and the
  /// caption above the list says so.
  func refresh(pageID: String) async {
    await startUpdate(plan(for: pageID), pageID: pageID)?.value
  }

  /// The one Update run there is. A pull and a tap go through the same tracked task, so they can
  /// never run at once — and a run already going is never cancelled by the second one, whose
  /// `defer` would otherwise clear the live run's spinner.
  @discardableResult
  private func startUpdate(_ plan: WeatherUpdatePlan, pageID: String) -> Task<Void, Never>? {
    guard let holder, updateRuns.begin(pageID: pageID, requests: plan.requests) else { return nil }
    let task = Task { [weak self] in
      guard let self else { return }
      await runUpdate(plan, pageID: pageID)
    }
    holder.replace("update", with: task)
    return task
  }

  private func runUpdate(_ plan: WeatherUpdatePlan, pageID: String) async {
    defer { updateRuns.end(pageID: pageID) }
    for (offset, request) in plan.requests.enumerated() {
      if offset > 0 {
        // The service refuses a second request inside the window (spec §8.2, §13): the steps are
        // queued rather than fired together.
        try? await Task.sleep(for: .seconds(WeatherService.requestSpacing))
        guard !Task.isCancelled else { return }
      }
      await sendPlanned(request)
    }
  }

  /// A step refused inside the spacing waits it out once rather than being dropped: another
  /// request of the user's own can land between two steps.
  private func sendPlanned(_ request: WeatherRequest) async {
    await send(request, queued: true)
    guard rateLimitedRequest == request else { return }
    try? await Task.sleep(for: .seconds(WeatherService.requestSpacing))
    guard !Task.isCancelled, rateLimitedRequest == request else { return }
    await send(request, queued: true)
  }

  /// The state storm reports and rainfall ask for on one page: the page's own state, or the one
  /// the user picked **on that page**. An override is one place's answer to "which state", and
  /// carrying it across the pager sent `>storm TX` for a page in Puerto Rico.
  func reportState(for pageID: String) -> String? {
    reportStateOverrides[pageID] ?? builds[pageID]?.context.placeStateCode
  }

  func setReportState(_ code: String, forPageID pageID: String) {
    reportStateOverrides[pageID] = code
  }

  // MARK: - The alert map (§17), per page

  /// Every sweep the **page's own** radio has sent, resolved into one map
  /// (`WeatherAlertMapPicture`): for each state the newest sweep that covers it wins, and only
  /// that sweep's entries for that state are drawn.
  ///
  /// Per page id, like every other drill-in in this tool: a pushed screen reads the page it was
  /// opened from and never the model's current page (docs/MESHWX_UI.md §13, §3.1 U-18).
  ///
  /// Computed rather than cached. It is a sort and one pass over at most eight sweeps' entries —
  /// a few hundred runs — and a cache keyed on the sweeps would have to be written from `body`,
  /// which is the one place this model never mutates itself from.
  func areaPicture(forPageID pageID: String) -> WeatherAlertMapPicture {
    guard let build = builds[pageID], let state = build.context.sourceState else {
      return .empty
    }
    return WeatherAlertMapPicture.make(
      sweeps: state.areaSweeps, states: MeshWXTables.shared.states, now: now)
  }

  /// What the next map should cover, for the page asking: the choice this phone last made, else
  /// that page's own state, else the whole country.
  func areaSelection(forPageID pageID: String) -> WeatherAreaSelection {
    chosenAreas ?? .default(placeState: builds[pageID]?.context.placeStateCode)
  }

  /// Saved as it changes — there is nothing to commit, and the picker has no Done
  /// (docs/MESHWX_UI.md §3.1 U-37). Device-local: which states somebody looks at is a fact about
  /// this phone, not about a radio.
  func setAreaSelection(_ selection: WeatherAreaSelection) {
    chosenAreas = selection
    areaSelectionStore.selection = selection
  }

  /// "Ask for the 3 missing parts" for one part of the map, or nil while it is not offered
  /// (`WeatherPartsOffer`: incomplete, settled fifteen seconds, and inside the bot's ten-minute
  /// cache).
  ///
  /// The part is matched back to the assembly it was built from by `(group, built)`: the picture
  /// carries what a screen needs to *say*, and the offer's rules need the receipt times, which
  /// only the assembly has.
  func areaPartsOffer(
    forPageID pageID: String, part: WeatherAlertMapPicture.Part
  ) -> WeatherRequest? {
    guard let state = builds[pageID]?.context.sourceState else { return nil }
    guard let assembly = state.areaSweeps.first(where: {
      $0.group == part.group && $0.builtMinutes == UInt32(part.builtAt.timeIntervalSince1970 / 60)
    }) else { return nil }
    return WeatherPartsOffer.make(assembly: assembly, kind: .areaSweep, now: now)
  }

  /// What the map says about one area: the event shading it and when the part that shaded it was
  /// built. Nil for an area no part names.
  ///
  /// The picture is in part order — newest part first — and each part's entries are in severity
  /// order, so the first entry naming the area is the newest and most severe word there is, which
  /// is also the one the map drew.
  func areaOnMap(forPageID pageID: String, ugc: String) -> WeatherAreaMapWord? {
    let picture = areaPicture(forPageID: pageID)
    let states = MeshWXTables.shared.states
    for entry in picture.entries where entry.entry.ugcCodes(states: states).contains(ugc) {
      guard picture.parts.indices.contains(entry.part) else { continue }
      return WeatherAreaMapWord(event: entry.entry.event, asOf: picture.parts[entry.part].builtAt)
    }
    return nil
  }

  // MARK: - Channel traffic (§12)

  /// The traffic screen is on screen, so the log is worth keeping up with. Set by that screen on
  /// appear and cleared on disappear; the rows themselves are left alone, so pushing a bubble's
  /// detail and coming back does not blank the timeline.
  @ObservationIgnored var isShowingTraffic = false

  /// Reads the log the service keeps of every datagram on the weather slot and every request this
  /// phone sent (`WeatherService.trafficLog`). Oldest first, as the timeline reads.
  func refreshTraffic() async {
    await refreshTraffic(from: appState?.services?.weatherService)
  }

  private func refreshTraffic(from service: WeatherService?) async {
    guard let service else {
      traffic = []
      return
    }
    traffic = await service.trafficLog()
  }

  /// The screen's "Clear": what is in the log is a window on the channel and nothing else depends
  /// on it, so there is nothing to undo — and the weather the phone has stored is not touched.
  func clearTraffic() async {
    guard let service = appState?.services?.weatherService else { return }
    await service.clearTrafficLog()
    traffic = []
  }

  // MARK: - Bots

  func selectBot(_ botID: UInt16?) {
    preferredBotID = botID
    WeatherPreferenceStore().selectedBotID = botID
    scheduleRebuild()
  }

  // MARK: - Channel

  /// Writes `#meshwx` to the first free slot. Only from the banner's alert, after it closes, and
  /// only after the channel sync: before it, the app's table is empty and every slot looks free.
  /// The chosen slot is read back from the radio first; a slot the radio says is taken is refused.
  func addChannel() async {
    guard let appState, let services = appState.services, let device = appState.connectedDevice else { return }
    guard isChannelSyncDone else {
      errorMessage = L10n.Weather.Weather.Channel.notSynced
      return
    }
    isAddingChannel = true
    do {
      let channels = try await services.dataStore.fetchChannels(radioID: device.radioID)
      if WeatherChannel.existingSlot(in: channels) == nil {
        if let slot = WeatherChannel.freeSlot(in: channels, maxChannels: device.maxChannels) {
          if try await services.channelService.fetchChannel(index: slot) != nil {
            errorMessage = L10n.Weather.Weather.Channel.slotInUse(Int(slot))
          } else {
            try await services.channelService.setChannel(
              radioID: device.radioID, index: slot, name: WeatherChannel.name, passphrase: WeatherChannel.name)
          }
        } else {
          errorMessage = L10n.Weather.Weather.Channel.full
        }
      }
    } catch {
      errorMessage = error.userFacingMessage
    }
    isAddingChannel = false
    cachedChannels = nil
    scheduleRebuild()
  }

  // MARK: - Clear

  /// Forgets everything held for a bot, named when the confirmation was presented.
  func clearReceivedWeather(botID: UInt16) async {
    if let service = appState?.services?.weatherService {
      await service.clearState(for: botID)
    } else {
      do {
        // The one shared store, in one atomic step: the service writes the same file.
        try await FileWeatherStateStore.default().modify { states in
          _ = states.removeValue(forKey: botID)
        }
      } catch {
        Self.logger.error("Clearing weather failed: \(error.localizedDescription)")
      }
      cachedOfflineStates = nil
      // A radio that connected while the file was being written has loaded the old file.
      if let service = appState?.services?.weatherService {
        await service.clearState(for: botID)
      }
    }
    outcomes.removeAll()
    answerNotes.removeAll()
    scheduleRebuild()
  }
}
