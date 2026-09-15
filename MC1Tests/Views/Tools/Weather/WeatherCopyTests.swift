import Foundation
import MC1Services
import MeshWX
import Testing

@testable import MC1

/// The sentences of docs/MESHWX_UI.md §7.4, §10 and §11, as the implementation reviews worded them.
@Suite("Weather copy")
struct WeatherCopyTests {
  typealias F = WeatherFormattingTests

  static let now = F.now
  static let austin = WeatherPlace(
    kind: .current, coordinate: MeshWXCoordinate(latitude: 30.2672, longitude: -97.7431), label: "Austin, TX",
    uncertaintyKilometres: 0.5, locatedAt: now)
  static let dallas = WeatherPlace(
    kind: .current, coordinate: MeshWXCoordinate(latitude: 32.7767, longitude: -96.7970), label: "Dallas, TX",
    uncertaintyKilometres: 0.5, locatedAt: now)
  static let roundRock = WeatherPlace(
    kind: .searched, coordinate: MeshWXCoordinate(latitude: 30.5083, longitude: -97.6789), label: "Round Rock, TX",
    uncertaintyKilometres: 5)

  /// 11:02 PM and 8:02 PM on the fixture's evening.
  static let elevenOhTwo = now.addingTimeInterval(-18 * 60)
  static let eightOhTwo = now.addingTimeInterval(-198 * 60)

  func status(_ status: WeatherAlertStatus, place: WeatherPlace? = WeatherCopyTests.austin, area: String? = nil,
              source: String = "WX-AUS") -> WeatherCopy.AlertStatusLine? {
    WeatherCopy.alertStatus(
      status, source: source, place: place, areaName: area, now: Self.now, calendar: F.calendar, locale: F.locale)
      .map { line in
        var line = line
        line.text = F.plain(line.text)
        return line
      }
  }

  // MARK: - Alert status line (§7.4)

  @Test
  func `no place and out of coverage say what cannot be known`() {
    #expect(status(.noPlace, place: nil)?.text == "Choose a place to see which alerts cover it")
    #expect(status(.outOfCoverage, place: Self.dallas)?.text == "Dallas is outside WX-AUS's area, so alerts there are unknown.")
  }

  @Test
  func `no alert list yet says the phone cannot tell, and offers to ask`() {
    let line = status(.notChecked)
    #expect(line?.text
      == "This phone hasn't received WX-AUS's alert list yet, so it can't tell whether any alerts are active. The list comes every 3 hours.")
    #expect(line?.action == .askForAlerts)
    #expect(line?.showsCheck == false)
  }

  @Test
  func `a stale feed has no button, since asking cannot help`() {
    let line = status(.feedStale(minutesSinceProduct: 300))
    #expect(line?.text == "WX-AUS hasn't heard from the Weather Service for 5 h. New alerts may not reach you.")
    #expect(line?.action == nil)
  }

  @Test
  func `an unknown area says the station report has not come, with no button`() {
    let line = status(.coverageUnknown)
    #expect(line?.text
      == "WX-AUS hasn't sent its station report yet, so the area it covers isn't known. It comes about every hour.")
    #expect(line?.action == nil)
    #expect(status(.coverageUnknown, source: "the weather radio")?.text.hasPrefix("The weather radio hasn't") == true)
  }

  @Test
  func `a generic source is capitalised where it starts a sentence`() {
    #expect(status(.feedStale(minutesSinceProduct: 300), source: "the weather radio")?.text
      == "The weather radio hasn't heard from the Weather Service for 5 h. New alerts may not reach you.")
  }

  @Test
  func `offline says your radio is not connected and names the list's time`() {
    let line = status(.radioOffline(listAsOf: Self.elevenOhTwo))
    #expect(line?.text == "Your radio isn't connected. Last alert list as of 11:02 PM.")
    #expect(line?.caption == "Connect your radio to ask WX-AUS")
  }

  @Test
  func `missed messages and an old list ask for alerts`() {
    #expect(status(.missedMessages)?.text == "This phone missed messages from WX-AUS. Some alerts may be missing.")
    #expect(status(.missedMessages)?.action == .askForAlerts)
    #expect(status(.listOld(asOf: Self.eightOhTwo))?.text == "Last alert list as of 8:02 PM.")
    #expect(status(.listOld(asOf: Self.eightOhTwo))?.action == .askForAlerts)
  }

  @Test
  func `an old location offers to update it`() {
    let line = status(.locationOld(since: Self.now.addingTimeInterval(-3 * 3600)))
    #expect(line?.text == "Your location is 3 h old.")
    #expect(line?.action == .updateLocation)
  }

  @Test
  func `an office the radio has not shown names the county and office`() {
    #expect(status(.officeMayNotBeCovered(office: "FWD"), area: "Bell County")?.text
      == "WX-AUS may not carry alerts for Bell County (NWS Fort Worth).")
    #expect(status(.officeMayNotBeCovered(office: "FWD"))?.text
      == "WX-AUS may not carry alerts for Austin (NWS Fort Worth).")
  }

  @Test
  func `rows speak for themselves`() {
    #expect(status(.rowsSpeak) == nil)
  }

  @Test
  func `alerts only elsewhere never earn the check`() {
    let line = status(.noneHere(elsewhere: 2, asOf: Self.elevenOhTwo))
    #expect(line?.text == "None for your location · as of 11:02 PM")
    #expect(line?.showsCheck == false)
    #expect(status(.noneHere(elsewhere: 2, asOf: Self.elevenOhTwo), place: Self.roundRock)?.text
      == "None for Round Rock · as of 11:02 PM")
  }

  @Test
  func `only nothing anywhere is the green check`() {
    let line = status(.clear(asOf: Self.elevenOhTwo))
    #expect(line?.text == "No alerts received · as of 11:02 PM")
    #expect(line?.showsCheck == true)
  }

  @Test
  func `the alerts card is titled for the place`() {
    #expect(WeatherCopy.alertsTitle(placeName: "Austin") == "Alerts for Austin")
    #expect(WeatherCopy.alertsTitle(placeName: nil) == "Alerts")
  }

  // MARK: - Request status (§11)

  func request(
    _ status: WeatherRequestStatus, for asked: WeatherRequest? = nil, answer: WeatherAnswerNote? = nil, source: String = "WX-AUS"
  ) -> String? {
    WeatherCopy.requestStatus(
      status, source: source, request: asked, answer: answer, now: Self.now, calendar: F.calendar, locale: F.locale)
      .map(F.plain)
  }

  @Test
  func `idle says nothing and blocks replace the button`() {
    #expect(request(.idle) == nil)
    #expect(request(.blocked(.radioOffline)) == "Connect your radio to ask WX-AUS")
    #expect(request(.blocked(.botNotAnnounced)) == "Can't ask until it announces itself")
    #expect(request(.blocked(.firmwareTooOld)) == "Your radio's firmware can't ask for weather")
    #expect(request(.blocked(.channelMissing)) == "Add #meshwx to your radio to ask")
    #expect(request(.blocked(.noBot)) != nil)
  }

  @Test
  func `pending, retrying and waiting`() {
    #expect(request(.pending(attempt: 0, sentAt: Self.now)) == "Asking WX-AUS… (up to 30 s)")
    #expect(request(.pending(attempt: 1, sentAt: Self.now)) == "Asking again…")
    #expect(request(.waitingForOther) == "Waiting for another answer…")
  }

  @Test
  func `every answer confirms, and one that changed nothing says so`() {
    let at = Self.now.addingTimeInterval(-60)
    #expect(request(.settled(.answered, at: at)) == "WX-AUS answered at 11:19 PM")
    #expect(request(.settled(.answered, at: at), answer: .changed) == "WX-AUS answered at 11:19 PM")
    #expect(request(.settled(.answered, at: at), answer: .unchanged(.other)) == "WX-AUS answered at 11:19 PM · nothing new")
  }

  @Test
  func `an unchanged forecast or reading never reads as up to date`() {
    let at = Self.now
    #expect(request(.settled(.answered, at: at), answer: .unchanged(.forecast)) == "No newer forecast from WX-AUS")
    #expect(request(.settled(.answered, at: at), answer: .unchanged(.readings)) == "No newer readings from WX-AUS")
  }

  @Test
  func `an answer the channel already delivered names its age and what it was as of`() {
    let received = Self.now.addingTimeInterval(-40)
    let settled = { (asOf: Date?) in WeatherRequestStatus.settled(.servedFromCache(receivedAt: received, contentAsOf: asOf), at: Self.now) }
    #expect(request(settled(nil), for: .spaceWeather) == "Received 40 s ago")
    #expect(request(settled(Self.elevenOhTwo), for: .digest) == "Received 40 s ago · list as of 11:02 PM")
    #expect(request(settled(Self.elevenOhTwo), for: .activeWarnings) == "Received 40 s ago · list as of 11:02 PM")
    #expect(request(settled(Self.elevenOhTwo), for: .observations) == "Received 40 s ago · readings as of 11:02 PM")
    #expect(request(settled(Self.eightOhTwo), for: .forecast(point: 103)) == "Received 40 s ago · issued 8:02 PM")
    #expect(request(settled(Self.eightOhTwo), for: .metar(station: "KAUS")) == "Received 40 s ago")
  }

  @Test
  func `an answer this phone already holds stands in for its button`() {
    #expect(F.plain(WeatherCopy.ownedReply(
      source: "WX-AUS", at: Self.elevenOhTwo, now: Self.now, calendar: F.calendar, locale: F.locale))
      == "WX-AUS answered at 11:02 PM")
  }

  @Test
  func `timeouts blame the right cause and name the time`() {
    let at = Self.now.addingTimeInterval(6 * 60)
    #expect(request(.settled(.timedOut(botWasHeard: false), at: at)) == "No answer at 11:26 PM. WX-AUS may be out of range.")
    #expect(request(.settled(.timedOut(botWasHeard: true), at: at)) == "WX-AUS was heard but didn't answer at 11:26 PM.")
  }

  @Test
  func `refusals name the radio and a failed send names your radio`() {
    #expect(request(.settled(.notAvailable(.noData), at: Self.now)) == "WX-AUS has no data for that yet")
    #expect(request(.settled(.notAvailable(.unknownLocation), at: Self.now)) == "WX-AUS didn't recognize that place")
    #expect(request(.settled(.notAvailable(.unsupported), at: Self.now)) == "WX-AUS can't do that")
    #expect(request(.settled(.notAvailable(.botError), at: Self.now)) == "WX-AUS had an error")
    #expect(request(.settled(.notAvailable(.rateLimited), at: Self.now)) == "WX-AUS is busy, try again in a few minutes")
    #expect(request(.settled(.notAvailable(.noData), at: Self.now), source: "the weather radio")
      == "The weather radio has no data for that yet")
    #expect(request(.settled(.failed("disconnected"), at: Self.now)) == "Your radio couldn't send this at 11:20 PM.")
  }

  @Test
  func `a quiet radio caption names when it was last heard`() {
    #expect(F.plain(WeatherCopy.quietCaption(
      source: "WX-AUS", since: Self.eightOhTwo, now: Self.now, calendar: F.calendar, locale: F.locale))
      == "WX-AUS not heard since 8:02 PM — it may not answer")
  }

  // MARK: - Header (§10)

  func header(
    _ place: WeatherPlace?, state: WeatherPlaceState = .resolved, heard: Date? = WeatherCopyTests.now.addingTimeInterval(-120)
  ) -> WeatherCopy.Header {
    WeatherCopy.header(place: place, placeState: state, sourceName: "WX-AUS", sourceHeardAt: heard, now: Self.now)
  }

  @Test
  func `your location names the radio and when it was last heard, on one line`() {
    let line = header(Self.austin)
    #expect(line.title == "Austin")
    #expect(line.subtitle == "Your location · WX-AUS last heard 2 min ago")
    #expect(line.action == nil)
  }

  @Test
  func `a searched town says so without repeating its name, and offers the way back`() {
    let line = header(Self.roundRock)
    #expect(line.title == "Round Rock")
    #expect(line.subtitle == "Searched town")
    #expect(line.action == .backToMyLocation)
  }

  @Test
  func `an old fix is still your location, with its age`() {
    var place = Self.austin
    place.kind = .lastKnown
    place.locatedAt = Self.now.addingTimeInterval(-3 * 3600)
    #expect(header(place).subtitle == "Your location · 3 h old")
  }

  @Test
  func `locating shows while a fix is on its way, even over an older one`() {
    #expect(header(Self.austin, state: .locating).subtitle == "Locating…")
    #expect(header(Self.roundRock, state: .locating).subtitle == "Searched town")
    #expect(header(nil, state: .locating).subtitle == "Locating…")
  }

  @Test
  func `no place asks for one and says why`() {
    #expect(header(nil, state: .needsPermission).title == "Choose a place")
    let denied = header(nil, state: .denied)
    #expect(denied.subtitle == "Location is off")
    #expect(denied.action == .openSettings)
  }

  @Test
  func `banners speak of your radio`() {
    #expect(WeatherCopy.banner(.firmwareTooOld(version: "v1.14.0")) == "Your radio has firmware 1.14. Weather needs MeshCore 1.15 or newer.")
    #expect(WeatherCopy.banner(.channelMissing) == "#meshwx isn't set up on your radio.")
    #expect(WeatherCopy.banner(.noBotHeard) == "No weather radio heard yet. They appear as nodes named like WX-AUS.")
  }

  // MARK: - Alert rows (§7.3)

  static func warning(event: UInt8, etn: UInt16, minutes: Int = 60, polygonAt latitude: Double, longitude: Double = -97.74,
                      areas: [MeshWXAreaRun]? = nil) -> WeatherStoredWarning {
    let polygon = [
      MeshWXCoordinate(latitude: latitude + 0.05, longitude: longitude - 0.06),
      MeshWXCoordinate(latitude: latitude + 0.05, longitude: longitude + 0.06),
      MeshWXCoordinate(latitude: latitude - 0.05, longitude: longitude + 0.06),
      MeshWXCoordinate(latitude: latitude - 0.05, longitude: longitude - 0.06)
    ]
    let expires = UInt32((now.timeIntervalSince1970 + Double(minutes * 60)) / 60)
    return WeatherStoredWarning(
      warning: MeshWXWarning(
        identity: MeshWXWarningIdentity(event: event, office: 35, etn: etn), expiresMinutes: expires,
        polygon: polygon, areas: areas),
      receivedAt: now)
  }

  static func items(_ warnings: [WeatherStoredWarning], place: WeatherPlace? = austin) -> [WeatherAlertItem] {
    var state = WeatherBotState(botID: 0x041D)
    for stored in warnings {
      state.warnings[stored.identity] = stored
    }
    return WeatherAlertItems.make(
      states: [0x041D: state], place: place, geometry: MeshWXGeometry.shared, tables: .shared, now: now)
  }

  @Test
  func `the card folds after two rows, but never a storm warning`() {
    let tables = MeshWXTables.shared
    let tornadoes = Self.items([
      Self.warning(event: 1, etn: 1, polygonAt: 30.2672),
      Self.warning(event: 1, etn: 2, polygonAt: 30.2672),
      Self.warning(event: 1, etn: 3, polygonAt: 30.2672)
    ])
    let unfolded = WeatherAlertFolding.fold(tornadoes, tables: tables)
    #expect(unfolded.rows.count == 3)
    #expect(unfolded.folded == 0)

    // Heat Advisory.
    let advisories = Self.items([
      Self.warning(event: 14, etn: 11, polygonAt: 30.2672),
      Self.warning(event: 14, etn: 12, polygonAt: 30.2672),
      Self.warning(event: 14, etn: 13, polygonAt: 30.2672)
    ])
    let folded = WeatherAlertFolding.fold(advisories, tables: tables)
    #expect(folded.rows.count == 2)
    #expect(folded.folded == 1)
  }

  @Test
  func `the covers line says here, how far, or that it cannot tell`() {
    #expect(WeatherCopy.coversLine(.here, placeName: "Austin") == "Covers Austin")
    #expect(WeatherCopy.coversLine(.near(kilometres: 25, direction: .north), placeName: "Austin") == "Doesn't cover Austin (25 km N)")
    #expect(WeatherCopy.coversLine(.elsewhere, placeName: "Austin") == "Doesn't cover Austin")
    #expect(WeatherCopy.coversLine(.unplaced, placeName: "Austin") == "Not sure it covers Austin")
  }

  @Test
  func `an alert elsewhere says which county and how far`() {
    // Llano County (TXC299), about 100 km west-northwest of downtown Austin.
    let llano = Self.warning(
      event: 3, etn: 44, polygonAt: 30.75, longitude: -98.67,
      areas: [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 299, run: 1)])
    let located = WeatherCopy.alertLocation(llano.warning, place: Self.austin, tables: .shared)
    #expect(located?.hasPrefix("Llano County · ") == true)
    #expect(located?.contains(" km W") == true)
    #expect(WeatherCopy.alertLocation(llano.warning, place: nil, tables: .shared) == "Llano County")
  }

  // MARK: - Forecast (§9)

  @Test
  func `row labels read against now in the phone's calendar`() {
    let calendar = F.calendar
    let wednesday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16)) ?? Self.now
    #expect(WeatherCopy.rowLabel(.today, calendar: calendar, locale: F.locale) == "Today")
    #expect(WeatherCopy.rowLabel(.tonight, calendar: calendar, locale: F.locale) == "Tonight")
    #expect(WeatherCopy.rowLabel(.tomorrow, calendar: calendar, locale: F.locale) == "Tomorrow")
    #expect(WeatherCopy.rowLabel(.tomorrowNight, calendar: calendar, locale: F.locale) == "Tomorrow night")
    #expect(WeatherCopy.rowLabel(.day(wednesday), calendar: calendar, locale: F.locale) == "Wednesday")
    #expect(WeatherCopy.rowLabel(.night(wednesday), calendar: calendar, locale: F.locale) == "Wednesday night")
  }

  @Test
  func `temperatures show what the row carries`() {
    let degrees = { WeatherFormatting.temperature(fahrenheit: $0, locale: F.locale) }
    #expect(WeatherCopy.temperatures(highF: 90, lowF: 70, locale: F.locale) == "\(degrees(90)) / \(degrees(70))")
    #expect(WeatherCopy.temperatures(highF: 90, lowF: nil, locale: F.locale) == "High \(degrees(90))")
    #expect(WeatherCopy.temperatures(highF: nil, lowF: 70, locale: F.locale) == "Low \(degrees(70))")
    #expect(WeatherCopy.temperatures(highF: nil, lowF: nil, locale: F.locale) == nil)
  }

  @Test
  func `a missing forecast names a far point, and no point says so`() throws {
    let point = try #require(MeshWXTables.shared.point(at: 103))
    let name = WeatherNames.pointName(point.name)
    #expect(WeatherCopy.forecastMissing(placeName: "Austin", point: point, kilometres: 4) == "No forecast for Austin yet.")
    #expect(WeatherCopy.forecastMissing(placeName: "Big Spring", point: point, kilometres: 60)
      == "No forecast for Big Spring yet. The nearest forecast point is \(name), 60 km.")
    #expect(WeatherCopy.noForecastPoint(placeName: "Albuquerque") == "No forecast point near Albuquerque.")
  }

  // MARK: - Now (§8)

  @Test
  func `the source line names the station with its direction, or the nearest report beyond 25 km`() {
    let reported = Self.now.addingTimeInterval(-2 * 60)
    #expect(F.plain(WeatherCopy.stationSource(
      stationName: "Austin-Camp Mabry", kilometres: 6.2, direction: .northNorthWest, botName: "WX-AUS", reportedAt: reported,
      now: Self.now, calendar: F.calendar, locale: F.locale)) == "Austin-Camp Mabry · 6 km NNW · in WX-AUS's 11:18 PM report")
    #expect(F.plain(WeatherCopy.stationSource(
      stationName: "Llano Municipal Airport", kilometres: 40, direction: .northWest, botName: "WX-AUS", reportedAt: reported,
      now: Self.now, calendar: F.calendar, locale: F.locale)) == "Nearest report · 40 km NW · in WX-AUS's 11:18 PM report")
  }

  @Test
  func `no station nearby names the nearest one's town, and the link names the area`() {
    #expect(WeatherCopy.noStationNearby(placeName: "Dallas", nearestTown: "Temple", kilometres: 190)
      == "No weather station near Dallas. Nearest: Temple, 190 km.")
    #expect(WeatherCopy.stationLink(inArea: 14, total: 14, source: "WX-AUS") == "14 stations in WX-AUS's area")
    #expect(WeatherCopy.stationLink(inArea: 1, total: 3, source: "WX-AUS") == "1 station in WX-AUS's area")
    #expect(WeatherCopy.stationLink(inArea: 0, total: 3, source: "WX-AUS") == "3 weather stations")
    #expect(WeatherCopy.stationLink(inArea: 0, total: 1, source: "WX-AUS") == "1 weather station")
  }
}
