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

  @Test
  func `a missing forecast names a far point, and no point says so`() throws {
    let point = try #require(MeshWXTables.shared.point(at: 103))
    let name = WeatherNames.pointLabel(point.name)
    #expect(WeatherCopy.forecastMissing(placeName: "Austin", point: point, kilometres: 4) == "No forecast for Austin yet.")
    #expect(WeatherCopy.forecastMissing(placeName: "Big Spring", point: point, kilometres: 60)
      == "No forecast for Big Spring yet. The nearest forecast point is \(name), 60 km.")
    #expect(WeatherCopy.noForecastPoint(placeName: "Albuquerque") == "No forecast point near Albuquerque.")
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
    #expect(WeatherCopy.dataSource(.goesSatellite) == "From the GOES satellite")
    #expect(WeatherCopy.dataSource(.internet) == "From the internet")
    #expect(WeatherCopy.dataSource(.mixed) == "From GOES and the internet")
    // A radio older than revision 7 has made no claim, and no screen may invent one for it.
    #expect(WeatherCopy.dataSource(.unstated) == nil)
  }

  @Test
  func `a cut reply says the rest did not fit, beside the source when there is one`() {
    #expect(WeatherCopy.reportFootnote(source: .goesSatellite, wasCut: false) == "From the GOES satellite")
    #expect(WeatherCopy.reportFootnote(source: .unstated, wasCut: true) == "The rest didn't fit on the radio.")
    #expect(WeatherCopy.reportFootnote(source: .internet, wasCut: true)
      == "From the internet · The rest didn't fit on the radio.")
    // Neither fact: no row at all, so a card from an older radio reads exactly as it did.
    #expect(WeatherCopy.reportFootnote(source: .unstated, wasCut: false) == nil)
  }
}
