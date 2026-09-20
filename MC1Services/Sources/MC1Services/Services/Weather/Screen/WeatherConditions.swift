import Foundation
import MeshWX

/// A weather station near the place that the phone holds no good reading from ("Luis Munoz Marin
/// International Airport, 11 km"): the one station worth asking for by its code.
public struct WeatherNearbyStation: Sendable, Hashable {
  public var icao: String
  public var name: String
  public var kilometres: Double

  public init(icao: String, name: String, kilometres: Double) {
    self.icao = icao
    self.name = name
    self.kilometres = kilometres
  }
}

/// What a place's page leads with, and when it leads with nothing (docs/MESHWX_UI.md §8).
///
/// A temperature on the page is a claim about the weather *here*. The owner's threshold decides
/// when that claim can be made: the reading the phone holds must be within
/// ``goodReadingKilometres`` of the place and not stale.
///
/// Past that, up to ``labelledReadingKilometres``, a fresh reading is still shown, **attributed to
/// its station** — "Nearest report: San Marcos, 26 km away" — rather than passed off as the town's
/// (owner decision 2026-09-18, docs/MESHWX_UI.md §3.1 U-2a). Wimberley's nearest station is 25.5 km
/// off: under a hard 25 km cliff its page asked, the answer arrived, and the page threw it away.
/// Further than that, or three hours old, a reading answers a different question and the page
/// shows the ask instead, naming the station a refresh would spend airtime on — or, when no
/// station is close enough for its answer to be shown, says so and asks for nothing.
///
/// ``WeatherUpdatePlan`` reads its readings step **off this verdict**, so the sentence on the page
/// and the packet on the air are always the same station. They used to be worked out twice, and
/// the two drifted: the page offered to ask about a station while Update called it current.
public enum WeatherConditions: Sendable, Hashable {
  /// A good reading: this is the weather here.
  case reading(WeatherStationReading)
  /// A fresh reading too far off to be the weather here but near enough to show, under its
  /// station's name and distance. `nearer` is a closer bundled station worth asking by code: the
  /// page shows what it holds, and Update asks for something better.
  case nearby(WeatherStationReading, nearer: WeatherNearbyStation?)
  /// No good reading, and a station to ask about by code.
  case ask(icao: String, kilometres: Double?)
  /// Nothing has ever arrived: the hourly batch is what fills this in, and it is not a place
  /// problem.
  case noneYet
  /// No station near enough to ask about, with the nearest one there is for naming it.
  case noStation(nearest: WeatherStationReading?)
  case noPlace

  /// **Tunable** (docs/MESHWX_UI.md §8): how close a reading has to be to speak for the place.
  /// Readings reach 80 km (``WeatherPrimaryStation/maxDistanceKilometres``) for the stations list
  /// and for what a Places row shows; this is the narrower distance at which the page is willing
  /// to print one number and call it the temperature here.
  public static let goodReadingKilometres = 25.0

  /// **Tunable** (docs/MESHWX_UI.md §3.1 U-2a): how close a reading has to be to be shown at all,
  /// attributed to its station, when it is too far to be the temperature here. Also the furthest
  /// the page will spend a packet on: asking a station further than this would bring back a
  /// reading the page will not show.
  public static let labelledReadingKilometres = 40.0

  /// The station whose reading is on the page, when one is.
  public var reading: WeatherStationReading? {
    switch self {
    case let .reading(reading), let .nearby(reading, _): reading
    default: nil
    }
  }

  /// **The one rule**, for the page and for a Places row alike (docs/MESHWX_UI.md §3.1 U-2): a
  /// reading speaks for a place when it is within ``goodReadingKilometres`` of it and is not
  /// stale.
  ///
  /// The row used to reach 80 km and show anything it found, so Places read "86° Partly cloudy ·
  /// 3 h old" for a place whose own page said "No current conditions" — the list and the page
  /// contradicting each other about the same town, one tap apart.
  public static func isGood(kilometres: Double?, isStale: Bool) -> Bool {
    guard let kilometres, !isStale else { return false }
    return kilometres <= goodReadingKilometres
  }

  /// A reading the page will show at all: good, or fresh and within ``labelledReadingKilometres``
  /// to be shown under its station's name. The same rule for a Places row.
  public static func isShowable(kilometres: Double?, isStale: Bool) -> Bool {
    guard let kilometres, !isStale else { return false }
    return kilometres <= labelledReadingKilometres
  }

  public static func make(
    primary: WeatherPrimaryStation,
    nearbyStation: WeatherNearbyStation?
  ) -> WeatherConditions {
    switch primary {
    case let .reading(reading):
      let kilometres = reading.distanceKilometres ?? .infinity
      if isGood(kilometres: reading.distanceKilometres, isStale: reading.isStale) { return .reading(reading) }
      // Too far to speak for the place: asking that same station again would not bring it closer,
      // so a nearer bundled station is the one worth a packet — while its answer could be shown.
      let nearer = nearbyStation.flatMap { station in
        station.icao != reading.station.icao && kilometres > goodReadingKilometres
          && station.kilometres <= labelledReadingKilometres ? station : nil
      }
      // Fresh and near enough to show: shown under its own name, never as the town's.
      if isShowable(kilometres: reading.distanceKilometres, isStale: reading.isStale) {
        return .nearby(reading, nearer: nearer)
      }
      if let nearer { return .ask(icao: nearer.icao, kilometres: nearer.kilometres) }
      // Near enough to show once it is fresh: the station itself is the one to ask about again.
      if kilometres <= labelledReadingKilometres {
        return .ask(icao: reading.station.icao, kilometres: reading.distanceKilometres)
      }
      // Nothing close enough for an answer to be shown: say so, and spend nothing.
      return .noStation(nearest: reading)
    case let .noneNearby(nearest):
      guard let nearbyStation, nearbyStation.kilometres <= labelledReadingKilometres else {
        return .noStation(nearest: nearest)
      }
      return .ask(icao: nearbyStation.icao, kilometres: nearbyStation.kilometres)
    case .noObservations:
      return .noneYet
    case .noPlace:
      return .noPlace
    }
  }
}

/// What a Places row shows for its place (docs/MESHWX_UI.md §12): the reading the place's own
/// page would lead with, and "—" when that page would lead with nothing.
///
/// It is **the same rule as the page's** (``WeatherConditions/isGood(kilometres:isStale:)``).
/// The row used to reach 80 km and show whatever it found, stale or not, so the list and the page
/// said different things about the same town one tap apart (docs/MESHWX_UI.md §3.1 U-2). A row is
/// a hint, but a hint that contradicts the page it opens is worse than no hint.
public struct WeatherPlaceRowReading: Sendable, Hashable {
  public var tempF: Int8?
  public var sky: MeshWXSky?
  /// The reading's own time, on the bot's clock.
  public var observedAt: Date?
  public var isStale: Bool
  /// The station's name when the reading is shown attributed to it — further than
  /// ``WeatherConditions/goodReadingKilometres`` — exactly as the page attributes it. Nil for a
  /// reading that is the weather here.
  public var attributedStation: String?

  public init(
    tempF: Int8? = nil, sky: MeshWXSky? = nil, observedAt: Date? = nil, isStale: Bool = false,
    attributedStation: String? = nil
  ) {
    self.tempF = tempF
    self.sky = sky
    self.observedAt = observedAt
    self.isStale = isStale
    self.attributedStation = attributedStation
  }

  /// Nothing is held for this place: the row reads "—" rather than a bare degree sign.
  public var isEmpty: Bool { observedAt == nil }

  public static func make(
    readings: [WeatherStationReading],
    at coordinate: MeshWXCoordinate,
    now: Date
  ) -> WeatherPlaceRowReading {
    guard let near = WeatherStations.nearestReading(
      in: readings, to: coordinate, within: WeatherConditions.labelledReadingKilometres),
      WeatherConditions.isShowable(kilometres: near.kilometres, isStale: near.reading.stored.isStale(at: now))
    else {
      return WeatherPlaceRowReading()
    }
    let observation = near.reading.stored.observation
    return WeatherPlaceRowReading(
      tempF: observation.tempF,
      // No cloud or weather group in the report: no condition word rather than a made-up sky.
      sky: observation.sky == .other ? nil : observation.sky,
      observedAt: near.reading.stored.observedAt,
      isStale: near.reading.stored.isStale(at: now),
      attributedStation: near.kilometres > WeatherConditions.goodReadingKilometres
        ? WeatherNames.stationName(near.reading.station.name) : nil)
  }
}

/// A place the phone holds nothing for: no reading good enough to be its temperature (§8) **and**
/// no forecast for its point (§9).
///
/// The Llano page was three separate refusals stacked down the screen — a blocked-request caption,
/// "No current conditions for Llano…", "No forecast for Llano yet…" — which reads as the app
/// failing three times rather than as one place the channel has not carried yet. The 25 km rule
/// that produces them is unchanged and is not the complaint (docs/MESHWX_UI.md §3.1 U-13); this is
/// what the page says when every part of it would say no.
public struct WeatherEmptyPlace: Sendable, Hashable {
  /// The airport code a refresh would ask about, when there is a station worth asking about.
  public var stationICAO: String?
  public var stationKilometres: Double?
  /// The forecast point a refresh would ask about, when one is in reach.
  public var pointName: String?
  public var pointKilometres: Double?
  /// A refresh would ask for a forecast, whether or not it can name a point: since revision 10
  /// a place with no bundled point in reach is asked about by coordinate (spec revision 10,
  /// §1.3), so "no point to name" is no longer "nothing to ask for".
  public var canAskForecast: Bool

  public init(
    stationICAO: String? = nil,
    stationKilometres: Double? = nil,
    pointName: String? = nil,
    pointKilometres: Double? = nil,
    canAskForecast: Bool = false
  ) {
    self.stationICAO = stationICAO
    self.stationKilometres = stationKilometres
    self.pointName = pointName
    self.pointKilometres = pointKilometres
    self.canAskForecast = canAskForecast
  }

  /// Nothing near enough to spend airtime on: the card says so instead of offering an ask that
  /// would come back empty.
  public var hasNothingToAsk: Bool { stationICAO == nil && pointName == nil && !canAskForecast }

  /// Nil unless the page would say no to both the weather and the forecast. A page with either
  /// one keeps the two sections it has always had.
  public static func make(
    conditions: WeatherConditions,
    forecast: WeatherForecastCard
  ) -> WeatherEmptyPlace? {
    switch conditions {
    case .reading, .nearby, .noPlace: return nil
    case .ask, .noneYet, .noStation: break
    }
    var empty = WeatherEmptyPlace()
    if case let .ask(icao, kilometres) = conditions {
      empty.stationICAO = icao
      empty.stationKilometres = kilometres
    }
    switch forecast {
    case .noPlace, .forecast:
      return nil
    case let .missing(point, kilometres):
      // Since revision 10 an empty card can have no bundled point to name and still have an ask:
      // `>f <lat>,<lon>` goes out for the place's own coordinate (spec revision 10, §1.3). The
      // card then names no point — there is none to name — but it is not nothing to ask for, so
      // ``hasNothingToAsk`` stops speaking for the forecast and the page keeps its Update.
      empty.pointName = point?.name
      empty.pointKilometres = kilometres
      empty.canAskForecast = true
    }
    return empty
  }
}
