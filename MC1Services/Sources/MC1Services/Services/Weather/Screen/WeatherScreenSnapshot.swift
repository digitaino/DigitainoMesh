import Foundation
import MeshWX

/// Why nothing can be asked of a bot right now. Shown in place of a request button, so a tap is
/// never a wait for an answer that cannot come (docs/MESHWX_UI.md §3 A2, §11).
public enum WeatherRequestBlock: Sendable, Hashable {
  case radioOffline
  case firmwareTooOld
  case channelMissing
  case noBot
  /// A bot heard on the channel whose advert the radio has not collected: its key, which a DM
  /// needs, is unknown.
  case botNotAnnounced
}

/// A request's state as any button for it shows it (docs/MESHWX_UI.md §11).
public enum WeatherRequestStatus: Sendable, Hashable {
  case idle
  case blocked(WeatherRequestBlock)
  case pending(attempt: Int, sentAt: Date)
  /// Another request is on the air; one at a time (spec §13).
  case waitingForOther
  case settled(WeatherRequestOutcome, at: Date)

  /// How long an outcome stays under its button.
  public static let outcomeLifetime: TimeInterval = 5 * 60

  public static func resolve(
    request: WeatherRequest,
    block: WeatherRequestBlock?,
    pending: [WeatherPendingRequest],
    outcomes: [WeatherRequest: WeatherSettledOutcome],
    now: Date
  ) -> WeatherRequestStatus {
    if let mine = pending.first(where: { $0.request == request }) {
      return .pending(attempt: mine.attempt, sentAt: mine.sentAt)
    }
    if let block { return .blocked(block) }
    if !pending.isEmpty { return .waitingForOther }
    if let settled = outcomes[request], now.timeIntervalSince(settled.at) < outcomeLifetime {
      return .settled(settled.outcome, at: settled.at)
    }
    return .idle
  }
}

/// A request's last outcome and when it came.
public struct WeatherSettledOutcome: Sendable, Hashable {
  public var outcome: WeatherRequestOutcome
  public var at: Date

  public init(outcome: WeatherRequestOutcome, at: Date) {
    self.outcome = outcome
    self.at = at
  }
}

/// A text reply held from some bot, and whether this phone asked for it.
public struct WeatherTextItem: Sendable, Hashable, Identifiable {
  public var botID: UInt16
  public var assembly: WeatherTextAssembly

  /// Answered this phone's request. Otherwise somebody else on the channel asked, and the
  /// subject is all that is known about what they asked for.
  public var isOwn: Bool { assembly.request != nil }
  public var id: String { "\(botID)-\(assembly.group)" }
}

/// Which page a snapshot was built for (docs/MESHWX_UI.md §4, §13).
///
/// The tool is a pager of places, and one snapshot at a time means "the snapshot" is whichever
/// page was built last: that is how a forecast discussion opened from Round Rock came back naming
/// Austin's office. The page travels *inside* the value instead, so a screen reached from a page
/// is handed that page's own build and every claim it makes is about that place.
public struct WeatherPageKey: Sendable, Hashable {
  /// `WeatherPage.id`: "here" for My location, the saved place's id for a saved one.
  public var pageID: String
  /// The place the page answers for, once it has one.
  public var place: WeatherPlace?

  public init(pageID: String = WeatherPage.myLocationID, place: WeatherPlace? = nil) {
    self.pageID = pageID
    self.place = place
  }
}

/// Everything the Weather screen shows for **one page**, computed in one pass from the service's
/// state and the phone's situation. Views read this and nothing else (docs/MESHWX_UI.md §13).
public struct WeatherScreenSnapshot: Sendable {
  public enum Banner: Sendable, Hashable {
    case firmwareTooOld(version: String)
    case channelMissing
    case noBotHeard
  }

  /// The bot requests go to and the screen names.
  public struct Source: Sendable, Hashable {
    public var botID: UInt16
    /// Nil for a bot heard on the channel without an advert.
    public var bot: WeatherBot?
    public var lastHeardAt: Date?
    /// The last message heard live, not drained from the radio's queue (`WeatherBotState`).
    public var lastLiveHeardAt: Date?
  }

  public struct Inputs: Sendable {
    public var states: [UInt16: WeatherBotState]
    public var bots: [WeatherBot]
    public var preferredBotID: UInt16?
    public var place: WeatherPlace?
    /// The page this build answers for. Stamped into the snapshot, so nothing downstream has to
    /// be told separately which place it is looking at.
    public var pageID: String
    public var isRadioConnected: Bool
    /// A link the weather transport provides of its own (`WeatherTransportLink`): the DEBUG
    /// bridge to a real bot, which is a live connection without any radio. When there is one,
    /// the radio reads as connected here and the link's bot as announced, whatever the phone's
    /// Bluetooth is doing. Nil over a radio, which is every build that is not a bridged one.
    public var transportLink: WeatherTransportLink?
    /// Nil when no radio has ever been seen, so no firmware claim can be made.
    public var firmwareSupportsWeather: Bool?
    public var firmwareVersion: String
    public var hasWeatherChannel: Bool
    public var session: WeatherSessionInfo
    public var now: Date
    public var calendar: Calendar

    public init(
      states: [UInt16: WeatherBotState],
      bots: [WeatherBot],
      preferredBotID: UInt16?,
      place: WeatherPlace?,
      pageID: String = WeatherPage.myLocationID,
      isRadioConnected: Bool,
      transportLink: WeatherTransportLink? = nil,
      firmwareSupportsWeather: Bool?,
      firmwareVersion: String,
      hasWeatherChannel: Bool,
      session: WeatherSessionInfo,
      now: Date,
      calendar: Calendar
    ) {
      self.states = states
      self.bots = bots
      self.preferredBotID = preferredBotID
      self.place = place
      self.pageID = pageID
      self.isRadioConnected = isRadioConnected
      self.transportLink = transportLink
      self.firmwareSupportsWeather = firmwareSupportsWeather
      self.firmwareVersion = firmwareVersion
      self.hasWeatherChannel = hasWeatherChannel
      self.session = session
      self.now = now
      self.calendar = calendar
    }
  }

  /// The page this snapshot was built for, and the place it answers for. Every screen reached
  /// from a page is handed the page's own snapshot, so nothing has to ask the model which place
  /// is on screen — and a swipe cannot change the answer under a pushed screen.
  public var page: WeatherPageKey
  public var place: WeatherPlace?
  public var banner: Banner?
  public var source: Source?
  /// Every bot the screen knows of, for the About sheet: advertised ones and heard-only ids.
  public var knownBotIDs: [UInt16]
  public var coverage: WeatherCoverage
  public var alerts: [WeatherAlertItem]
  public var alertStatus: WeatherAlertStatus
  public var readings: [WeatherStationReading]
  public var primaryStation: WeatherPrimaryStation
  public var forecast: WeatherForecastCard
  public var otherPlaces: [WeatherOtherPlace]
  public var texts: [WeatherTextItem]
  /// What the channel carried recently, newest first, and everything this phone is holding from
  /// it. Both are for the weather radio's own page (docs/MESHWX_UI.md §12); neither says who
  /// asked, which the phone does not record.
  public var heard: [WeatherHeardItem]
  public var cache: WeatherCache
  public var requestBlock: WeatherRequestBlock?
  /// Set when the source bot has not been heard live for 90 minutes: it may not answer. A
  /// backlog drained at connect is stamped with the drain time and does not count.
  public var sourceQuietSince: Date?
  public var now: Date

  public static let quietAfter: TimeInterval = 90 * 60

  public static func make(
    _ inputs: Inputs,
    geometry: any WeatherAreaGeometry,
    tables: MeshWXTables
  ) -> WeatherScreenSnapshot {
    var inputs = inputs
    // A transport with a link of its own is the connection: the DEBUG bridge talks to one real
    // bot over HTTP, so requests are not blocked on this phone's Bluetooth and the bot it names
    // is announced although no advert of its ever reached the radio. Over a radio the link is
    // nil and none of this runs.
    if let link = inputs.transportLink {
      inputs.isRadioConnected = true
      // The firmware claim is about **the transport that carries the request**, and over a bridge
      // that is not the radio: a phone paired with an old radio (the simulator's mock is firmware
      // 8) had Update disabled with "Your radio's firmware can't ask for weather" while the bridge
      // beside it was answering (docs/MESHWX_UI.md §3.1 U-20).
      inputs.firmwareSupportsWeather = true
      inputs.bots = link.announcing(inputs.bots)
    }
    let now = inputs.now
    let coverage = WeatherCoverage.make(states: inputs.states, tables: tables, now: now)
    let source = pickSource(inputs, coverage: coverage)

    let banner: Banner?
    if inputs.firmwareSupportsWeather == false {
      banner = .firmwareTooOld(version: inputs.firmwareVersion)
    } else if inputs.isRadioConnected, !inputs.hasWeatherChannel, inputs.session.lastChannelDatagramAt == nil {
      banner = .channelMissing
    } else if source == nil {
      banner = .noBotHeard
    } else {
      banner = nil
    }

    let requestBlock: WeatherRequestBlock?
    if !inputs.isRadioConnected {
      requestBlock = .radioOffline
    } else if banner == .firmwareTooOld(version: inputs.firmwareVersion) {
      requestBlock = .firmwareTooOld
    } else if banner == .channelMissing {
      requestBlock = .channelMissing
    } else if let source {
      requestBlock = source.bot == nil ? .botNotAnnounced : nil
    } else {
      requestBlock = .noBot
    }

    let alerts = WeatherAlertItems.make(
      states: inputs.states, place: inputs.place, geometry: geometry, tables: tables, now: now)
    let readings = WeatherStations.readings(
      states: inputs.states, coverage: coverage, place: inputs.place, tables: tables, now: now)
    let primaryStation = WeatherPrimaryStation.pick(readings: readings, place: inputs.place)
    let forecast = WeatherForecastCard.make(
      states: inputs.states, place: inputs.place, tables: tables, now: now, calendar: inputs.calendar)
    let placePoint: UInt16? = switch forecast {
    case let .forecast(summary): summary.point.index
    case let .missing(point, _): point.index
    case .noPlace, .noPointNearby: nil
    }

    let texts = inputs.states.flatMap { botID, state in
      state.texts.values.map { WeatherTextItem(botID: botID, assembly: $0) }
    }.sorted { $0.assembly.lastReceivedAt > $1.assembly.lastReceivedAt }

    var known = Set(inputs.states.keys)
    known.formUnion(inputs.bots.map(\.botID))

    return WeatherScreenSnapshot(
      page: WeatherPageKey(pageID: inputs.pageID, place: inputs.place),
      place: inputs.place,
      banner: banner,
      source: source,
      knownBotIDs: known.sorted(),
      coverage: coverage,
      alerts: alerts,
      alertStatus: WeatherAlertStatus.evaluate(
        place: inputs.place, coverage: coverage, states: inputs.states, items: alerts,
        isRadioConnected: inputs.isRadioConnected, sessionStartedAt: inputs.session.startedAt,
        tables: tables, now: now),
      // The station the Now card names leads the list its own link opens.
      readings: WeatherStations.ordered(readings, leading: primaryStation.index),
      primaryStation: primaryStation,
      forecast: forecast,
      otherPlaces: WeatherOtherPlace.make(states: inputs.states, excludingPoint: placePoint, tables: tables, now: now),
      texts: texts,
      heard: WeatherHeard.make(states: inputs.states, now: now),
      cache: WeatherCache.make(states: inputs.states, readings: readings, alerts: alerts, tables: tables),
      requestBlock: requestBlock,
      sourceQuietSince: source.flatMap { source in
        guard let heard = source.lastLiveHeardAt, now.timeIntervalSince(heard) > quietAfter else { return nil }
        return heard
      },
      now: now
    )
  }

  /// The user's pick; else an advertised bot that covers the place; else the advertised bot
  /// heard most recently; else any advertised bot; else the heard-only bot heard most recently.
  static func pickSource(_ inputs: Inputs, coverage: WeatherCoverage) -> Source? {
    func source(_ botID: UInt16) -> Source {
      Source(
        botID: botID,
        bot: inputs.bots.first { $0.botID == botID },
        lastHeardAt: inputs.states[botID]?.lastHeardAt,
        lastLiveHeardAt: inputs.states[botID]?.lastLiveHeardAt)
    }
    let advertised = Set(inputs.bots.map(\.botID))
    let heard = inputs.states.keys

    if let preferred = inputs.preferredBotID, advertised.contains(preferred) || inputs.states[preferred] != nil {
      return source(preferred)
    }
    if let place = inputs.place {
      let covering = coverage.botIDs(covering: place.coordinate).intersection(advertised)
      if let best = covering.max(by: { lastHeard($0, inputs) < lastHeard($1, inputs) }) { return source(best) }
    }
    if let best = advertised.filter({ inputs.states[$0] != nil }).max(by: { lastHeard($0, inputs) < lastHeard($1, inputs) }) {
      return source(best)
    }
    if let first = inputs.bots.first { return source(first.botID) }
    if let best = heard.max(by: { lastHeard($0, inputs) < lastHeard($1, inputs) }) { return source(best) }
    return nil
  }

  private static func lastHeard(_ botID: UInt16, _ inputs: Inputs) -> Date {
    inputs.states[botID]?.lastHeardAt ?? .distantPast
  }
}

// MARK: - Update runs

/// Which page's Update run is on the air, and what each page's last run asked for
/// (docs/MESHWX_UI.md §11.1, §13).
///
/// Two rules, and they are the same rule from two sides. **Per page**: a run belongs to the page
/// that started it, so one place's requests never narrate another place's caption and a page
/// being swiped past does not spin because its neighbour is asking for something. **One at a
/// time**: there is one radio and one queue, so a pull and a tap cannot both be running — the
/// second is refused rather than replacing the first, whose own cleanup would otherwise put the
/// live run's spinner out.
public struct WeatherUpdateRuns: Sendable, Hashable {
  /// The page whose run is going, if one is.
  public private(set) var runningPageID: String?
  /// What each page's last run put on the air, kept after it ends so the caption can say how it
  /// went.
  public private(set) var requestsByPage: [String: Set<WeatherRequest>] = [:]

  public init() {}

  public var isRunning: Bool { runningPageID != nil }

  public func isRunning(pageID: String) -> Bool { runningPageID == pageID }

  public func requests(pageID: String) -> Set<WeatherRequest> { requestsByPage[pageID] ?? [] }

  /// Starts a run for one page. Returns false when another run is already going, and then
  /// nothing is changed: the page that asked second simply does not send.
  public mutating func begin(pageID: String, requests: [WeatherRequest]) -> Bool {
    guard runningPageID == nil, !requests.isEmpty else { return false }
    runningPageID = pageID
    requestsByPage[pageID] = Set(requests)
    return true
  }

  /// Ends that page's run. A run that is no longer the one going ends nothing: a cancelled task's
  /// cleanup must not clear the live run's spinner.
  public mutating func end(pageID: String) {
    guard runningPageID == pageID else { return }
    runningPageID = nil
  }
}

// MARK: - Update

/// What one tap on **Update** would ask the weather radio for (docs/MESHWX_UI.md §11).
///
/// The screen has one request control, and it says what it will send before it sends it. The
/// plan is the minimal set that would repair what the phone is actually missing, read from the
/// held state rather than from thresholds hidden inside the cards: the alert list when none is
/// held, it is past its three-hour cadence, or a gap is outstanding; the readings when the last
/// hourly batch was missed; the forecast when none is held or it was issued over twelve hours
/// ago. Nothing at all is asked for what the channel delivered in the last five minutes, which
/// is airtime etiquette rather than a claim about the bot (spec §13).
public struct WeatherUpdatePlan: Sendable, Hashable {
  /// What a step is for, in the order the steps are sent. One word each on the button's caption.
  public enum Item: Sendable, Hashable {
    /// The bot's own alert list, or the one warning it named that never arrived.
    case alerts
    /// The place's county and zone, for a place outside the bot's area: the bot serves
    /// place-named requests nationwide, so it can still be asked about them by name.
    case areaAlerts
    case readings
    case forecast
    /// What the bot carries, from the bot itself (`>cov`): the one thing that tells "outside the
    /// area" from "nothing said yet", and otherwise a three-hour wait.
    case coverage
  }

  public struct Step: Sendable, Hashable {
    public var item: Item
    public var request: WeatherRequest

    public init(item: Item, request: WeatherRequest) {
      self.item = item
      self.request = request
    }
  }

  /// In send order, five seconds apart.
  public var steps: [Step]
  /// Left out only because the channel delivered the answer in the last five minutes: there is
  /// nothing to ask for, but the phone is not current either.
  public var justReceived: [Item]
  /// With nothing to ask for and nothing just received: the oldest of the content times the plan
  /// checked — the time "everything is current" is true as of, on the bot's clock. Nil when the
  /// phone holds none of them.
  public var currentAsOf: Date?

  /// A reading older than this is worth asking about: the batch is hourly, plus ten minutes for
  /// a late broadcast.
  public static let readingFreshFor: TimeInterval = 70 * 60
  /// Spec §7: a forecast is issued at least twice a day.
  public static let forecastFreshFor: TimeInterval = 12 * 60 * 60

  public var isEmpty: Bool { steps.isEmpty }
  public var requests: [WeatherRequest] { steps.map(\.request) }

  /// Each item once, in send order: what the caption names.
  public var items: [Item] {
    var seen: Set<Item> = []
    return steps.compactMap { seen.insert($0.item).inserted ? $0.item : nil }
  }

  /// A stale reading the bot's newest batch still carries asks for the batch; anything else asks
  /// for that station by code. Being in the bot's area is not enough: the footprint is every
  /// multi-station batch of the last day, and a bare `>o` comes back with the batch the bot would
  /// send *now* — which cannot refresh a station it has dropped, or one held from somebody's
  /// single-station answer to a bot that never lists it.
  public static func readingsRequest(for reading: WeatherStationReading) -> WeatherRequest {
    reading.isInLatestBatch ? .observations : .observation(station: reading.station.icao)
  }

  /// Nothing to ask for and nothing held: the plan before the first snapshot is built.
  public static let empty = WeatherUpdatePlan(steps: [], justReceived: [], currentAsOf: nil)

  /// The plan for one station's own screen (docs/MESHWX_UI.md §12): that station's reading, and
  /// nothing else. The station screen answers for a station, so the alert list and the forecast
  /// stay with the screen that shows them.
  ///
  /// - Parameters:
  ///   - reading: what the phone holds for the station, if anything.
  ///   - icao: the station's airport code, for a station no reading has ever arrived for.
  public static func make(stationReading reading: WeatherStationReading?, icao: String?, now: Date) -> WeatherUpdatePlan {
    guard let reading else {
      guard let icao else { return .empty }
      return WeatherUpdatePlan(
        steps: [Step(item: .readings, request: .observation(station: icao))], justReceived: [], currentAsOf: nil)
    }
    guard now.timeIntervalSince(reading.stored.observedAt) > readingFreshFor else {
      return WeatherUpdatePlan(steps: [], justReceived: [], currentAsOf: reading.stored.observedAt)
    }
    guard now.timeIntervalSince(reading.stored.receivedAt) >= WeatherService.recentAnswerWindow else {
      return WeatherUpdatePlan(steps: [], justReceived: [.readings], currentAsOf: nil)
    }
    return WeatherUpdatePlan(
      steps: [Step(item: .readings, request: readingsRequest(for: reading))], justReceived: [], currentAsOf: nil)
  }

  /// The plan for a screen.
  ///
  /// - Parameters:
  ///   - sourceState: the bot the requests would go to. Its gaps and missing identities are the
  ///     only ones a request to it can repair (`WeatherAlertRequests`).
  ///   - nearbyStationICAO: the nearest bundled station to the place, which can be asked for by
  ///     code. It is what the plan spends its readings packet on whenever the reading held is no
  ///     good for the place — none in reach, or one from further than
  ///     ``WeatherConditions/goodReadingKilometres``.
  ///   - notAvailable: identities this bot has already said it does not have, so a tap moves on
  ///     to the next one instead of asking again.
  ///   - coverageAlreadyAsked: this phone has already asked this bot what it covers on this
  ///     visit, however that ended, so a statement it never sent is not asked for on every tap.
  public static func make(
    snapshot: WeatherScreenSnapshot,
    sourceState: WeatherBotState?,
    placeCountyUGC: String? = nil,
    placeZoneUGC: String? = nil,
    placeOffice: String? = nil,
    nearbyStationICAO: String? = nil,
    notAvailable: Set<MeshWXWarningIdentity> = [],
    coverageAlreadyAsked: Bool = false,
    tables: MeshWXTables,
    now: Date
  ) -> WeatherUpdatePlan {
    var steps: [Step] = []
    var justReceived: [Item] = []
    var currentTimes: [Date] = []

    /// The channel delivered this in the last five minutes, so asking again would only have the
    /// bot rebuild the same answer on everyone's airtime.
    func isJustReceived(_ receivedAt: Date?) -> Bool {
      guard let receivedAt else { return false }
      return now.timeIntervalSince(receivedAt) < WeatherService.recentAnswerWindow
    }

    // Alerts. A gap, a warning the list named that never arrived, or an upgrade whose
    // replacement never came is outstanding whatever the list's age, and the five-minute rule
    // never holds it back: what was missed came after the answer that was received (§3.1 R-3).
    let outstanding = sourceState.map {
      $0.needsDigest || !$0.missingFromDigest.isEmpty || !$0.pendingUpgrades.isEmpty
    } ?? false
    if let state = sourceState, outstanding {
      steps.append(Step(item: .alerts, request: WeatherAlertRequests.missedMessages(
        source: state, placeCountyUGC: placeCountyUGC, placeOffice: placeOffice,
        notAvailable: notAvailable, tables: tables)))
    } else if let digest = sourceState?.digest {
      if now.timeIntervalSince(digest.builtAt) > WeatherAlertStatus.listFreshFor {
        if isJustReceived(digest.receivedAt) {
          justReceived.append(.alerts)
        } else {
          steps.append(Step(item: .alerts, request: .digest))
        }
      } else {
        currentTimes.append(digest.builtAt)
      }
    } else {
      // No list held at all: the one thing that says whether anything is active.
      steps.append(Step(item: .alerts, request: .digest))
    }

    // Outside the bot's area its own list speaks for somewhere else, but the bot answers
    // place-named requests nationwide: the place's zone carries the watches and advisories, its
    // county the storm-based warnings (spec §8.2).
    //
    // Only a verdict of `.outside` — a complete statement, or a footprint, that genuinely
    // excludes the place. "No bot says inside" also covers a zone list the bot had to cut,
    // outlines still loading and a bot that has stated nothing, and spending two nationwide
    // requests on those would be spending airtime on a place that is very likely inside the area
    // (`WeatherCoverageVerdict`).
    if let place = snapshot.place, snapshot.coverage.verdict(for: place) == .outside {
      for ugc in [placeZoneUGC, placeCountyUGC].compactMap({ $0 }) {
        steps.append(Step(item: .areaAlerts, request: .warningsTouching(ugc: ugc)))
      }
    }

    // Readings.
    switch snapshot.primaryStation {
    case let .reading(reading):
      if let icao = nearbyStationICAO, icao != reading.station.icao,
         (reading.distanceKilometres ?? .infinity) > WeatherConditions.goodReadingKilometres {
        // The reading held is too far away to be the weather here (`WeatherConditions`), so the
        // page shows the ask rather than a temperature. Asking that same station again would not
        // bring it closer: the packet goes to the nearest station instead, the one the page named.
        steps.append(Step(item: .readings, request: .observation(station: icao)))
      } else if now.timeIntervalSince(reading.stored.observedAt) > readingFreshFor {
        if isJustReceived(reading.stored.receivedAt) {
          justReceived.append(.readings)
        } else {
          steps.append(Step(item: .readings, request: readingsRequest(for: reading)))
        }
      } else {
        currentTimes.append(reading.stored.observedAt)
      }
    case .noneNearby:
      // Nothing held in reach of the place, but a bundled station is: that one station by code.
      if let icao = nearbyStationICAO {
        steps.append(Step(item: .readings, request: .observation(station: icao)))
      }
    case .noObservations:
      steps.append(Step(item: .readings, request: .observations))
    case .noPlace:
      break
    }

    // Forecast.
    switch snapshot.forecast {
    case let .forecast(summary):
      if now.timeIntervalSince(summary.stored.issuedAt) > forecastFreshFor {
        if isJustReceived(summary.stored.receivedAt) {
          justReceived.append(.forecast)
        } else {
          steps.append(Step(item: .forecast, request: .forecast(point: summary.point.index)))
        }
      } else {
        currentTimes.append(summary.stored.issuedAt)
      }
    case let .missing(point, _):
      steps.append(Step(item: .forecast, request: .forecast(point: point.index)))
    case .noPointNearby, .noPlace:
      break
    }

    // Coverage, last: it is about what the *next* answer can be trusted to mean, not about the
    // weather now, and on shared airtime the weather goes first. One packet, asked while the bot
    // has been heard and has stated nothing, and only until it has been asked once on this visit
    // — a statement does not go stale (§6), so a bot that has made one is never asked again, and
    // one that did not answer is not asked on every tap (§14 Q4).
    if let sourceState, sourceState.coverage == nil, !coverageAlreadyAsked {
      steps.append(Step(item: .coverage, request: .coverage))
    }

    // An upgrade already asks by the place's county, which the out-of-area step would repeat.
    var sent: Set<WeatherRequest> = []
    let unique = steps.filter { sent.insert($0.request).inserted }
    return WeatherUpdatePlan(
      steps: unique,
      justReceived: justReceived,
      // Only a plan with nothing to ask for and nothing held back can say everything is current.
      currentAsOf: unique.isEmpty && justReceived.isEmpty ? currentTimes.min() : nil)
  }
}
