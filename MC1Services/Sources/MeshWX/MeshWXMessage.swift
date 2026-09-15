import Foundation

// MARK: - Shared scalars

/// A 16-point compass direction, as carried in a wind nibble (spec §6, §7).
///
/// The wire spends four bits on direction, so a station reporting 157° and one
/// reporting 163° are the same value on air. Keeping the nibble as the model (rather
/// than the degrees it was rounded from) is what makes a decode/re-encode round trip
/// byte-identical; ``degrees`` reconstructs the centre of the sector for a compass rose.
public enum MeshWXCompass: UInt8, Sendable, Hashable, Codable, CaseIterable {
  case north = 0
  case northNorthEast = 1
  case northEast = 2
  case eastNorthEast = 3
  case east = 4
  case eastSouthEast = 5
  case southEast = 6
  case southSouthEast = 7
  case south = 8
  case southSouthWest = 9
  case southWest = 10
  case westSouthWest = 11
  case west = 12
  case westNorthWest = 13
  case northWest = 14
  case northNorthWest = 15

  /// Never fails: the nibble is masked, and all 16 values are defined.
  public init(nibble: UInt8) {
    self = MeshWXCompass(rawValue: nibble & 0x0F) ?? .north
  }

  /// Degrees true to the nearest sector, the reference's `wind_dir_nibble`.
  ///
  /// Spec §6: direction 0 with speed 0 means calm, so a nil heading maps to north and
  /// the *speed* is what tells the caller there was no wind.
  public init(degrees: Double?) {
    guard let degrees, degrees.isFinite else {
      self = .north
      return
    }
    // Wrap before rounding so a bearing of 3600° or −45° cannot overflow the Int
    // conversion; Swift's `%` keeps the sign of the dividend where Python's does not,
    // hence the explicit fold.
    let wrapped = degrees.truncatingRemainder(dividingBy: 360)
    let sector = Int((wrapped / 22.5).rounded(.toNearestOrEven))
    self = MeshWXCompass(nibble: UInt8((sector % 16 + 16) % 16))
  }

  /// Centre of the sector, in degrees true.
  public var degrees: Double { Double(rawValue) * 22.5 }

  /// The NWS abbreviation: `"N"`, `"NNE"`, … Not localised on purpose; these are
  /// symbols, and the app shows them as-is the way an aviation report does.
  public var abbreviation: String {
    switch self {
    case .north: "N"
    case .northNorthEast: "NNE"
    case .northEast: "NE"
    case .eastNorthEast: "ENE"
    case .east: "E"
    case .eastSouthEast: "ESE"
    case .southEast: "SE"
    case .southSouthEast: "SSE"
    case .south: "S"
    case .southSouthWest: "SSW"
    case .southWest: "SW"
    case .westSouthWest: "WSW"
    case .west: "W"
    case .westNorthWest: "WNW"
    case .northWest: "NW"
    case .northNorthWest: "NNW"
    }
  }
}

/// Sky condition code (spec §10.1, `protocol.json` `sky_codes`).
public enum MeshWXSky: UInt8, Sendable, Hashable, Codable, CaseIterable {
  case clear = 0
  case few = 1
  case scattered = 2
  case broken = 3
  case overcast = 4
  case fog = 5
  case smoke = 6
  case haze = 7
  case rain = 8
  case snow = 9
  case thunderstorm = 10
  case drizzle = 11
  case mist = 12
  case squall = 13
  case sandOrDust = 14
  case other = 15

  /// Never fails: the nibble is masked, and all 16 values are defined.
  public init(nibble: UInt8) {
    self = MeshWXSky(rawValue: nibble & 0x0F) ?? .other
  }
}

/// A polygon vertex. Plain degrees rather than `CLLocationCoordinate2D` so this module
/// stays free of CoreLocation and testable on a Mac without a location stack.
public struct MeshWXCoordinate: Sendable, Hashable, Codable {
  public var latitude: Double
  public var longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }
}

// MARK: - Warning

/// The key a warning is stored under (spec §2.3).
///
/// Not `seq`: the bot re-sends a warning whenever its expiry, tags or area change, with
/// a fresh sequence number every time. An app that keys by anything else ends up with
/// the same storm listed twice.
public struct MeshWXWarningIdentity: Sendable, Hashable, Codable {
  /// VTEC event code (`protocol.json` `events`, e.g. `SV.W` = 3).
  public var event: UInt8
  /// Index into `index.json` `offices`.
  public var office: UInt8
  /// Event tracking number.
  public var etn: UInt16

  public init(event: UInt8, office: UInt8, etn: UInt16) {
    self.event = event
    self.office = office
    self.etn = etn
  }
}

/// Tornado tag, bits 7-6 of the warning tag byte (spec §3).
public enum MeshWXTornadoTag: UInt8, Sendable, Hashable, Codable, CaseIterable {
  case none = 0
  case possible = 1
  case radarIndicated = 2
  case observed = 3
}

/// Flood source tag, bits 5-4 of the warning tag byte (spec §3).
public enum MeshWXFloodSource: UInt8, Sendable, Hashable, Codable, CaseIterable {
  case none = 0
  case radar = 1
  case radarAndGauge = 2
  case observed = 3
}

/// Flood damage tag, bits 3-2 of the warning tag byte (spec §3).
///
/// Only three values are defined; `reserved` exists so the two-bit field always decodes
/// rather than throwing on a byte from a newer bot.
public enum MeshWXFloodDamage: UInt8, Sendable, Hashable, Codable, CaseIterable {
  case none = 0
  case considerable = 1
  case catastrophic = 2
  case reserved = 3
}

/// One run of consecutive UGC numbers in the same state and of the same kind (spec §3).
///
/// `TXZ191`…`TXZ194` is one run, not four entries: a winter storm covering twenty zones
/// is the difference between fitting in a packet and not.
public struct MeshWXAreaRun: Sendable, Hashable, Codable {
  /// Index into `index.json` `states` (bits 6-0 of the wire byte).
  public var stateIndex: UInt8
  /// Bit 7 of the wire byte: county (`C`) rather than forecast zone (`Z`).
  public var isCounty: Bool
  /// First UGC number in the run.
  public var start: UInt16
  /// How many consecutive numbers the run covers, from 1.
  public var run: UInt8

  public init(stateIndex: UInt8, isCounty: Bool, start: UInt16, run: UInt8) {
    self.stateIndex = stateIndex
    self.isCounty = isCounty
    self.start = start
    self.run = run
  }

  /// The UGC numbers this run covers.
  public var numbers: [UInt16] {
    guard run > 0 else { return [] }
    return (0..<UInt16(run)).map { start &+ $0 }
  }

  /// Expand to UGC strings (`"TXC453"`, `"TXZ191"`) using `index.json` `states`.
  ///
  /// Returns an empty array when the state index is not in the table: an older bundle
  /// decoding a newer bot's traffic should lose the *names*, never the message.
  public func ugcCodes(states: [String]) -> [String] {
    guard Int(stateIndex) < states.count else { return [] }
    let state = states[Int(stateIndex)]
    let kind = isCounty ? "C" : "Z"
    return numbers.map { number in
      "\(state)\(kind)\(Self.ugcDigits(number))"
    }
  }

  /// UGC numbers are three digits, zero padded. Anything wider is out of spec but is
  /// rendered verbatim rather than truncated.
  static func ugcDigits(_ number: UInt16) -> String {
    let text = String(number)
    return text.count >= 3 ? text : String(repeating: "0", count: 3 - text.count) + text
  }

  /// Turn NWS UGC codes into runs — the reference's `areas_from_ugcs`.
  ///
  /// Codes whose state is not in `states` are skipped (the bundle is append-only, so an
  /// unknown state means an old bundle, not a bad product). Duplicates collapse, the
  /// result is sorted by `(state, kind, number)`, and consecutive numbers merge into
  /// runs of at most 255.
  public static func runs(fromUGCs ugcs: [String], states: [String]) -> [MeshWXAreaRun] {
    // The wire spends only bits 6-0 on the state, so an index past 127 has no
    // encoding; the table is append-only and 78 long, so this is a guard, not a case.
    var index: [String: UInt8] = [:]
    for (position, code) in states.enumerated() where position <= 127 {
      index[code] = UInt8(position)
    }

    struct Key: Hashable, Comparable {
      let state: UInt8
      let isCounty: Bool
      let number: UInt16

      static func < (lhs: Key, rhs: Key) -> Bool {
        // Matches Python's tuple ordering, where False sorts before True.
        (lhs.state, lhs.isCounty ? 1 : 0, lhs.number)
          < (rhs.state, rhs.isCounty ? 1 : 0, rhs.number)
      }
    }

    var seen: Set<Key> = []
    for raw in ugcs {
      let ugc = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      guard ugc.count == 6 else { continue }
      let letters = Array(ugc)
      let kind = letters[2]
      guard kind == "C" || kind == "Z" else { continue }
      guard let number = UInt16(String(letters[3...])), letters[3...].allSatisfy(\.isNumber)
      else { continue }
      guard let state = index[String(letters[0...1])] else { continue }
      seen.insert(Key(state: state, isCounty: kind == "C", number: number))
    }

    var runs: [MeshWXAreaRun] = []
    for key in seen.sorted() {
      if var last = runs.last,
        last.stateIndex == key.state,
        last.isCounty == key.isCounty,
        UInt16(last.run) + last.start == key.number,
        last.run < 255
      {
        last.run += 1
        runs[runs.count - 1] = last
        continue
      }
      runs.append(
        MeshWXAreaRun(stateIndex: key.state, isCounty: key.isCounty, start: key.number, run: 1))
    }
    return runs
  }
}

/// A watch, warning or advisory (type 1, spec §3).
public struct MeshWXWarning: Sendable, Hashable, Codable {
  public var identity: MeshWXWarningIdentity
  /// Absolute Unix minutes. Count down against the phone's clock, not against a
  /// received-at timestamp: a message drained from an offline queue an hour late must
  /// still expire on time.
  public var expiresMinutes: UInt32
  public var tornado: MeshWXTornadoTag
  public var floodSource: MeshWXFloodSource
  public var floodDamage: MeshWXFloodDamage
  /// Hail tag in quarter inches (4 = 1.00 in). 0 = no tag.
  public var hailQuarterInches: UInt8
  /// Wind tag in mph. 0 = no tag.
  public var windMph: UInt8
  /// Header flags bit 0: the bot had already sent this identity. Informational only —
  /// the app replaces by identity either way.
  public var isUpdate: Bool
  /// Storm-based warnings carry a polygon; zone-based products do not.
  public var polygon: [MeshWXCoordinate]?
  /// The counties or forecast zones the product names.
  public var areas: [MeshWXAreaRun]?

  public init(
    identity: MeshWXWarningIdentity,
    expiresMinutes: UInt32,
    tornado: MeshWXTornadoTag = .none,
    floodSource: MeshWXFloodSource = .none,
    floodDamage: MeshWXFloodDamage = .none,
    hailQuarterInches: UInt8 = 0,
    windMph: UInt8 = 0,
    isUpdate: Bool = false,
    polygon: [MeshWXCoordinate]? = nil,
    areas: [MeshWXAreaRun]? = nil
  ) {
    self.identity = identity
    self.expiresMinutes = expiresMinutes
    self.tornado = tornado
    self.floodSource = floodSource
    self.floodDamage = floodDamage
    self.hailQuarterInches = hailQuarterInches
    self.windMph = windMph
    self.isUpdate = isUpdate
    self.polygon = polygon
    self.areas = areas
  }

  public var event: UInt8 { identity.event }
  public var office: UInt8 { identity.office }
  public var etn: UInt16 { identity.etn }

  /// Hail tag in inches, or nil when there is no tag. The *number* is returned, not a
  /// string, because the unit and the decimal separator are the app's to localise.
  public var hailInches: Double? {
    hailQuarterInches == 0 ? nil : Double(hailQuarterInches) / 4.0
  }
}

// MARK: - Cancel

/// Why a warning ended early (spec §4, the cancel flags nibble).
public enum MeshWXCancelReason: Sendable, Hashable, Codable {
  case cancelled
  case expiredEarly
  /// A replacement warning follows; do not tell the user the weather improved.
  case upgraded
  case other(UInt8)

  public init(rawValue: UInt8) {
    switch rawValue & 0x0F {
    case 0: self = .cancelled
    case 1: self = .expiredEarly
    case 2: self = .upgraded
    case let value: self = .other(value)
    }
  }

  public var rawValue: UInt8 {
    switch self {
    case .cancelled: 0
    case .expiredEarly: 1
    case .upgraded: 2
    case .other(let value): value & 0x0F
    }
  }

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(UInt8.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A warning ended before its stored expiry (type 2, spec §4). Remove the identity.
public struct MeshWXCancel: Sendable, Hashable, Codable {
  public var identity: MeshWXWarningIdentity
  public var reason: MeshWXCancelReason

  public init(identity: MeshWXWarningIdentity, reason: MeshWXCancelReason) {
    self.identity = identity
    self.reason = reason
  }
}

// MARK: - Digest

/// Everything active in the bot's coverage (type 3, spec §5).
///
/// This is the recovery mechanism: an identity here that the app does not hold is one
/// `>w` away, and an identity the app holds that is *absent* has ended.
public struct MeshWXDigest: Sendable, Hashable, Codable {
  public struct Entry: Sendable, Hashable, Codable {
    public var identity: MeshWXWarningIdentity
    /// Minutes after ``MeshWXDigest/nowMinutes``, as carried on the wire.
    public var expiresRelativeMinutes: UInt16
    /// `nowMinutes + expiresRelativeMinutes`, resolved for the caller.
    public var expiresMinutes: UInt32

    public init(
      identity: MeshWXWarningIdentity,
      expiresRelativeMinutes: UInt16,
      expiresMinutes: UInt32
    ) {
      self.identity = identity
      self.expiresRelativeMinutes = expiresRelativeMinutes
      self.expiresMinutes = expiresMinutes
    }
  }

  /// Unix minutes when the digest was built. Expiries are relative to this, not to
  /// receipt, so a queued digest delivered hours late still resolves correctly.
  public var nowMinutes: UInt32
  /// Minutes since the bot last heard from its home office, in units of 4, capped at
  /// 255. Above ~60 the bot's silence stops meaning "calm weather" (spec §5).
  public var feedHealth: UInt8
  public var entries: [Entry]

  public init(nowMinutes: UInt32, feedHealth: UInt8, entries: [Entry]) {
    self.nowMinutes = nowMinutes
    self.feedHealth = feedHealth
    self.entries = entries
  }
}

// MARK: - Observations

/// One METAR station's current conditions (spec §6, 11 bytes on the wire).
public struct MeshWXStationObservation: Sendable, Hashable, Codable {
  /// Index into `index.json` `stations` (the ICAO list).
  public var stationIndex: UInt16
  public var tempF: Int8?
  public var dewpointF: Int8?
  /// Direction 0 with ``windMph`` 0 means calm, not "wind from the north".
  public var windDirection: MeshWXCompass
  public var sky: MeshWXSky
  public var windMph: UInt8?
  /// 0 = no gust reported (distinct from an unknown wind speed).
  public var gustMph: UInt8
  public var visibilityMiles: UInt8?
  /// Inches of mercury, two decimals. The wire carries `(inHg − 29.00) × 100`.
  public var pressureInHg: Double?
  public var humidityPercent: UInt8?
  /// Feels-like minus temperature. 0 = the same, which is also "no heat index or wind
  /// chill applies"; the two are not distinguished on the wire.
  public var feelsDeltaF: Int8

  public init(
    stationIndex: UInt16,
    tempF: Int8? = nil,
    dewpointF: Int8? = nil,
    windDirection: MeshWXCompass = .north,
    sky: MeshWXSky = .other,
    windMph: UInt8? = nil,
    gustMph: UInt8 = 0,
    visibilityMiles: UInt8? = nil,
    pressureInHg: Double? = nil,
    humidityPercent: UInt8? = nil,
    feelsDeltaF: Int8 = 0
  ) {
    self.stationIndex = stationIndex
    self.tempF = tempF
    self.dewpointF = dewpointF
    self.windDirection = windDirection
    self.sky = sky
    self.windMph = windMph
    self.gustMph = gustMph
    self.visibilityMiles = visibilityMiles
    self.pressureInHg = pressureInHg
    self.humidityPercent = humidityPercent
    self.feelsDeltaF = feelsDeltaF
  }

  /// Apparent temperature, or nil when the temperature itself is unknown.
  public var feelsLikeF: Int? {
    tempF.map { Int($0) + Int(feelsDeltaF) }
  }
}

/// A batch of current conditions (type 4, spec §6).
public struct MeshWXObservations: Sendable, Hashable, Codable {
  /// Unix minutes of the *newest* observation in the batch; staleness is judged from it
  /// for the whole batch (spec §10.3).
  public var timestampMinutes: UInt32
  public var stations: [MeshWXStationObservation]

  public init(timestampMinutes: UInt32, stations: [MeshWXStationObservation]) {
    self.timestampMinutes = timestampMinutes
    self.stations = stations
  }
}

// MARK: - Forecast

/// One forecast period (spec §7, 5 bytes on the wire).
public struct MeshWXForecastPeriod: Sendable, Hashable, Codable {
  /// Nil on night periods.
  public var highF: Int8?
  /// Nil on day periods.
  public var lowF: Int8?
  public var popPercent: UInt8?
  public var sky: MeshWXSky
  public var thunder: Bool
  /// Snow, sleet or freezing rain.
  public var wintry: Bool
  /// Sustained 20 mph or more.
  public var windy: Bool
  public var fog: Bool
  public var windDirection: MeshWXCompass
  /// Already multiplied out of the nibble: 0, 5, 10 … 75 mph (75 means "or more").
  public var windMph: UInt8

  public init(
    highF: Int8? = nil,
    lowF: Int8? = nil,
    popPercent: UInt8? = nil,
    sky: MeshWXSky = .other,
    thunder: Bool = false,
    wintry: Bool = false,
    windy: Bool = false,
    fog: Bool = false,
    windDirection: MeshWXCompass = .north,
    windMph: UInt8 = 0
  ) {
    self.highF = highF
    self.lowF = lowF
    self.popPercent = popPercent
    self.sky = sky
    self.thunder = thunder
    self.wintry = wintry
    self.windy = windy
    self.fog = fog
    self.windDirection = windDirection
    self.windMph = windMph
  }
}

/// A point forecast (type 5, spec §7).
public struct MeshWXForecast: Sendable, Hashable, Codable {
  /// Index into `pfm_points.json` `points`, or ``MeshWXWire/unbundledPoint`` when the
  /// bot resolved a place with no bundled point — label that one from the request you
  /// sent, because the wire carries no name.
  public var pointIndex: UInt16
  public var issuedMinutes: UInt32
  /// Period id of the first entry: 0 today, 1 tonight, 2 tomorrow, … Even is a day,
  /// odd a night, and the day offset from the issue date is the id halved.
  public var firstPeriod: UInt8
  public var periods: [MeshWXForecastPeriod]

  public init(
    pointIndex: UInt16,
    issuedMinutes: UInt32,
    firstPeriod: UInt8,
    periods: [MeshWXForecastPeriod]
  ) {
    self.pointIndex = pointIndex
    self.issuedMinutes = issuedMinutes
    self.firstPeriod = firstPeriod
    self.periods = periods
  }

  /// True when the bot could not name a bundled point for the request.
  public var isUnbundledPoint: Bool { pointIndex == MeshWXWire.unbundledPoint }
}

// MARK: - Text

/// What a text reply is about (spec §8.1).
///
/// These are the v5 subjects from `protocol.json` `v5.text_subjects`, which are *not*
/// the legacy top-level `text_subjects` in the same file (that table is v3/v4 and its
/// numbering differs).
public enum MeshWXTextSubject: Sendable, Hashable, Codable {
  case warningNarrative
  case forecastDiscussion
  case spaceWeather
  case stormReports
  case rainfall
  case metarOrTAF
  case hazardousOutlook
  case nowcast
  case general
  case other(UInt8)

  public init(rawValue: UInt8) {
    switch rawValue {
    case 0: self = .warningNarrative
    case 1: self = .forecastDiscussion
    case 2: self = .spaceWeather
    case 3: self = .stormReports
    case 4: self = .rainfall
    case 5: self = .metarOrTAF
    case 6: self = .hazardousOutlook
    case 7: self = .nowcast
    case 8: self = .general
    case let value: self = .other(value)
    }
  }

  public var rawValue: UInt8 {
    switch self {
    case .warningNarrative: 0
    case .forecastDiscussion: 1
    case .spaceWeather: 2
    case .stormReports: 3
    case .rainfall: 4
    case .metarOrTAF: 5
    case .hazardousOutlook: 6
    case .nowcast: 7
    case .general: 8
    case .other(let value): value
    }
  }

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(UInt8.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// One chunk of a narrative reply (type 6, spec §8.1).
///
/// Reassemble by `(bot, group)` in ``index`` order. A chunk that never arrives leaves a
/// hole: show the partial text with a marker rather than nothing, because a warning
/// narrative with one paragraph missing is still worth reading.
public struct MeshWXText: Sendable, Hashable, Codable {
  public var subject: MeshWXTextSubject
  /// Shared by every chunk of one reply (the `seq` of its first chunk).
  public var group: UInt8
  public var index: UInt8
  public var total: UInt8
  public var text: String

  public init(subject: MeshWXTextSubject, group: UInt8, index: UInt8, total: UInt8, text: String) {
    self.subject = subject
    self.group = group
    self.index = index
    self.total = total
    self.text = text
  }
}

// MARK: - Not available

/// Why the bot could not serve a request (spec §8.3).
public enum MeshWXNotAvailableReason: Sendable, Hashable, Codable {
  case noData
  case unknownLocation
  case unsupported
  case botError
  /// Try later; do not retry immediately or the next request is refused too.
  case rateLimited
  case other(UInt8)

  public init(rawValue: UInt8) {
    switch rawValue {
    case 0: self = .noData
    case 1: self = .unknownLocation
    case 2: self = .unsupported
    case 3: self = .botError
    case 4: self = .rateLimited
    case let value: self = .other(value)
    }
  }

  public var rawValue: UInt8 {
    switch self {
    case .noData: 0
    case .unknownLocation: 1
    case .unsupported: 2
    case .botError: 3
    case .rateLimited: 4
    case .other(let value): value
    }
  }

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(UInt8.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// The bot declining a request (type 7, spec §8.3).
public struct MeshWXNotAvailable: Sendable, Hashable, Codable {
  /// ASCII code of the request's first letter — `w`, `o`, `f`, `a`, `s`, `r`, `m`, `t`,
  /// `h`, `d`. Stored as the byte so the letter and the code can never disagree.
  public var requestCode: UInt8
  public var reason: MeshWXNotAvailableReason

  /// The request's first letter.
  public var requestLetter: Character { Character(UnicodeScalar(requestCode)) }

  public init(requestCode: UInt8, reason: MeshWXNotAvailableReason) {
    self.requestCode = requestCode
    self.reason = reason
  }
}

// MARK: - Message

/// The decoded body of a v5 message.
public enum MeshWXPayload: Sendable, Hashable {
  case warning(MeshWXWarning)
  case cancel(MeshWXCancel)
  case digest(MeshWXDigest)
  case observations(MeshWXObservations)
  case forecast(MeshWXForecast)
  case text(MeshWXText)
  case notAvailable(MeshWXNotAvailable)
  /// A reserved or third-party type (spec §2.2, nibbles 8-15). Receivers ignore these,
  /// but the header still decoded, so `(bot, seq)` tracking keeps working.
  case unknown
}

/// One decoded v5 message: the common header plus its typed body.
public struct MeshWXMessage: Sendable, Hashable {
  public var header: MeshWXHeader
  public var payload: MeshWXPayload

  public init(header: MeshWXHeader, payload: MeshWXPayload) {
    self.header = header
    self.payload = payload
  }
}
