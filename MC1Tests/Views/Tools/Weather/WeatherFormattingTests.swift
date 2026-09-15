import Foundation
import MC1Services
import MeshWX
import Testing

@testable import MC1

/// The Weather tool's wording rules (spec §10).
///
/// `MeshWX` is tested against the kit's wire vectors; this is the other half — the numbers it
/// hands over turning into the exact strings the spec quotes. Both halves have to hold for a
/// screen to be right, and only this one can catch "0 mph" appearing where a station reported
/// nothing.
@Suite("Weather formatting")
struct WeatherFormattingTests {

  /// Unix minutes for a fixed instant, so nothing here depends on when it runs.
  private static let nowMinutes: UInt32 = 29_500_000
  private static var now: Date { Date(unixMinutes: nowMinutes) }

  // MARK: - Expiry countdown

  @Test
  func `a warning forty-two minutes out counts down in minutes`() {
    let text = WeatherFormatting.expiry(
      expiresMinutes: Self.nowMinutes + 42,
      now: Self.now
    )
    #expect(text == "expires in 42 min")
  }

  @Test
  func `an expiry more than an hour out counts down in hours and minutes`() {
    let text = WeatherFormatting.expiry(
      expiresMinutes: Self.nowMinutes + 125,
      now: Self.now
    )
    #expect(text == "expires in 2 h 5 min")
  }

  /// Zero minutes left is not "expires in 0 min": the warning is over.
  @Test
  func `an expiry at this minute reads as expired`() {
    let text = WeatherFormatting.expiry(expiresMinutes: Self.nowMinutes, now: Self.now)
    #expect(text == "expired")
  }

  @Test
  func `a past expiry reads as expired`() {
    let text = WeatherFormatting.expiry(expiresMinutes: Self.nowMinutes - 90, now: Self.now)
    #expect(text == "expired")
  }

  // MARK: - Forecast period labels

  /// A forecast issued on a Monday afternoon whose first period is `1` (tonight), which is the
  /// common shape of a PFM: the first five labels a person reads down the list.
  @Test
  func `periods from tonight run today, tomorrow, then weekdays`() {
    let calendar = Self.utcCalendar
    let issuedAt = Self.mondayAfternoon

    let labels = (0..<5).map { offset in
      WeatherFormatting.periodLabel(
        periodID: 1 + UInt8(offset),
        issuedAt: issuedAt,
        calendar: calendar,
        locale: Locale(identifier: "en_US")
      )
    }

    #expect(labels == ["Tonight", "Tomorrow", "Tomorrow night", "Wednesday", "Wednesday night"])
  }

  /// Period 0 is the issue day itself, which is "Today" and not the weekday name.
  @Test
  func `period zero is today`() {
    let label = WeatherFormatting.periodLabel(
      periodID: 0,
      issuedAt: Self.mondayAfternoon,
      calendar: Self.utcCalendar,
      locale: Locale(identifier: "en_US")
    )
    #expect(label == "Today")
  }

  // MARK: - Wind

  @Test
  func `a reported wind reads as direction, speed and gust`() {
    let observation = MeshWXStationObservation(
      stationIndex: 0,
      windDirection: .southSouthEast,
      windMph: 12,
      gustMph: 21
    )
    #expect(WeatherFormatting.wind(MeshWXWindReading(observation: observation)) == "SSE 12 gusting 21")
  }

  @Test
  func `a wind with no gust leaves the gust out`() {
    let observation = MeshWXStationObservation(
      stationIndex: 0,
      windDirection: .south,
      windMph: 10,
      gustMph: 0
    )
    #expect(WeatherFormatting.wind(MeshWXWindReading(observation: observation)) == "S 10")
  }

  /// Direction 0 with speed 0 is calm (spec §6), not "wind from the north".
  @Test
  func `zero speed from north reads as calm`() {
    let observation = MeshWXStationObservation(
      stationIndex: 0,
      windDirection: .north,
      windMph: 0,
      gustMph: 0
    )
    #expect(WeatherFormatting.wind(MeshWXWindReading(observation: observation)) == "Calm")
  }

  /// A station that reported no wind at all is not a station reporting calm, so the caller gets
  /// nil and shows a dash rather than a number nobody measured.
  @Test
  func `an unreported wind has no text at all`() {
    let observation = MeshWXStationObservation(stationIndex: 0, windDirection: .north, windMph: nil)
    #expect(WeatherFormatting.wind(MeshWXWindReading(observation: observation)) == nil)
  }

  // MARK: - Pressure

  /// The wire carries `(inHg − 29.00) × 100`, so 92 is the standard-atmosphere 29.92.
  @Test
  func `the pressure byte becomes inches of mercury`() {
    #expect(WeatherFormatting.pressure(rawPressure: 92, locale: Locale(identifier: "en_US")) == "29.92")
    #expect(WeatherFormatting.pressure(rawPressure: 0, locale: Locale(identifier: "en_US")) == "29.00")
  }

  @Test
  func `the unknown pressure sentinel has no text`() {
    #expect(WeatherFormatting.pressure(rawPressure: 255, locale: Locale(identifier: "en_US")) == nil)
  }

  // MARK: - Station names

  /// The bundle shouts; a list row should not.
  @Test
  func `an all-caps station name is title-cased`() {
    #expect(WeatherFormatting.stationName("AUSTIN-BERGSTROM INTL") == "Austin-Bergstrom Intl")
  }

  /// A name that already carries case was written that way on purpose.
  @Test
  func `a mixed-case station name is left alone`() {
    #expect(WeatherFormatting.stationName("Austin-Bergstrom Intl") == "Austin-Bergstrom Intl")
  }

  // MARK: - Tags

  @Test
  func `tags read as the spec words them`() {
    let warning = MeshWXWarning(
      identity: MeshWXWarningIdentity(event: 3, office: 1, etn: 42),
      expiresMinutes: Self.nowMinutes + 30,
      tornado: .radarIndicated,
      floodDamage: .considerable,
      hailQuarterInches: 4,
      windMph: 60
    )
    let tags = WeatherFormatting.tagTexts(for: warning, locale: Locale(identifier: "en_US"))
    #expect(tags == [
      "Tornado: radar indicated",
      "Flash flood damage: considerable",
      "Hail 1.00 in",
      "Wind 60 mph",
    ])
  }

  /// A warning with no tags renders as a bare headline, not as a row of "none".
  @Test
  func `an untagged warning has no tags`() {
    let warning = MeshWXWarning(
      identity: MeshWXWarningIdentity(event: 3, office: 1, etn: 1),
      expiresMinutes: Self.nowMinutes + 30
    )
    #expect(WeatherFormatting.tagTexts(for: warning).isEmpty)
  }

  // MARK: - Fixtures

  private static var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    calendar.locale = Locale(identifier: "en_US")
    return calendar
  }

  /// 2026-03-02 18:00 UTC, a Monday.
  private static var mondayAfternoon: Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 3
    components.day = 2
    components.hour = 18
    return utcCalendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
  }
}
