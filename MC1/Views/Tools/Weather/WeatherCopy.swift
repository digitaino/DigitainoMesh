import Foundation
import MC1Services
import MeshWX

/// Where the screen stands on finding a place, for the header and the empty cards.
enum WeatherPlaceState: Sendable, Hashable {
  case resolved
  /// Waiting for a fix: up to five seconds on arrival, or after "Back to my location".
  case locating
  /// Location permission never asked: only "Use my location" may ask.
  case needsPermission
  case denied
  /// Authorized, but no fix came.
  case unavailable
}

/// What an answer did to what the phone holds, for the confirmation under its button.
enum WeatherAnswerNote: Sendable, Hashable {
  enum Kind: Sendable, Hashable {
    case forecast
    case readings
    case other
  }

  case changed
  case unchanged(Kind)
}

/// The sentences the Weather screen is built from (docs/MESHWX_UI.md §7.4, §10, §11), each a
/// pure function of the snapshot's values.
enum WeatherCopy {
  // MARK: - Header (§10)

  struct Header: Equatable {
    enum Action: Equatable {
      case backToMyLocation
      case openSettings
    }

    var title: String
    var subtitle: String
    var action: Action?
  }

  /// One line under the place: where it comes from and when the source was last heard. Radio
  /// offline is not repeated here; the status line and the ask captions say it.
  static func header(
    place: WeatherPlace?,
    placeState: WeatherPlaceState,
    sourceName: String?,
    sourceHeardAt: Date?,
    now: Date
  ) -> Header {
    let heard: String? = sourceName.flatMap { name in
      sourceHeardAt.map { L10n.Weather.Weather.Header.heard(name, WeatherFormatting.ago($0, now: now)) }
    }
    var parts: [String] = []
    var action: Header.Action?
    let title = place.map { WeatherFormatting.shortPlaceName($0.label) } ?? L10n.Weather.Weather.Header.choosePlace

    if let place, place.kind == .searched {
      parts.append(L10n.Weather.Weather.Header.searched)
      action = .backToMyLocation
    } else if placeState == .locating {
      parts.append(L10n.Weather.Weather.Header.locating)
    } else if let place {
      parts.append(L10n.Weather.Weather.Header.yourLocation)
      if place.kind == .lastKnown, let locatedAt = place.locatedAt {
        parts.append(WeatherFormatting.age(locatedAt, now: now))
      } else if let heard {
        parts.append(heard)
      }
    } else if placeState == .denied {
      parts.append(L10n.Weather.Weather.Header.locationOff)
      action = .openSettings
    } else if let heard {
      parts.append(heard)
    }
    return Header(title: title, subtitle: parts.joined(separator: " · "), action: action)
  }

  // MARK: - Banners (§10)

  static func banner(_ banner: WeatherScreenSnapshot.Banner) -> String {
    switch banner {
    case let .firmwareTooOld(version):
      L10n.Weather.Weather.Banner.firmware(WeatherFormatting.firmwareVersion(version))
    case .channelMissing:
      L10n.Weather.Weather.Banner.channelMissing
    case .noBotHeard:
      L10n.Weather.Weather.Banner.noBot
    }
  }

  // MARK: - Alert status line (§7.4)

  struct AlertStatusLine: Equatable {
    enum Action: Equatable {
      case askForAlerts
      case updateLocation
    }

    var text: String
    /// The green check: only for `.clear`.
    var showsCheck = false
    var action: Action?
    /// A second line under the text, for the offline case.
    var caption: String?
  }

  static func alertStatus(
    _ status: WeatherAlertStatus,
    source: String,
    place: WeatherPlace?,
    areaName: String?,
    now: Date,
    calendar: Calendar,
    locale: Locale
  ) -> AlertStatusLine? {
    func time(_ date: Date) -> String {
      WeatherFormatting.clockTime(date, now: now, calendar: calendar, locale: locale)
    }
    let placeName = place.map { WeatherFormatting.shortPlaceName($0.label) } ?? ""
    let sourceStart = WeatherFormatting.sentenceStart(source)

    switch status {
    case .noPlace:
      return AlertStatusLine(text: L10n.Weather.Weather.AlertStatus.noPlace)
    case .outOfCoverage:
      return AlertStatusLine(text: L10n.Weather.Weather.AlertStatus.outOfCoverage(placeName, source))
    case .notChecked:
      return AlertStatusLine(text: L10n.Weather.Weather.AlertStatus.notChecked(source), action: .askForAlerts)
    case let .feedStale(minutes):
      return AlertStatusLine(
        text: L10n.Weather.Weather.AlertStatus.feedStale(sourceStart, WeatherFormatting.quietDuration(minutes: minutes)))
    case let .radioOffline(listAsOf):
      return AlertStatusLine(
        text: L10n.Weather.Weather.AlertStatus.radioOffline(time(listAsOf)),
        caption: requestBlocked(.radioOffline, source: source))
    case .missedMessages:
      return AlertStatusLine(text: L10n.Weather.Weather.AlertStatus.missedMessages(source), action: .askForAlerts)
    case let .listOld(asOf):
      return AlertStatusLine(text: L10n.Weather.Weather.AlertStatus.listOld(time(asOf)), action: .askForAlerts)
    case let .locationOld(since):
      return AlertStatusLine(
        text: L10n.Weather.Weather.AlertStatus.locationOld(WeatherFormatting.age(since, now: now)),
        action: .updateLocation)
    case .coverageUnknown:
      return AlertStatusLine(text: L10n.Weather.Weather.AlertStatus.coverageUnknown(sourceStart))
    case let .officeMayNotBeCovered(office):
      return AlertStatusLine(
        text: L10n.Weather.Weather.AlertStatus.officeNotCovered(
          sourceStart, areaName ?? placeName, WeatherReferenceNames.officeName(office)))
    case .rowsSpeak:
      return nil
    case let .noneHere(_, asOf):
      let text = place?.kind == .searched
        ? L10n.Weather.Weather.AlertStatus.noneHerePlace(placeName, time(asOf))
        : L10n.Weather.Weather.AlertStatus.noneHere(time(asOf))
      return AlertStatusLine(text: text)
    case let .clear(asOf):
      return AlertStatusLine(text: L10n.Weather.Weather.AlertStatus.clear(time(asOf)), showsCheck: true)
    }
  }

  /// "Alerts for Austin", or "Alerts" with no place.
  static func alertsTitle(placeName: String?) -> String {
    placeName.map { L10n.Weather.Weather.Alerts.titlePlace($0) } ?? L10n.Weather.Weather.Alerts.title
  }

  // MARK: - Alert rows (§7.3)

  /// The one line under an alert's name that says where it is or what became of it.
  static func alertQualifier(
    _ item: WeatherAlertItem,
    placeName: String?,
    now: Date
  ) -> String? {
    switch item.kind {
    case .upgradedAwaitingReplacement:
      return L10n.Weather.Weather.Alerts.upgraded
    case .expiredRecently:
      return L10n.Weather.Weather.Alerts.expired(WeatherFormatting.duration(seconds: now.timeIntervalSince(item.expiresAt)))
    case .active:
      break
    }
    switch item.placement {
    case let .near(kilometres, direction):
      return WeatherFormatting.distance(kilometres, direction: direction)
    case .checking:
      return L10n.Weather.Weather.Alerts.checking
    case .unplaced:
      return placeName.map { L10n.Weather.Weather.Coverage.unknown($0) }
    case .here, .elsewhere:
      return nil
    }
  }

  /// Where an alert away from the place is: "Llano County · 105 km W" — its first named area,
  /// and the distance and direction from the place to the alert's centre. Only the area with no
  /// place.
  static func alertLocation(
    _ warning: MeshWXWarning,
    place: WeatherPlace?,
    tables: MeshWXTables
  ) -> String? {
    let areas = tables.namedAreas(for: warning)
    let areaName = areas.first.map(WeatherFormatting.shortAreaName)
    let centre: MeshWXCoordinate? = if let polygon = warning.polygon, polygon.count >= 3 {
      Self.centre(polygon)
    } else {
      Self.centre(areas.compactMap { area in
        area.lat.flatMap { lat in area.lon.map { MeshWXCoordinate(latitude: lat, longitude: $0) } }
      })
    }
    var distance: String?
    if let place, let centre {
      let kilometres = MeshWXGeo.distanceKilometres(
        fromLat: place.coordinate.latitude, lon: place.coordinate.longitude,
        toLat: centre.latitude, lon: centre.longitude)
      distance = WeatherFormatting.distance(
        kilometres, direction: WeatherFormatting.direction(from: place.coordinate, to: centre))
    }
    switch (areaName, distance) {
    case let (area?, distance?): return L10n.Weather.Weather.Alerts.areaDistance(area, distance)
    case let (area?, nil): return area
    case let (nil, distance?): return distance
    case (nil, nil): return nil
    }
  }

  static func centre(_ coordinates: [MeshWXCoordinate]) -> MeshWXCoordinate? {
    guard !coordinates.isEmpty else { return nil }
    let latitude = coordinates.reduce(0) { $0 + $1.latitude } / Double(coordinates.count)
    let longitude = coordinates.reduce(0) { $0 + $1.longitude } / Double(coordinates.count)
    return MeshWXCoordinate(latitude: latitude, longitude: longitude)
  }

  /// "Covers Austin" / "Doesn't cover Austin (25 km N)" / "Not sure it covers Austin".
  static func coversLine(_ placement: WeatherAlertPlacement, placeName: String) -> String {
    switch placement {
    case .here:
      L10n.Weather.Weather.Coverage.covers(placeName)
    case let .near(kilometres, direction):
      L10n.Weather.Weather.Coverage.near(placeName, WeatherFormatting.distance(kilometres, direction: direction))
    case .elsewhere:
      L10n.Weather.Weather.Coverage.doesNotCover(placeName)
    case .checking:
      L10n.Weather.Weather.Coverage.checking(placeName)
    case .unplaced:
      L10n.Weather.Weather.Coverage.unknown(placeName)
    }
  }

  // MARK: - Requests (§11)

  static func requestBlocked(_ block: WeatherRequestBlock, source: String) -> String {
    switch block {
    case .radioOffline: L10n.Weather.Weather.Request.Blocked.offline(source)
    case .firmwareTooOld: L10n.Weather.Weather.Request.Blocked.firmware
    case .channelMissing: L10n.Weather.Weather.Request.Blocked.channel
    case .noBot: L10n.Weather.Weather.Request.Blocked.noBot
    case .botNotAnnounced: L10n.Weather.Weather.Request.Blocked.notAnnounced
    }
  }

  /// What a button shows for a request's status, or nil when the button speaks for itself.
  ///
  /// - Parameters:
  ///   - request: what was asked, for naming the content time of an answer already received.
  ///   - answer: for an answered request, whether it changed what the phone holds.
  static func requestStatus(
    _ status: WeatherRequestStatus,
    source: String,
    request: WeatherRequest? = nil,
    answer: WeatherAnswerNote? = nil,
    now: Date,
    calendar: Calendar,
    locale: Locale
  ) -> String? {
    func time(_ date: Date) -> String {
      WeatherFormatting.clockTime(date, now: now, calendar: calendar, locale: locale)
    }
    let sourceStart = WeatherFormatting.sentenceStart(source)
    switch status {
    case .idle:
      return nil
    case let .blocked(block):
      return requestBlocked(block, source: source)
    case let .pending(attempt, _):
      return attempt == 0 ? L10n.Weather.Weather.Request.pending(source) : L10n.Weather.Weather.Request.retrying
    case .waitingForOther:
      return L10n.Weather.Weather.Request.waiting
    case let .settled(outcome, at):
      switch outcome {
      case .answered:
        switch answer {
        case .unchanged(.forecast): return L10n.Weather.Weather.Request.noNewerForecast(source)
        case .unchanged(.readings): return L10n.Weather.Weather.Request.noNewerReadings(source)
        case .unchanged(.other): return L10n.Weather.Weather.Request.answeredNothingNew(sourceStart, time(at))
        case .changed, nil: return L10n.Weather.Weather.Request.answeredAt(sourceStart, time(at))
        }
      case let .servedFromCache(receivedAt, contentAsOf):
        // Receipt says how fresh the copy is; the content time says how fresh the weather is.
        let received = L10n.Weather.Weather.Request.received(WeatherFormatting.ago(receivedAt, now: now))
        guard let contentAsOf, let content = cachedContent(request, time: time(contentAsOf)) else { return received }
        return L10n.Weather.Weather.Request.receivedContent(received, content)
      case let .timedOut(botWasHeard):
        return botWasHeard
          ? L10n.Weather.Weather.Request.heardNoAnswer(sourceStart, time(at))
          : L10n.Weather.Weather.Request.noAnswer(time(at), source)
      case let .notAvailable(reason):
        return notAvailable(reason, source: sourceStart)
      case .failed:
        return L10n.Weather.Weather.Request.failed(time(at))
      }
    }
  }

  static func notAvailable(_ reason: MeshWXNotAvailableReason, source: String) -> String {
    switch reason {
    case .noData: L10n.Weather.Weather.Request.NotAvailable.noData(source)
    case .unknownLocation: L10n.Weather.Weather.Request.NotAvailable.unknownPlace(source)
    case .unsupported: L10n.Weather.Weather.Request.NotAvailable.unsupported(source)
    case .botError: L10n.Weather.Weather.Request.NotAvailable.error(source)
    case .rateLimited: L10n.Weather.Weather.Request.NotAvailable.busy(source)
    case .other: L10n.Weather.Weather.Request.NotAvailable.other(source)
    }
  }

  static func quietCaption(source: String, since: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
    L10n.Weather.Weather.Request.quiet(
      WeatherFormatting.sentenceStart(source),
      WeatherFormatting.clockTime(since, now: now, calendar: calendar, locale: locale))
  }

  // MARK: - Forecast (§9)

  static func rowLabel(_ label: WeatherForecastRow.Label, calendar: Calendar, locale: Locale) -> String {
    func weekday(_ date: Date) -> String {
      var style = Date.FormatStyle.dateTime.weekday(.wide).locale(locale)
      style.calendar = calendar
      style.timeZone = calendar.timeZone
      return date.formatted(style)
    }
    switch label {
    case .today: return L10n.Weather.Weather.Forecast.Label.today
    case .tonight: return L10n.Weather.Weather.Forecast.Label.tonight
    case .tomorrow: return L10n.Weather.Weather.Forecast.Label.tomorrow
    case .tomorrowNight: return L10n.Weather.Weather.Forecast.Label.tomorrowNight
    case let .day(date): return weekday(date)
    case let .night(date): return L10n.Weather.Weather.Forecast.Label.night(weekday(date))
    }
  }

  /// "70% rain tonight" for a paired row whose night carries the rain chance; "30% rain" otherwise.
  static func rainChance(_ row: WeatherForecastRow) -> String? {
    guard let pop = row.popPercent, pop > 0 else { return nil }
    return row.popIsNight && row.highF != nil
      ? L10n.Weather.Weather.Forecast.rainTonight(Int(pop))
      : L10n.Weather.Weather.Forecast.rain(Int(pop))
  }

  /// "Storms · Windy": every hazard flag the row carries.
  static func hazards(_ row: WeatherForecastRow) -> String? {
    var words: [String] = []
    if row.thunder { words.append(L10n.Weather.Weather.Forecast.Hazard.thunder) }
    if row.wintry { words.append(L10n.Weather.Weather.Forecast.Hazard.wintry) }
    if row.windy { words.append(L10n.Weather.Weather.Forecast.Hazard.windy) }
    if row.fog { words.append(L10n.Weather.Weather.Forecast.Hazard.fog) }
    return words.isEmpty ? nil : words.joined(separator: " · ")
  }

  /// "102° / 77°", or the one temperature the row carries, labelled.
  static func temperatures(highF: Int8?, lowF: Int8?, locale: Locale = .autoupdatingCurrent) -> String? {
    func degrees(_ value: Int8) -> String { WeatherFormatting.temperature(fahrenheit: Int(value), locale: locale) }
    switch (highF, lowF) {
    case let (high?, low?): return L10n.Weather.Weather.Forecast.highLow(degrees(high), degrees(low))
    case let (high?, nil): return L10n.Weather.Weather.Forecast.high(degrees(high))
    case let (nil, low?): return L10n.Weather.Weather.Forecast.low(degrees(low))
    case (nil, nil): return nil
    }
  }

  /// "No forecast for Austin yet."; with the point more than 10 km off, "No forecast for Big
  /// Spring yet. The nearest forecast point is Midland, 60 km."
  static func forecastMissing(placeName: String, point: MeshWXPoint, kilometres: Double) -> String {
    guard kilometres > WeatherForecastCard.nearbyPointKilometres else {
      return L10n.Weather.Weather.Forecast.missing(placeName)
    }
    return L10n.Weather.Weather.Forecast.missingFar(
      placeName, WeatherNames.pointName(point.name), WeatherFormatting.kilometres(kilometres))
  }

  /// "No forecast point near Albuquerque."
  static func noForecastPoint(placeName: String) -> String {
    L10n.Weather.Weather.Forecast.noPoint(placeName)
  }

  // MARK: - Answers already held (§11)

  /// "list as of 3:02 PM", "readings as of 1:13 AM", "issued 7:52 PM": what an answer already
  /// received was as of, in the words for what was asked.
  static func cachedContent(_ request: WeatherRequest?, time: String) -> String? {
    guard let request else { return nil }
    switch request {
    case .digest, .activeWarnings, .warning, .warningsTouching:
      return L10n.Weather.Weather.Request.contentList(time)
    case .observations, .observation:
      return L10n.Weather.Weather.Request.contentReadings(time)
    case .forecast, .forecastForPlace, .homeForecast:
      return L10n.Weather.Weather.Request.contentIssued(time)
    default:
      return nil
    }
  }

  /// "WX-AUS answered at 1:32 AM", in place of a button whose answer this phone already holds.
  static func ownedReply(source: String, at: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
    L10n.Weather.Weather.Request.answeredAt(
      WeatherFormatting.sentenceStart(source), WeatherFormatting.clockTime(at, now: now, calendar: calendar, locale: locale))
  }

  // MARK: - Now (§8)

  /// Within 25 km: "Austin-Camp Mabry · 6 km NNW · in WX-AUS's 11:18 PM report"; beyond it,
  /// "Nearest report · 40 km NW · in WX-AUS's 11:18 PM report".
  static func stationSource(
    stationName: String,
    kilometres: Double?,
    direction: MeshWXCompass?,
    botName: String,
    reportedAt: Date,
    now: Date,
    calendar: Calendar,
    locale: Locale
  ) -> String {
    let report = L10n.Weather.Weather.Now.report(
      botName, WeatherFormatting.clockTime(reportedAt, now: now, calendar: calendar, locale: locale))
    guard let kilometres else { return "\(stationName) · \(report)" }
    let distance = WeatherFormatting.distance(kilometres, direction: direction)
    if kilometres > 25 {
      return "\(L10n.Weather.Weather.Now.nearestReport) · \(distance) · \(report)"
    }
    return "\(stationName) · \(distance) · \(report)"
  }

  /// "No weather station near Dallas. Nearest: Temple, 190 km."
  static func noStationNearby(placeName: String, nearestTown: String, kilometres: Double?) -> String {
    guard let kilometres else { return L10n.Weather.Weather.Now.noneNearbyUnknown(placeName, nearestTown) }
    return L10n.Weather.Weather.Now.noneNearby(placeName, nearestTown, WeatherFormatting.kilometres(kilometres))
  }

  /// "14 stations in WX-AUS's area", or "3 weather stations" when none came in the bot's batch.
  static func stationLink(inArea: Int, total: Int, source: String) -> String {
    if inArea > 0 {
      return inArea == 1
        ? L10n.Weather.Weather.Now.stationsInAreaOne(source)
        : L10n.Weather.Weather.Now.stationsInArea(inArea, source)
    }
    return total == 1 ? L10n.Weather.Weather.Now.stationsOne : L10n.Weather.Weather.Now.stations(total)
  }
}
