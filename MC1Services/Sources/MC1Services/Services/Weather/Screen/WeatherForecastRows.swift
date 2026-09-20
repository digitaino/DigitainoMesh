import Foundation
import MeshWX

/// One line of the forecast card, labelled against now (docs/MESHWX_UI.md §9).
public struct WeatherForecastRow: Sendable, Hashable, Identifiable {
  public enum Label: Sendable, Hashable {
    case today
    case tonight
    case tomorrow
    case tomorrowNight
    case day(Date)
    case night(Date)
  }

  public var id: Int
  public var label: Label
  public var highF: Int8?
  public var lowF: Int8?
  public var popPercent: UInt8?
  /// For a row pairing a day with its night: the rain chance shown is the night's.
  public var popIsNight: Bool
  public var sky: MeshWXSky
  /// Draw the night variant of the sky icon.
  public var isNightIcon: Bool
  public var thunder: Bool
  public var wintry: Bool
  public var windy: Bool
  public var fog: Bool
  public var windDirection: MeshWXCompass
  public var windMph: UInt8
}

public enum WeatherForecastRows {
  /// NWS day periods run 6 AM–6 PM and nights 6 PM–6 AM.
  static let dayEndsHour = 18
  static let nightEndsHour = 6

  /// Rows for a forecast, dropping what has already ended. The shape comes from the entries
  /// (`MeshWXForecastLayout`): whole days, spec periods paired day-with-night, or one row per
  /// entry when neither reading can be trusted.
  public static func rows(for forecast: MeshWXForecast, now: Date, calendar: Calendar) -> [WeatherForecastRow] {
    let layout = MeshWXForecastLayout(of: forecast)
    let entries = MeshWXForecastEntry.entries(of: forecast)
    let issueDay = calendar.startOfDay(for: Date(unixMinutes: forecast.issuedMinutes))
    let today = calendar.startOfDay(for: now)

    func date(_ offset: Int) -> Date {
      calendar.date(byAdding: .day, value: offset, to: issueDay) ?? issueDay
    }
    func at(_ hour: Int, _ day: Date) -> Date {
      calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }
    func dayEnded(_ day: Date) -> Bool { now >= at(dayEndsHour, day) }
    func nightEnded(_ day: Date) -> Bool {
      now >= at(nightEndsHour, calendar.date(byAdding: .day, value: 1, to: day) ?? day)
    }
    func wholeDayEnded(_ day: Date) -> Bool { day < today }
    func label(_ day: Date, night: Bool) -> WeatherForecastRow.Label {
      let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
      switch (days, night) {
      case (...0, true): return .tonight
      case (0, false): return .today
      case (1, false): return .tomorrow
      case (1, true): return .tomorrowNight
      case (_, false): return .day(day)
      case (_, true): return .night(day)
      }
    }
    func row(_ id: Int, _ label: WeatherForecastRow.Label, _ period: MeshWXForecastPeriod, night: Bool) -> WeatherForecastRow {
      WeatherForecastRow(
        id: id, label: label, highF: period.highF, lowF: period.lowF, popPercent: period.popPercent,
        popIsNight: night, sky: period.sky, isNightIcon: night, thunder: period.thunder,
        wintry: period.wintry, windy: period.windy, fog: period.fog,
        windDirection: period.windDirection, windMph: period.windMph)
    }

    switch layout {
    case .days:
      return entries.compactMap { entry in
        let day = date(entry.dayOffset)
        guard !wholeDayEnded(day) else { return nil }
        return row(entry.index, label(day, night: false), entry.period, night: false)
      }

    case .mixed:
      return entries.compactMap { entry in
        let day = date(entry.dayOffset)
        let night = entry.isNight ?? false
        guard night ? !nightEnded(day) : !dayEnded(day) else { return nil }
        return row(entry.index, label(day, night: night), entry.period, night: night)
      }

    case .periods:
      var byDay: [Int: (day: MeshWXForecastEntry?, night: MeshWXForecastEntry?)] = [:]
      for entry in entries {
        var slot = byDay[entry.dayOffset] ?? (nil, nil)
        if entry.isNight == true { slot.night = entry } else { slot.day = entry }
        byDay[entry.dayOffset] = slot
      }
      return byDay.keys.sorted().compactMap { offset in
        let day = date(offset)
        let dayPart = byDay[offset]?.day.flatMap { dayEnded(day) ? nil : $0 }
        let nightPart = byDay[offset]?.night.flatMap { nightEnded(day) ? nil : $0 }
        switch (dayPart, nightPart) {
        case (nil, nil):
          return nil
        case let (nil, night?):
          return row(night.index, label(day, night: true), night.period, night: true)
        case let (day?, nil):
          return row(day.index, label(date(offset), night: false), day.period, night: false)
        case let (dayEntry?, nightEntry?):
          return merged(dayEntry, nightEntry, label: label(day, night: false))
        }
      }
    }
  }

  /// A day and its night as one row: the day's high, the night's low, the worse sky, every
  /// hazard flag from either half, the higher rain chance and which half it belongs to.
  static func merged(
    _ day: MeshWXForecastEntry, _ night: MeshWXForecastEntry, label: WeatherForecastRow.Label
  ) -> WeatherForecastRow {
    let dayPop = day.period.popPercent
    let nightPop = night.period.popPercent
    let popIsNight = (nightPop ?? 0) > (dayPop ?? 0) || (dayPop == nil && nightPop != nil)
    let windier = night.period.windMph > day.period.windMph ? night.period : day.period
    return WeatherForecastRow(
      id: day.index,
      label: label,
      highF: day.period.highF,
      lowF: night.period.lowF,
      popPercent: popIsNight ? nightPop : dayPop,
      popIsNight: popIsNight,
      sky: worse(day.period.sky, night.period.sky),
      isNightIcon: false,
      thunder: day.period.thunder || night.period.thunder,
      wintry: day.period.wintry || night.period.wintry,
      windy: day.period.windy || night.period.windy,
      fog: day.period.fog || night.period.fog,
      windDirection: windier.windDirection,
      windMph: windier.windMph
    )
  }

  static func worse(_ lhs: MeshWXSky, _ rhs: MeshWXSky) -> MeshWXSky {
    skyRank(lhs) >= skyRank(rhs) ? lhs : rhs
  }

  static func skyRank(_ sky: MeshWXSky) -> Int {
    switch sky {
    case .thunderstorm: 12
    case .snow: 11
    case .squall: 10
    case .rain: 9
    case .drizzle: 8
    case .fog: 7
    case .sandOrDust, .smoke: 6
    case .mist: 5
    case .haze: 4
    case .overcast: 3
    case .broken: 2
    case .scattered, .few: 1
    case .clear: 0
    case .other: -1
    }
  }
}

/// The Forecast card's content (docs/MESHWX_UI.md §9).
public enum WeatherForecastCard: Sendable, Hashable {
  public struct Summary: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
      /// The forecast point nearest the place.
      case placePoint
      /// Another point's forecast, already held, close enough to stand in.
      case nearbyPoint(kilometres: Double)
      /// A point the **bot** chose, answering a `>f <lat>,<lon>` for this place (spec revision
      /// 10, §1.3). `kilometres` is from the place to the coordinate that was asked about, which
      /// is the only coordinate the phone knows: the point the bot forecast for is not in this
      /// bundle, which is the whole reason the ask exists.
      ///
      /// The card labels it "Forecast point chosen by WX-AUS", because a forecast is for a point
      /// and this page cannot say which one.
      case botChosenPoint(kilometres: Double)
    }

    /// Nil for a forecast the bot resolved to a point this bundle does not carry
    /// (``Source/botChosenPoint(kilometres:)``).
    public var point: MeshWXPoint?
    public var stored: WeatherStoredForecast
    public var botID: UInt16
    public var layout: MeshWXForecastLayout
    public var rows: [WeatherForecastRow]
    public var source: Source
    public var isStale: Bool
    /// How far the point is from the place, in kilometres.
    ///
    /// A forecast is for a *point*, and two towns twenty kilometres apart share one. The header
    /// names the point and this distance whenever the point is not the place itself, so a page
    /// never shows a forecast without saying what it is a forecast of — which is how Round Rock
    /// and Austin came to show the same seven rows with nothing to tell them apart
    /// (docs/MESHWX_UI.md §3.1 U-9).
    public var kilometres: Double

    /// The forecast was answered to a request of this phone's. False for one overheard on the
    /// channel, which the header says (docs/MESHWX_UI.md §3.1 U-14).
    public var isOwn: Bool { stored.requestedHere }
  }

  case noPlace
  /// Nothing held for the place: ask.
  ///
  /// `point` is the bundled point the ask would name, `kilometres` from the place — and **nil**
  /// when the bundle has no point within reach, in which case the ask is
  /// ``WeatherRequest/forecastAt(latitude:longitude:)`` for the place's own coordinate.
  ///
  /// There is no longer a case for "no point nearby, nothing to ask for". `pfm_points.json`
  /// version 1 had no point at all for nine offices, so the app showed "No forecast point near
  /// Albuquerque" and offered nothing while the bot held a forecast fifteen kilometres away —
  /// which is what the owner saw: "Forecast works in chat (`forecast santa fe nm`) but not in the
  /// app. I thought we were using the same engine." Whenever the place has a coordinate there is
  /// something to ask (spec revision 10, §1.3), so this is the only empty card there is.
  case missing(point: MeshWXPoint?, kilometres: Double?)
  case forecast(Summary)

  public static let nearbyPointKilometres = 10.0
  /// How far the coordinate a `>f <lat>,<lon>` asked about may be from a place and still be that
  /// place's forecast (spec revision 10, §1.3).
  ///
  /// Much tighter than ``nearbyPointKilometres`` is generous, and deliberately so: what is held
  /// under a coordinate is a forecast for a point *the phone cannot see*, somewhere near that
  /// coordinate. Ten kilometres of slack for the place plus the bot's own choice is already the
  /// width of a front, and 25 km is where that stops being one weather.
  public static let askedCoordinateKilometres = 25.0

  /// How far the nearest forecast point may be and still stand for the place.
  ///
  /// From the bundle's own density (2026-09-15 kit): measured from every `places.json` entry to
  /// its nearest `pfm_points.json` point, over the 34,556 places with any point within 1,000 km
  /// (Hawaii, American Samoa, Guam and the Northern Marianas had none), the distance was 23 km at
  /// the median, 68 km at p95 and 114 km at p99. The cutoff is that p99, rounded up.
  ///
  /// `pfm_points.json` version 2 (spec revision 10, §1.3) appended eighty-five points for the
  /// nine offices the first cut had none for, and the same measurement now reads 22.5 km at the
  /// median, 62.6 km at p95 and 90.2 km at p99, with 109 of 34,909 places beyond this cutoff.
  /// The number is left where it is: what it decides is not "is there a point" but "is that
  /// point's forecast this place's weather", and that did not change when the bundle grew.
  ///
  /// A place beyond it is no longer a place with nothing to ask for. It is asked about by
  /// coordinate (``WeatherRequest/forecastAt(latitude:longitude:)``), because the bundle was
  /// never the authority on what the bot holds.
  public static let pointReachKilometres = 115.0

  public static func make(
    states: [UInt16: WeatherBotState],
    place: WeatherPlace?,
    tables: MeshWXTables,
    now: Date,
    calendar: Calendar
  ) -> WeatherForecastCard {
    guard let place else { return .noPlace }
    // The bundle's nearest point, when it has one within reach. Since revision 10 the bundle is
    // not the authority on whether the place can be asked about at all: with no point in reach
    // the ask is the coordinate itself.
    let placePoint = tables.nearestPoint(toLat: place.coordinate.latitude, lon: place.coordinate.longitude)
    let placePointKilometres = placePoint.map {
      WeatherGeo.kilometres(place.coordinate, MeshWXCoordinate(latitude: $0.lat, longitude: $0.lon))
    }
    let reachablePoint: MeshWXPoint? = (placePointKilometres ?? .infinity) <= pointReachKilometres
      ? placePoint : nil

    var newest: [UInt16: (stored: WeatherStoredForecast, botID: UInt16)] = [:]
    for (botID, state) in states {
      for (index, stored) in state.forecasts where index != MeshWXWire.unbundledPoint {
        if let held = newest[index], held.stored.forecast.issuedMinutes >= stored.forecast.issuedMinutes { continue }
        newest[index] = (stored, botID)
      }
    }

    func summary(
      _ point: MeshWXPoint?, _ entry: (stored: WeatherStoredForecast, botID: UInt16),
      _ source: Summary.Source, _ kilometres: Double
    ) -> WeatherForecastCard {
      .forecast(Summary(
        point: point,
        stored: entry.stored,
        botID: entry.botID,
        layout: MeshWXForecastLayout(of: entry.stored.forecast),
        rows: WeatherForecastRows.rows(for: entry.stored.forecast, now: now, calendar: calendar),
        source: source,
        isStale: entry.stored.isStale(at: now),
        kilometres: kilometres))
    }

    if let reachablePoint, let held = newest[reachablePoint.index] {
      return summary(reachablePoint, held, .placePoint, placePointKilometres ?? 0)
    }

    let nearby = newest.compactMap { index, entry -> (MeshWXPoint, (stored: WeatherStoredForecast, botID: UInt16), Double)? in
      guard let point = tables.point(at: index) else { return nil }
      let distance = WeatherGeo.kilometres(place.coordinate, MeshWXCoordinate(latitude: point.lat, longitude: point.lon))
      return distance <= nearbyPointKilometres ? (point, entry, distance) : nil
    }.min { $0.2 < $1.2 }
    if let (point, entry, distance) = nearby {
      return summary(point, entry, .nearbyPoint(kilometres: distance), distance)
    }

    // A forecast held under the coordinate somebody asked about from this phone (spec revision
    // 10, §1.3). It has no point of its own that this bundle can name, so the place's own
    // distance from the *question* is what is checked, and the card says the bot chose the point.
    if let asked = nearestAskedCoordinate(states: states, place: place) {
      return summary(nil, (asked.stored, asked.botID), .botChosenPoint(kilometres: asked.kilometres), asked.kilometres)
    }

    // Nothing held. With a bundled point in reach the ask names it; without one it names the
    // coordinate, and `WeatherUpdatePlan` reads which from the nil here.
    return .missing(point: reachablePoint, kilometres: reachablePoint == nil ? nil : placePointKilometres)
  }

  /// The nearest coordinate-keyed forecast within ``askedCoordinateKilometres`` of the place, and
  /// how far away the question it answers was asked (spec revision 10, §1.3).
  ///
  /// Only keys that parse as a coordinate: the one slot for an answer nobody here asked for
  /// (``WeatherBotState/unbundledAskKey``) is somebody else's question and is never a place's
  /// forecast, which is the whole reason it has a key that cannot be mistaken for one.
  static func nearestAskedCoordinate(
    states: [UInt16: WeatherBotState], place: WeatherPlace
  ) -> (stored: WeatherStoredForecast, botID: UInt16, kilometres: Double)? {
    var best: (stored: WeatherStoredForecast, botID: UInt16, kilometres: Double)?
    for (botID, state) in states {
      for (key, stored) in state.unbundledForecasts {
        guard let coordinate = coordinate(fromKey: key) else { continue }
        let distance = WeatherGeo.kilometres(place.coordinate, coordinate)
        guard distance <= askedCoordinateKilometres else { continue }
        if let held = best, held.kilometres < distance { continue }
        if let held = best, held.kilometres == distance,
           held.stored.forecast.issuedMinutes >= stored.forecast.issuedMinutes { continue }
        best = (stored, botID, distance)
      }
    }
    return best
  }

  /// `"35.687,-105.938"` back into a coordinate, or nil for anything that is not one — which is
  /// what ``WeatherBotState/unbundledAskKey`` is.
  static func coordinate(fromKey key: String) -> MeshWXCoordinate? {
    let parts = key.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]),
          (-90...90).contains(latitude), (-180...180).contains(longitude)
    else { return nil }
    return MeshWXCoordinate(latitude: latitude, longitude: longitude)
  }
}

/// Forecasts on the channel that this phone did not ask for: somebody else's places, offered
/// in the place picker and labelled as theirs (docs/MESHWX_UI.md §12).
public struct WeatherOtherPlace: Sendable, Hashable, Identifiable {
  public var point: MeshWXPoint
  public var issuedAt: Date
  public var receivedAt: Date
  public var id: UInt16 { point.index }

  public static let window: TimeInterval = 24 * 60 * 60

  public static func make(
    states: [UInt16: WeatherBotState],
    excludingPoint excluded: UInt16?,
    tables: MeshWXTables,
    now: Date
  ) -> [WeatherOtherPlace] {
    var byPoint: [UInt16: WeatherOtherPlace] = [:]
    for state in states.values {
      for (index, stored) in state.forecasts
      where index != MeshWXWire.unbundledPoint && index != excluded && !stored.requestedHere
        && now.timeIntervalSince(stored.receivedAt) <= window {
        guard let point = tables.point(at: index) else { continue }
        let candidate = WeatherOtherPlace(point: point, issuedAt: stored.issuedAt, receivedAt: stored.receivedAt)
        if let held = byPoint[index], held.receivedAt >= candidate.receivedAt { continue }
        byPoint[index] = candidate
      }
    }
    return byPoint.values.sorted { $0.receivedAt > $1.receivedAt }
  }
}
