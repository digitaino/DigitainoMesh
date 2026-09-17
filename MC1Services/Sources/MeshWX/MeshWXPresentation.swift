import Foundation

/// How severe a product is, read off the VTEC significance letter (spec §3).
///
/// The wire carries no severity field: the letter after the dot is the severity, which
/// is why an app can rank a product it has never heard of.
public enum MeshWXSeverity: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
  case warning
  case watch
  case advisory
  case statement

  /// `"SV.W"` → ``warning``. `"SPS"` has no significance letter and is a statement.
  public init?(vtec: String) {
    let code = vtec.uppercased()
    let letter: Character
    if let dot = code.lastIndex(of: "."), code.index(after: dot) < code.endIndex {
      letter = code[code.index(after: dot)]
    } else if code == "SPS" {
      letter = "S"
    } else {
      return nil
    }
    switch letter {
    case "W": self = .warning
    case "A": self = .watch
    case "Y": self = .advisory
    case "S": self = .statement
    default: return nil
    }
  }

  /// Sort order for a warning list: the thing that can kill you first (spec §10.2,
  /// "sort by severity then expiry").
  public var rank: Int {
    switch self {
    case .warning: 3
    case .watch: 2
    case .advisory: 1
    case .statement: 0
    }
  }

  public static func < (lhs: MeshWXSeverity, rhs: MeshWXSeverity) -> Bool {
    lhs.rank < rhs.rank
  }
}

/// A colour *name*, not a colour.
///
/// The palette belongs to the app's design system (and has to answer to dark mode and
/// to accessibility contrast); this module only knows which NWS convention a product
/// falls under, so it names it and stops. Spec §10.2.
public enum MeshWXEventTint: String, Sendable, Hashable, Codable, CaseIterable {
  case red
  case yellow
  case orange
  case lightOrange
  case darkGreen
  case green
  case lightGreen
  case orangeRed
  case pink
  case purple
  case lavender
  case tan
  case magenta
  case blue
  case grey
}

/// The icon and wind accent for a forecast period or an observation.
public struct MeshWXConditionIcon: Sendable, Hashable {
  /// SF Symbol name.
  public let symbolName: String
  /// The period is windy (sustained 20 mph or more): show a `wind` glyph *alongside*
  /// the symbol rather than instead of it, so "windy and raining" still reads as rain.
  public let showsWindAccent: Bool

  public init(symbolName: String, showsWindAccent: Bool) {
    self.symbolName = symbolName
    self.showsWindAccent = showsWindAccent
  }
}

/// Which day and half of it a forecast period covers (spec §7, the `first` byte).
public struct MeshWXPeriodSlot: Sendable, Hashable, Codable {
  /// Days after the issue date: 0 is the issue day.
  public let dayOffset: Int
  /// Odd period ids are nights.
  public let isNight: Bool

  public init(periodID: UInt8) {
    dayOffset = Int(periodID) / 2
    isNight = periodID % 2 == 1
  }
}

/// How a forecast's entries are laid out in time, read from the entries themselves.
///
/// Spec §7 (revision 3): the bot sends whole days, `first` even, each entry with a high and a
/// low; a 127 in either marks that half of the day missing at the edge of the forecast window,
/// not a night. The spec keeps revision 1's form for a later bot — 12-hour periods alternating
/// day and night from `first`, one temperature each — recognisable by an odd `first` or by one
/// temperature always missing. Trusting the period ids renders whole days as "Tonight: high
/// 100°", so the layout is decided by what the entries carry, and a forecast that fits neither
/// shape is shown without hiding any value it holds.
public enum MeshWXForecastLayout: Sendable, Hashable {
  /// Spec §7's reserved form: alternating day and night periods, one temperature each.
  case periods
  /// Consecutive days, each with a high and a low, one of which may be missing at the edge of
  /// the window.
  case days
  /// Neither: labels follow the period ids and every temperature present is shown.
  case mixed

  /// Days when `first` is even and any entry carries both temperatures (a day with one is cut at
  /// the window's edge); spec periods when none carries both and every single temperature sits in
  /// its slot (a high by day, a low by night); mixed otherwise — an odd `first` with whole days,
  /// or singles in the wrong slot, where the period ids and the data disagree and neither can be
  /// trusted to label the other.
  public init(of forecast: MeshWXForecast) {
    var both = 0
    var inSlot = 0
    var outOfSlot = 0
    for (index, period) in forecast.periods.enumerated() {
      let isNight = (Int(forecast.firstPeriod) + index) % 2 == 1
      switch (period.highF != nil, period.lowF != nil) {
      case (true, true): both += 1
      case (true, false): if isNight { outOfSlot += 1 } else { inSlot += 1 }
      case (false, true): if isNight { inSlot += 1 } else { outOfSlot += 1 }
      case (false, false): break
      }
    }
    if both > 0, forecast.firstPeriod % 2 == 0 {
      self = .days
    } else if both == 0, outOfSlot == 0 {
      self = .periods
    } else {
      self = .mixed
    }
  }
}

/// One forecast entry placed in time.
public struct MeshWXForecastEntry: Sendable, Hashable {
  /// Position in the message, from 0.
  public let index: Int
  /// Days after the issue date's calendar day.
  public let dayOffset: Int
  /// True or false for a 12-hour period; nil for a whole-day entry.
  public let isNight: Bool?
  public let period: MeshWXForecastPeriod

  /// Lays out a forecast's entries per ``MeshWXForecastLayout``.
  ///
  /// For whole days the offset counts entries from `first ÷ 2`, the day the first period id
  /// names; for periods it is the period id ÷ 2 and the parity says night (spec §7).
  public static func entries(of forecast: MeshWXForecast) -> [MeshWXForecastEntry] {
    let layout = MeshWXForecastLayout(of: forecast)
    return forecast.periods.enumerated().map { index, period in
      switch layout {
      case .days:
        return MeshWXForecastEntry(
          index: index, dayOffset: Int(forecast.firstPeriod) / 2 + index, isNight: nil, period: period)
      case .periods, .mixed:
        let id = Int(forecast.firstPeriod) + index
        return MeshWXForecastEntry(index: index, dayOffset: id / 2, isNight: id % 2 == 1, period: period)
      }
    }
  }
}

/// A wind reading broken into its pieces, ready to be formatted.
///
/// Returns numbers and a compass point, never `"WNW 15 gusting 26"`: the unit, the word
/// "gusting" and the order are the app's to localise.
public struct MeshWXWindReading: Sendable, Hashable {
  /// Nil when the wind is calm — direction 0 with speed 0 (spec §6).
  public let direction: MeshWXCompass?
  /// Nil when the station did not report a speed.
  public let speedMph: UInt8?
  /// Nil when there is no gust (the wire's 0).
  public let gustMph: UInt8?

  public var isCalm: Bool { speedMph == 0 && direction == nil }

  public init(observation: MeshWXStationObservation) {
    let calm = observation.windMph == 0 && observation.windDirection == .north
    direction = calm ? nil : observation.windDirection
    speedMph = observation.windMph
    gustMph = observation.gustMph == 0 ? nil : observation.gustMph
  }

  public init(period: MeshWXForecastPeriod) {
    let calm = period.windMph == 0 && period.windDirection == .north
    direction = calm ? nil : period.windDirection
    speedMph = period.windMph
    gustMph = nil
  }
}

/// What a digest's `feed_health` byte can honestly say (spec §5).
///
/// The byte counts minutes since the bot's *home office* last issued anything (EWX for WX-AUS),
/// not the health of the satellite feed: a quiet office passes four hours on a calm night with
/// the feed working. Only "never received" says alerts may not be reaching the bot at all.
public enum MeshWXFeedHealth: Sendable, Hashable {
  /// A product from the home office within four hours.
  case recent(minutes: Int)
  /// Nothing from the home office for longer than four hours: normal for a quiet office, and
  /// also what a broken feed looks like. The byte cannot tell the two apart.
  case quiet(minutes: Int)
  /// 255: nothing has ever been received.
  case neverReceived

  public init(feedHealth: UInt8) {
    if feedHealth == MeshWXPresentation.feedNeverReceived {
      self = .neverReceived
    } else if MeshWXPresentation.isFeedStale(feedHealth: feedHealth) {
      self = .quiet(minutes: MeshWXPresentation.feedHealthMinutes(feedHealth))
    } else {
      self = .recent(minutes: MeshWXPresentation.feedHealthMinutes(feedHealth))
    }
  }

  /// Quiet and never-received both withhold "no alerts": the bot's silence is evidence of calm
  /// only while its feed is known to be delivering.
  public var withholdsCalm: Bool {
    switch self {
    case .recent: false
    case .quiet, .neverReceived: true
    }
  }
}

/// The pure half of spec §10 and §11: icons, tints, staleness and unit conversions,
/// with no UI framework anywhere near them so every rule is a unit test.
public enum MeshWXPresentation {

  // MARK: - Sky and condition icons (spec §10.1)

  /// SF Symbol for an observation's sky, or nil for sky 15, which in an observation means the
  /// report had no cloud or weather group (spec §6, revision 3): no icon rather than an
  /// invented condition.
  public static func observationSymbolName(for sky: MeshWXSky, isNight: Bool = false) -> String? {
    sky == .other ? nil : symbolName(for: sky, isNight: isNight)
  }

  /// SF Symbol for a sky code. The night variants matter: `sun.max` on an overnight
  /// forecast period is the kind of detail that makes an app look wrong at a glance.
  public static func symbolName(for sky: MeshWXSky, isNight: Bool = false) -> String {
    switch sky {
    case .clear: isNight ? "moon.stars" : "sun.max"
    case .few, .scattered: isNight ? "cloud.moon" : "cloud.sun"
    case .broken: "cloud"
    case .overcast: "cloud.fill"
    case .fog: "cloud.fog"
    case .smoke: "smoke"
    case .haze: isNight ? "moon.haze" : "sun.haze"
    case .rain: "cloud.rain"
    case .snow: "cloud.snow"
    case .thunderstorm: "cloud.bolt.rain"
    case .drizzle: "cloud.drizzle"
    case .mist: "cloud.fog"
    case .squall: "wind"
    case .sandOrDust: "sun.dust"
    case .other: "cloud"
    }
  }

  /// Icon for a forecast period: the `cond` flags override the base sky code (spec
  /// §10.1).
  ///
  /// Order is by what the flag means for a person's day — a thunderstorm outranks the
  /// sleet that may follow it, both outrank fog, and wind is an accent on whatever else
  /// is happening rather than a replacement for it.
  public static func icon(for period: MeshWXForecastPeriod, isNight: Bool = false)
    -> MeshWXConditionIcon
  {
    let symbol: String
    if period.thunder {
      symbol = "cloud.bolt.rain"
    } else if period.wintry {
      // `cloud.sleet` is the mixed-precipitation glyph; plain snow keeps `cloud.snow`.
      symbol = period.sky == .snow ? "cloud.snow" : "cloud.sleet"
    } else if period.fog {
      symbol = "cloud.fog"
    } else {
      symbol = symbolName(for: period.sky, isNight: isNight)
    }
    return MeshWXConditionIcon(symbolName: symbol, showsWindAccent: period.windy)
  }

  // MARK: - Warning colour and icon (spec §10.2)

  /// NWS colour convention for a VTEC code, falling back to the significance letter.
  ///
  /// Returns ``MeshWXEventTint/grey`` for a code with no recognisable significance:
  /// an unknown product is still worth showing, just not worth colouring as an alarm.
  public static func tint(forVTEC vtec: String) -> MeshWXEventTint {
    switch vtec.uppercased() {
    case "TO.W": return .red
    case "TO.A": return .yellow
    case "SV.W": return .orange
    case "SV.A": return .lightOrange
    case "FF.W": return .darkGreen
    case "FA.W", "FL.W": return .green
    case "FA.Y", "FL.Y": return .lightGreen
    case "HT.Y", "EH.W": return .orangeRed
    case "WS.W": return .pink
    case "BZ.W": return .purple
    case "WW.Y": return .lavender
    case "HW.W", "WI.Y": return .tan
    case "FW.W": return .magenta
    default: break
    }
    switch MeshWXSeverity(vtec: vtec) {
    case .warning: return .red
    case .watch: return .yellow
    case .advisory: return .orange
    case .statement: return .grey
    case nil: return .grey
    }
  }

  /// SF Symbol for a VTEC code, `exclamationmark.triangle` for anything unlisted.
  public static func symbolName(forVTEC vtec: String) -> String {
    switch vtec.uppercased() {
    case "TO.W", "TO.A": "tornado"
    case "SV.W", "SV.A": "cloud.bolt"
    case "FF.W", "FA.W", "FL.W": "water.waves"
    case "FA.Y", "FL.Y": "drop"
    case "HT.Y", "EH.W": "thermometer.sun"
    case "WS.W", "BZ.W", "WW.Y": "snowflake"
    case "HW.W", "WI.Y": "wind"
    case "FW.W": "flame"
    default: "exclamationmark.triangle"
    }
  }

  // MARK: - Warning tags (spec §10.2)
  //
  // The app renders "Hail 1.00 in"; this module hands over the 1.0. Unit systems,
  // decimal separators and the word for hail are all localisation, and a string built
  // here would be one an app cannot translate.

  /// Hail tag in inches, or nil when the product carries no hail tag.
  public static func hailInches(quarterInches: UInt8) -> Double? {
    quarterInches == 0 ? nil : Double(quarterInches) / 4.0
  }

  /// Wind tag in mph, or nil when there is none.
  public static func windTagMph(_ mph: UInt8) -> UInt8? {
    mph == 0 ? nil : mph
  }

  /// The tags worth showing for a warning, in the order §10.2 lists them. Each case
  /// carries its number; the words are the app's.
  public enum Tag: Sendable, Hashable {
    case tornado(MeshWXTornadoTag)
    case floodSource(MeshWXFloodSource)
    case floodDamage(MeshWXFloodDamage)
    case hail(inches: Double)
    case wind(mph: UInt8)
  }

  /// Non-zero tags only: a warning with no tags should render as a bare headline, not
  /// as a row of "none".
  public static func tags(for warning: MeshWXWarning) -> [Tag] {
    var tags: [Tag] = []
    if warning.tornado != .none { tags.append(.tornado(warning.tornado)) }
    if warning.floodSource != .none { tags.append(.floodSource(warning.floodSource)) }
    if warning.floodDamage != .none, warning.floodDamage != .reserved {
      tags.append(.floodDamage(warning.floodDamage))
    }
    if let inches = hailInches(quarterInches: warning.hailQuarterInches) {
      tags.append(.hail(inches: inches))
    }
    if let mph = windTagMph(warning.windMph) { tags.append(.wind(mph: mph)) }
    return tags
  }

  // MARK: - Staleness (spec §10.3, §5)

  /// Observations older than this are stale.
  public static let observationStaleAfterMinutes: UInt32 = 120
  /// Forecasts older than this are stale.
  public static let forecastStaleAfterMinutes: UInt32 = 720
  /// `feed_health` above this (4-minute units, so ~4 hours) means the bot's silence
  /// stops being evidence of calm weather.
  public static let feedStaleThreshold: UInt8 = 60
  /// `feed_health` 255: the bot has never received a product from its home office (spec §5).
  public static let feedNeverReceived: UInt8 = 255

  /// Unix minutes for a date, the unit every timestamp on the wire uses.
  public static func unixMinutes(for date: Date) -> UInt32 {
    let seconds = date.timeIntervalSince1970
    guard seconds > 0 else { return 0 }
    return UInt32(min(seconds / 60, Double(UInt32.max)))
  }

  public static func isObservationStale(timestampMinutes: UInt32, now: UInt32) -> Bool {
    now > timestampMinutes &+ observationStaleAfterMinutes
  }

  public static func isForecastStale(issuedMinutes: UInt32, now: UInt32) -> Bool {
    now > issuedMinutes &+ forecastStaleAfterMinutes
  }

  /// Quiet or never received: either way silence is no evidence of calm (``MeshWXFeedHealth``).
  public static func isFeedStale(feedHealth: UInt8) -> Bool {
    feedHealth > feedStaleThreshold
  }

  /// `feed_health` in minutes. 255 is capped and means "17 hours or more, or unknown",
  /// so it is reported as its floor rather than as a precise 1020.
  public static func feedHealthMinutes(_ feedHealth: UInt8) -> Int {
    Int(feedHealth) * 4
  }

  /// Minutes until a warning expires, or nil once it has passed.
  public static func minutesUntilExpiry(expiresMinutes: UInt32, now: UInt32) -> Int? {
    expiresMinutes > now ? Int(expiresMinutes - now) : nil
  }

  // MARK: - Forecast periods (spec §7)

  /// Which day and half of it the `n`th period of a forecast covers.
  public static func slot(forecast: MeshWXForecast, periodOffset: Int) -> MeshWXPeriodSlot {
    MeshWXPeriodSlot(periodID: forecast.firstPeriod &+ UInt8(truncatingIfNeeded: periodOffset))
  }

  // MARK: - Units

  /// Wire byte → inches of mercury. Built from integers so the result is exactly the
  /// two-decimal value, matching the decoder.
  public static func inchesOfMercury(fromRawPressure raw: UInt8) -> Double? {
    raw == MeshWXWire.unsignedUnknown ? nil : Double(2900 + Int(raw)) / 100
  }

  /// Inches of mercury → millibars (hPa), for the rest of the world.
  public static func millibars(fromInchesOfMercury inHg: Double) -> Double {
    inHg * 33.863886666667
  }

  public static func celsius(fromFahrenheit fahrenheit: Double) -> Double {
    (fahrenheit - 32) * 5 / 9
  }

  public static func kilometres(fromMiles miles: Double) -> Double {
    miles * 1.609344
  }

  public static func kilometresPerHour(fromMilesPerHour mph: Double) -> Double {
    mph * 1.609344
  }
}
