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
    let placeName = place.map { WeatherFormatting.placeName($0.label) } ?? ""
    let sourceStart = WeatherFormatting.sentenceStart(source)

    switch status {
    case .noPlace:
      return AlertStatusLine(text: L10n.Weather.Weather.AlertStatus.noPlace)
    case .outOfCoverage:
      return AlertStatusLine(text: L10n.Weather.Weather.AlertStatus.outOfCoverage(placeName, source))
    case .notChecked:
      return AlertStatusLine(text: L10n.Weather.Weather.AlertStatus.notChecked(source), action: .askForAlerts)
    case .feedNeverReceived:
      return AlertStatusLine(text: L10n.Weather.Weather.AlertStatus.feedNone(sourceStart))
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
    case let .feedQuiet(minutes):
      return AlertStatusLine(
        text: L10n.Weather.Weather.AlertStatus.feedQuiet(sourceStart, WeatherFormatting.quietDuration(minutes: minutes)))
    case .noneHere, .clear:
      // Nothing is said on a quiet day: no green check, no "none for your location", no status
      // line at all. Silence is still not calm — but the owner put that honesty in the radio row
      // and on the radio page, and a line here would be the reassurance he took out.
      return nil
    }
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
      // Attempt 0 on the route, 1 the same again, 2 by flood after the route was forgotten
      // (`WeatherService.floodAttempt`).
      switch attempt {
      case 0: return L10n.Weather.Weather.Request.pending(source)
      case 1: return L10n.Weather.Weather.Request.retrying
      default: return L10n.Weather.Weather.Request.flooding
      }
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
      case let .alreadyReceived(receivedAt, contentAsOf):
        // Receipt says how fresh the copy is; the content time says how fresh the weather is.
        let received = L10n.Weather.Weather.Request.received(WeatherFormatting.ago(receivedAt, now: now))
        guard let contentAsOf, let content = heldContent(request, time: time(contentAsOf)) else { return received }
        return L10n.Weather.Weather.Request.receivedContent(received, content)
      case let .timedOut(botWasHeard, botRadioReceived):
        // The bot's radio confirmed the request, so range is not why no answer came.
        if botRadioReceived {
          return L10n.Weather.Weather.Request.receivedNoAnswer(sourceStart, time(at))
        }
        return botWasHeard
          ? L10n.Weather.Weather.Request.heardNoAnswer(sourceStart, time(at))
          : L10n.Weather.Weather.Request.noAnswer(time(at), source)
      case let .notAvailable(reason):
        // The map's own rate limit is not the radio being busy and is certainly not an error:
        // the sweep is the one answer the whole channel shares, so a refusal means somebody else
        // has just spent those eight packets and this phone is about to be handed the same map
        // (docs/MESHWX_UI.md §17).
        if case .rateLimited = reason, case .areaSweep? = request {
          return L10n.Weather.Weather.AreaMap.busy(source)
        }
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
  ///
  /// **There is no "No forecast point near Albuquerque" any more** (spec revision 10, §1.3;
  /// docs/MESHWX_UI.md §3.1 U-38). `pfm_points.json` version 1 had no point at all for nine
  /// offices, so the app said that sentence and offered nothing while the bot held a forecast
  /// fifteen kilometres away — which is what the owner saw: *Forecast works in chat (`forecast
  /// santa fe nm`) but not in the app. I thought we were using the same engine.* A place with a
  /// coordinate can always be asked about, so an empty card with no point to name says only that
  /// there is no forecast yet, and Update sends `>f <lat>,<lon>`.
  static func forecastMissing(placeName: String, point: MeshWXPoint?, kilometres: Double?) -> String {
    guard let point, let kilometres, kilometres > WeatherForecastCard.nearbyPointKilometres else {
      return L10n.Weather.Weather.Forecast.missing(placeName)
    }
    return L10n.Weather.Weather.Forecast.missingFar(
      placeName, WeatherNames.pointLabel(point.name), WeatherFormatting.kilometres(kilometres))
  }

  // MARK: - Where the data came from (§12.1)

  /// "Via GOES satellite", "Via internet", "Via GOES and internet" — and **nil**
  /// when the radio did not say (spec §2.2, revision 7).
  ///
  /// Nil rather than a phrase, because a bot older than revision 7 has made no claim and a screen
  /// that filled the silence with one would be inventing provenance. A page fed by such a bot
  /// looks exactly as it did.
  static func dataSource(_ source: MeshWXDataSource) -> String? {
    switch source {
    case .unstated: nil
    case .goesSatellite: L10n.Weather.Weather.Source.goes
    case .internet: L10n.Weather.Weather.Source.internet
    case .mixed: L10n.Weather.Weather.Source.mixed
    }
  }

  /// The last line of a text reply's card: where the product came from, and whether the bot had to
  /// drop its tail. Nil when it would say neither.
  ///
  /// The cut is worth its own sentence rather than a marker in the body: a hole in the text is a
  /// chunk the air ate and asking again may fill it, while this is the whole reply that bot will
  /// ever send for that request (spec §8.1, revision 7).
  static func reportFootnote(source: MeshWXDataSource, wasCut: Bool) -> String? {
    let parts = [dataSource(source), wasCut ? L10n.Weather.Weather.Reports.cut : nil]
      .compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: - Answers already held (§11)

  /// "Ask for Tornado Warning" when the tap asks for one warning by identity, "Ask for alerts"
  /// otherwise.
  static func askAlertsTitle(for request: WeatherRequest, tables: MeshWXTables) -> String {
    guard case let .warning(identity) = request,
          let parsed = WeatherAlertRequests.identity(from: identity, tables: tables)
    else { return L10n.Weather.Weather.Request.askAlerts }
    return L10n.Weather.Weather.Request.askWarning(WeatherFormatting.eventName(parsed.event, tables: tables))
  }

  /// "list as of 3:02 PM", "readings as of 1:13 AM", "issued 7:52 PM": what an answer already
  /// received was as of, in the words for what was asked.
  static func heldContent(_ request: WeatherRequest?, time: String) -> String? {
    guard let request else { return nil }
    switch request {
    case .digest, .activeWarnings, .warning, .warningsTouching:
      return L10n.Weather.Weather.Request.contentList(time)
    case .observations, .observation:
      return L10n.Weather.Weather.Request.contentReadings(time)
    case .forecast, .forecastForPlace, .homeForecast, .forecastAt:
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

  // MARK: - Update (§11)

  /// "Asks WX-AUS for: alert list, readings" — every tap says what it will spend airtime on
  /// before it spends it.
  static func updateAsks(_ plan: WeatherUpdatePlan, source: String) -> String {
    L10n.Weather.Weather.Update.asks(source, plan.items.map(itemName).joined(separator: ", "))
  }

  static func itemName(_ item: WeatherUpdatePlan.Item) -> String {
    switch item {
    case .alerts: L10n.Weather.Weather.Update.Item.alerts
    case .areaAlerts: L10n.Weather.Weather.Update.Item.areaAlerts
    case .readings: L10n.Weather.Weather.Update.Item.readings
    case .forecast: L10n.Weather.Weather.Update.Item.forecast
    case .coverage: L10n.Weather.Weather.Update.Item.coverage
    }
  }

  /// "Everything is current · WX-AUS 4:25 PM": true as of the oldest of the things the plan
  /// checked, on the bot's clock.
  static func everythingCurrent(
    source: String, asOf: Date?, now: Date, calendar: Calendar, locale: Locale
  ) -> String {
    guard let asOf else { return L10n.Weather.Weather.Update.currentUnknown }
    return L10n.Weather.Weather.Update.current(
      source, WeatherFormatting.clockTime(asOf, now: now, calendar: calendar, locale: locale))
  }

  /// Nothing to ask for because the channel just delivered it — which is not the same as
  /// everything being current (spec §13).
  static func updateJustReceived(source: String) -> String {
    L10n.Weather.Weather.Update.justReceived(WeatherFormatting.sentenceStart(source))
  }

  // MARK: - Now (§8)

  /// "in WX-AUS's 9:40 AM report" — which message a reading arrived in, and nothing else.
  ///
  /// The station screen already carries the station's name as its headline and its distance from
  /// the place on its own line, so `stationSource` said both of them a second and third time
  /// ("Austin-Bergstrom International Airport · under 1 km N · in …'s 9:40 AM report", above
  /// "under 1 km N from Austin"). This is the part that is not said anywhere else.
  static func stationReport(botName: String, reportedAt: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
    L10n.Weather.Weather.Now.report(
      botName, WeatherFormatting.clockTime(reportedAt, now: now, calendar: calendar, locale: locale))
  }

  /// "No weather station near Dallas. Nearest: Temple, 190 km."
  static func noStationNearby(placeName: String, nearestTown: String, kilometres: Double?) -> String {
    guard let kilometres else { return L10n.Weather.Weather.Now.noneNearbyUnknown(placeName, nearestTown) }
    return L10n.Weather.Weather.Now.noneNearby(placeName, nearestTown, WeatherFormatting.kilometres(kilometres))
  }

  /// The one line under the temperature: "Camp Mabry · 6 km · as of 8:24 PM" (docs/MESHWX_UI.md
  /// §8). The station, how far it is, and when it read — and nothing else on the page unless it
  /// is tapped. The radio that carried it is named by the radio row, once, at the foot.
  ///
  /// With no station name — a reading the block already attributes above its number (§3.1 U-2a)
  /// — it is the time alone: "As of 6:56 AM".
  static func conditionsSource(
    stationName: String?,
    kilometres: Double?,
    observedAt: Date,
    now: Date,
    calendar: Calendar,
    locale: Locale
  ) -> String {
    let asOf = L10n.Weather.Weather.Stations.asOf(
      WeatherFormatting.clockTime(observedAt, now: now, calendar: calendar, locale: locale))
    guard let stationName else { return WeatherFormatting.sentenceStart(asOf) }
    guard let kilometres else { return "\(stationName) · \(asOf)" }
    return "\(stationName) · \(WeatherFormatting.kilometres(kilometres)) · \(asOf)"
  }

  /// A fresh reading too far off to be the weather here, shown anyway under its station: "Nearest
  /// report: San Marcos, 26 km away" (docs/MESHWX_UI.md §3.1 U-2a). It sits above the number, so
  /// the number is never read as the town's.
  static func nearbyReadingLead(stationName: String, kilometres: Double?) -> String {
    guard let kilometres else { return L10n.Weather.Weather.Now.nearbyReadingUnknown(stationName) }
    return L10n.Weather.Weather.Now.nearbyReading(stationName, WeatherFormatting.kilometres(kilometres))
  }

  /// No reading good enough to be the weather here: the ask, and the station a refresh would
  /// spend airtime on — "No current conditions for Llano. Pull down to ask WX-AUS for KAQO."
  ///
  /// With something blocking every request, the sentence **stops offering the pull**: the gesture
  /// cannot send anything, and telling someone to pull while a disconnected radio makes it inert
  /// is the app describing a screen it does not have (docs/MESHWX_UI.md §3.1 U-6). It names the
  /// station and leaves it there; the reason is already at the top of the list.
  static func conditionsAsk(
    placeName: String, source: String, icao: String, block: WeatherRequestBlock? = nil
  ) -> String {
    guard block == nil else { return L10n.Weather.Weather.Conditions.askBlocked(placeName, icao) }
    return L10n.Weather.Weather.Conditions.ask(placeName, source, icao)
  }

  // MARK: - A place with nothing held (§3.1 U-13)

  /// "No weather for Llano yet."
  static func emptyPlaceTitle(placeName: String) -> String {
    L10n.Weather.Weather.Empty.title(placeName)
  }

  /// What is nearest, in one line: "Nearest station Burnet Municipal Cradock Field Airport, 18 km
  /// · Nearest forecast point Burnet Airport, 43 km". Nil when neither is in reach — then the
  /// action line says so instead.
  ///
  /// **Both halves name their subject.** The sentence used to code the station and name the point
  /// — "Nearest station TJIG, 1 km · Nearest forecast point Luis Munoz Marin International
  /// Airport-San Juan, 12 km" — so one clause was for a pilot and the other for a reader
  /// (docs/MESHWX_UI.md §3.1 U-27). The airport code is on the station's own screen, which this
  /// card's Update opens onto.
  static func emptyPlaceNearest(_ empty: WeatherEmptyPlace, tables: MeshWXTables = .shared) -> String? {
    var parts: [String] = []
    if let icao = empty.stationICAO {
      let station = tables.station(icao: icao).map { WeatherNames.stationName($0.name) } ?? icao
      parts.append(empty.stationKilometres.map {
        L10n.Weather.Weather.Empty.station(station, WeatherFormatting.kilometres($0))
      } ?? L10n.Weather.Weather.Empty.stationOnly(station))
    }
    if let point = empty.pointName {
      parts.append(empty.pointKilometres.map {
        L10n.Weather.Weather.Empty.point(WeatherNames.pointLabel(point), WeatherFormatting.kilometres($0))
      } ?? L10n.Weather.Weather.Empty.pointOnly(WeatherNames.pointLabel(point)))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// The one thing to do about it: ask, or — with nothing in reach to ask about — that there is
  /// nothing to ask for.
  ///
  /// Nil when nothing can be asked at all. **The reason is said once on the page** and this is
  /// not where: the caption at the top, or the banner when there is one, already carries it, and
  /// this card printed a third copy of "Your radio's firmware can't ask for weather" two lines
  /// under the second (docs/MESHWX_UI.md §3.1 U-24).
  static func emptyPlaceAction(
    _ empty: WeatherEmptyPlace, placeName: String, source: String, block: WeatherRequestBlock?
  ) -> String? {
    guard block == nil else { return nil }
    guard !empty.hasNothingToAsk else { return L10n.Weather.Weather.Empty.nothing(placeName) }
    return L10n.Weather.Weather.Empty.ask(source)
  }

  /// "14 stations in WX-AUS's area", or "3 weather stations" when none came in the bot's batch.
  /// The link names every row the screen it opens will show: with single-station answers held on
  /// top of the batch, "19 weather stations, 14 in WX-AUS's area" — the area count alone promised
  /// 14 rows and opened 19.
  static func stationLink(inArea: Int, total: Int, source: String) -> String {
    guard inArea > 0 else {
      return total == 1 ? L10n.Weather.Weather.Now.stationsOne : L10n.Weather.Weather.Now.stations(total)
    }
    guard total > inArea else {
      return inArea == 1
        ? L10n.Weather.Weather.Now.stationsInAreaOne(source)
        : L10n.Weather.Weather.Now.stationsInArea(inArea, source)
    }
    return L10n.Weather.Weather.Now.stationsWithArea(total, inArea, source)
  }

  // MARK: - The radio row (§10)

  /// "WX-AUS · heard 2 min ago · alerts as of 8:02 PM", the row at the foot of every place page.
  /// It is the only thing on the page that mentions the alert list, and it never leaves the list
  /// out: with none held it says so rather than saying nothing.
  static func radioRow(
    _ row: WeatherRadioRow,
    source: String,
    now: Date,
    calendar: Calendar,
    locale: Locale
  ) -> String {
    var parts = [source]
    if let heardAt = row.heardAt {
      parts.append(L10n.Weather.Weather.About.heard(WeatherFormatting.ago(heardAt, now: now)))
    } else {
      parts.append(L10n.Weather.Weather.About.notHeard)
    }
    if let builtAt = row.listBuiltAt {
      parts.append(L10n.Weather.Weather.RadioRow.alertsAsOf(
        WeatherFormatting.clockTime(builtAt, now: now, calendar: calendar, locale: locale)))
    } else {
      parts.append(L10n.Weather.Weather.RadioRow.noAlertList)
    }
    return parts.joined(separator: " · ")
  }

  // MARK: - Places rows (§12)

  /// "86° Cloudy", and "—" when the place's own page would show no temperature either
  /// (docs/MESHWX_UI.md §12, §3.1 U-2). The row and the page ask the same question of the same
  /// reading, so they can never disagree about the same town one tap apart.
  static func placeRow(_ reading: WeatherPlaceRowReading, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
    guard let observedAt = reading.observedAt else { return L10n.Weather.Weather.Picker.noReading }
    var parts: [String] = []
    if let tempF = reading.tempF {
      parts.append(WeatherFormatting.temperature(fahrenheit: Int(tempF), locale: locale))
    }
    if let sky = reading.sky, let condition = WeatherFormatting.condition(sky) {
      parts.append(condition)
    }
    var head = parts.joined(separator: " ")
    // Shown under its station on the page, so under its station here (§3.1 U-2a).
    if let station = reading.attributedStation, !head.isEmpty { head += " · \(station)" }
    guard reading.isStale else { return head.isEmpty ? L10n.Weather.Weather.Picker.noReading : head }
    let age = WeatherFormatting.age(observedAt, now: now)
    return head.isEmpty ? age : "\(head) · \(age)"
  }

  // MARK: - The weather radio's page (§12)

  /// What a request asked for, in a few words: for the log of this phone's own requests, and for
  /// the rows of what the channel carried. It names what was asked for and never who asked.
  static func requestName(_ request: WeatherRequest, tables: MeshWXTables = .shared) -> String {
    func withSubject(_ name: String, _ subject: String) -> String {
      L10n.Weather.Weather.RequestName.withSubject(name, subject)
    }
    switch request {
    case .digest:
      return L10n.Weather.Weather.RequestName.alertList
    case .activeWarnings:
      return L10n.Weather.Weather.RequestName.activeWarnings
    case let .warning(identity):
      return warningName(identity, tables: tables)
    case let .warningsTouching(ugc):
      return L10n.Weather.Weather.RequestName.areaWarnings(ugc)
    case let .warningText(identity):
      return L10n.Weather.Weather.RequestName.warningText(warningName(identity, tables: tables))
    case .observations:
      return L10n.Weather.Weather.RequestName.readings
    case let .observation(station):
      return L10n.Weather.Weather.RequestName.stationReading(station)
    case .homeForecast:
      return L10n.Weather.Weather.Forecast.titleGeneric
    case let .forecast(point):
      return L10n.Weather.Weather.RequestName.forecast(pointName(point, tables: tables) ?? String(point))
    case let .forecastForPlace(place):
      return L10n.Weather.Weather.RequestName.forecast(place)
    case let .forecastDiscussion(office):
      return withSubject(L10n.Weather.Weather.Reports.Discussion.title, WeatherReferenceNames.officeName(office))
    case .spaceWeather:
      return L10n.Weather.Weather.Reports.Space.title
    case let .stormReports(state):
      return withSubject(L10n.Weather.Weather.Reports.Storms.title, WeatherReferenceNames.stateName(state))
    case let .rainfall(state):
      return withSubject(L10n.Weather.Weather.Reports.Rainfall.title, WeatherReferenceNames.stateName(state))
    case let .metar(station):
      return withSubject(L10n.Weather.Weather.RequestName.metar, station)
    case let .taf(station):
      return withSubject(L10n.Weather.Weather.RequestName.taf, station)
    case .hazardousOutlook:
      return L10n.Weather.Weather.Reports.Outlook.title
    case .coverage:
      return L10n.Weather.Weather.RequestName.coverage
    case let .areaSweep(includesAdvisories, states):
      // A scoped ask names its states, because the log is where somebody works out what those
      // packets were spent on and "Alert map" twice over answers nothing (revision 10, §1.2).
      guard !states.isEmpty else {
        return includesAdvisories
          ? L10n.Weather.Weather.RequestName.areaMapAll
          : L10n.Weather.Weather.RequestName.areaMap
      }
      // Normalised here as well as on the wire: two selections of the same states have to be one
      // row in the log, whatever order the value was built with.
      let named = WeatherAreaMapCopy.stateList(WeatherRequest.sweepStates(states))
      return includesAdvisories
        ? L10n.Weather.Weather.RequestName.areaMapStatesAll(named)
        : L10n.Weather.Weather.RequestName.areaMapStates(named)
    case let .parts(_, _, kind):
      // The kind is carried for exactly this: the wire says only `>part 212 1,4,6`, and a log row
      // reading "Missing parts" with no subject is a row nobody can act on (revision 10, §1.1).
      return partsName(kind)
    case let .forecastAt(latitude, longitude):
      // The coordinate is the only name such a forecast has: the bot picks the point, and this
      // bundle may hold no index for it at all (revision 10, §1.3).
      return L10n.Weather.Weather.RequestName.forecastAt(
        WeatherRequest.coordinateKey(latitude: latitude, longitude: longitude))
    }
  }

  /// "Missing parts of Alert map", "Missing parts of Storm reports".
  static func partsName(_ kind: WeatherPartsKind) -> String {
    switch kind {
    case .areaSweep:
      return L10n.Weather.Weather.RequestName.parts(L10n.Weather.Weather.AreaMap.title)
    case let .text(subject):
      let parsed = MeshWXTextSubject(rawValue: subject)
      // A subject code this build does not know has no name to put in the sentence, and
      // "Missing parts of Text" claims one. The bare noun is the honest row.
      if case .other = parsed { return L10n.Weather.Weather.RequestName.partsGeneric }
      return L10n.Weather.Weather.RequestName.parts(textSubjectName(parsed))
    }
  }

  /// "Tornado Warning" for an identity the tables can read; the identity itself when a newer bot
  /// names an event this bundle does not have.
  static func warningName(_ identity: String, tables: MeshWXTables) -> String {
    guard let parsed = WeatherAlertRequests.identity(from: identity, tables: tables) else { return identity }
    return WeatherFormatting.eventName(parsed.event, tables: tables)
  }

  static func pointName(_ point: UInt16, tables: MeshWXTables) -> String? {
    tables.point(at: point).map { WeatherNames.pointLabel($0.name) }
  }

  /// How one of this phone's requests ended (§12). Four outcomes; which reason the bot gave, and
  /// whether its radio confirmed the request, stay under the button that sent it (§11.2).
  static func requestOutcome(_ outcome: WeatherRequestLogEntry.Outcome?) -> String {
    switch outcome {
    case .answered: L10n.Weather.Weather.Requests.answered
    case .noAnswer: L10n.Weather.Weather.Requests.noAnswer
    case .notAvailable: L10n.Weather.Weather.Requests.notAvailable
    case .refused: L10n.Weather.Weather.Requests.refused
    case nil: L10n.Weather.Weather.Requests.pending
    }
  }

  /// What one thing on the channel was, in words. A name for the row, never a claim about who
  /// asked for it.
  static func channelSubject(_ subject: WeatherChannelSubject, tables: MeshWXTables = .shared) -> String {
    switch subject {
    case .alertList:
      return L10n.Weather.Weather.RequestName.alertList
    case let .warning(identity):
      return WeatherFormatting.eventName(identity.event, tables: tables)
    case let .readings(stations):
      return stations == 1
        ? L10n.Weather.Weather.Heard.readingsOne
        : L10n.Weather.Weather.Heard.readings(stations)
    case let .reading(station):
      return tables.station(at: station).map { WeatherNames.stationName($0.name) }
        ?? L10n.Weather.Weather.RequestName.readings
    case let .forecast(point, label):
      // A forecast the bot resolved from a place string has no bundled point, and the request
      // that fetched it is the only name it has (spec §7).
      let name = pointName(point, tables: tables) ?? label ?? String(point)
      return L10n.Weather.Weather.RequestName.forecast(name)
    case let .text(subject, request):
      // A chunk carries only its subject: with no request of this phone's behind it, the subject
      // is all the row can say.
      return request.map { requestName($0, tables: tables) } ?? textSubjectName(subject)
    case .coverage:
      return L10n.Weather.Weather.RequestName.coverage
    }
  }

  static func textSubjectName(_ subject: MeshWXTextSubject) -> String {
    switch subject {
    case .warningNarrative: L10n.Weather.Weather.AlertDetail.fullText
    case .forecastDiscussion: L10n.Weather.Weather.Reports.Discussion.title
    case .spaceWeather: L10n.Weather.Weather.Reports.Space.title
    case .stormReports: L10n.Weather.Weather.Reports.Storms.title
    case .rainfall: L10n.Weather.Weather.Reports.Rainfall.title
    case .metarOrTAF: L10n.Weather.Weather.Station.airportReports
    case .hazardousOutlook: L10n.Weather.Weather.Reports.Outlook.title
    case .nowcast, .general, .other: L10n.Weather.Weather.Heard.text
    }
  }

  /// "as of 1:13 AM · received 1:14 AM": the content's own time on the bot's clock and when this
  /// phone got it. A message that carries no time of its own says only the second (§2).
  static func channelTimes(
    contentAt: Date?, receivedAt: Date, now: Date, calendar: Calendar, locale: Locale
  ) -> String {
    func time(_ date: Date) -> String {
      WeatherFormatting.clockTime(date, now: now, calendar: calendar, locale: locale)
    }
    let received = L10n.Weather.Weather.Reports.received(time(receivedAt))
    guard let contentAt else { return received }
    return "\(L10n.Weather.Weather.Stations.asOf(time(contentAt))) · \(received)"
  }

  static func cacheGroup(_ group: WeatherCacheGroup) -> String {
    switch group {
    case .readings: L10n.Weather.Weather.RequestName.readings
    case .forecasts: L10n.Weather.Weather.Cache.forecasts
    case .airportReports: L10n.Weather.Weather.Cache.airportReports
    case .warningNarratives: L10n.Weather.Weather.Cache.narratives
    case .warningsElsewhere: L10n.Weather.Weather.Cache.warningsElsewhere
    }
  }
}
