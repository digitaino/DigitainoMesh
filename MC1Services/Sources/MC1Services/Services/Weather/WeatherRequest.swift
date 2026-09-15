import Foundation

/// The MeshWX v5 request grammar (spec §8.2), one case per line of the table, with the text
/// the bot parses and the answer the app should wait for.
///
/// Requests are plain-text DMs to the bot starting with `>`. The same words without the
/// prefix are what people type in the bot's chat and get a text reply for; the prefix is
/// what turns the answer into v5 messages on `#meshwx` for every listening app. Identities
/// and codes are carried as the strings the bot expects (`SV.W.EWX.42`, `TXC453`, `KAUS`,
/// `EWX`); the caller renders them from the bundle tables, so this type stays free of the
/// wire tables and of anything the UI would have to localise.
public enum WeatherRequest: Sendable, Hashable, Codable {
  /// `>d` — the active-warning digest.
  case digest
  /// `>w` — every active warning in coverage (at most 6, newest first), then a digest.
  case activeWarnings
  /// `>w SV.W.EWX.42` — one warning by identity (`event.office.etn`).
  case warning(identity: String)
  /// `>w TXC453` / `>w TXZ192` — every active warning touching a county or zone (at most 6).
  case warningsTouching(ugc: String)
  /// `>wt SV.W.EWX.42` — a warning's narrative as text, subject 0.
  case warningText(identity: String)
  /// `>o` — observations for the coverage stations.
  case observations
  /// `>o KAUS` — one station.
  case observation(station: String)
  /// `>f` — the forecast for the bot's home point.
  case homeForecast
  /// `>f 102` — the forecast for a bundled point index.
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
    case .activeWarnings, .warning, .warningsTouching: .warnings
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
    }
  }

  /// Whether another bot's answer to the same question settles it.
  ///
  /// Spec §12: a request naming a place may be answered by the bot nearest that place, and a
  /// forecast for point 102 is the same forecast whoever broadcasts it. The alert list, the
  /// coverage batch and the office outlook describe one bot's area and only that bot answers.
  public var acceptsAnswerFromAnyBot: Bool {
    switch self {
    case .forecast, .forecastForPlace, .forecastDiscussion, .stormReports, .rainfall, .metar, .taf,
      .observation, .warning, .spaceWeather:
      true
    // A narrative names its event and areas but not its office or tracking number, so only the
    // bot asked can vouch that the text is for the warning asked about.
    case .digest, .activeWarnings, .warningsTouching, .warningText, .observations, .homeForecast, .hazardousOutlook:
      false
    }
  }
}

/// The answer a request expects, used to pair a pending request with the message that
/// settles it. Where the request names a station or point the answer is checked against
/// it; `nil` accepts any.
public enum WeatherReplyKind: Sendable, Hashable {
  case digest
  /// One or more warning messages, followed by a digest that ends the reply.
  case warnings
  case observations(station: String?)
  case forecast(point: UInt16?)
  case text(subject: UInt8)
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
