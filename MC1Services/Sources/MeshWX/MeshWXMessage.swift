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
  /// In an observation: the report had no cloud or weather group, so the sky is unknown (spec
  /// §6, revision 3).
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

  /// Whether this run covers a UGC code (`"TXZ192"`, `"TXC453"`), read against `index.json`
  /// `states`. False for a malformed code and for one whose state the bundle does not know: an
  /// old bundle loses the *match*, and a caller must not read that as "not covered".
  public func covers(ugc: String, states: [String]) -> Bool {
    guard let key = Self.key(forUGC: ugc, states: states) else { return false }
    guard key.stateIndex == stateIndex, key.isCounty == isCounty else { return false }
    // In Int: `start + run` can pass the u16 ceiling for an out-of-spec run.
    return Int(key.number) >= Int(start) && Int(key.number) < Int(start) + Int(run)
  }

  /// Split a UGC code into the fields a run carries, or nil when it is malformed or its state is
  /// not in `index.json` `states`.
  public static func key(
    forUGC ugc: String, states: [String]
  ) -> (stateIndex: UInt8, isCounty: Bool, number: UInt16)? {
    let code = Array(ugc.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    guard code.count == 6 else { return nil }
    let kind = code[2]
    guard kind == "C" || kind == "Z" else { return nil }
    guard code[3...].allSatisfy(\.isNumber), let number = UInt16(String(code[3...])) else { return nil }
    // Only bits 6-0 carry the state, so an index past 127 has no run to match.
    guard let index = states.firstIndex(of: String(code[0...1])), index <= 127 else { return nil }
    return (UInt8(index), kind == "C", number)
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
  /// Minutes between the NWS product's own issuance and ``expiresMinutes``, exactly as the wire
  /// carries it (spec §3, revision 5); nil when the message did not carry an issue time.
  ///
  /// The wire value rather than the instant, for the same reason ``MeshWXCompass`` keeps its
  /// nibble: a re-encode has to reproduce the two bytes. It also keeps the saturation readable —
  /// 65535 means "45.5 days or more", which an absolute time alone cannot say.
  public var issuedBeforeMinutes: UInt16?

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
    areas: [MeshWXAreaRun]? = nil,
    issuedBeforeMinutes: UInt16? = nil
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
    self.issuedBeforeMinutes = issuedBeforeMinutes
  }

  public var event: UInt8 { identity.event }
  public var office: UInt8 { identity.office }
  public var etn: UInt16 { identity.etn }

  /// When NWS issued the product, in Unix minutes: `expires − issued_before` (spec §3). Nil when
  /// the warning carries no issue time — a bot older than revision 5.
  ///
  /// This is the product's own header time, kept across continuations, so an SVS update does not
  /// restamp a warning as newly issued. It is never when the bot read the file and never when the
  /// phone heard the packet (spec §10.5): a radio out of range for three hours must still say
  /// *issued 1:29 PM*. With ``isIssueTimeSaturated`` the product was issued at or before this.
  public var issuedMinutes: UInt32? {
    issuedBeforeMinutes.map { expiresMinutes &- UInt32($0) }
  }

  /// The gap ran past the u16 and saturated (spec §3), so ``issuedMinutes`` is a ceiling: the
  /// product was issued 45.5 days before its expiry *or more*. No NWS product runs that long from
  /// issuance to expiry, so this is a guard against a wrap, not a case a screen will meet.
  public var isIssueTimeSaturated: Bool {
    issuedBeforeMinutes == MeshWXWire.issuedBeforeSaturatedMinutes
  }

  /// Hail tag in inches, or nil when there is no tag. The *number* is returned, not a
  /// string, because the unit and the decimal separator are the app's to localise.
  public var hailInches: Double? {
    hailQuarterInches == 0 ? nil : Double(hailQuarterInches) / 4.0
  }
}

// MARK: - Cancel

/// Why a warning ended early (spec §4, the cancel flags nibble).
///
/// **The one type whose flags nibble is not shared.** Since revision 7 bits 3-2 of every other
/// type's nibble carry ``MeshWXDataSource``; a Cancel spends the *whole* nibble on this reason,
/// so reason 12 is `other(12)` and never "mixed". ``MeshWXHeader/dataSource`` returns
/// ``MeshWXDataSource/unstated`` for a Cancel for that reason, and a Cancel's nibble is decoded
/// and re-encoded exactly as it was before revision 7.
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
  /// How far behind the batch's ``MeshWXObservations/timestampMinutes`` this station's own report
  /// is, in the wire's 10-minute steps (spec §6.1, revision 5): 0 to 150, where
  /// ``MeshWXWire/observationAgeSaturatedMinutes`` means "150 minutes or more"
  /// (``isAgeSaturated``).
  ///
  /// Nil when the batch carried no ages — a bot older than revision 5 — which is *not* 0: "this
  /// station's report is the batch time" and "the batch does not say" are different answers, and
  /// only the second one leaves a phone guessing.
  public var ageMinutes: UInt16?

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
    feelsDeltaF: Int8 = 0,
    ageMinutes: UInt16? = nil
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
    self.ageMinutes = ageMinutes
  }

  /// Apparent temperature, or nil when the temperature itself is unknown.
  public var feelsLikeF: Int? {
    tempF.map { Int($0) + Int(feelsDeltaF) }
  }

  /// The age nibble saturated (spec §6.1): this report is 150 minutes old *or more*. The bot
  /// admits stations up to 120 minutes old, so a saturated station is one whose report aged
  /// further while the batch waited.
  public var isAgeSaturated: Bool {
    ageMinutes == MeshWXWire.observationAgeSaturatedMinutes
  }
}

/// A batch of current conditions (type 4, spec §6).
public struct MeshWXObservations: Sendable, Hashable, Codable {
  /// Unix minutes of the *newest* observation in the batch. A station in the same batch may have
  /// filed its METAR up to 120 minutes earlier; from revision 5 each one says by how much
  /// (``MeshWXStationObservation/ageMinutes``), and ``reportMinutes(for:)`` is the time to show.
  public var timestampMinutes: UInt32
  public var stations: [MeshWXStationObservation]

  public init(timestampMinutes: UInt32, stations: [MeshWXStationObservation]) {
    self.timestampMinutes = timestampMinutes
    self.stations = stations
  }

  /// Whether this batch carries per-station ages. All or nothing (spec §6.1): the flag means
  /// every station in the batch has one.
  public var carriesAges: Bool {
    !stations.isEmpty && stations.allSatisfy { $0.ageMinutes != nil }
  }

  /// One station's own report time, in Unix minutes: the batch `ts` less its age (spec §6.1).
  ///
  /// The batch time itself for a batch without ages, which is all such a batch says — and what an
  /// app had to show under every reading before revision 5, wrong about most of them.
  public func reportMinutes(for station: MeshWXStationObservation) -> UInt32 {
    timestampMinutes &- UInt32(station.ageMinutes ?? 0)
  }
}

// MARK: - Forecast

/// One forecast period (spec §7, 5 bytes on the wire).
public struct MeshWXForecastPeriod: Sendable, Hashable, Codable {
  /// Nil when the entry has no high: a whole day whose first half is missing at the edge of the
  /// forecast window (spec §7, revision 3), or a revision 1 night period.
  public var highF: Int8?
  /// Nil when the entry has no low: the edge of the window, or a revision 1 day period.
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
  /// Flags bit 0 (spec §8.1, revision 7): the product ran past ``MeshWXWire/maxTextChunks``
  /// chunks and the bot dropped the tail, cutting at a sentence boundary.
  ///
  /// Set on every chunk of a cut reply, so a phone that never received the last one still knows
  /// the reply is short of the product. It is not the same claim as a missing chunk: a hole is
  /// something the air ate and asking again may fix, while this is the whole reply the bot will
  /// ever send for that request.
  public var wasCut: Bool

  public init(
    subject: MeshWXTextSubject,
    group: UInt8,
    index: UInt8,
    total: UInt8,
    text: String,
    wasCut: Bool = false
  ) {
    self.subject = subject
    self.group = group
    self.index = index
    self.total = total
    self.text = text
    self.wasCut = wasCut
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

// MARK: - Coverage

/// What a bot carries, stated by the bot (type 8, spec §7A).
///
/// The only thing an app may read a bot's area from. Inferring it from the stations in the hourly
/// batches and from the offices of whatever warnings happened to be active told a real phone that
/// WX-AUS "may not carry alerts for Travis County" — the bot's own home county — because the one
/// warning active that minute came from a neighbouring office. The stations are recomputed every
/// hour and warnings come and go; neither describes coverage. This does.
///
/// Read a cut list as incomplete, **never** as a denial: with ``areasCut`` or ``officesCut`` set,
/// an absence means "not listed", and nothing may be called outside the area on the strength of
/// it. With both clear the lists are the whole area, which is what lets an app say a place is
/// outside at all.
public struct MeshWXCoverage: Sendable, Hashable, Codable {
  /// The coverage circle's centre — the bot's home point — in degrees. 0,0 with
  /// ``radiusKilometres`` 0 means no centre was stated; read ``centre``, which is nil for that,
  /// rather than these two.
  public var latitude: Double
  public var longitude: Double
  /// Kilometres. 0 = no circle stated; the area is then whatever the runs list.
  public var radiusKilometres: UInt16
  /// The most stations one hourly Observations batch can carry (13 for WX-AUS, which sends the
  /// per-station ages and pays a station for them — spec §6.1); 0 = this bot broadcasts none. A
  /// cap, not a count: the batch is rebuilt every hour (spec §6), so a count would describe this
  /// hour rather than the coverage.
  public var stationCap: UInt8
  /// Indices into `index.json` `offices`, ascending: every office whose zones the bot covers,
  /// plus any the operator named outright.
  public var officeIndices: [UInt8]
  /// The forecast zones (or counties) covered, in exactly a Warning's area-run encoding (spec §3).
  public var areas: [MeshWXAreaRun]
  /// Flags bit 0: the runs were cut to fit, so a zone absent from them may still be covered.
  public var areasCut: Bool
  /// Flags bit 1: the office list was cut, so an office absent from it may still be carried.
  public var officesCut: Bool

  public init(
    latitude: Double,
    longitude: Double,
    radiusKilometres: UInt16,
    stationCap: UInt8,
    officeIndices: [UInt8],
    areas: [MeshWXAreaRun],
    areasCut: Bool = false,
    officesCut: Bool = false
  ) {
    self.latitude = latitude
    self.longitude = longitude
    self.radiusKilometres = radiusKilometres
    self.stationCap = stationCap
    self.officeIndices = officeIndices
    self.areas = areas
    self.areasCut = areasCut
    self.officesCut = officesCut
  }

  /// The centre of the coverage circle, or nil when the bot stated none: its area came from
  /// states or offices rather than a circle, and 0,0 is the non-position an advert carries
  /// (spec §1), not the Gulf of Guinea.
  public var centre: MeshWXCoordinate? {
    latitude == 0 && longitude == 0 && radiusKilometres == 0
      ? nil : MeshWXCoordinate(latitude: latitude, longitude: longitude)
  }

  /// Whether the stated circle contains a point.
  ///
  /// False when no circle was stated — which is not "outside": a bot without a centre still
  /// covers whatever its runs list, so callers must go on to ``covers(ugc:states:)``.
  public func circleContains(_ point: MeshWXCoordinate) -> Bool {
    guard let centre, radiusKilometres > 0 else { return false }
    let distance = MeshWXGeo.distanceKilometres(
      fromLat: centre.latitude, lon: centre.longitude, toLat: point.latitude, lon: point.longitude)
    return distance <= Double(radiusKilometres)
  }

  /// Whether a stated run covers a UGC code.
  public func covers(ugc: String, states: [String]) -> Bool {
    areas.contains { $0.covers(ugc: ugc, states: states) }
  }

  /// `n` = 0 and `k` = 0 with neither list cut: the operator set no area filter at all, so the
  /// bot carries every product its feed does and no place is outside it (spec §7A). That is an
  /// answer, not an empty message.
  public var hasNoAreaFilter: Bool {
    officeIndices.isEmpty && areas.isEmpty && isComplete
  }

  /// Whether both lists are whole. Only a complete statement can put a place outside the area.
  public var isComplete: Bool { !areasCut && !officesCut }
}

// MARK: - Request

/// An app's `>` request, flooded on `#meshwx` as a datagram (type 9, spec §7B).
///
/// The one v5 message this app transmits. A DM rides one stored route hop by hop and fails
/// silently once that route has gone stale — the field record of 16 September lost seven
/// requests in six minutes to a bot that was on the air and answering everyone else — while a
/// flood needs no route and costs about what a DM costs by its second try.
///
/// The header fields ride here as well as on ``MeshWXMessage/header``: this is a value the app
/// builds and sends on its own (``encode()``), not only a body the decoder hands back. The two
/// never disagree for a decoded message, and ``MeshWXEncoder/encode(_:)`` writes the header's.
public struct MeshWXRequest: Sendable, Hashable, Codable {
  /// The **sender's** counter, one more per new request and repeated on a resend (spec §7B).
  /// Informational to the bot, which keys copies on ``timestamp``.
  public var seq: UInt8
  /// The bot asked, as in every message: the first two bytes of its public key. `0xFFFF` asks
  /// every bot on the channel.
  public var botID: UInt16
  /// The first six bytes of the sender's public key, in key order — the prefix a DM identifies
  /// the same phone by, so one phone's DM and its datagram are one sender to the bot's limits.
  public var senderPrefix: Data
  /// Unix **seconds** (not minutes) on the sender's clock: the request's own time. A resend
  /// repeats it, and that is what makes it a copy rather than a second request.
  public var timestamp: UInt32
  /// The request exactly as spec §8.2 writes it, starting with `>`.
  public var text: String

  /// Every bot on the channel, for an app that has not chosen one (spec §7B, §12).
  public static let anyBot: UInt16 = 0xFFFF

  public init(seq: UInt8, botID: UInt16, senderPrefix: Data, timestamp: UInt32, text: String) {
    self.seq = seq
    self.botID = botID
    self.senderPrefix = senderPrefix
    self.timestamp = timestamp
    self.text = text
  }

  /// The datagram's bytes, header and all.
  public func encode() throws -> Data {
    try MeshWXEncoder.request(seq: seq, bot: botID, self)
  }
}

// MARK: - Area sweep

/// One packet of an area sweep (type 10, spec §7C).
///
/// The sweep is the answer to one question — *where is anything happening?* — and it is the most
/// expensive answer on the channel: up to eight packets, broadcast to everyone listening. Nothing
/// may ask for one on a timer, on appear or on a pull; only a tap.
///
/// Since revision 10 the question can be asked of a few states rather than of the country
/// (``isScoped``, ``scope``), which is the owner's "that way we don't default to sending
/// everything". A scoped sweep is not a smaller national one: the states it does not name are
/// **unknown**, never clear.
///
/// Reassemble by `(bot, group)` in ``index`` order exactly as a Text reply is (spec §8.1). A
/// packet that never arrives leaves a hole: draw the entries that did arrive and say the sweep is
/// partial, because a map of forty states is still worth looking at. Since revision 10 the packets
/// that never arrived can also be asked for by name (`>part`), which is the one repair that costs
/// three packets instead of eight.
public struct MeshWXAreaSweep: Sendable, Hashable, Codable {
  /// One run of consecutive UGC numbers in one state, under one event (spec §7C).
  ///
  /// Four bytes for what a Warning spends four bytes on *without* the event, which is the whole
  /// point: the country's alerts fit in eight packets because a Winter Weather Advisory over
  /// thirty Montana zones is one entry.
  public struct Entry: Sendable, Hashable, Codable {
    /// Event code, from the same `protocol.json` `events` table a Warning uses — so the app's
    /// existing event names, severities and tints apply unchanged.
    public var event: UInt8
    /// Index into `index.json` `states` (bits 7-1 of the wire byte).
    public var stateIndex: UInt8
    /// Bit 0 of the wire byte: county (`C`) rather than forecast zone (`Z`).
    public var isCounty: Bool
    /// First UGC number in the run (bits 0-9 of the wire u16).
    public var start: UInt16
    /// How many consecutive numbers the run covers, 1 to
    /// ``MeshWXWire/maxAreaSweepRun``. Carried less one in bits 10-15.
    public var run: UInt8

    public init(event: UInt8, stateIndex: UInt8, isCounty: Bool, start: UInt16, run: UInt8) {
      self.event = event
      self.stateIndex = stateIndex
      self.isCounty = isCounty
      self.start = start
      self.run = run
    }

    /// The UGC numbers this entry covers.
    public var numbers: [UInt16] {
      guard run > 0 else { return [] }
      return (0..<UInt16(run)).map { start &+ $0 }
    }

    /// Expand to UGC strings (`"TXZ192"`, `"TXC453"`) using `index.json` `states`.
    ///
    /// Empty when the state index is not in the table: an older bundle decoding a newer bot's
    /// sweep should lose the *names*, never the message. A run never crosses a state, so every
    /// code here carries the same two letters.
    public func ugcCodes(states: [String]) -> [String] {
      guard Int(stateIndex) < states.count else { return [] }
      let state = states[Int(stateIndex)]
      let kind = isCounty ? "C" : "Z"
      return numbers.map { "\(state)\(kind)\(MeshWXAreaRun.ugcDigits($0))" }
    }

    /// The same run as a Warning carries it, for anything that already speaks that shape
    /// (`MeshWXTables.namedAreas(for:)`, `MeshWXAreaRun.covers(ugc:states:)`).
    public var areaRun: MeshWXAreaRun {
      MeshWXAreaRun(stateIndex: stateIndex, isCounty: isCounty, start: start, run: run)
    }
  }

  /// Unix **minutes** the bot built the sweep. The age on screen is measured from this and never
  /// from receipt: a sweep drained from the radio's queue an hour late is an hour old.
  public var builtMinutes: UInt32
  /// Shared by every packet of one sweep (the `seq` of its first packet), exactly as Text does.
  public var group: UInt8
  public var index: UInt8
  /// 1 to ``MeshWXWire/maxAreaSweepPackets``: the `total` byte's low nibble
  /// (``MeshWXWire/sweepTotalMask``), bit 7 having become the scope flag in revision 10.
  public var total: UInt8
  /// Flags bit 0: entries were dropped to fit.
  ///
  /// Set on every packet of a cut sweep, so a phone that missed the last one still knows the map
  /// is short of the country. An area absent from a cut sweep is **not** an area with no alert.
  public var wasCut: Bool
  /// Flags bit 1: advisories are in the sweep, not only warnings and watches. Clear does not mean
  /// there are no advisories — it means the narrower scope was asked for.
  public var includesAdvisories: Bool
  /// `total` bit 7 (spec revision 10, §7C): the sweep covers only the states its scope names, not
  /// the country.
  ///
  /// The one field of this type carried on **every** packet that a phone must have before it can
  /// read the map at all: an unshaded state inside the scope has nothing active, and an unshaded
  /// state outside it was never asked about. Getting that backwards paints half the country clear
  /// on the strength of a question nobody asked.
  public var isScoped: Bool
  /// The state indices this packet's scope entries name (spec revision 10, §7C), in the order the
  /// bot sent them.
  ///
  /// Empty for a national sweep, and empty for the packets of a scoped sweep after the first: the
  /// bot writes the scope once, at the head of packet 0. ``isScoped`` is what says the sweep is
  /// scoped; this says *what to*, when the packet carrying it arrived.
  public var scope: [UInt8]
  /// The alert entries, most severe first, as the bot ordered them.
  ///
  /// Alert entries only: a scope entry (event 0) is lifted into ``scope`` by the decoder and put
  /// back, first, by the encoder. Nothing downstream has to know that the scope travels as an
  /// entry, and nothing can mistake `XXZ000` for an area under an alert.
  public var entries: [Entry]

  public init(
    builtMinutes: UInt32,
    group: UInt8,
    index: UInt8,
    total: UInt8,
    wasCut: Bool = false,
    includesAdvisories: Bool = false,
    isScoped: Bool = false,
    scope: [UInt8] = [],
    entries: [Entry]
  ) {
    self.builtMinutes = builtMinutes
    self.group = group
    self.index = index
    self.total = total
    self.wasCut = wasCut
    self.includesAdvisories = includesAdvisories
    self.isScoped = isScoped
    self.scope = scope
    self.entries = entries
  }

  /// A scope entry as the wire carries it (spec revision 10, §7C): `event 0`, kind zone,
  /// `start 0`, `run 1`. One per state named, sorting before every alert entry.
  public static func scopeEntry(stateIndex: UInt8) -> Entry {
    Entry(
      event: MeshWXWire.sweepScopeEvent, stateIndex: stateIndex, isCounty: false, start: 0, run: 1)
  }
}

// MARK: - Radar

/// How hard it is raining (or snowing) in one cell (spec revision 11, §7D).
///
/// Two bits, and the thresholds are the bundle's (`protocol.json` `v5.radar.levels_dbz`): 20 dBZ
/// and up is light, 35 moderate, 50 heavy. A cell carries the **strongest** echo in it rather than
/// an average, so a hail core two kilometres across still reads heavy at seven-kilometre cells.
///
/// ``none`` is "no echo here" only inside a partial tile's ``MeshWXRadarBounds``. Outside them it
/// is the wire's way of writing *unknown* — the quadtree has no fourth value — and nothing may
/// draw those cells as dry (``MeshWXRadar/isUnknown(row:col:)``).
public enum MeshWXRadarLevel: UInt8, Sendable, Hashable, Codable, CaseIterable {
  case none = 0
  case light = 1
  case moderate = 2
  case heavy = 3

  /// Never fails: the field is two bits wide and all four values are defined.
  public init(bits: UInt8) {
    self = MeshWXRadarLevel(rawValue: bits & 0x3) ?? .none
  }

  /// Whether anything is falling in the cell.
  public var isWet: Bool { self != .none }
}

/// The part of a tile a partial radar picture reaches (spec revision 11, §7D).
///
/// Inclusive rows and columns **in the packet's own grid**, so a coarse tile's bounds run 0-15 and
/// a fine one's 0-31. The tile still covers the whole square of earth; these say which of its
/// cells the mosaic had anything to say about.
public struct MeshWXRadarBounds: Sendable, Hashable, Codable {
  public var row0: UInt8
  public var row1: UInt8
  public var col0: UInt8
  public var col1: UInt8

  public init(row0: UInt8, row1: UInt8, col0: UInt8, col1: UInt8) {
    self.row0 = row0
    self.row1 = row1
    self.col0 = col0
    self.col1 = col1
  }

  /// Whether a cell of the packet's grid is inside the picture.
  public func contains(row: Int, col: Int) -> Bool {
    row >= Int(row0) && row <= Int(row1) && col >= Int(col0) && col <= Int(col1)
  }

  /// Whether the bounds describe a real rectangle of a `size` × `size` grid. Checked on both
  /// sides of the wire: a `row1` of 200 would otherwise put every cell "outside the picture".
  public func isInside(size: Int) -> Bool {
    row0 <= row1 && Int(row1) < size && col0 <= col1 && Int(col1) < size
  }

  /// The four bytes as the wire orders them.
  var wireBytes: [UInt8] { [row0, row1, col0, col1] }
}

/// A square of the earth a radar answer covers (spec revision 11, §7D).
///
/// Tiles sit on a fixed lattice of half their span, so a tile one phone asked for is a tile every
/// phone can use: two people a few kilometres apart ask about the same square and the second one
/// costs the channel nothing. The lattice is what makes that true, and ``containing(latitude:longitude:zoom:)``
/// is the whole of it — the same arithmetic in every language a client is written in, ties
/// included.
public struct MeshWXRadarTile: Sendable, Hashable, Codable {
  /// Southern edge, whole degrees.
  public var south: Int
  /// Western edge, whole degrees.
  public var west: Int
  /// 0 to ``MeshWXWire/maxRadarZoom``.
  public var zoom: Int

  public init(south: Int, west: Int, zoom: Int) {
    self.south = south
    self.west = west
    self.zoom = zoom
  }

  /// The tile that answers a coordinate: the one whose **centre** is the nearest lattice point.
  ///
  /// `floor(x / step + 0.5) * step - step`, not a rounding function: `round()` is half-to-even in
  /// Swift and Python and half-away-from-zero in JavaScript, and three clients that disagree about
  /// 30.5 would ask for two different tiles and each pay for one. A tie falls **up** everywhere.
  ///
  /// Centring on the place rather than snapping to a corner is what keeps the asked coordinate at
  /// least a quarter of the span from every edge — 55 km at zoom 0 — so the picture is about the
  /// place and not about the county next door.
  ///
  /// A zoom outside 0…``MeshWXWire/maxRadarZoom`` is clamped rather than refused: this is the
  /// lattice, not a request, and every caller wants a tile back.
  public static func containing(latitude: Double, longitude: Double, zoom: Int) -> MeshWXRadarTile {
    let level = min(max(zoom, 0), Int(MeshWXWire.maxRadarZoom))
    let step = Double(1 << level)
    func origin(_ value: Double) -> Int {
      Int((value / step + 0.5).rounded(.down) * step - step)
    }
    return MeshWXRadarTile(south: origin(latitude), west: origin(longitude), zoom: level)
  }

  /// How many degrees the tile spans on each side: 2, 4, 8, 16.
  public var spanDegrees: Int { 1 << (zoom + 1) }

  public var north: Int { south + spanDegrees }
  public var east: Int { west + spanDegrees }

  /// One cell's width in degrees, for a grid of `size` cells a side.
  public func cellDegrees(size: Int) -> Double {
    size > 0 ? Double(spanDegrees) / Double(size) : 0
  }

  /// Whether a coordinate is in the tile. Half-open on the north and east edges, so two
  /// neighbouring tiles never both claim a point.
  public func contains(latitude: Double, longitude: Double) -> Bool {
    latitude >= Double(south) && latitude < Double(north)
      && longitude >= Double(west) && longitude < Double(east)
  }

  /// The patch of earth one cell covers. Row 0 is the **northern** row and column 0 the western
  /// one (spec revision 11, §7D), which is the picture's order and not the lattice's.
  public func cellBox(row: Int, col: Int, size: Int) -> (south: Double, west: Double, north: Double, east: Double) {
    let cell = cellDegrees(size: size)
    let top = Double(north) - Double(row) * cell
    let left = Double(west) + Double(col) * cell
    return (south: top - cell, west: left, north: top, east: left + cell)
  }

  /// The cell a coordinate falls in, or nil when it is outside the tile.
  ///
  /// Clamped into the grid after the division: a coordinate a hair inside the northern edge can
  /// otherwise land on row −0 through floating point, and an out-of-range index here would be an
  /// index into somebody's cell array.
  public func cell(latitude: Double, longitude: Double, size: Int) -> (row: Int, col: Int)? {
    guard size > 0, contains(latitude: latitude, longitude: longitude) else { return nil }
    let cell = cellDegrees(size: size)
    let row = Int(((Double(north) - latitude) / cell).rounded(.down))
    let col = Int(((longitude - Double(west)) / cell).rounded(.down))
    return (row: min(max(row, 0), size - 1), col: min(max(col, 0), size - 1))
  }
}

/// One tile of a radar picture (type 11, spec revision 11, §7D).
///
/// **One packet, always.** Radar was in the v4 protocol and was taken out on 14 September because
/// it pulled a four-megabyte composite off the internet for every answer; revision 11 brings it
/// back cut from the mosaics the dish already receives, as a quadtree of two-bit levels that fits
/// a 165-byte datagram — 131 bytes for Dallas under a squall line, 13 for a clear tile. When the
/// fine picture does not fit, the same tile goes out at half the detail (``isCoarse``) rather than
/// in two packets: there is no `>part` for radar and never will be.
public struct MeshWXRadar: Sendable, Hashable, Codable {
  /// Unix minutes: the time **printed on the radar picture**. Not when the bot received the
  /// mosaic, not when it sent the packet. The age on screen is measured from this, so a tile
  /// drained from the radio's queue an hour late is an hour older than it looks.
  public var takenMinutes: UInt32
  /// The tile's southern edge, whole degrees.
  public var south: Int8
  /// The tile's western edge, whole degrees (−180 to 179).
  public var west: Int16
  /// 0 to ``MeshWXWire/maxRadarZoom``, from the shape byte's low two bits.
  public var zoom: UInt8
  /// Which mosaic the tile was cut from: an index into `protocol.json` `v5.radar.products`.
  public var product: UInt8
  /// Flags bit 0: the grid is 16 × 16, not 32 × 32.
  public var isCoarse: Bool
  /// Flags bit 1: the picture reaches only these rows and columns. Nil means the whole tile is
  /// inside it, which is the ordinary case.
  public var bounds: MeshWXRadarBounds?
  /// The grid, row-major, **north row first and west column first**, `size * size` of them, each
  /// 0 to 3. Kept as the raw levels rather than as ``MeshWXRadarLevel`` so a decode and re-encode
  /// is byte-identical whatever a future bot puts in the two bits.
  public var cells: [UInt8]

  public init(
    takenMinutes: UInt32,
    south: Int8,
    west: Int16,
    zoom: UInt8,
    product: UInt8,
    isCoarse: Bool,
    bounds: MeshWXRadarBounds? = nil,
    cells: [UInt8]
  ) {
    self.takenMinutes = takenMinutes
    self.south = south
    self.west = west
    self.zoom = zoom
    self.product = product
    self.isCoarse = isCoarse
    self.bounds = bounds
    self.cells = cells
  }

  /// Cells along one side: 16 when coarse, else 32.
  public var size: Int { isCoarse ? MeshWXWire.radarCoarseGrid : MeshWXWire.radarGrid }

  /// The square of earth this is a picture of.
  public var tile: MeshWXRadarTile {
    MeshWXRadarTile(south: Int(south), west: Int(west), zoom: Int(zoom))
  }

  /// The level of one cell, or ``MeshWXRadarLevel/none`` for an index off the grid.
  public func level(row: Int, col: Int) -> MeshWXRadarLevel {
    guard row >= 0, col >= 0, row < size, col < size else { return .none }
    let index = row * size + col
    guard cells.indices.contains(index) else { return .none }
    return MeshWXRadarLevel(bits: cells[index])
  }

  /// Whether a cell is outside the radar picture, so its level 0 means *unknown* rather than dry
  /// (spec revision 11, §7D). Always false for a whole tile.
  public func isUnknown(row: Int, col: Int) -> Bool {
    guard let bounds else { return false }
    return !bounds.contains(row: row, col: col)
  }

  /// How many cells carry precipitation. The channel traffic row's number, and the one measure of
  /// a tile that means the same thing at both grid sizes.
  public var wetCellCount: Int {
    cells.reduce(0) { $0 + ($1 & 0x3 != 0 ? 1 : 0) }
  }

  /// A 32 × 32 grid as 16 × 16, each coarse cell the **highest** of the four it replaces — the
  /// reference's `radar_coarsen`, and what a bot does when the fine tile does not fit.
  ///
  /// Here rather than on the bot's side alone because the app's own tests fabricate tiles, and a
  /// coarsening that disagreed with the bot's would make every coarse vector fail for the wrong
  /// reason. Returns the cells unchanged for a grid that is already coarse.
  public static func coarsened(cells: [UInt8], size: Int) -> [UInt8] {
    guard size > 1, cells.count == size * size else { return cells }
    let half = size / 2
    var out = [UInt8](repeating: 0, count: half * half)
    for row in 0..<half {
      for col in 0..<half {
        let top = 2 * row * size + 2 * col
        let bottom = (2 * row + 1) * size + 2 * col
        out[row * half + col] = max(
          max(cells[top], cells[top + 1]), max(cells[bottom], cells[bottom + 1]))
      }
    }
    return out
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
  case coverage(MeshWXCoverage)
  /// An app's request (spec §7B). Only ever *heard* from another phone on the channel: this
  /// app sends its own and never acts on somebody else's.
  case request(MeshWXRequest)
  /// One packet of a national area sweep (spec §7C).
  case areaSweep(MeshWXAreaSweep)
  /// One tile of a radar picture (spec revision 11, §7D).
  case radar(MeshWXRadar)
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
