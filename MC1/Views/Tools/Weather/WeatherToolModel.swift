import CoreLocation
import Foundation
import MC1Services
import MeshWX
import OSLog

/// The Weather tool's view model: a main-actor mirror of `WeatherService` for the bot the
/// user is looking at, plus the three things the service does not know — which radio is
/// connected, which contacts are bots, and whether `#meshwx` is on the radio.
///
/// View-owned (`@State`) and re-attached on every services change, like the other tool
/// models. The service keeps ingesting whether or not this screen exists; this only reads.
@Observable
@MainActor
final class WeatherToolModel {
  // MARK: - Radio

  /// What stands between the user and weather data, in the order it is checked.
  enum RadioStatus: Equatable {
    case disconnected
    /// The radio's firmware predates channel datagrams (MeshCore v1.15). It never delivers
    /// them, silently, so the tool says so rather than showing an empty screen.
    case firmwareTooOld(version: String)
    /// `#meshwx` is not on the radio. `canAdd` is false when every slot is taken.
    case channelMissing(canAdd: Bool)
    case ready(channelIndex: UInt8)

    var isReady: Bool {
      if case .ready = self { return true }
      return false
    }
  }

  private(set) var radioStatus: RadioStatus = .disconnected
  private(set) var isChannelPromptDismissed = false
  private(set) var isAddingChannel = false
  var channelError: String?

  // MARK: - Bots

  /// Every `WX-` contact the radio knows, nearest first.
  private(set) var bots: [WeatherBot] = []
  /// Bot IDs heard on the channel whose advert the radio never collected: state exists, a
  /// name does not.
  private(set) var heardOnlyBotIDs: [UInt16] = []
  private var pickedBotID: UInt16?

  /// The bot the screen is showing, as the wire names it: the user's pick while it still
  /// resolves, else the nearest advertised bot, else one heard on the channel.
  ///
  /// A bot is audible long before its advert is collected, and every message carries only the
  /// id — so selecting by id rather than by contact is what lets the tool show that bot's
  /// warnings instead of an empty screen.
  var selectedBotID: UInt16? {
    if let pickedBotID,
       bots.contains(where: { $0.botID == pickedBotID }) || heardOnlyBotIDs.contains(pickedBotID) {
      return pickedBotID
    }
    return bots.first?.botID ?? heardOnlyBotIDs.first
  }

  /// The contact behind ``selectedBotID``, or nil for a heard-only bot — which is the
  /// difference between reading what it sent and being able to ask it anything.
  var selectedBot: WeatherBot? {
    guard let selectedBotID else { return nil }
    return bots.first { $0.botID == selectedBotID }
  }

  /// What to call the selected bot in a header.
  var selectedBotName: String {
    if let selectedBot { return selectedBot.name }
    guard let selectedBotID else { return "" }
    return L10n.Weather.Weather.Bot.heardOnlyName(Self.hexID(selectedBotID))
  }

  /// The id as the bot writes it in its own name: four uppercase hex digits.
  static func hexID(_ botID: UInt16) -> String {
    String(format: "%04X", botID)
  }

  // MARK: - State

  private(set) var states: [UInt16: WeatherBotState] = [:]
  private(set) var pendingRequests: [WeatherPendingRequest] = []
  private(set) var lastOutcome: (request: WeatherPendingRequest, outcome: WeatherRequestOutcome)?
  /// The last request sent for each text subject, by wire code. A text reply names its subject
  /// and nothing else, so this is what "ask again" for a missing chunk of `>storm TX` re-sends.
  private(set) var lastTextRequests: [UInt8: WeatherRequest] = [:]

  enum RequestFailure: Equatable {
    case rateLimited(seconds: Int)
    case transport(String)
    case noBot
  }

  var requestFailure: RequestFailure?

  /// The clock the countdowns and stale badges read. Ticks every 30 s while attached, so a
  /// "expires in 12 min" row does not sit at 12 all afternoon.
  private(set) var now = Date()

  /// The bundle tables. The first touch loads them (a few hundred milliseconds for the 1.4 MB
  /// places file); `attach` warms them off the main actor so the first screen does not pay.
  var tables: MeshWXTables { MeshWXTables.shared }

  var botState: WeatherBotState? {
    selectedBotID.flatMap { states[$0] }
  }

  // MARK: - Derived, for the selected bot

  var activeWarnings: [WeatherStoredWarning] {
    guard let botState else { return [] }
    let tables = tables
    return botState.activeWarnings(at: now) { tables.severity(for: $0) }
  }

  /// Latest reading per station, nearest to the reference location first, then by ICAO.
  var observations: [WeatherStoredObservation] {
    guard let botState else { return [] }
    let tables = tables
    let reference = referenceLocation
    return botState.observations.values.sorted { lhs, rhs in
      if let reference,
         let l = tables.station(at: lhs.observation.stationIndex),
         let r = tables.station(at: rhs.observation.stationIndex) {
        let ld = MeshWXGeo.distanceKilometres(fromLat: reference.latitude, lon: reference.longitude, toLat: l.lat, lon: l.lon)
        let rd = MeshWXGeo.distanceKilometres(fromLat: reference.latitude, lon: reference.longitude, toLat: r.lat, lon: r.lon)
        if ld != rd { return ld < rd }
      }
      return lhs.observation.stationIndex < rhs.observation.stationIndex
    }
  }

  /// Most recently received first, so the answer to the last request is on top.
  var forecasts: [WeatherStoredForecast] {
    botState?.forecasts.values.sorted { $0.receivedAt > $1.receivedAt } ?? []
  }

  /// Most recently touched first.
  var texts: [WeatherTextAssembly] {
    botState?.texts.values.sorted { $0.lastReceivedAt > $1.lastReceivedAt } ?? []
  }

  var isFeedStale: Bool { botState?.digest?.isFeedStale ?? false }
  var needsDigest: Bool { botState?.needsDigest ?? false }
  var lastHeardAt: Date? { botState?.lastHeardAt }
  var missingFromDigest: [MeshWXWarningIdentity] { botState?.missingFromDigest ?? [] }

  /// Whether a request can go out right now: a ready radio and a bot to send to.
  var canSendRequests: Bool {
    radioStatus.isReady && selectedBot != nil
  }

  var hasPendingRequest: Bool { !pendingRequests.isEmpty }

  // MARK: - Dependencies

  private var services: ServiceContainer?
  private var device: DeviceDTO?
  private var referenceLocation: CLLocationCoordinate2D?
  private var eventsTask: Task<Void, Never>?
  private var tickTask: Task<Void, Never>?
  private let preferences = WeatherPreferenceStore()
  private let logger = Logger(subsystem: "com.mc1", category: "WeatherToolModel")

  // MARK: - Lifecycle

  /// Binds to a connection (or to none: state still shows from disk). Safe to call again
  /// for the same services.
  func attach(
    services: ServiceContainer?,
    device: DeviceDTO?,
    location: CLLocationCoordinate2D?
  ) async {
    self.services = services
    self.device = device
    referenceLocation = location
    pickedBotID = preferences.selectedBotID
    if let device {
      isChannelPromptDismissed = preferences.isChannelPromptDismissed(deviceID: device.id)
    }

    // Warm the tables where the first-touch cost is invisible.
    Task.detached(priority: .utility) { _ = MeshWXTables.shared }

    startTicking()
    subscribeToEvents()
    await refreshRadioStatus()
    await refreshBots()
    await refreshStates()
  }

  func detach() {
    eventsTask?.cancel()
    eventsTask = nil
    tickTask?.cancel()
    tickTask = nil
    services = nil
    device = nil
    radioStatus = .disconnected
    pendingRequests = []
  }

  private func startTicking() {
    tickTask?.cancel()
    now = Date()
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        guard !Task.isCancelled else { return }
        self?.now = Date()
      }
    }
  }

  private func subscribeToEvents() {
    eventsTask?.cancel()
    guard let services else { return }
    let events = services.weatherService.events()
    eventsTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case .stateLoaded, .received:
          await refreshStates()
        case .requestSent:
          pendingRequests = await services.weatherService.pendingRequests()
        case let .requestSettled(request, outcome):
          lastOutcome = (request, outcome)
          pendingRequests = await services.weatherService.pendingRequests()
          if outcome == .answered || outcome == .servedFromCache {
            await refreshStates()
          }
        }
      }
    }
  }

  // MARK: - Refresh

  func refreshStates() async {
    guard let services else {
      // No connection: read the shared file directly so the last-known picture still shows.
      states = (try? await FileWeatherStateStore.default().load()) ?? [:]
      updateHeardOnlyBots()
      return
    }
    states = await services.weatherService.allStates()
    pendingRequests = await services.weatherService.pendingRequests()
    updateHeardOnlyBots()
  }

  /// Re-reads the contact list for bots; call when contacts change.
  func refreshBots() async {
    guard let services, let device else {
      bots = []
      updateHeardOnlyBots()
      return
    }
    do {
      let contacts = try await services.contactService.getContacts(radioID: device.radioID)
      let near = referenceLocation.map { (latitude: $0.latitude, longitude: $0.longitude) }
      bots = WeatherBot.bots(from: contacts, near: near)
    } catch {
      logger.error("Bot lookup failed: \(error.localizedDescription)")
      bots = []
    }
    updateHeardOnlyBots()
  }

  private func updateHeardOnlyBots() {
    let known = Set(bots.map(\.botID))
    heardOnlyBotIDs = states.keys.filter { !known.contains($0) }.sorted()
  }

  func refreshRadioStatus() async {
    guard let services, let device else {
      radioStatus = .disconnected
      return
    }
    guard device.supportsChannelDatagrams else {
      radioStatus = .firmwareTooOld(version: device.firmwareVersionString)
      return
    }
    do {
      let channels = try await services.dataStore.fetchChannels(radioID: device.radioID)
      if let slot = WeatherChannel.existingSlot(in: channels) {
        radioStatus = .ready(channelIndex: slot)
      } else {
        let canAdd = WeatherChannel.freeSlot(in: channels, maxChannels: device.maxChannels) != nil
        radioStatus = .channelMissing(canAdd: canAdd)
      }
    } catch {
      logger.error("Channel lookup failed: \(error.localizedDescription)")
      radioStatus = .channelMissing(canAdd: false)
    }
  }

  // MARK: - Actions

  func select(bot: WeatherBot?) {
    select(botID: bot?.botID)
  }

  /// Picks by wire id, so a bot heard on the channel but never advertised is selectable too.
  func select(botID: UInt16?) {
    pickedBotID = botID
    preferences.selectedBotID = botID
    requestFailure = nil
    lastOutcome = nil
  }

  /// Writes `#meshwx` to the first free slot. Only ever called from the prompt's button
  /// (docs/MESHWX.md: prompted, never silent).
  func addChannel() async {
    guard let services, let device, case .channelMissing(true) = radioStatus else { return }
    isAddingChannel = true
    defer { isAddingChannel = false }
    channelError = nil
    do {
      let channels = try await services.dataStore.fetchChannels(radioID: device.radioID)
      guard let slot = WeatherChannel.freeSlot(in: channels, maxChannels: device.maxChannels) else {
        radioStatus = .channelMissing(canAdd: false)
        return
      }
      try await services.channelService.setChannel(
        radioID: device.radioID,
        index: slot,
        name: WeatherChannel.name,
        passphrase: WeatherChannel.name
      )
      radioStatus = .ready(channelIndex: slot)
    } catch {
      channelError = error.userFacingMessage
    }
  }

  func dismissChannelPrompt() {
    isChannelPromptDismissed = true
    if let device {
      preferences.setChannelPromptDismissed(true, deviceID: device.id)
    }
  }

  func send(_ request: WeatherRequest) async {
    requestFailure = nil
    guard let services, let bot = selectedBot else {
      requestFailure = .noBot
      return
    }
    if case let .text(subject) = request.expectedReply {
      // A reply arrives as a subject and a group, never as an echo of the request, so the
      // only way to ask again for a missing chunk of "storm TX" is to remember the argument.
      lastTextRequests[subject] = request
    }
    do {
      _ = try await services.weatherService.send(request, to: bot)
    } catch let error as WeatherRequestError {
      switch error {
      case let .rateLimited(retryAfter):
        requestFailure = .rateLimited(seconds: Int(retryAfter.rounded(.up)))
      case let .transport(message):
        requestFailure = .transport(message)
      }
    } catch {
      requestFailure = .transport(error.localizedDescription)
    }
    pendingRequests = await services.weatherService.pendingRequests()
  }

  func clearSelectedBotState() async {
    guard let services, let botID = selectedBotID else { return }
    await services.weatherService.clearState(for: botID)
    lastTextRequests = [:]
    await refreshStates()
  }

  /// Drops the banner the last request left behind, once the screen has shown it long enough.
  func clearLastOutcome() {
    lastOutcome = nil
  }

  // MARK: - Identities

  /// The `event.office.etn` form a request names a warning by (`SV.W.EWX.42`), or nil when
  /// the bundle has no code for the event or office.
  func identityString(_ identity: MeshWXWarningIdentity) -> String? {
    guard let vtec = tables.vtec(for: identity.event),
          let office = tables.officeCode(identity.office) else { return nil }
    return "\(vtec).\(office).\(identity.etn)"
  }
}
