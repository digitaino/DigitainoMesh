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
/// ``goodReadingKilometres`` of the place and not stale. Anything else is no temperature at all —
/// a reading from sixty kilometres away, or three hours old, answers a different question — and
/// the page shows the ask instead, naming the station a refresh would spend airtime on.
///
/// The station named is the one ``WeatherUpdatePlan`` would ask for, so the sentence on the page
/// and the packet on the air are always the same station.
public enum WeatherConditions: Sendable, Hashable {
  /// A good reading: this is the weather here.
  case reading(WeatherStationReading)
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

  /// The station whose reading is on the page, when one is.
  public var reading: WeatherStationReading? {
    guard case let .reading(reading) = self else { return nil }
    return reading
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

  public static func make(
    primary: WeatherPrimaryStation,
    nearbyStation: WeatherNearbyStation?
  ) -> WeatherConditions {
    switch primary {
    case let .reading(reading):
      let kilometres = reading.distanceKilometres ?? .infinity
      if isGood(kilometres: reading.distanceKilometres, isStale: reading.isStale) { return .reading(reading) }
      // Too far to speak for the place: asking that same station again would not bring it closer,
      // so the ask names the nearest bundled station instead — which is what the plan sends.
      if let nearbyStation, nearbyStation.icao != reading.station.icao, kilometres > goodReadingKilometres {
        return .ask(icao: nearbyStation.icao, kilometres: nearbyStation.kilometres)
      }
      // Near enough, but stale: the station itself is the right one to ask about again.
      return .ask(icao: reading.station.icao, kilometres: reading.distanceKilometres)
    case let .noneNearby(nearest):
      guard let nearbyStation else { return .noStation(nearest: nearest) }
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

  public init(tempF: Int8? = nil, sky: MeshWXSky? = nil, observedAt: Date? = nil, isStale: Bool = false) {
    self.tempF = tempF
    self.sky = sky
    self.observedAt = observedAt
    self.isStale = isStale
  }

  /// Nothing is held for this place: the row reads "—" rather than a bare degree sign.
  public var isEmpty: Bool { observedAt == nil }

  public static func make(
    readings: [WeatherStationReading],
    at coordinate: MeshWXCoordinate,
    now: Date
  ) -> WeatherPlaceRowReading {
    guard let near = WeatherStations.nearestReading(
      in: readings, to: coordinate, within: WeatherConditions.goodReadingKilometres),
      WeatherConditions.isGood(kilometres: near.kilometres, isStale: near.reading.stored.isStale(at: now))
    else {
      return WeatherPlaceRowReading()
    }
    let observation = near.reading.stored.observation
    return WeatherPlaceRowReading(
      tempF: observation.tempF,
      // No cloud or weather group in the report: no condition word rather than a made-up sky.
      sky: observation.sky == .other ? nil : observation.sky,
      observedAt: near.reading.stored.observedAt,
      isStale: near.reading.stored.isStale(at: now))
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

  public init(
    stationICAO: String? = nil,
    stationKilometres: Double? = nil,
    pointName: String? = nil,
    pointKilometres: Double? = nil
  ) {
    self.stationICAO = stationICAO
    self.stationKilometres = stationKilometres
    self.pointName = pointName
    self.pointKilometres = pointKilometres
  }

  /// Nothing near enough to spend airtime on: the card says so instead of offering an ask that
  /// would come back empty.
  public var hasNothingToAsk: Bool { stationICAO == nil && pointName == nil }

  /// Nil unless the page would say no to both the weather and the forecast. A page with either
  /// one keeps the two sections it has always had.
  public static func make(
    conditions: WeatherConditions,
    forecast: WeatherForecastCard
  ) -> WeatherEmptyPlace? {
    switch conditions {
    case .reading, .noPlace: return nil
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
      empty.pointName = point.name
      empty.pointKilometres = kilometres
    case .noPointNearby:
      break
    }
    return empty
  }
}
