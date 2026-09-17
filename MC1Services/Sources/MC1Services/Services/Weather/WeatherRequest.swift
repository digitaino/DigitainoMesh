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
    case let .forecastDiscussion(office): ">afd \(office)"
    case .spaceWeather: ">space"
    case let .stormReports(state): ">storm \(state)"
    case let .rainfall(state): ">rain \(state)"
    case let .metar(station): ">metar \(station)"
    case let .taf(station): ">taf \(station)"
    case .hazardousOutlook: ">hwo"
    case .coverage: ">cov"
    }
  }

  /// The letter a Not-available reply echoes back (spec §8.3): the ASCII code of the
  /// request's first letter after `>`.
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
    case .forecastDiscussion: .text(subject: WeatherTextSubjectCode.forecastDiscussion)
    case .spaceWeather: .text(subject: WeatherTextSubjectCode.spaceWeather)
    case .stormReports: .text(subject: WeatherTextSubjectCode.stormReports)
    case .rainfall: .text(subject: WeatherTextSubjectCode.rainfall)
    case .metar, .taf: .text(subject: WeatherTextSubjectCode.metarTaf)
    case .hazardousOutlook: .text(subject: WeatherTextSubjectCode.hazardousOutlook)
    case .coverage: .coverage
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
    // one's area.
    case .digest, .activeWarnings, .warningsTouching, .warningText, .observations, .homeForecast, .forecastForPlace,
      .hazardousOutlook, .coverage:
      false
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
