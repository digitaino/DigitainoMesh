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
  func `countdowns switch to hours at sixty minutes`() {
    #expect(WeatherFormatting.countdown(minutes: 40) == "in 40 min")
    #expect(WeatherFormatting.countdown(minutes: 80) == "in 1 h 20 min")
    #expect(WeatherFormatting.countdown(minutes: 120) == "in 2 h")
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

  @Test
  func `the until line names the end and counts down to it`() {
    let text = WeatherFormatting.untilLine(
      expiresAt: Self.now.addingTimeInterval(40 * 60), now: Self.now, calendar: Self.calendar, locale: Self.locale)
    #expect(Self.plain(text) == "until 12:00 AM · in 40 min")
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
