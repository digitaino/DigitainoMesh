import Foundation

/// The MeshWX v5 request grammar (spec §8.2), one case per line of the table, with the text
/// the bot parses and the answer the app should wait for.
///
/// Requests are plain text starting with `>`. The bot takes them as a DM or as text on
/// `#meshwx`; the app sends a DM, which only the addressed bot can read, so exactly one bot
/// answers (spec §8.2, §12, revision 2). The same words without the prefix are what people type
/// in the bot's chat and get a text reply for; the prefix is what turns the answer into v5
/// messages on `#meshwx` for every listening app. Identities
/// and codes are carried as the strings the bot expects (`SV.W.EWX.42`, `TXC453`, `KAUS`,
/// `EWX`); the caller renders them from the bundle tables, so this type stays free of the
/// wire tables and of anything the UI would have to localise.
public enum WeatherRequest: Sendable, Hashable, Codable {
  /// `>d` — the active-warning digest.
  case digest
  /// `>w` — every active warning in coverage (at most 6, newest first), then a digest.
  case activeWarnings
  /// `>w SV.W.EWX.42` — one warning by identity (`event.office.etn`), or Not available. No
  /// digest follows.
  case warning(identity: String)
  /// `>w TXC453` / `>w TXZ192` — every active warning whose area list names that county or zone
  /// exactly (at most 6). No digest follows. Storm-based warnings carry county codes, most other
  /// products zone codes, so a county finds no watch or advisory (spec §8.2).
  case warningsTouching(ugc: String)
  /// `>wt SV.W.EWX.42` — a warning's narrative as text, subject 0.
  case warningText(identity: String)
  /// `>o` — observations for the coverage stations: a batch of one when only one reported.
  case observations
  /// `>o KAUS` — one station.
  case observation(station: String)
  /// `>f` — the forecast for the bot's home point.
  case homeForecast
  /// `>f 102` — the forecast for a bundled point index. It comes back under that index when the
  /// forecast is at the point's coordinates (spec §7, revision 3; a revision 2 bot could use
  /// another index with the same coordinates); a nearby point within 80 km carries its own
  /// index, and a place with no bundled point `0xFFFF`.
  case forecast(point: UInt16)
  /// `>f round rock tx` — the forecast for a place the bot resolves (the reply's `point` may
  /// be `0xFFFF`, in which case the request itself is the label).
  case forecastForPlace(String)
  /// `>f 35.687,-105.938` — the forecast for a coordinate, from the nearest point the **bot**
  /// holds one for (spec revision 10, §1.3). Three decimals, recognised by the comma.
  ///
  /// The ask that exists because the bundle was not the authority it was being treated as.
  /// `pfm_points.json` version 1 was built from one day's products and has no point at all for
  /// nine offices — ABQ, AFC, BOU, GUM, HFO, PIH, PPG, PQE, PQW — so the app asked for nothing
  /// in Santa Fe while the bot held a forecast fifteen kilometres away, and the owner could see
  /// it: "Forecast works in chat (`forecast santa fe nm`) but not in the app. I thought we were
  /// using the same engine." Version 2 of the bundle fills those points in; this case is the
  /// other half, so the app stops depending on the bundle being complete at all.
  case forecastAt(latitude: Double, longitude: Double)
  /// `>afd EWX` — the office's forecast discussion, text subject 1.
  case forecastDiscussion(office: String)
  /// `>space` — space weather, text subject 2.
  case spaceWeather
  /// `>storm TX` — storm reports, text subject 3.
  case stormReports(state: String)
  /// `>rain TX` — rainfall totals, text subject 4.
  case rainfall(state: String)
  /// `>metar KAUS` — the raw METAR, text subject 5.
  case metar(station: String)
  /// `>taf KAUS` — the raw TAF, text subject 5.
  case taf(station: String)
  /// `>hwo` — the hazardous weather outlook, text subject 6.
  case hazardousOutlook
  /// `>cov` — what the bot carries, stated by the bot (spec §7A, §8.2). The statement otherwise
  /// arrives only on the three-hourly broadcast, so a phone that has just opened the tool cannot
  /// tell "outside the area" from "nothing said yet" until one does — and withholds both the
  /// check and the out-of-area requests meanwhile (docs/MESHWX_UI.md §6, §11.1).
  case coverage
  /// `>wmap` / `>wmap all` / `>wmap TXOK` / `>wmap all TXOK` — every area under an alert, as an
  /// Area sweep of at most eight packets (spec §7C).
  ///
  /// The most expensive request in the grammar, and the only one whose cost is stated on the
  /// button before it is spent (docs/MESHWX_UI.md §17). `includesAdvisories` sends `>wmap all`,
  /// which widens the sweep from warnings and watches to advisories as well — more shaded, and
  /// more of the eight packets used.
  ///
  /// `states` empty is the whole country, as in revision 9. Otherwise it is up to
  /// ``MeshWXWire/maxSweepScopeStates`` two-letter codes, **sorted and upper case** — the order
  /// is part of the value, because two selections of the same states have to be one request for
  /// the five-minute rule and one row in the log. Use ``sweepStates(_:)`` rather than building
  /// the array by hand.
  case areaSweep(includesAdvisories: Bool, states: [String])
  /// `>part 212 1,4,6` — the packets of a multi-packet answer that never arrived, sent again
  /// (spec revision 10, §1.1).
  ///
  /// The owner's first ask of revision 10, looking at "4 of 7 parts arrived": *should allow me to
  /// re-request the missing data.* Three packets instead of eight, and the bot resends the bytes
  /// it transmitted rather than rebuilding the answer, so what comes back fills the holes in the
  /// assembly already on screen.
  ///
  /// `of` names which kind of answer the group belongs to. It is **for the log's wording only** —
  /// the wire carries `group` and the indexes and nothing else — so nothing may pair an answer by
  /// it.
  case parts(group: UInt8, indexes: [UInt8], of: WeatherPartsKind)

  /// The DM body, exactly as the bot parses it.
  public var wireText: String {
    switch self {
    case .digest: ">d"
    case .activeWarnings: ">w"
    case let .warning(identity): ">w \(identity)"
    case let .warningsTouching(ugc): ">w \(ugc)"
    case let .warningText(identity): ">wt \(identity)"
    case .observations: ">o"
    case let .observation(station): ">o \(station)"
    case .homeForecast: ">f"
    case let .forecast(point): ">f \(point)"
    case let .forecastForPlace(place): ">f \(place)"
    case let .forecastAt(latitude, longitude):
      ">f \(Self.coordinateKey(latitude: latitude, longitude: longitude))"
    case let .forecastDiscussion(office): ">afd \(office)"
    case .spaceWeather: ">space"
    case let .stormReports(state): ">storm \(state)"
    case let .rainfall(state): ">rain \(state)"
    case let .metar(station): ">metar \(station)"
    case let .taf(station): ">taf \(station)"
    case .hazardousOutlook: ">hwo"
    case .coverage: ">cov"
    case let .areaSweep(includesAdvisories, states):
      // The compact form on purpose (spec revision 10, §1.2): upper case, run together, no
      // separators. Fifteen states are then 30 characters, which is what makes the widest
      // selection fit `maxRequestTextBytes` beside `>wmap all `.
      switch (includesAdvisories, Self.sweepStates(states).joined()) {
      case (false, ""): ">wmap"
      case (true, ""): ">wmap all"
      case let (false, codes): ">wmap \(codes)"
      case let (true, codes): ">wmap all \(codes)"
      }
    case let .parts(group, indexes, _):
      ">part \(group) \(indexes.map(String.init).joined(separator: ","))"
    }
  }

  /// A coordinate as the wire writes it: three decimals, always a `.`, never a thousands
  /// separator. `String(format:)` with no locale is what guarantees the last two — the same
  /// number under a French locale is `35,687`, which the bot would read as two arguments.
  static func degrees(_ value: Double) -> String {
    String(format: "%.3f", value)
  }

  /// State codes as ``areaSweep(includesAdvisories:states:)`` wants them: upper case, de-duplicated
  /// and sorted, so one selection is one value however the picker handed it over.
  public static func sweepStates(_ states: [String]) -> [String] {
    Array(Set(states.map { $0.uppercased() })).sorted()
  }

  /// The key a `>f <lat>,<lon>` answer is filed under in
  /// ``WeatherBotState/unbundledForecasts``: the coordinate exactly as the wire wrote it,
  /// `"35.687,-105.938"`. It is the question, which is the only name such a forecast has.
  public static func coordinateKey(latitude: Double, longitude: Double) -> String {
    "\(degrees(latitude)),\(degrees(longitude))"
  }

  /// The letter a Not-available reply echoes back (spec §8.3): the ASCII code of the
  /// request's first letter after `>`. Revision 10 adds `p`, for `>part`.
  public var requestLetter: Character {
    // `wireText` always starts with `>` followed by a lowercase ASCII letter.
    wireText[wireText.index(after: wireText.startIndex)]
  }

  /// What the bot sends back when it can serve the request.
  public var expectedReply: WeatherReplyKind {
    switch self {
    case .digest: .digest
    case .activeWarnings: .warnings
    case let .warning(identity): .warning(identity: identity)
    case let .warningsTouching(ugc): .warningsTouching(ugc: ugc)
    case .warningText: .text(subject: WeatherTextSubjectCode.warningNarrative)
    case .observations: .observations(station: nil)
    case let .observation(station): .observations(station: station)
    case .homeForecast: .forecast(point: nil)
    case let .forecast(point): .forecast(point: point)
    case .forecastForPlace: .forecast(point: nil)
    // The bot picks the point (spec revision 10, §1.3), so no index can be checked against the
    // answer here. What the coordinate is for is the *distance* check the service makes on top
    // of this: any point, but only from the bot asked, and only within
    // `WeatherService.forecastSubstituteKilometres` of what was asked about.
    case .forecastAt: .forecast(point: nil)
    case .forecastDiscussion: .text(subject: WeatherTextSubjectCode.forecastDiscussion)
    case .spaceWeather: .text(subject: WeatherTextSubjectCode.spaceWeather)
    case .stormReports: .text(subject: WeatherTextSubjectCode.stormReports)
    case .rainfall: .text(subject: WeatherTextSubjectCode.rainfall)
    case .metar, .taf: .text(subject: WeatherTextSubjectCode.metarTaf)
    case .hazardousOutlook: .text(subject: WeatherTextSubjectCode.hazardousOutlook)
    case .coverage: .coverage
    case .areaSweep: .areaSweep
    case let .parts(group, _, _): .parts(group: group)
    }
  }

  /// Whether another bot's message carrying exactly what was asked for settles it.
  ///
  /// Only the addressed bot answers a DM (spec §12, revision 2), so this is not about who
  /// answers: another bot's broadcast, or its answer to somebody else, can carry the very thing
  /// asked for — the forecast for point 102, the reading for KAUS, warning SV.W.EWX.42, the
  /// discussion for EWX — and then there is nothing left to wait for. What describes one bot's
  /// area (the alert list, the coverage batch, the outlook, the home forecast) and a place the bot
  /// resolves for itself settle only from the bot asked.
  public var acceptsAnswerFromAnyBot: Bool {
    switch self {
    case .forecast, .forecastDiscussion, .stormReports, .rainfall, .metar, .taf, .observation, .warning, .spaceWeather:
      true
    // A narrative names its event and areas but not its office or tracking number, so only the
    // bot asked can vouch that the text is for the warning asked about. A coverage statement
    // describes the bot that sent it and nothing else, so another bot's says nothing about this
    // one's area. A sweep is one bot's reading of the country — what it carries, and how far its
    // own feed reaches — and a second bot's sweep may be cut somewhere else entirely, so only the
    // bot asked settles this one.
    //
    // `>part` names a `group` byte, which is one bot's counter and means nothing on another's:
    // group 212 from a second bot is a different answer entirely, and taking it for this one
    // would merge two bots' packets into one assembly. `>f <lat>,<lon>` is a place the bot
    // resolves for itself, exactly as `>f <place>` is.
    case .digest, .activeWarnings, .warningsTouching, .warningText, .observations, .homeForecast, .forecastForPlace,
      .forecastAt, .hazardousOutlook, .coverage, .areaSweep, .parts:
      false
    }
  }
}

/// Which kind of multi-packet answer a `>part` request is repairing (spec revision 10, §1.1).
///
/// The wire carries a `group` byte and nothing else, so this is never used to pair an answer: it
/// is what lets the request log say "the alert map" or "the storm reports" rather than "group
/// 212", and what the parts offer carries out of the assembly it was built from.
public enum WeatherPartsKind: Sendable, Hashable, Codable {
  /// An Area sweep (type 10) — a map missing some of its packets.
  case areaSweep
  /// A Text reply (type 6) — a report missing a chunk. The subject is the wire code
  /// (``WeatherTextSubjectCode``), so this file still needs no tables.
  case text(subject: UInt8)
}

// MARK: - Codable

/// Decoding by hand, encoding by synthesis, and the two agree byte for byte.
///
/// A `WeatherRequest` is persisted in two places a phone already has on disk: the request log
/// (`WeatherRequestLogEntry`) and the weather state (`WeatherTextAssembly.request`,
/// `WeatherAreaSweepAssembly.request`). Revision 10 gave ``WeatherRequest/areaSweep(includesAdvisories:states:)``
/// a second associated value, and the compiler's own decoder would then refuse every file written
/// before it — taking the whole state file with it, because one unreadable field fails the decode
/// of everything around it.
///
/// So the decoder is written out: it is the synthesized one, case for case and key for key, with
/// `states` read as absent-means-national. `encode(to:)` is still synthesized (declaring only
/// `init(from:)` leaves the other requirement to the compiler), which is what keeps the two
/// halves from drifting: there is no second place to spell a key wrong.
///
/// The shape, for the JavaScript port (`meshwx/web/docs/PORTING.md`): one key, the case name,
/// holding an object of the labelled values — `{"areaSweep":{"includesAdvisories":false,"states":["OK","TX"]}}`,
/// `{"digest":{}}`, and `{"forecastForPlace":{"_0":"round rock tx"}}` for the one unlabelled case.
extension WeatherRequest {
  private enum CodingKeys: String, CodingKey {
    case digest, activeWarnings, warning, warningsTouching, warningText, observations, observation,
      homeForecast, forecast, forecastForPlace, forecastAt, forecastDiscussion, spaceWeather,
      stormReports, rainfall, metar, taf, hazardousOutlook, coverage, areaSweep, parts
  }

  private enum IdentityKeys: String, CodingKey { case identity }
  private enum UGCKeys: String, CodingKey { case ugc }
  private enum StationKeys: String, CodingKey { case station }
  private enum PointKeys: String, CodingKey { case point }
  private enum PlaceKeys: String, CodingKey { case _0 }
  private enum CoordinateKeys: String, CodingKey { case latitude, longitude }
  private enum OfficeKeys: String, CodingKey { case office }
  private enum StateKeys: String, CodingKey { case state }
  private enum AreaSweepKeys: String, CodingKey { case includesAdvisories, states }
  private enum PartsKeys: String, CodingKey { case group, indexes, of }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.allKeys.count == 1, let key = container.allKeys.first else {
      throw DecodingError.dataCorrupted(DecodingError.Context(
        codingPath: container.codingPath,
        debugDescription: "a WeatherRequest is exactly one case key, not \(container.allKeys.count)"))
    }
    switch key {
    case .digest: self = .digest
    case .activeWarnings: self = .activeWarnings
    case .warning:
      self = .warning(identity: try container.nestedContainer(keyedBy: IdentityKeys.self, forKey: key)
        .decode(String.self, forKey: .identity))
    case .warningsTouching:
      self = .warningsTouching(ugc: try container.nestedContainer(keyedBy: UGCKeys.self, forKey: key)
        .decode(String.self, forKey: .ugc))
    case .warningText:
      self = .warningText(identity: try container.nestedContainer(keyedBy: IdentityKeys.self, forKey: key)
        .decode(String.self, forKey: .identity))
    case .observations: self = .observations
    case .observation:
      self = .observation(station: try container.nestedContainer(keyedBy: StationKeys.self, forKey: key)
        .decode(String.self, forKey: .station))
    case .homeForecast: self = .homeForecast
    case .forecast:
      self = .forecast(point: try container.nestedContainer(keyedBy: PointKeys.self, forKey: key)
        .decode(UInt16.self, forKey: .point))
    case .forecastForPlace:
      self = .forecastForPlace(try container.nestedContainer(keyedBy: PlaceKeys.self, forKey: key)
        .decode(String.self, forKey: ._0))
    case .forecastAt:
      let nested = try container.nestedContainer(keyedBy: CoordinateKeys.self, forKey: key)
      self = .forecastAt(
        latitude: try nested.decode(Double.self, forKey: .latitude),
        longitude: try nested.decode(Double.self, forKey: .longitude))
    case .forecastDiscussion:
      self = .forecastDiscussion(office: try container.nestedContainer(keyedBy: OfficeKeys.self, forKey: key)
        .decode(String.self, forKey: .office))
    case .spaceWeather: self = .spaceWeather
    case .stormReports:
      self = .stormReports(state: try container.nestedContainer(keyedBy: StateKeys.self, forKey: key)
        .decode(String.self, forKey: .state))
    case .rainfall:
      self = .rainfall(state: try container.nestedContainer(keyedBy: StateKeys.self, forKey: key)
        .decode(String.self, forKey: .state))
    case .metar:
      self = .metar(station: try container.nestedContainer(keyedBy: StationKeys.self, forKey: key)
        .decode(String.self, forKey: .station))
    case .taf:
      self = .taf(station: try container.nestedContainer(keyedBy: StationKeys.self, forKey: key)
        .decode(String.self, forKey: .station))
    case .hazardousOutlook: self = .hazardousOutlook
    case .coverage: self = .coverage
    case .areaSweep:
      let nested = try container.nestedContainer(keyedBy: AreaSweepKeys.self, forKey: key)
      self = .areaSweep(
        includesAdvisories: try nested.decode(Bool.self, forKey: .includesAdvisories),
        // A revision 9 file names no states, and a revision 9 `>wmap` was the whole country.
        // Absent is national, which is what that request was.
        states: Self.sweepStates(try nested.decodeIfPresent([String].self, forKey: .states) ?? []))
    case .parts:
      let nested = try container.nestedContainer(keyedBy: PartsKeys.self, forKey: key)
      self = .parts(
        group: try nested.decode(UInt8.self, forKey: .group),
        indexes: try nested.decode([UInt8].self, forKey: .indexes),
        of: try nested.decode(WeatherPartsKind.self, forKey: .of))
    }
  }
}

/// The answer a request expects, used to pair a pending request with the message that
/// settles it. Where the request names a station, point, warning or area the answer is checked
/// against it; `nil` accepts any.
public enum WeatherReplyKind: Sendable, Hashable {
  case digest
  /// `>w`: warning messages followed by a digest; either settles.
  case warnings
  /// `>w SV.W.EWX.42`: that warning. No digest follows (spec §8.2).
  case warning(identity: String)
  /// `>w TXC453`: a warning whose area list names that county or zone. No digest follows.
  case warningsTouching(ugc: String)
  case observations(station: String?)
  case forecast(point: UInt16?)
  case text(subject: UInt8)
  /// `>cov`: the bot's statement of its area. It carries no argument to check it against —
  /// a statement is about whichever bot sent it.
  case coverage
  /// `>wmap`: a packet of the area sweep. Neither scope asked for is checked against the answer:
  /// a bot that will not widen to advisories answers the narrow sweep, and one that has only
  /// Texas answers a two-state ask with Texas — both are still the answer to the tap, and the
  /// sweep's own flag and scope entries say what arrived.
  case areaSweep
  /// `>part <group> …`: a packet or chunk of that group, sent again. The **indexes** are not in
  /// here: the reply kind is what pairs a message with a request by shape, and which of the
  /// indexes asked for arrived is checked by the service against the request itself, the way a
  /// text reply's words are (`WeatherService.answers`).
  case parts(group: UInt8)
}

/// Text subjects on the wire (spec §8.1), kept as raw codes here so this file needs no
/// table; the MeshWX codec's enum is the typed form.
public enum WeatherTextSubjectCode {
  public static let warningNarrative: UInt8 = 0
  public static let forecastDiscussion: UInt8 = 1
  public static let spaceWeather: UInt8 = 2
  public static let stormReports: UInt8 = 3
  public static let rainfall: UInt8 = 4
  public static let metarTaf: UInt8 = 5
  public static let hazardousOutlook: UInt8 = 6
  public static let nowcast: UInt8 = 7
  public static let general: UInt8 = 8
}
