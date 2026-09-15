import CoreLocation
import Foundation
import MC1Services
import MeshWX
import OSLog
import SwiftUI

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

/// What the place picker asked for, applied once its sheet has gone.
enum WeatherPlacePickerAction: Equatable {
  case place(WeatherPlace)
  case currentLocation
}

/// The Weather tool's model: gathers the inputs, builds one `WeatherScreenSnapshot` off the main
/// actor on defined triggers, and holds what the service does not — the place, request outcomes,
/// and the transient notices.
///
/// Owned by `WeatherModelStore` for the visit. `init` allocates nothing; `attach` and `appear`
/// start the work, idempotently.
@Observable
@MainActor
final class WeatherToolModel {
  // MARK: - Published

  private(set) var snapshot: WeatherScreenSnapshot?
  private(set) var context = WeatherScreenContext()
  private(set) var placeState: WeatherPlaceState = .needsPermission
  private(set) var searchedPlace: WeatherPlace?
  /// Requests on the air, as the service's events report them. Builds never write this.
  private(set) var pending: [WeatherPendingRequest] = []
  /// Requests between the tap and the service's answer to `send`, so a second tap in that window
  /// finds the button already disabled.
  private(set) var inFlight: Set<WeatherRequest> = []
  private(set) var outcomes: [WeatherRequest: WeatherSettledOutcome] = [:]
  private(set) var answerNotes: [WeatherRequest: WeatherAnswerNote] = [:]
  /// The request refused inside the five-second spacing, while its notice shows.
  private(set) var rateLimitedRequest: WeatherRequest?
  private(set) var preferredBotID: UInt16?
  private(set) var isAddingChannel = false
  /// The connect-time channel sync has finished for the connected radio. Until then the app's
  /// channel table may be empty, and "#meshwx isn't set up" would be a guess.
  private(set) var isChannelSyncDone = false
  private(set) var now = Date(timeIntervalSince1970: 0)
  var errorMessage: String?
  /// The state storm reports and rainfall ask for, when the user changed it this visit.
  var reportStateOverride: String?
  /// A pick from the place picker, applied when its sheet has closed.
  var pendingPlaceAction: WeatherPlacePickerAction?

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
  @ObservationIgnored private var latestSample: WeatherLocationSample?
  @ObservationIgnored private var locatingUntil: Date?
  @ObservationIgnored private var isSceneActive = true
  @ObservationIgnored private var isRebuildScheduled = false
  @ObservationIgnored private var isBuilding = false
  @ObservationIgnored private var needsAnotherBuild = false
  @ObservationIgnored private var hasRequestedGeometry = false
  @ObservationIgnored private(set) var fingerprints: [WeatherRequest: Fingerprint] = [:]

  // Caches, so the 30-second rebuild reads no database, no disk and no 35,000-place table.
  @ObservationIgnored private var cachedContacts: [ContactDTO]?
  @ObservationIgnored private var cachedChannels: [ChannelDTO]?
  @ObservationIgnored private var cachedOfflineStates: [UInt16: WeatherBotState]?
  @ObservationIgnored private var cachedRadioID: UUID?
  @ObservationIgnored private var placeFacts: WeatherPlaceFacts?
  @ObservationIgnored private var stationTowns: [UInt16: String] = [:]

  private static let logger = Logger(subsystem: "com.mc1", category: "WeatherToolModel")
  static let debounce: Duration = .milliseconds(150)
  static let tick: Duration = .seconds(30)
  static let locatingWindow: TimeInterval = 5
  /// A fix older than this is refreshed on "Back to my location".
  static let staleFixAge: TimeInterval = 5 * 60

  // MARK: - Derived

  var sourceName: String {
    guard let source = snapshot?.source else { return L10n.Weather.Weather.Bot.generic }
    return WeatherFormatting.botName(botID: source.botID, bot: source.bot)
  }

  func botName(_ botID: UInt16) -> String {
    WeatherFormatting.botName(botID: botID, bot: context.bots.first { $0.botID == botID })
  }

  /// The place's short name, "Austin".
  var placeName: String? {
    snapshot?.place.map { WeatherFormatting.shortPlaceName($0.label) }
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

  /// A complete reply to this very request, owned by this phone and under five minutes old: the
  /// bot would only send its cached copy, so the answer stands in for the button.
  func freshOwnedReply(for request: WeatherRequest) -> WeatherTextItem? {
    guard case .text = request.expectedReply else { return nil }
    return snapshot?.texts.first { Self.isFreshOwnedReply($0.assembly, for: request, now: now) }
  }

  nonisolated static func isFreshOwnedReply(_ assembly: WeatherTextAssembly, for request: WeatherRequest, now: Date) -> Bool {
    assembly.request == request && assembly.isComplete
      && now.timeIntervalSince(assembly.lastReceivedAt) < WeatherService.cacheWindow
  }

  // MARK: - Lifecycle

  /// Binds to the current services. Called from `.task(id: servicesVersion)`: safe to repeat,
  /// and never undone by a disappearance.
  func attach(appState: AppState) async {
    start(appState)
    let services = appState.services
    let identity = services.map(ObjectIdentifier.init)
    if !hasSubscribed || identity != subscribedServices {
      hasSubscribed = true
      subscribedServices = identity
      cachedContacts = nil
      cachedChannels = nil
      cachedOfflineStates = nil
      subscribe(to: services?.weatherService)
      pending = await services?.weatherService.pendingRequests() ?? []
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
    updatePlaceState()
    scheduleRebuild()
  }

  private func start(_ appState: AppState) {
    self.appState = appState
    guard holder == nil else { return }
    holder = WeatherTaskHolder()
    preferredBotID = WeatherPreferenceStore().selectedBotID
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
  }

  /// No tick while the scene is inactive; a refresh as soon as it is active again.
  func scenePhaseChanged(_ phase: ScenePhase) {
    guard holder != nil else { return }
    let active = phase == .active
    guard active != isSceneActive else { return }
    isSceneActive = active
    if active {
      now = Date()
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
    switch event {
    case .stateLoaded, .received:
      scheduleRebuild()
    case let .requestSent(entry):
      pending.removeAll { $0.id == entry.id }
      pending.append(entry)
      pending = await service.pendingRequests()
    case let .requestSettled(request, outcome):
      now = Date()
      pending.removeAll { $0.id == request.id }
      outcomes[request.request] = WeatherSettledOutcome(outcome: outcome, at: now)
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

  private func rebuild() async {
    isRebuildScheduled = false
    guard let appState else { return }
    isBuilding = true
    let request = buildRequest(appState)
    let result = await Task.detached(priority: .userInitiated) {
      await WeatherScreenBuilder.build(request)
    }.value
    isBuilding = false
    apply(result, for: request)
    if needsAnotherBuild {
      needsAnotherBuild = false
      scheduleRebuild()
    }
  }

  private func buildRequest(_ appState: AppState) -> WeatherBuildRequest {
    let services = appState.services
    let device = appState.connectedDevice
    let radioID = device?.radioID ?? appState.currentRadioID
    if radioID != cachedRadioID {
      cachedRadioID = radioID
      cachedContacts = nil
      cachedChannels = nil
    }
    let place: WeatherBuildRequest.PlaceInput = if let searchedPlace {
      .searched(searchedPlace)
    } else if let placeSample {
      .location(placeSample)
    } else {
      .none
    }
    return WeatherBuildRequest(
      weatherService: services?.weatherService,
      contactService: services?.contactService,
      dataStore: services?.dataStore ?? appState.offlineDataStore,
      radioID: radioID,
      preferredBotID: preferredBotID,
      place: place,
      isRadioConnected: services != nil,
      isChannelSyncDone: isChannelSyncDone,
      firmwareSupportsWeather: device?.supportsChannelDatagrams,
      firmwareVersion: device?.firmwareVersionString ?? "",
      now: Date(),
      calendar: .autoupdatingCurrent,
      contacts: cachedContacts,
      channels: cachedChannels,
      offlineStates: services == nil ? cachedOfflineStates : nil,
      placeFacts: placeFacts,
      stationTowns: stationTowns)
  }

  private func apply(_ result: WeatherBuildResult, for request: WeatherBuildRequest) {
    snapshot = result.snapshot
    context = result.context
    now = result.snapshot.now
    if request.radioID == cachedRadioID {
      cachedContacts = result.contacts
      cachedChannels = result.channels
    }
    if request.weatherService == nil, appState?.services == nil {
      cachedOfflineStates = result.offlineStates
    }
    placeFacts = result.placeFacts
    stationTowns = result.stationTowns
    updatePlaceState()

    if result.context.needsGeometry, !hasRequestedGeometry {
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

  /// A town from the picker, for this visit only.
  func pick(_ place: WeatherPlace) {
    searchedPlace = place
    endLocating()
    scheduleRebuild()
  }

  /// Back to the phone's location; a stale fix is refreshed, with "Locating…" meanwhile.
  func backToMyLocation() {
    guard let appState else { return }
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
    case let .place(place):
      pick(place)
      return false
    case .currentLocation:
      guard isLocationAuthorized else { return true }
      backToMyLocation()
      return false
    }
  }

  /// The one path that may ask for location permission: the user's tap.
  func useMyLocation() async {
    guard let appState else { return }
    let location = appState.locationService
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
    var effective = pending
    for sending in inFlight where !pending.contains(where: { $0.request == sending }) {
      effective.append(WeatherPendingRequest(request: sending, botID: 0, botPublicKey: Data(), sentAt: now))
    }
    return WeatherRequestStatus.resolve(
      request: request, block: snapshot?.requestBlock ?? .noBot, pending: effective, outcomes: outcomes, now: now)
  }

  func statusText(for request: WeatherRequest) -> String? {
    if rateLimitedRequest == request { return L10n.Weather.Weather.Request.rateLimited }
    return WeatherCopy.requestStatus(
      status(for: request), source: sourceName, request: request, answer: answerNotes[request],
      now: now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
  }

  func send(_ request: WeatherRequest) async {
    guard let service = appState?.services?.weatherService, let bot = snapshot?.source?.bot else { return }
    switch status(for: request) {
    case .idle, .settled: break
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
      let newest = states.values.flatMap { $0.observations.values.filter { $0.batchSize > 1 }.map(\.timestampMinutes) }.max()
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
  func alertsRequest(for status: WeatherAlertStatus) -> WeatherRequest {
    guard case .missedMessages = status, let source = context.sourceState else { return .digest }
    return WeatherAlertRequests.missedMessages(
      source: source, placeCountyUGC: context.placeCounty?.ugc, tables: .shared)
  }

  /// The warnings the source bot's alert list named that never arrived.
  var missingWarnings: [MeshWXWarningIdentity] {
    context.sourceState?.missingFromDigest ?? []
  }

  /// The one request for them ("Listed, not received · Ask").
  var missingWarningsRequest: WeatherRequest? {
    context.sourceState.flatMap {
      WeatherAlertRequests.missingWarnings(source: $0, placeCountyUGC: context.placeCounty?.ugc, tables: .shared)
    }
  }

  /// A stale primary from the bot's batch asks for the batch; one from a single-station answer
  /// asks for that station.
  static func observationsRequest(for reading: WeatherStationReading) -> WeatherRequest {
    reading.isInFootprint ? .observations : .observation(station: reading.station.icao)
  }

  var reportState: String? {
    reportStateOverride ?? context.placeStateCode
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
