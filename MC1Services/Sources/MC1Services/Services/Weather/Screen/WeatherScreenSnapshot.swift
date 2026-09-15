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

/// Everything the Weather screen shows, computed in one pass from the service's state and the
/// phone's situation. Views read this and nothing else (docs/MESHWX_UI.md §13).
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
    public var isRadioConnected: Bool
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
      isRadioConnected: Bool,
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
      self.isRadioConnected = isRadioConnected
      self.firmwareSupportsWeather = firmwareSupportsWeather
      self.firmwareVersion = firmwareVersion
      self.hasWeatherChannel = hasWeatherChannel
      self.session = session
      self.now = now
      self.calendar = calendar
    }
  }

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
      readings: readings,
      primaryStation: WeatherPrimaryStation.pick(readings: readings, place: inputs.place),
      forecast: forecast,
      otherPlaces: WeatherOtherPlace.make(states: inputs.states, excludingPoint: placePoint, tables: tables, now: now),
      texts: texts,
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
