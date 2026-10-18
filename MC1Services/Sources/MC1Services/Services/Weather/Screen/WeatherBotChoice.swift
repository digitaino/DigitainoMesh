import Foundation
import MeshWX

/// The user's choice of weather radio (docs/MESHWX_UI.md §3.1 U-63, spec §10.8).
///
/// A pick used to be one bot id for every place and for good. Other cities run their own bots on
/// the same `#meshwx`, so a pick made at home followed the phone to San Antonio and sent every
/// request to a bot that could no longer hear it. A pick now belongs to **the area it was made
/// in** — within ``areaKilometres`` of the place on screen when it was made — and **lapses** once
/// its bot has gone ``unheardLapse`` unheard. Elsewhere, and after that, the app chooses
/// (``WeatherBotChoice``).
public struct WeatherBotPick: Sendable, Hashable, Codable {
  /// A pick speaks for places this close to where it was made.
  public static let areaKilometres = 75.0
  /// A pick lapses once its bot has not been heard live for this long.
  public static let unheardLapse: TimeInterval = 6 * 60 * 60

  public var botID: UInt16
  /// The whole public key when the pick was of an announced radio, so that of two radios
  /// answering to one id the one picked is the one named. Nil for a heard-only bot.
  public var publicKey: Data?
  /// Where it was made; nil when no place was on screen, and then it holds wherever the phone is.
  public var latitude: Double?
  public var longitude: Double?
  public var pickedAt: Date

  public init(botID: UInt16, publicKey: Data? = nil, latitude: Double? = nil, longitude: Double? = nil, pickedAt: Date) {
    self.botID = botID
    self.publicKey = publicKey
    self.latitude = latitude
    self.longitude = longitude
    self.pickedAt = pickedAt
  }

  /// Whether the pick has gone ``unheardLapse`` with its bot unheard live since it was made.
  public func isLapsed(lastLiveHeardAt: Date?, now: Date) -> Bool {
    let heard = max(pickedAt, lastLiveHeardAt ?? .distantPast)
    return now.timeIntervalSince(heard) > Self.unheardLapse
  }

  /// Whether the pick was made near this place: within ``areaKilometres``, or made with no place.
  public func isNear(_ place: WeatherPlace?) -> Bool {
    guard let latitude, let longitude, let place else { return true }
    return WeatherGeo.kilometres(place.coordinate, MeshWXCoordinate(latitude: latitude, longitude: longitude))
      <= Self.areaKilometres
  }

  /// Whether the pick chooses the bot for this place now.
  public func applies(to place: WeatherPlace?, lastLiveHeardAt: Date?, now: Date) -> Bool {
    !isLapsed(lastLiveHeardAt: lastLiveHeardAt, now: now) && isNear(place)
  }
}

/// Where the pick is kept: device-local, beside the other weather choices. One JSON value under
/// one key; the bare id stored before phase 2 is dropped on first read, since it says nothing
/// about where it was made and the choice it stood for is exactly the one that followed a phone
/// across the state.
public struct WeatherBotPickStore: @unchecked Sendable {
  private let defaults: UserDefaults
  static let key = "weather.botPick"
  /// The bare id of the app before phase 2.
  static let legacyKey = "weather.selectedBotID"

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var pick: WeatherBotPick? {
    get {
      if defaults.object(forKey: Self.legacyKey) != nil { defaults.removeObject(forKey: Self.legacyKey) }
      guard let data = defaults.data(forKey: Self.key) else { return nil }
      return try? JSONDecoder().decode(WeatherBotPick.self, from: data)
    }
    nonmutating set {
      if let newValue, let data = try? JSONEncoder().encode(newValue) {
        defaults.set(data, forKey: Self.key)
      } else {
        defaults.removeObject(forKey: Self.key)
      }
    }
  }
}

/// Which bot a page asks when the user has not picked one for where it is (phase 2, 18 October
/// 2026, spec §10.8).
///
/// Several cities' bots share `#meshwx`, meshes are bridged so a phone hears two bots and then
/// loses one, and people travel. So the first question is **who can hear this phone now**: a bot
/// heard live — any message, not drained from the radio's queue — in the last ``liveWindow``, and
/// not silent since a request to it went unanswered. A bot with no advert counts as much as one
/// with: a Request datagram names it by the two bytes its own packets carry (spec §7B). Only then
/// **who covers the place**, by the bot's own statement or its station footprint
/// (``WeatherCoverage``): inside before unknown before outside. A statement with no area filter is
/// unknown, never "covers everything" — it is the cheapest thing on the wire to forge.
///
/// After that a bot with an advert, then the one heard live most recently, then the one heard at
/// all most recently, then the advert list's own order (nearest first), then the id.
///
/// The travel case: Austin to San Antonio, WX-SAT heard live and WX-AUS not — WX-SAT, whatever
/// WX-AUS's coverage says. The bridge case: WX-SAT heard over a bridge that drops — its request
/// goes unanswered, it is not live again until it is heard again, and the page moves on. The
/// spoof case: an id chattering every minute with an empty coverage statement is live and covers
/// nothing known, so the real bot covering the place stays first.
///
/// A bot two radios answer to (``WeatherBot/conflicts(among:)``) is never chosen here at all:
/// until signing, nothing says which of them is the city's, and the user picks.
public enum WeatherBotChoice {
  /// Heard live this recently is in range.
  public static let liveWindow: TimeInterval = WeatherCrossBot.liveWindow

  /// Whether a bot is in range: heard live in the last ``liveWindow``, and not silent since a
  /// request to it went unanswered. `unansweredAt` is the visit's record of requests that timed
  /// out.
  public static func isLive(
    _ botID: UInt16, states: [UInt16: WeatherBotState], unansweredAt: [UInt16: Date] = [:], now: Date
  ) -> Bool {
    guard let heard = states[botID]?.lastLiveHeardAt, now.timeIntervalSince(heard) <= liveWindow else { return false }
    if let silent = unansweredAt[botID], silent > heard { return false }
    return true
  }

  /// 2 for a place inside the bot's area, 1 for unknown or no place, 0 for outside.
  public static func coverageRank(_ botID: UInt16, coverage: WeatherCoverage?, place: WeatherPlace?) -> Int {
    guard let coverage, let place else { return 1 }
    switch coverage.verdict(of: botID, for: place) {
    case .inside: return 2
    case .outside: return 0
    case .unknown: return 1
    }
  }

  /// Every bot that could be asked, best first: the advertised ones and the ones heard on the
  /// channel, less any two radios answer to.
  public static func ranked(
    states: [UInt16: WeatherBotState], bots: [WeatherBot], place: WeatherPlace?, coverage: WeatherCoverage?,
    conflicts: [UInt16: WeatherBot.Conflict] = [:], unansweredAt: [UInt16: Date] = [:], now: Date
  ) -> [UInt16] {
    var order: [UInt16: Int] = [:]
    for (index, bot) in bots.enumerated() where order[bot.botID] == nil { order[bot.botID] = index }
    let ids = Set(order.keys).union(states.keys).filter { conflicts[$0] == nil }
    struct Score {
      let botID: UInt16
      let live: Int
      let covers: Int
      let advertised: Int
      let liveHeardAt: Date
      let heardAt: Date
      let index: Int
    }
    let scored = ids.map { botID in
      Score(
        botID: botID,
        live: isLive(botID, states: states, unansweredAt: unansweredAt, now: now) ? 1 : 0,
        covers: coverageRank(botID, coverage: coverage, place: place),
        advertised: order[botID] == nil ? 0 : 1,
        liveHeardAt: states[botID]?.lastLiveHeardAt ?? .distantPast,
        heardAt: states[botID]?.lastHeardAt ?? .distantPast,
        index: order[botID] ?? Int.max)
    }
    return scored.sorted { lhs, rhs in
      if lhs.live != rhs.live { return lhs.live > rhs.live }
      if lhs.covers != rhs.covers { return lhs.covers > rhs.covers }
      if lhs.advertised != rhs.advertised { return lhs.advertised > rhs.advertised }
      if lhs.liveHeardAt != rhs.liveHeardAt { return lhs.liveHeardAt > rhs.liveHeardAt }
      if lhs.heardAt != rhs.heardAt { return lhs.heardAt > rhs.heardAt }
      if lhs.index != rhs.index { return lhs.index < rhs.index }
      return lhs.botID < rhs.botID
    }.map(\.botID)
  }

  /// The bot to ask again when a request to `failed` went unanswered (phase 2): another bot heard
  /// live in the last ``liveWindow`` whose area covers the place, best first, or nil. Only one that
  /// covers it: a place-named question would reach any bot, but the one asked was chosen for this
  /// place, and a bot that cannot be shown to carry it is no better an answer than silence.
  public static func fallback(
    from failed: UInt16, states: [UInt16: WeatherBotState], bots: [WeatherBot], place: WeatherPlace?,
    coverage: WeatherCoverage?, conflicts: [UInt16: WeatherBot.Conflict] = [:],
    unansweredAt: [UInt16: Date] = [:], now: Date
  ) -> UInt16? {
    guard place != nil else { return nil }
    return ranked(
      states: states, bots: bots, place: place, coverage: coverage, conflicts: conflicts,
      unansweredAt: unansweredAt, now: now
    ).first { botID in
      botID != failed
        && isLive(botID, states: states, unansweredAt: unansweredAt, now: now)
        && coverageRank(botID, coverage: coverage, place: place) == 2
    }
  }
}

/// The bots whose held state is never thrown away to make room (phase 2): the one the user picked,
/// the ones pages are asking, and every bot holding a warning in force that is anywhere near a
/// watched place (``WeatherAlertPlacement`` other than elsewhere — a placement still loading
/// counts). What ``WeatherService/maxBotStates`` evicts around.
public enum WeatherBotRetention {
  public static func protectedBotIDs(
    states: [UInt16: WeatherBotState], pickedBotID: UInt16?, sourceBotIDs: Set<UInt16> = [],
    watch: WeatherAlertWatch?, geometry: any WeatherAreaGeometry, tables: MeshWXTables, now: Date
  ) -> Set<UInt16> {
    var out = sourceBotIDs
    if let pickedBotID { out.insert(pickedBotID) }
    var places = (watch?.places ?? []).map { WeatherWatchedPlace(saved: $0) }
    if let position = watch?.myLocation {
      places.append(WeatherWatchedPlace.myLocation(position, label: "", now: now))
    }
    guard !places.isEmpty else { return out }
    for (botID, state) in states where !out.contains(botID) {
      let near = state.warnings.values.contains { stored in
        !stored.isExpired(at: now) && places.contains { watched in
          WeatherAlertPlacement.place(stored.warning, at: watched.place, geometry: geometry, tables: tables) != .elsewhere
        }
      }
      if near { out.insert(botID) }
    }
    return out
  }
}
