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
    #expect(status(.outOfCoverage, place: Self.dallas)?.text == "Dallas, TX is outside WX-AUS's area, so alerts there are unknown.")
  }

  @Test
  func `no alert list yet says the phone cannot tell, and offers to ask`() {
    let line = status(.notChecked)
    #expect(line?.text
      == "This phone hasn't received WX-AUS's alert list yet, so it can't tell whether any alerts are active. The list comes every 3 hours.")
    #expect(line?.action == .askForAlerts)
  }

  @Test
  func `a quiet home office says it may be normal, never that alerts may not arrive, and has no button`() {
    let line = status(.feedQuiet(minutesSinceProduct: 300))
    #expect(line?.text
      == "WX-AUS hasn't had anything from its home Weather Service office for 5 h. That's normal on a quiet night, but its feed could also be down.")
    #expect(line?.action == nil)
  }

  @Test
  func `a feed that never delivered says new alerts may not reach you, with no button`() {
    let line = status(.feedNeverReceived)
    #expect(line?.text == "WX-AUS hasn't received anything from the Weather Service. New alerts may not reach you.")
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
    #expect(status(.feedNeverReceived, source: "the weather radio")?.text
      == "The weather radio hasn't received anything from the Weather Service. New alerts may not reach you.")
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
      == "WX-AUS may not carry alerts for Austin, TX (NWS Fort Worth).")
  }

  @Test
  func `rows speak for themselves`() {
    #expect(status(.rowsSpeak) == nil)
  }

  /// Answer 13: nothing about alerts on a quiet day. No check, no "none for your location", no
  /// status line — the honesty moved to the radio row and the radio page.
  @Test
  func `a quiet day says nothing at all`() {
    #expect(status(.noneHere(elsewhere: 2, asOf: Self.elevenOhTwo)) == nil)
    #expect(status(.noneHere(elsewhere: 2, asOf: Self.elevenOhTwo), place: Self.roundRock) == nil)
    #expect(status(.clear(asOf: Self.elevenOhTwo)) == nil)
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
  func `pending, retrying, flooding and waiting`() {
    // No duration in the pending line: a channel request settles within 20 s, the DM fallback
    // within 45 s, and one number would be wrong for the other.
    #expect(request(.pending(attempt: 0, sentAt: Self.now)) == "Asking WX-AUS…")
    #expect(request(.pending(attempt: 1, sentAt: Self.now)) == "Asking again…")
    // The DM ladder's third send, after the route was forgotten.
    #expect(request(.pending(attempt: 2, sentAt: Self.now)) == "Asking again by flood…")
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
    let settled = { (asOf: Date?) in WeatherRequestStatus.settled(.alreadyReceived(receivedAt: received, contentAsOf: asOf), at: Self.now) }
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

  /// Out of range, one request per sender every five seconds, and 60 answers an hour all end in
  /// silence (spec §8.3): the copy allows for all three.
  @Test
  func `timeouts allow for range and a busy radio, and name the time`() {
    let at = Self.now.addingTimeInterval(6 * 60)
    #expect(request(.settled(.timedOut(botWasHeard: false), at: at)) == "No answer at 11:26 PM. WX-AUS may be out of range or busy.")
    #expect(request(.settled(.timedOut(botWasHeard: true), at: at)) == "WX-AUS was heard but didn't answer at 11:26 PM. It may be busy.")
  }

  /// The bot's radio confirmed the request, so the copy leaves out range: the bot may be busy, or
  /// its answer was lost. Unconfirmed keeps "may be out of range or busy".
  @Test
  func `a timeout the bot's radio confirmed says the request arrived`() {
    let at = Self.now.addingTimeInterval(6 * 60)
    let received = "WX-AUS received the request, but no answer reached this phone by 11:26 PM. It may be busy, or its answer was lost."
    #expect(request(.settled(.timedOut(botWasHeard: false, botRadioReceived: true), at: at)) == received)
    #expect(request(.settled(.timedOut(botWasHeard: true, botRadioReceived: true), at: at)) == received)
    #expect(request(.settled(.timedOut(botWasHeard: false, botRadioReceived: false), at: at))
      == "No answer at 11:26 PM. WX-AUS may be out of range or busy.")
  }

  @Test
  func `an ask for one missing warning names it`() {
    #expect(WeatherCopy.askAlertsTitle(for: .warning(identity: "TO.W.EWX.30"), tables: .shared) == "Ask for Tornado Warning")
    #expect(WeatherCopy.askAlertsTitle(for: .digest, tables: .shared) == "Ask for alerts")
    #expect(WeatherCopy.askAlertsTitle(for: .warningsTouching(ugc: "TXC453"), tables: .shared) == "Ask for alerts")
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

  // MARK: - The radio row (§10)

  func radioRow(
    _ row: WeatherRadioRow, source: String = "WX-AUS"
  ) -> String {
    F.plain(WeatherCopy.radioRow(row, source: source, now: Self.now, calendar: F.calendar, locale: F.locale))
  }

  @Test
  func `the radio row names the radio, when it was heard, and how old the list is`() {
    #expect(radioRow(WeatherRadioRow(
      heardAt: Self.now.addingTimeInterval(-120), listBuiltAt: Self.eightOhTwo,
      missedMessages: false, listIsOld: false))
      == "WX-AUS · heard 2 min ago · alerts as of 8:02 PM")
  }

  /// The row never leaves the alert list out: with none held it says so, because the page above
  /// it now says nothing about alerts at all.
  @Test
  func `no list and nothing heard are both said, not left out`() {
    #expect(radioRow(WeatherRadioRow()) == "WX-AUS · not heard yet · no alert list yet")
  }

  // MARK: - The temperature block (§8)

  @Test
  func `the one line under the temperature is the station, the distance and the reading's own time`() {
    #expect(F.plain(WeatherCopy.conditionsSource(
      stationName: "Austin-Camp Mabry", kilometres: 6.2, observedAt: Self.now.addingTimeInterval(-2 * 60),
      now: Self.now, calendar: F.calendar, locale: F.locale)) == "Austin-Camp Mabry · 6 km · as of 11:18 PM")
    // No place, no distance: the time still stands, because the reading has one of its own.
    #expect(F.plain(WeatherCopy.conditionsSource(
      stationName: "Llano Municipal Airport", kilometres: nil, observedAt: Self.now.addingTimeInterval(-2 * 60),
      now: Self.now, calendar: F.calendar, locale: F.locale)) == "Llano Municipal Airport · as of 11:18 PM")
  }

  /// From 25 to 40 km the reading is shown, but under its station: the station and distance lead,
  /// above the number, and the line at the foot keeps only the time (§3.1 U-2a).
  @Test
  func `a reading from 25 to 40 km names its station above the number and its time below`() {
    #expect(F.plain(WeatherCopy.nearbyReadingLead(stationName: "San Marcos", kilometres: 25.51))
      == "Nearest report: San Marcos, 26 km away")
    #expect(F.plain(WeatherCopy.nearbyReadingLead(stationName: "San Marcos", kilometres: nil))
      == "Nearest report: San Marcos")
    #expect(F.plain(WeatherCopy.conditionsSource(
      stationName: nil, kilometres: nil, observedAt: Self.now.addingTimeInterval(-2 * 60),
      now: Self.now, calendar: F.calendar, locale: F.locale)) == "As of 11:18 PM")
  }

  /// No good reading means no temperature at all — only the ask, and the code it would spend
  /// airtime on (answer 11).
  @Test
  func `no good reading names the place, the radio and the station's code`() {
    #expect(WeatherCopy.conditionsAsk(placeName: "Llano", source: "WX-AUS", icao: "KAQO")
      == "No current conditions for Llano. Pull down to ask WX-AUS for KAQO.")
  }

  // MARK: - Places rows (§12)

  @Test
  func `a places row is the temperature and the condition, aged when stale and a dash when empty`() {
    let fresh = WeatherPlaceRowReading(
      tempF: 86, sky: .broken, observedAt: Self.now.addingTimeInterval(-12 * 60), isStale: false)
    #expect(F.plain(WeatherCopy.placeRow(fresh, now: Self.now, locale: F.locale)) == "86° Mostly cloudy")

    var stale = fresh
    stale.observedAt = Self.now.addingTimeInterval(-3 * 3600)
    stale.isStale = true
    #expect(F.plain(WeatherCopy.placeRow(stale, now: Self.now, locale: F.locale)) == "86° Mostly cloudy · 3 h old")

    #expect(WeatherCopy.placeRow(WeatherPlaceRowReading(), now: Self.now, locale: F.locale) == "—")

    // From 25 to 40 km the page names the station, so the row does too.
    var attributed = fresh
    attributed.attributedStation = "San Marcos"
    #expect(F.plain(WeatherCopy.placeRow(attributed, now: Self.now, locale: F.locale))
      == "86° Mostly cloudy · San Marcos")
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

  /// Revision 10, §1.3: "No forecast point near Albuquerque." is gone. `pfm_points.json` version 1
  /// had no point at all for nine offices, so the app said that and offered nothing while the bot
  /// held a forecast fifteen kilometres away — the owner's fourth ask. A place with no bundled
  /// point in reach says only that there is no forecast yet, and Update sends `>f <lat>,<lon>`.
  @Test
  func `a missing forecast names a far point, and with no point at all says only that`() throws {
    let point = try #require(MeshWXTables.shared.point(at: 103))
    let name = WeatherNames.pointLabel(point.name)
    #expect(WeatherCopy.forecastMissing(placeName: "Austin", point: point, kilometres: 4) == "No forecast for Austin yet.")
    #expect(WeatherCopy.forecastMissing(placeName: "Big Spring", point: point, kilometres: 60)
      == "No forecast for Big Spring yet. The nearest forecast point is \(name), 60 km.")
    #expect(WeatherCopy.forecastMissing(placeName: "Santa Fe", point: nil, kilometres: nil)
      == "No forecast for Santa Fe yet.")
    // A point with no distance cannot claim one either.
    #expect(WeatherCopy.forecastMissing(placeName: "Santa Fe", point: point, kilometres: nil)
      == "No forecast for Santa Fe yet.")
  }

  /// A forecast the **bot** picked the point for has no bundled point to name (revision 10,
  /// §1.3), so the card says who picked it rather than leaving the rows unattributed.
  @Test
  func `a bot-chosen forecast point is labelled as the radio's choice`() {
    #expect(L10n.Weather.Weather.Forecast.chosenByBot("WX-AUS") == "Forecast point chosen by WX-AUS")
  }

  // MARK: - Now (§8)

  /// The station screen says each fact once: the name is its headline, the distance is its
  /// "from Austin" line, and this is the message the reading arrived in (§3.1 U-8).
  @Test
  func `the report line names the radio and the message, and nothing the screen already says`() {
    let reported = Self.now.addingTimeInterval(-2 * 60)
    #expect(F.plain(WeatherCopy.stationReport(
      botName: "WX-AUS", reportedAt: reported, now: Self.now, calendar: F.calendar, locale: F.locale))
      == "in WX-AUS's 11:18 PM report")
  }

  @Test
  func `no station nearby names the nearest one's town, and the link names the area`() {
    #expect(WeatherCopy.noStationNearby(placeName: "Dallas", nearestTown: "Temple", kilometres: 190)
      == "No weather station near Dallas. Nearest: Temple, 190 km.")
    #expect(WeatherCopy.stationLink(inArea: 14, total: 14, source: "WX-AUS") == "14 stations in WX-AUS's area")
    #expect(WeatherCopy.stationLink(inArea: 1, total: 1, source: "WX-AUS") == "1 station in WX-AUS's area")
    // The link promised 14 rows and opened 19: it names every station the screen will show.
    #expect(WeatherCopy.stationLink(inArea: 14, total: 19, source: "WX-AUS") == "19 weather stations, 14 in WX-AUS's area")
    #expect(WeatherCopy.stationLink(inArea: 1, total: 3, source: "WX-AUS") == "3 weather stations, 1 in WX-AUS's area")
    #expect(WeatherCopy.stationLink(inArea: 0, total: 3, source: "WX-AUS") == "3 weather stations")
    #expect(WeatherCopy.stationLink(inArea: 0, total: 1, source: "WX-AUS") == "1 weather station")
  }

  // MARK: - Where the data came from (§12.1)

  @Test
  func `the source line names the path the data took, and says nothing when the radio did not`() {
    #expect(WeatherCopy.dataSource(.goesSatellite) == "Via GOES satellite")
    #expect(WeatherCopy.dataSource(.internet) == "Via internet")
    #expect(WeatherCopy.dataSource(.mixed) == "Via GOES and internet")
    // A radio older than revision 7 has made no claim, and no screen may invent one for it.
    #expect(WeatherCopy.dataSource(.unstated) == nil)
  }

  @Test
  func `a shortened reply says so, beside the source when there is one`() {
    #expect(WeatherCopy.reportFootnote(source: .goesSatellite, wasCut: false) == "Via GOES satellite")
    #expect(WeatherCopy.reportFootnote(source: .unstated, wasCut: true) == "Shortened for radio")
    #expect(WeatherCopy.reportFootnote(source: .internet, wasCut: true)
      == "Via internet · Shortened for radio")
    // Neither fact: no row at all, so a card from an older radio reads exactly as it did.
    #expect(WeatherCopy.reportFootnote(source: .unstated, wasCut: false) == nil)
  }
  // MARK: - The alert map (§17, revision 10)

  static func sweep(
    builtMinutesAgo: Int = 0,
    group: UInt8 = 7,
    total: UInt8 = 1,
    packets: [UInt8: [MeshWXAreaSweep.Entry]] = [0: []],
    wasCut: Bool = false,
    includesAdvisories: Bool = false,
    isScoped: Bool = false,
    scope: [UInt8]? = []
  ) -> WeatherAreaSweepAssembly {
    let built = UInt32(now.timeIntervalSince1970 / 60) - UInt32(builtMinutesAgo)
    return WeatherAreaSweepAssembly(
      builtMinutes: built, group: group, total: total, packets: packets,
      firstReceivedAt: now, lastReceivedAt: now, wasCut: wasCut,
      includesAdvisories: includesAdvisories, isScoped: isScoped, scope: scope)
  }

  static func picture(_ sweeps: [WeatherAreaSweepAssembly]) -> WeatherAlertMapPicture {
    WeatherAlertMapPicture.make(sweeps: sweeps, states: MeshWXTables.shared.states, now: now)
  }

  static func stateIndex(_ code: String) -> UInt8 {
    UInt8(MeshWXTables.shared.states.firstIndex(of: code) ?? 0)
  }

  static func partLine(_ part: WeatherAlertMapPicture.Part, in picture: WeatherAlertMapPicture) -> String {
    F.plain(WeatherAreaMapCopy.partLine(
      part, picture: picture, now: now, calendar: F.calendar, locale: F.locale, tables: .shared))
  }

  /// The radio's own build time, and how long ago that was — never when the packets arrived.
  @Test
  func `the map line names when the radio built it and how old that makes it`() {
    #expect(F.plain(WeatherAreaMapCopy.builtLine(
      Self.sweep(builtMinutesAgo: 198), now: Self.now, calendar: F.calendar, locale: F.locale))
      == "Map as of 8:02 PM · 3 h old")
  }

  /// Revision 10: a phone holds several sweeps at once, so the card is one line per part — what
  /// each is the newest word on, when the radio built it, and how old that makes it. A national
  /// part is "the whole country" until something scoped and newer takes states off it.
  @Test
  func `each part of the map names what it is the word on, with its own age`() {
    let picture = Self.picture([
      Self.sweep(builtMinutesAgo: 20, group: 1),
      Self.sweep(builtMinutesAgo: 2, group: 2, isScoped: true,
                 scope: [Self.stateIndex("TX"), Self.stateIndex("OK")])
    ])
    #expect(Self.partLine(picture.parts[0], in: picture) == "Oklahoma and Texas · as of 11:18 PM · 2 min old")
    #expect(Self.partLine(picture.parts[1], in: picture) == "The rest of the country · as of 11:00 PM · 20 min old")
    #expect(WeatherAreaMapCopy.level(picture.parts[0]) == "Warnings and watches")
    #expect(WeatherAreaMapCopy.level(Self.picture([Self.sweep(includesAdvisories: true)]).parts[0])
      == "Warnings, watches and advisories")
    // With nothing scoped over it, the national part speaks for the country and says so.
    let alone = Self.picture([Self.sweep(builtMinutesAgo: 20, group: 1)])
    #expect(Self.partLine(alone.parts[0], in: alone) == "The whole country · as of 11:00 PM · 20 min old")
  }

  /// Two parts a reader would otherwise have to work out for themselves: one whose scope never
  /// arrived, and one every state of which a newer sweep has since covered.
  @Test
  func `a part with no scope says so, and one a newer part replaced says that`() throws {
    let texas = Self.stateIndex("TX")
    let picture = Self.picture([
      Self.sweep(builtMinutesAgo: 1, group: 3, isScoped: true, scope: nil),
      Self.sweep(builtMinutesAgo: 5, group: 4, isScoped: true, scope: [texas]),
      Self.sweep(builtMinutesAgo: 30, group: 5, isScoped: true, scope: [texas])
    ])
    #expect(Self.partLine(picture.parts[0], in: picture)
      == "Part of the country, states not known · as of 11:19 PM · 1 min old")
    // A scope that never arrived wins no state, but it is not "replaced": nothing took it away.
    #expect(WeatherAreaMapCopy.isReplaced(picture.parts[0]) == false)
    // The newer Texas sweep keeps the state and is named for it.
    #expect(Self.partLine(picture.parts[1], in: picture) == "Texas · as of 11:15 PM · 5 min old")
    #expect(WeatherAreaMapCopy.isReplaced(picture.parts[1]) == false)
    // The older one is still named by what it asked for; the line under it says what happened.
    #expect(Self.partLine(picture.parts[2], in: picture) == "Texas · as of 10:50 PM · 30 min old")
    #expect(WeatherAreaMapCopy.isReplaced(picture.parts[2]))
    #expect(L10n.Weather.Weather.AreaMap.partReplaced == "A newer part above covers these states.")
  }

  /// With nothing national held, an unshaded state outside the scope is **unknown**, and the card
  /// has to say so: it is the one thing a map of two states can be read wrongly about.
  @Test
  func `a map with no national part says which states it covers, and that the rest was not asked for`() {
    let picture = Self.picture([
      Self.sweep(isScoped: true, scope: [Self.stateIndex("TX"), Self.stateIndex("OK")])
    ])
    #expect(picture.coversWholeCountry == false)
    #expect(WeatherAreaMapCopy.coveredStates(picture) == "Oklahoma and Texas")
    #expect(L10n.Weather.Weather.AreaMap.covers("Oklahoma and Texas")
      == "This map covers Oklahoma and Texas.")
    #expect(L10n.Weather.Weather.AreaMap.notAsked
      == "The rest of the country was not asked for. A state outside this map is unknown, not clear.")
    // A part whose scope never arrived can name nothing, so the sentence is not offered at all.
    #expect(WeatherAreaMapCopy.coveredStates(
      Self.picture([Self.sweep(isScoped: true, scope: nil)])) == nil)
  }

  @Test
  func `the map counts the areas it shades`() {
    var drawing = WeatherAreaMapDrawing()
    drawing.areaCount = 1
    #expect(WeatherAreaMapCopy.areaCount(drawing, picture: Self.picture([Self.sweep()]), source: "WX-AUS")
      == "1 area under an alert")
    drawing.areaCount = 42
    #expect(WeatherAreaMapCopy.areaCount(drawing, picture: Self.picture([Self.sweep()]), source: "WX-AUS")
      == "42 areas under an alert")
  }

  /// "Nothing anywhere" needs a whole map of the whole country. A part that was cut, or that is
  /// missing packets, says nothing about the areas it never named — and a map of two states says
  /// nothing about the forty-eight nobody asked about.
  @Test
  func `only a whole national map may call the country clear`() {
    let drawing = WeatherAreaMapDrawing()
    func count(_ sweeps: [WeatherAreaSweepAssembly]) -> String? {
      WeatherAreaMapCopy.areaCount(drawing, picture: Self.picture(sweeps), source: "WX-AUS")
    }
    #expect(count([Self.sweep()]) == "WX-AUS found nothing under an alert anywhere in the country.")
    #expect(count([Self.sweep(wasCut: true)]) == nil)
    #expect(count([Self.sweep(total: 3, packets: [0: []])]) == nil)
    #expect(count([Self.sweep(isScoped: true, scope: [Self.stateIndex("TX")])]) == nil)
    // A hole in any part silences it, not only a hole in the national one.
    #expect(count([
      Self.sweep(builtMinutesAgo: 20, group: 1),
      Self.sweep(builtMinutesAgo: 2, group: 2, total: 3, packets: [0: []], isScoped: true,
                 scope: [Self.stateIndex("TX")])
    ]) == nil)
  }

  /// The bundle is a cut in time and the UGC tables grow, so a map is honestly a little smaller
  /// than the sweep — and the difference is said rather than swallowed.
  @Test
  func `areas with no outline are counted out loud`() {
    var drawing = WeatherAreaMapDrawing()
    #expect(WeatherAreaMapCopy.undrawn(drawing) == nil)
    drawing.undrawnCount = 1
    #expect(WeatherAreaMapCopy.undrawn(drawing) == "1 of them has no outline in this app and isn\'t shaded")
    drawing.undrawnCount = 6
    #expect(WeatherAreaMapCopy.undrawn(drawing) == "6 of them have no outline in this app and aren\'t shaded")
  }

  /// Reason 4 on a sweep is not the radio being broken and not the radio being busy: somebody
  /// else has just spent those packets, and this phone is about to be handed the same map.
  @Test
  func `a refused map reads as another radio having asked, never as an error`() {
    let refused = WeatherRequestStatus.settled(.notAvailable(.rateLimited), at: Self.now)
    #expect(request(refused, for: .areaSweep(includesAdvisories: false, states: []))
      == "Another radio asked WX-AUS for the map recently — try again in a few minutes.")
    #expect(request(refused, for: .areaSweep(includesAdvisories: true, states: ["TX"]))
      == "Another radio asked WX-AUS for the map recently — try again in a few minutes.")
    // Every other request keeps the wording it had.
    #expect(request(refused, for: .digest) == "WX-AUS is busy, try again in a few minutes")
    #expect(request(.settled(.notAvailable(.botError), at: Self.now), for: .areaSweep(includesAdvisories: false, states: []))
      == "WX-AUS had an error")
  }

  /// The owner's third ask: *have a way for the user to select which areas they want to request
  /// the warnings for. One, a few, or all.* The row shows the choice, the button names what the
  /// tap will ask for, and past fifteen states the two deliberately differ — with the reason said
  /// before the tap rather than after it.
  @Test
  func `the row names the selection and the button names what the tap asks for`() {
    #expect(WeatherAreaMapCopy.selectionName(.wholeCountry) == "The whole country")
    #expect(WeatherAreaMapCopy.askTitle(.wholeCountry) == "Ask for the whole country")

    let one = WeatherAreaSelection(isWholeCountry: false, states: ["tx"])
    #expect(WeatherAreaMapCopy.selectionName(one) == "Texas")
    #expect(WeatherAreaMapCopy.askTitle(one) == "Ask for Texas")

    let two = WeatherAreaSelection(isWholeCountry: false, states: ["TX", "OK"])
    #expect(WeatherAreaMapCopy.selectionName(two) == "Oklahoma and Texas")
    #expect(WeatherAreaMapCopy.askTitle(two) == "Ask for Oklahoma and Texas")

    let three = WeatherAreaSelection(isWholeCountry: false, states: ["TX", "OK", "NM"])
    #expect(WeatherAreaMapCopy.askTitle(three) == "Ask for New Mexico, Oklahoma and Texas")

    // Past three the names are a wall and the count is the fact.
    let four = WeatherAreaSelection(isWholeCountry: false, states: ["TX", "OK", "NM", "LA"])
    #expect(WeatherAreaMapCopy.selectionName(four) == "4 states")

    // Sixteen states cannot be named in a forty-byte request, so the tap asks for the country.
    let sixteen = WeatherAreaSelection(
      isWholeCountry: false, states: Array(WeatherReferenceNames.stateNames.keys.sorted().prefix(16)))
    #expect(sixteen.isAskingWholeCountryByOverflow)
    #expect(WeatherAreaMapCopy.askTitle(sixteen) == "Ask for the whole country")
    #expect(L10n.Weather.Weather.AreaMap.tooManyStates(MeshWXWire.maxSweepScopeStates)
      == "More than 15 states asks for the whole country.")
    // Fifteen still names itself, by count.
    let fifteen = WeatherAreaSelection(
      isWholeCountry: false, states: Array(WeatherReferenceNames.stateNames.keys.sorted().prefix(15)))
    #expect(fifteen.isAskingWholeCountryByOverflow == false)
  }

  /// Every tap on this screen says what it will spend before it spends it — the sweep in "About N
  /// packets", the parts offer in the exact number it asks the radio to send again.
  @Test
  func `each ask says what it will spend`() {
    let held = Self.picture([Self.sweep(total: 5)])
    #expect(WeatherAreaSweepCost.packets(for: .wholeCountry, advisories: false, held: held) == 5)
    #expect(WeatherAreaMapCopy.cost(5) == "About 5 packets on the shared channel.")
    // One state is often one packet, which is the whole point of asking by state.
    #expect(WeatherAreaMapCopy.cost(1) == "About 1 packet on the shared channel.")
    #expect(WeatherAreaSweepCost.packets(
      for: WeatherAreaSelection(isWholeCountry: false, states: ["TX"]), advisories: false,
      held: Self.picture([])) == 1)
    #expect(WeatherAreaMapCopy.packets(1) == "1 packet")
    #expect(WeatherAreaMapCopy.packets(3) == "3 packets")
    #expect(L10n.Weather.Weather.AreaMap.partsArrived(4, 7) == "4 of 7 parts arrived")

    let three = WeatherRequest.parts(group: 212, indexes: [1, 4, 6], of: .areaSweep)
    #expect(WeatherAreaMapCopy.packetCount(three) == 3)
    #expect(WeatherAreaMapCopy.askPartsTitle(three) == "Ask for the 3 missing parts")
    #expect(WeatherAreaMapCopy.askPartsTitle(three, isReport: true) == "Ask for the 3 missing parts")

    let one = WeatherRequest.parts(group: 212, indexes: [4], of: .text(subject: 3))
    #expect(WeatherAreaMapCopy.askPartsTitle(one) == "Ask for the missing part")
    #expect(WeatherAreaMapCopy.askPartsTitle(one, isReport: true) == "Ask for the missing part")
    // Anything that is not a parts request asks for no packets, and never claims one.
    #expect(WeatherAreaMapCopy.packetCount(.digest) == 0)
  }

  /// The log is where somebody works out what those packets were spent on, so a scoped ask names
  /// its states and a `>part` names what it is filling in.
  @Test
  func `the log names a scoped map, its missing parts and a forecast by coordinate`() {
    #expect(WeatherCopy.requestName(.areaSweep(includesAdvisories: false, states: []))
      == "National alert map")
    #expect(WeatherCopy.requestName(.areaSweep(includesAdvisories: true, states: []))
      == "National alert map · with advisories")
    // Normalised in the row as on the wire: two selections of the same states are one log entry.
    #expect(WeatherCopy.requestName(.areaSweep(includesAdvisories: false, states: ["TX", "OK"]))
      == "Alert map · Oklahoma and Texas")
    #expect(WeatherCopy.requestName(.areaSweep(includesAdvisories: false, states: ["ok", "tx"]))
      == "Alert map · Oklahoma and Texas")
    #expect(WeatherCopy.requestName(.areaSweep(includesAdvisories: true, states: ["TX"]))
      == "Alert map · Texas · with advisories")
    #expect(WeatherCopy.requestName(.parts(group: 212, indexes: [1, 4], of: .areaSweep))
      == "Missing parts of Alert map")
    #expect(WeatherCopy.requestName(.parts(group: 9, indexes: [1], of: .text(subject: 3)))
      == "Missing parts of Storm reports")
    // A subject code this build does not know has no name to put in the sentence.
    #expect(WeatherCopy.requestName(.parts(group: 9, indexes: [1], of: .text(subject: 200)))
      == "Missing parts")
    #expect(WeatherCopy.requestName(.forecastAt(latitude: 35.687, longitude: -105.938))
      == "Forecast for 35.687,-105.938")
    #expect(L10n.Weather.Weather.Request.publicNote == "Everyone listening on #meshwx gets the answer.")
  }

  /// The owner's second ask: *this "on the map" vs "what the phone holds" is weird.* One card, and
  /// the map's own event is worth a row only when no held alert of that kind is already above it.
  @Test
  func `the tapped area names the map's event only when the phone holds no alert of that kind`() {
    let word = WeatherAreaMapWord(event: 12, asOf: Self.eightOhTwo)
    #expect(WeatherAreaMapCopy.unheldMapWord(word, heldEvents: []) == word)
    #expect(WeatherAreaMapCopy.unheldMapWord(word, heldEvents: [7, 40]) == word)
    // The row above it already says this, in full.
    #expect(WeatherAreaMapCopy.unheldMapWord(word, heldEvents: [7, 12]) == nil)
    // Nothing on the map for the area: no row at all, whatever the phone holds.
    #expect(WeatherAreaMapCopy.unheldMapWord(nil, heldEvents: []) == nil)
    #expect(F.plain(L10n.Weather.Weather.AreaMap.onMapAsOf("1:20 PM"))
      == "On the map as of 1:20 PM. Details not received.")
  }

  /// The list beside the map: one row per alert kind, an area belonging to the first kind that
  /// named it, and names a reader recognises rather than UGC codes (§3.1 U-32).
  @Test
  func `the map's list groups areas by alert kind, most severe first`() throws {
    let tables = MeshWXTables.shared
    // The codes the bot actually sends for these, read back out of the shared table.
    let heat = try #require((0...255).map(UInt8.init).first { tables.vtec(for: $0) == "HT.Y" })
    let tornado = try #require((0...255).map(UInt8.init).first { tables.vtec(for: $0) == "TO.W" })
    let stateIndex = Self.stateIndex("TX")
    func entry(_ event: UInt8, start: UInt16, run: UInt8, county: Bool) -> MeshWXAreaSweep.Entry {
      MeshWXAreaSweep.Entry(event: event, stateIndex: stateIndex, isCounty: county, start: start, run: run)
    }
    let groups = WeatherAreaMapList.groups(
      [entry(tornado, start: 453, run: 1, county: true),
       entry(heat, start: 192, run: 3, county: false),
       // The same county again, under the milder one: the first kind keeps it.
       entry(heat, start: 453, run: 1, county: true)],
      tables: tables)
    #expect(groups.map(\.event) == [tornado, heat])
    #expect(groups[0].codes == ["TXC453"])
    #expect(groups[1].codes == ["TXZ192", "TXZ193", "TXZ194"])
    #expect(groups[0].name.isEmpty == false)
    #expect(WeatherAreaMapList.areaName("TXC453", tables: tables).contains("Travis"))
    // An area the tables do not carry is still the code the radio would be asked about.
    #expect(WeatherAreaMapList.areaName("ZZZ999", tables: tables) == "ZZZ999")
  }

  /// The state picker finds a state by its code or by its name, and matches nothing on a query
  /// that is neither (§3.1 U-37).
  @Test
  func `the state picker matches a code or a name`() {
    #expect(WeatherAreaPickerView.matches("TX", search: ""))
    #expect(WeatherAreaPickerView.matches("TX", search: "tx"))
    #expect(WeatherAreaPickerView.matches("TX", search: "Tex"))
    #expect(WeatherAreaPickerView.matches("TX", search: "  "))
    #expect(WeatherAreaPickerView.matches("TX", search: "Okla") == false)
    #expect(L10n.Weather.Weather.AreaMap.pickerSelected(4) == "4 selected")
    #expect(L10n.Weather.Weather.AreaMap.pickerNoMatches == "No states match that search.")
  }
}
