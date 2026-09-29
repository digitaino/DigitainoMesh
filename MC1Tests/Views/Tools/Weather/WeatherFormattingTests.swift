import Foundation
import MC1Services
import MeshWX
import Testing

@testable import MC1

/// Units, durations and names as the Weather screen writes them (docs/MESHWX_UI.md).
@Suite("Weather formatting")
struct WeatherFormattingTests {
  static let locale = Locale(identifier: "en_US")

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .gmt
    calendar.locale = locale
    return calendar
  }

  /// 2026-09-14 23:20 CDT.
  static let now = Date(timeIntervalSince1970: 1_789_446_000)

  /// ICU puts a narrow no-break space before AM/PM.
  static func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
  }

  func clock(_ offset: TimeInterval) -> String {
    Self.plain(WeatherFormatting.clockTime(Self.now.addingTimeInterval(offset), now: Self.now, calendar: Self.calendar, locale: Self.locale))
  }

  // MARK: - Durations

  @Test
  func `durations use the largest unit that fits`() {
    #expect(WeatherFormatting.duration(seconds: 40) == "40 s")
    #expect(WeatherFormatting.duration(seconds: 150) == "2 min")
    #expect(WeatherFormatting.duration(seconds: 3 * 3600 + 1200) == "3 h")
    #expect(WeatherFormatting.duration(seconds: 3 * 86_400) == "3 d")
  }

  @Test
  func `ages read as ago and old, with just now for a few seconds`() {
    #expect(WeatherFormatting.ago(Self.now.addingTimeInterval(-2), now: Self.now) == "just now")
    #expect(WeatherFormatting.ago(Self.now.addingTimeInterval(-40), now: Self.now) == "40 s ago")
    #expect(WeatherFormatting.ago(Self.now.addingTimeInterval(-120), now: Self.now) == "2 min ago")
    #expect(WeatherFormatting.age(Self.now.addingTimeInterval(-3 * 3600), now: Self.now) == "3 h old")
  }

  @Test
  func `time left switches to hours at sixty minutes`() {
    #expect(WeatherFormatting.timeLeft(minutes: 40) == "40 min")
    #expect(WeatherFormatting.timeLeft(minutes: 80) == "1 h 20 min")
    #expect(WeatherFormatting.timeLeft(minutes: 120) == "2 h")
  }

  @Test
  func `a quiet feed is minutes under an hour, then whole hours`() {
    #expect(WeatherFormatting.quietDuration(minutes: 45) == "45 min")
    #expect(WeatherFormatting.quietDuration(minutes: 300) == "5 h")
  }

  @Test
  func `times today and soon are clock times`() {
    #expect(clock(-18 * 60) == "11:02 PM")
    // 12:40 AM tomorrow: a warning ending after midnight still reads as a time.
    #expect(clock(80 * 60) == "12:40 AM")
  }

  @Test
  func `a past time on another day never passes for today`() {
    #expect(clock(-26 * 3600) == "yesterday 9:20 PM")
    let older = clock(-3 * 86_400)
    #expect(older.hasPrefix("Sep 11") && older.hasSuffix("11:20 PM") && !older.contains("2026"))
    let later = clock(20 * 3600)
    #expect(later.hasPrefix("Sep 15") && later.hasSuffix("7:20 PM"))
  }

  // MARK: - When an alert applies (docs/MESHWX_REV12.md)

  /// The two clocks every alert test runs in: the phone's own 12- or 24-hour format comes from the
  /// locale, so both are fixed here, as are the calendar and the zone — never the machine's.
  enum Clock: String, CaseIterable, CustomTestStringConvertible {
    case twelveHour = "en_US"
    case twentyFourHour = "en_GB"

    var locale: Locale { Locale(identifier: rawValue) }
    var calendar: Calendar {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .gmt
      calendar.locale = locale
      return calendar
    }
    var testDescription: String { rawValue }

    /// One of two spellings, by clock.
    func pick(_ twelve: String, _ twentyFour: String) -> String { self == .twelveHour ? twelve : twentyFour }
  }

  /// The owner's Flood Watch of 29 September: issued Tuesday 09:24 CDT for Wednesday 19:00
  /// through Friday 19:00.
  enum FloodWatch {
    static let issued = Date(timeIntervalSince1970: 1_790_691_840)
    static let begins = issued.addingTimeInterval(2016 * 60)
    static let expires = issued.addingTimeInterval(4896 * 60)
  }

  func window(
    begins: Date?, expires: Date, now: Date, _ clock: Clock, countdown: Bool = true
  ) -> String {
    Self.plain(WeatherFormatting.alertWindow(
      beginsAt: begins, expiresAt: expires, now: now, calendar: clock.calendar, locale: clock.locale,
      countdown: countdown))
  }

  func alertClock(_ date: Date, now: Date, _ clock: Clock) -> String {
    Self.plain(WeatherFormatting.alertClock(date, now: now, calendar: clock.calendar, locale: clock.locale))
  }

  /// The contract's three moments (docs/MESHWX_REV12.md §3): the screen that said "until Oct 2 at
  /// 19:00 · in 81 h 28 min" on Tuesday morning now says when it starts, and counts down only in
  /// its last twelve hours.
  @Test(arguments: Clock.allCases)
  func `the flood watch reads from its start, then until its end, then counts down`(_ clock: Clock) {
    let w = FloodWatch.self
    #expect(window(begins: w.begins, expires: w.expires, now: w.issued.addingTimeInterval(8 * 60), clock)
      == clock.pick("from Wed 7:00 PM until Fri 7:00 PM", "from Wed 19:00 until Fri 19:00"))
    #expect(window(begins: w.begins, expires: w.expires, now: w.begins, clock)
      == clock.pick("until Fri 7:00 PM", "until Fri 19:00"), "in effect from its start")
    #expect(window(begins: w.begins, expires: w.expires, now: w.expires.addingTimeInterval(-12 * 3600), clock)
      == clock.pick("until 7:00 PM · 12 h left", "until 19:00 · 12 h left"), "Friday 07:00")
  }

  @Test(arguments: Clock.allCases)
  func `an alert in effect counts down only in its last twelve hours`(_ clock: Clock) {
    let now = Self.now // Monday 14 September, 23:20 CDT
    #expect(window(begins: nil, expires: now.addingTimeInterval(21 * 60), now: now, clock)
      == clock.pick("until 11:41 PM · 21 min left", "until 23:41 · 21 min left"))
    // Just after midnight: within twelve hours, so the time alone.
    #expect(window(begins: nil, expires: now.addingTimeInterval(80 * 60), now: now, clock)
      == clock.pick("until 12:40 AM · 1 h 20 min left", "until 00:40 · 1 h 20 min left"))
    #expect(window(begins: nil, expires: now.addingTimeInterval(160 * 60), now: now, clock)
      == clock.pick("until 2:00 AM · 2 h 40 min left", "until 02:00 · 2 h 40 min left"))
    // Exactly twelve hours still counts down, and still names the time alone.
    #expect(window(begins: nil, expires: now.addingTimeInterval(12 * 3600), now: now, clock)
      == clock.pick("until 11:20 AM · 12 h left", "until 11:20 · 12 h left"))
    // A minute past twelve hours: the day and the time, no count.
    #expect(window(begins: nil, expires: now.addingTimeInterval(12 * 3600 + 60), now: now, clock)
      == clock.pick("until Tue 11:21 AM", "until Tue 11:21"))
    // A part-minute left rounds up, so an alert in effect is never said to have none.
    #expect(window(begins: nil, expires: now.addingTimeInterval(30), now: now, clock)
      == clock.pick("until 11:20 PM · 1 min left", "until 23:20 · 1 min left"))
    // A start already past is in effect, and reads as if there were none.
    #expect(window(begins: now.addingTimeInterval(-3600), expires: now.addingTimeInterval(21 * 60), now: now, clock)
      == window(begins: nil, expires: now.addingTimeInterval(21 * 60), now: now, clock))
  }

  @Test(arguments: Clock.allCases)
  func `nothing counts down to an end that has not begun`(_ clock: Clock) {
    let now = Self.now // Monday 23:20
    // Starting just after midnight and ending before dawn: both within twelve hours, times alone.
    #expect(window(begins: now.addingTimeInterval(70 * 60), expires: now.addingTimeInterval(400 * 60), now: now, clock)
      == clock.pick("from 12:30 AM until 6:00 AM", "from 00:30 until 06:00"))
    // A start one minute ahead is still ahead.
    #expect(window(begins: now.addingTimeInterval(60), expires: now.addingTimeInterval(40 * 60), now: now, clock)
      == clock.pick("from 11:21 PM until 12:00 AM", "from 23:21 until 00:00"))
  }

  /// Notifications never count down: "40 min left" on a lock screen is stale when it is read.
  @Test(arguments: Clock.allCases)
  func `without the countdown an alert ending soon says only when`(_ clock: Clock) {
    let now = Self.now
    #expect(window(begins: nil, expires: now.addingTimeInterval(21 * 60), now: now, clock, countdown: false)
      == clock.pick("until 11:41 PM", "until 23:41"))
    let w = FloodWatch.self
    #expect(window(begins: w.begins, expires: w.expires, now: w.issued, clock, countdown: false)
      == clock.pick("from Wed 7:00 PM until Fri 7:00 PM", "from Wed 19:00 until Fri 19:00"))
  }

  /// Today or within twelve hours: the time. The six days after today: the weekday. The seventh —
  /// today's weekday again — and beyond: the date.
  @Test(arguments: Clock.allCases)
  func `an alert's moment is a time, a weekday, then a date`(_ clock: Clock) {
    let now = FloodWatch.issued // Tuesday 29 September, 09:24
    #expect(alertClock(now.addingTimeInterval(3600), now: now, clock) == clock.pick("10:24 AM", "10:24"))
    // Later today, more than twelve hours on: still today, so the time.
    let tonight = now.addingTimeInterval(14 * 3600 + 30 * 60) // 23:54
    #expect(alertClock(tonight, now: now, clock) == clock.pick("11:54 PM", "23:54"))
    // Tomorrow, within twelve hours of a late evening: the time alone.
    let lateEvening = now.addingTimeInterval(12 * 3600) // 21:24
    #expect(alertClock(lateEvening.addingTimeInterval(4 * 3600), now: lateEvening, clock) == clock.pick("1:24 AM", "01:24"))
    #expect(alertClock(now.addingTimeInterval(86_400), now: now, clock) == clock.pick("Wed 9:24 AM", "Wed 09:24"))
    #expect(alertClock(now.addingTimeInterval(6 * 86_400), now: now, clock) == clock.pick("Mon 9:24 AM", "Mon 09:24"))
    // Seven days out, the same weekday as today: the date, never "Tue".
    #expect(alertClock(now.addingTimeInterval(7 * 86_400), now: now, clock) == clock.pick("Oct 6 at 9:24 AM", "6 Oct at 09:24"))
    // Six days and twenty-three hours on is also next Tuesday by the calendar: the date again.
    #expect(alertClock(now.addingTimeInterval(7 * 86_400 - 3600), now: now, clock) == clock.pick("Oct 6 at 8:24 AM", "6 Oct at 08:24"))
    // Weeks out: the date.
    #expect(alertClock(now.addingTimeInterval(20 * 86_400), now: now, clock) == clock.pick("Oct 19 at 9:24 AM", "19 Oct at 09:24"))
  }

  /// The 24-hour clock is the locale's, not an English one: German names its own weekday.
  @Test
  func `a German phone gets its own weekday and 24-hour clock`() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .gmt
    let locale = Locale(identifier: "de_DE")
    calendar.locale = locale
    let text = Self.plain(WeatherFormatting.alertClock(
      FloodWatch.begins, now: FloodWatch.issued, calendar: calendar, locale: locale))
    #expect(text.contains("19:00") && text.hasPrefix("Mi"))
    #expect(!text.contains("PM"))
  }

  /// A notification body says when the alert applies the way every screen does, without the
  /// countdown (docs/MESHWX_REV12.md §2).
  @Test(arguments: Clock.allCases)
  func `a notification says from and until, and never counts down`(_ clock: Clock) {
    let tables = MeshWXTables.shared
    let copy = WeatherAlertNotificationCopyImpl(calendar: clock.calendar, locale: clock.locale)
    let w = FloodWatch.self
    let watch = MeshWXWarning(
      identity: MeshWXWarningIdentity(event: tables.eventByCode["FA.A"] ?? 0, office: 35, etn: 8),
      expiresMinutes: UInt32(w.expires.timeIntervalSince1970 / 60),
      areas: [MeshWXAreaRun(stateIndex: 42, isCounty: false, start: 191, run: 4)],
      issuedBeforeMinutes: 4896, beginsBeforeMinutes: 2880)
    func body(now: Date, beginsAt: Date?) -> String {
      Self.plain(copy.content(
        for: WeatherAlertNotificationSubject(
          warning: watch, placeLabel: "Austin, TX", placement: .here, botName: "WX-AUS", isLate: false,
          now: now, beginsAt: beginsAt),
        tables: tables).body)
    }
    #expect(body(now: w.issued, beginsAt: w.begins)
      == clock.pick("Austin, TX · from Wed 7:00 PM until Fri 7:00 PM", "Austin, TX · from Wed 19:00 until Fri 19:00"))
    #expect(body(now: w.expires.addingTimeInterval(-40 * 60), beginsAt: w.begins)
      == clock.pick("Austin, TX · until 7:00 PM", "Austin, TX · until 19:00"))
  }

  // MARK: - Distance

  @Test
  func `distances are whole kilometres with a compass point`() {
    #expect(WeatherFormatting.kilometres(3.2) == "3 km")
    #expect(WeatherFormatting.kilometres(0.3) == "under 1 km")
    #expect(WeatherFormatting.distance(25.4, direction: .north) == "25 km N")
    #expect(WeatherFormatting.distance(40, direction: .northWest) == "40 km NW")
  }

  @Test
  func `directions point from the place towards the target`() {
    let austin = MeshWXCoordinate(latitude: 30.27, longitude: -97.74)
    #expect(WeatherFormatting.direction(from: austin, to: MeshWXCoordinate(latitude: 30.77, longitude: -97.74)) == .north)
    #expect(WeatherFormatting.direction(from: austin, to: MeshWXCoordinate(latitude: 30.27, longitude: -98.74)) == .west)
  }

  // MARK: - Names

  @Test
  func `a radio heard without an advert is named by its hex id`() {
    #expect(WeatherFormatting.botName(botID: 0x041D, bot: nil) == "Weather radio 041D")
  }

  @Test
  func `a name starting a sentence is capitalised`() {
    #expect(WeatherFormatting.sentenceStart("the weather radio") == "The weather radio")
    #expect(WeatherFormatting.sentenceStart("WX-AUS") == "WX-AUS")
  }

  /// **One label per place** (docs/MESHWX_UI.md §3.1 U-12). The label a place carries is the name
  /// it is shown by everywhere — the title bar, Places, every sentence that names it — and the
  /// state stays on, because it is what tells two Austins apart. One tap used to produce
  /// "Austin" in the title, "Austin, TX" in Places and a station's own town in the source line.
  @Test
  func `a place is named the same way everywhere`() {
    #expect(WeatherFormatting.placeName("Round Rock, TX") == "Round Rock, TX")
    #expect(WeatherFormatting.placeName("this location") == "this location")
    #expect(WeatherFormatting.placeName(" Austin, TX ") == "Austin, TX")
  }

  @Test
  func `firmware versions drop the v and a trailing zero`() {
    #expect(WeatherFormatting.firmwareVersion("v1.14.0") == "1.14")
    #expect(WeatherFormatting.firmwareVersion("1.14.2") == "1.14.2")
    #expect(WeatherFormatting.firmwareVersion("dev") == "dev")
  }

  /// A forecast point is named by `WeatherNames.pointLabel`, the one function every site that
  /// names one calls (docs/MESHWX_UI.md §3.1 U-25); the rule itself is tested where it lives
  /// (`WeatherScreenTests`). This is the app's side of it: the point's name, its state when it
  /// has one, and nothing else.
  @Test
  func `forecast points read as places, by the one function that names them`() {
    #expect(WeatherNames.pointState("Austin Camp Mabry-Travis TX") == "TX")
    #expect(WeatherNames.pointState("Luis Munoz Marin International Airport-San Juan") == nil)
    #expect(WeatherNames.pointLabel("Central Park-New York NY") == "Central Park, NY")
    #expect(WeatherNames.pointLabel("Luis Munoz Marin International Airport-San Juan")
      == "Luis Munoz Marin International Airport")
    #expect(WeatherNames.pointLabel("10 Mile Boxcars") == "10 Mile Boxcars")
  }

  @Test
  func `an area named twice is listed once`() {
    let runs = [
      MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1),
      MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 209, run: 1),
      MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1)
    ]
    let areas = MeshWXTables.shared.namedAreas(for: runs)
    #expect(areas.count == 3)
    #expect(WeatherFormatting.uniqueAreas(areas).map(\.ugc) == ["TXC453", "TXC209"])
    #expect(areas.first.map(WeatherFormatting.shortAreaName) == "Travis County")
  }

  @Test
  func `offices are named by city and unknown ones by code`() {
    #expect(WeatherReferenceNames.officeName("EWX") == "NWS Austin/San Antonio")
    #expect(WeatherReferenceNames.officeName("FWD") == "NWS Fort Worth")
    #expect(WeatherReferenceNames.officeName("ZZZ") == "NWS ZZZ")
    #expect(WeatherReferenceNames.officeName("WNS") == "Storm Prediction Center")
    #expect(WeatherReferenceNames.officeName("NHC") == "National Hurricane Center")
    #expect(WeatherReferenceNames.stateName("TX") == "Texas")
  }

  /// Spec §6 (revision 3): whole miles rounded down, so 1/2SM arrives as 0.
  @Test
  func `visibility under a mile reads under 1 mi, not 0`() {
    let english = Locale(identifier: "en_US")
    #expect(WeatherFormatting.visibility(miles: 0, locale: english) == "under 1 mi")
    #expect(WeatherFormatting.visibility(miles: 10, locale: english) == "10 mi")
  }

  // MARK: - Wind, pressure, tags

  @Test
  func `a reported wind reads as direction, speed and gust`() {
    let gusty = MeshWXStationObservation(stationIndex: 0, windDirection: .southSouthEast, windMph: 12, gustMph: 21)
    #expect(WeatherFormatting.wind(MeshWXWindReading(observation: gusty)) == "SSE 12 gusting 21")
    let steady = MeshWXStationObservation(stationIndex: 0, windDirection: .south, windMph: 10, gustMph: 0)
    #expect(WeatherFormatting.wind(MeshWXWindReading(observation: steady)) == "S 10")
  }

  @Test
  func `zero speed is calm and an unreported wind has no text`() {
    let calm = MeshWXStationObservation(stationIndex: 0, windDirection: .north, windMph: 0, gustMph: 0)
    #expect(WeatherFormatting.wind(MeshWXWindReading(observation: calm)) == "calm")
    let missing = MeshWXStationObservation(stationIndex: 0, windDirection: .north, windMph: nil)
    #expect(WeatherFormatting.wind(MeshWXWindReading(observation: missing)) == nil)
  }

  @Test
  func `pressure is two decimals of inches of mercury`() {
    #expect(WeatherFormatting.pressure(inchesOfMercury: 29.92, locale: Self.locale) == "29.92")
  }

  @Test
  func `tags read as the spec words them, on one line`() {
    let warning = MeshWXWarning(
      identity: MeshWXWarningIdentity(event: 3, office: 1, etn: 42), expiresMinutes: 29_500_030,
      tornado: .radarIndicated, floodDamage: .considerable, hailQuarterInches: 4, windMph: 60)
    #expect(WeatherFormatting.tagTexts(for: warning, locale: Self.locale) == [
      "Tornado: radar indicated", "Flash flood damage: considerable", "Hail 1.00 in", "Wind 60 mph"
    ])
    #expect(WeatherFormatting.tagLine(for: warning, locale: Self.locale)
      == "Tornado: radar indicated · Flash flood damage: considerable · Hail 1.00 in · Wind 60 mph")
  }

  @Test
  func `every sky code but other has a word`() {
    for sky in MeshWXSky.allCases {
      #expect((WeatherFormatting.condition(sky) == nil) == (sky == .other))
    }
  }

  @Test
  func `the night icon runs from seven in the evening to six in the morning`() {
    let calendar = Self.calendar
    func at(_ hour: Int) -> Date {
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: hour)) ?? Self.now
    }
    #expect(WeatherFormatting.isNight(at(23), calendar: calendar))
    #expect(WeatherFormatting.isNight(at(5), calendar: calendar))
    #expect(!WeatherFormatting.isNight(at(12), calendar: calendar))
  }
}
