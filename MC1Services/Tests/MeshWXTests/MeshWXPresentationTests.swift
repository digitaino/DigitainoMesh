import Foundation
import Testing

@testable import MeshWX

/// The rendering rules of spec §10, kept testable by never returning a colour or a
/// localised string — only a name, a symbol and a number.
@Suite("MeshWX presentation")
struct MeshWXPresentationTests {

  @Test func skySymbolsHaveDayAndNightVariants() {
    #expect(MeshWXPresentation.symbolName(for: .clear) == "sun.max")
    #expect(MeshWXPresentation.symbolName(for: .clear, isNight: true) == "moon.stars")
    #expect(MeshWXPresentation.symbolName(for: .few) == "cloud.sun")
    #expect(MeshWXPresentation.symbolName(for: .few, isNight: true) == "cloud.moon")
    // Cloud decks and precipitation look the same at night.
    #expect(MeshWXPresentation.symbolName(for: .overcast) == "cloud.fill")
    #expect(MeshWXPresentation.symbolName(for: .overcast, isNight: true) == "cloud.fill")
    #expect(MeshWXPresentation.symbolName(for: .thunderstorm) == "cloud.bolt.rain")
  }

  @Test func forecastFlagsOverrideTheBaseSkyIcon() {
    let clearNight = MeshWXForecastPeriod(sky: .clear)
    #expect(MeshWXPresentation.icon(for: clearNight, isNight: true).symbolName == "moon.stars")

    // Thunder wins over a "few clouds" sky code.
    let storm = MeshWXForecastPeriod(sky: .few, thunder: true)
    #expect(MeshWXPresentation.icon(for: storm).symbolName == "cloud.bolt.rain")

    let sleet = MeshWXForecastPeriod(sky: .rain, wintry: true)
    #expect(MeshWXPresentation.icon(for: sleet).symbolName == "cloud.sleet")
    let snow = MeshWXForecastPeriod(sky: .snow, wintry: true)
    #expect(MeshWXPresentation.icon(for: snow).symbolName == "cloud.snow")

    let foggy = MeshWXForecastPeriod(sky: .broken, fog: true)
    #expect(MeshWXPresentation.icon(for: foggy).symbolName == "cloud.fog")

    // Wind is an accent, not a replacement: a windy rainy day still shows rain.
    let windyRain = MeshWXForecastPeriod(sky: .rain, windy: true)
    let icon = MeshWXPresentation.icon(for: windyRain)
    #expect(icon.symbolName == "cloud.rain")
    #expect(icon.showsWindAccent)
    #expect(!MeshWXPresentation.icon(for: MeshWXForecastPeriod(sky: .rain)).showsWindAccent)
  }

  @Test func eventTintsFollowTheNWSTable() {
    #expect(MeshWXPresentation.tint(forVTEC: "TO.W") == .red)
    #expect(MeshWXPresentation.tint(forVTEC: "TO.A") == .yellow)
    #expect(MeshWXPresentation.tint(forVTEC: "SV.W") == .orange)
    #expect(MeshWXPresentation.tint(forVTEC: "SV.A") == .lightOrange)
    #expect(MeshWXPresentation.tint(forVTEC: "FF.W") == .darkGreen)
    #expect(MeshWXPresentation.tint(forVTEC: "FA.W") == .green)
    #expect(MeshWXPresentation.tint(forVTEC: "FL.Y") == .lightGreen)
    #expect(MeshWXPresentation.tint(forVTEC: "EH.W") == .orangeRed)
    #expect(MeshWXPresentation.tint(forVTEC: "WS.W") == .pink)
    #expect(MeshWXPresentation.tint(forVTEC: "BZ.W") == .purple)
    #expect(MeshWXPresentation.tint(forVTEC: "WW.Y") == .lavender)
    #expect(MeshWXPresentation.tint(forVTEC: "HW.W") == .tan)
    #expect(MeshWXPresentation.tint(forVTEC: "FW.W") == .magenta)
  }

  @Test func unlistedEventsFallBackToSignificance() {
    // Nothing in §10.2 covers a dust storm warning or a rip current statement; the
    // letter after the dot still ranks and colours them.
    #expect(MeshWXPresentation.tint(forVTEC: "DS.W") == .red)
    #expect(MeshWXPresentation.tint(forVTEC: "SQ.A") == .yellow)
    #expect(MeshWXPresentation.tint(forVTEC: "RP.S") == .grey)
    #expect(MeshWXPresentation.tint(forVTEC: "SPS") == .grey)
    #expect(MeshWXPresentation.tint(forVTEC: "nonsense") == .grey)
    #expect(MeshWXPresentation.symbolName(forVTEC: "DS.W") == "exclamationmark.triangle")
    #expect(MeshWXPresentation.symbolName(forVTEC: "TO.W") == "tornado")
    #expect(MeshWXPresentation.symbolName(forVTEC: "FW.W") == "flame")
  }

  @Test func severityRanksWarningsFirst() {
    #expect(MeshWXSeverity(vtec: "SV.W") == .warning)
    #expect(MeshWXSeverity(vtec: "SV.A") == .watch)
    #expect(MeshWXSeverity(vtec: "HT.Y") == .advisory)
    #expect(MeshWXSeverity(vtec: "SPS") == .statement)
    #expect(MeshWXSeverity(vtec: "garbage") == nil)
    #expect(MeshWXSeverity.warning > MeshWXSeverity.watch)
    #expect(MeshWXSeverity.advisory > MeshWXSeverity.statement)
  }

  @Test func tagsAreReturnedAsNumbersNotSentences() {
    // §10.2 renders "Hail 1.00 in" and "Wind 60 mph"; the module hands over 1.0 and 60
    // so the app can translate the words and choose the unit.
    #expect(MeshWXPresentation.hailInches(quarterInches: 4) == 1.0)
    #expect(MeshWXPresentation.hailInches(quarterInches: 7) == 1.75)
    #expect(MeshWXPresentation.hailInches(quarterInches: 0) == nil)
    #expect(MeshWXPresentation.windTagMph(60) == 60)
    #expect(MeshWXPresentation.windTagMph(0) == nil)

    let warning = MeshWXWarning(
      identity: MeshWXWarningIdentity(event: 3, office: 35, etn: 42),
      expiresMinutes: 29_823_945,
      tornado: .radarIndicated,
      floodDamage: .considerable,
      hailQuarterInches: 4,
      windMph: 60)
    #expect(warning.hailInches == 1.0)
    let tags = MeshWXPresentation.tags(for: warning)
    #expect(
      tags == [
        .tornado(.radarIndicated), .floodDamage(.considerable), .hail(inches: 1.0), .wind(mph: 60),
      ])

    let quiet = MeshWXWarning(
      identity: MeshWXWarningIdentity(event: 24, office: 35, etn: 7), expiresMinutes: 0)
    #expect(MeshWXPresentation.tags(for: quiet).isEmpty)
  }

  @Test func stalenessThresholdsMatchTheSpec() {
    let issued: UInt32 = 1_000_000
    // Two hours for an observation.
    #expect(!MeshWXPresentation.isObservationStale(timestampMinutes: issued, now: issued + 120))
    #expect(MeshWXPresentation.isObservationStale(timestampMinutes: issued, now: issued + 121))
    // Twelve for a forecast.
    #expect(!MeshWXPresentation.isForecastStale(issuedMinutes: issued, now: issued + 720))
    #expect(MeshWXPresentation.isForecastStale(issuedMinutes: issued, now: issued + 721))
    // feed_health is in units of four minutes; 60 is four hours.
    #expect(!MeshWXPresentation.isFeedStale(feedHealth: 60))
    #expect(MeshWXPresentation.isFeedStale(feedHealth: 61))
    #expect(MeshWXPresentation.feedHealthMinutes(7) == 28)
    #expect(MeshWXPresentation.feedHealthMinutes(255) == 1020)
  }

  /// Spec §6 (revision 3): sky 15 is a report with no cloud or weather group.
  @Test func anObservationWithNoSkyGroupHasNoIcon() {
    #expect(MeshWXPresentation.observationSymbolName(for: .other) == nil)
    #expect(MeshWXPresentation.observationSymbolName(for: .clear, isNight: true) == "moon.stars")
  }

  /// Spec §5: the byte is one office's quiet, and only 255 says nothing ever arrived.
  @Test func feedHealthSplitsAQuietOfficeFromAFeedThatNeverDelivered() {
    #expect(MeshWXFeedHealth(feedHealth: 0) == .recent(minutes: 0))
    #expect(MeshWXFeedHealth(feedHealth: 60) == .recent(minutes: 240))
    #expect(MeshWXFeedHealth(feedHealth: 61) == .quiet(minutes: 244))
    #expect(MeshWXFeedHealth(feedHealth: 254) == .quiet(minutes: 1016))
    #expect(MeshWXFeedHealth(feedHealth: 255) == .neverReceived)
    #expect(!MeshWXFeedHealth.recent(minutes: 240).withholdsCalm)
    #expect(MeshWXFeedHealth.quiet(minutes: 244).withholdsCalm)
    #expect(MeshWXFeedHealth.neverReceived.withholdsCalm)
  }

  @Test func expiryCountsDownAndThenStops() {
    #expect(MeshWXPresentation.minutesUntilExpiry(expiresMinutes: 1042, now: 1000) == 42)
    #expect(MeshWXPresentation.minutesUntilExpiry(expiresMinutes: 1000, now: 1000) == nil)
    #expect(MeshWXPresentation.minutesUntilExpiry(expiresMinutes: 999, now: 1000) == nil)
  }

  @Test func periodIDsMapToDayAndNight() {
    // 0 today, 1 tonight, 2 tomorrow, 3 tomorrow night (spec §7).
    #expect(MeshWXPeriodSlot(periodID: 0) == MeshWXPeriodSlot(periodID: 0))
    #expect(!MeshWXPeriodSlot(periodID: 0).isNight)
    #expect(MeshWXPeriodSlot(periodID: 0).dayOffset == 0)
    #expect(MeshWXPeriodSlot(periodID: 1).isNight)
    #expect(MeshWXPeriodSlot(periodID: 1).dayOffset == 0)
    #expect(MeshWXPeriodSlot(periodID: 2).dayOffset == 1)
    #expect(MeshWXPeriodSlot(periodID: 7).dayOffset == 3)
    #expect(MeshWXPeriodSlot(periodID: 7).isNight)

    // The kit's forecast vector starts at period 1 (tonight), so its fourth entry is
    // the day after tomorrow's daytime.
    let forecast = MeshWXForecast(
      pointIndex: 102, issuedMinutes: 29_823_780, firstPeriod: 1, periods: [])
    #expect(MeshWXPresentation.slot(forecast: forecast, periodOffset: 0).isNight)
    #expect(MeshWXPresentation.slot(forecast: forecast, periodOffset: 3).dayOffset == 2)
    #expect(!MeshWXPresentation.slot(forecast: forecast, periodOffset: 3).isNight)
  }

  @Test func windReadingsSeparateCalmFromUnknown() {
    // Direction 0 with speed 0 is calm (spec §6), so no arrow should be drawn.
    let calm = MeshWXStationObservation(stationIndex: 860, windDirection: .north, windMph: 0)
    let calmReading = MeshWXWindReading(observation: calm)
    #expect(calmReading.direction == nil)
    #expect(calmReading.isCalm)

    let breezy = MeshWXStationObservation(
      stationIndex: 202, windDirection: .southSouthEast, windMph: 12, gustMph: 21)
    let reading = MeshWXWindReading(observation: breezy)
    #expect(reading.direction == .southSouthEast)
    #expect(reading.speedMph == 12)
    #expect(reading.gustMph == 21)
    #expect(!reading.isCalm)

    // No speed at all is not calm — it is unknown.
    let silent = MeshWXStationObservation(stationIndex: 976, windDirection: .westNorthWest)
    #expect(MeshWXWindReading(observation: silent).speedMph == nil)
    #expect(!MeshWXWindReading(observation: silent).isCalm)

    // Forecast periods never carry a gust.
    #expect(
      MeshWXWindReading(period: MeshWXForecastPeriod(windDirection: .south, windMph: 10)).gustMph
        == nil)
  }

  @Test func pressureConvertsBothWays() {
    #expect(MeshWXPresentation.inchesOfMercury(fromRawPressure: 92) == 29.92)
    #expect(MeshWXPresentation.inchesOfMercury(fromRawPressure: 0) == 29.00)
    #expect(MeshWXPresentation.inchesOfMercury(fromRawPressure: 255) == nil)
    let millibars = MeshWXPresentation.millibars(fromInchesOfMercury: 29.92)
    #expect(abs(millibars - 1013.2) < 0.1)
    #expect(abs(MeshWXPresentation.celsius(fromFahrenheit: 88) - 31.1) < 0.05)
    #expect(abs(MeshWXPresentation.kilometres(fromMiles: 10) - 16.09) < 0.01)
  }

  @Test func unixMinutesMatchTheWire() {
    // The kit's severe thunderstorm vector expires at 29 823 945 minutes.
    let date = Date(timeIntervalSince1970: 29_823_945 * 60)
    #expect(MeshWXPresentation.unixMinutes(for: date) == 29_823_945)
    #expect(MeshWXPresentation.unixMinutes(for: Date(timeIntervalSince1970: -10)) == 0)
  }
}

/// The forecast shape is read from the entries, not from spec §7's period ids alone.
@Suite("MeshWX forecast layout")
struct MeshWXForecastLayoutTests {
  /// The kit vector: first period 1 (tonight), alternating single temperatures.
  let specForecast = MeshWXForecast(
    pointIndex: 102, issuedMinutes: 29_823_780, firstPeriod: 1,
    periods: [
      MeshWXForecastPeriod(lowF: 73, popPercent: 20, sky: .scattered),
      MeshWXForecastPeriod(highF: 93, popPercent: 40, sky: .broken),
      MeshWXForecastPeriod(lowF: 72, popPercent: 30, sky: .broken),
      MeshWXForecastPeriod(highF: 90, popPercent: 60, sky: .rain)
    ])

  /// The live WX-AUS forecast for Austin Camp Mabry on 2026-09-14, as the phone held it.
  let liveForecast = MeshWXForecast(
    pointIndex: 103, issuedMinutes: 29_823_380, firstPeriod: 0,
    periods: [(102, 77), (100, 78), (98, 75), (97, 73), (98, 74), (99, 76), (96, 81)].map {
      MeshWXForecastPeriod(highF: Int8($0.0), lowF: Int8($0.1), sky: .scattered)
    })

  @Test func theKitVectorIsSpecPeriods() {
    #expect(MeshWXForecastLayout(of: specForecast) == .periods)
    let entries = MeshWXForecastEntry.entries(of: specForecast)
    #expect(entries.map(\.dayOffset) == [0, 1, 1, 2])
    #expect(entries.map(\.isNight) == [true, false, true, false])
  }

  @Test func theLiveBotSendsWholeDays() {
    #expect(MeshWXForecastLayout(of: liveForecast) == .days)
    let entries = MeshWXForecastEntry.entries(of: liveForecast)
    #expect(entries.map(\.dayOffset) == [0, 1, 2, 3, 4, 5, 6])
    #expect(entries.allSatisfy { $0.isNight == nil })
    #expect(entries[1].period.highF == 100 && entries[1].period.lowF == 78)
  }

  /// Spec §7 (revision 3): a 127 at the edge of the forecast window is half a day missing, not a
  /// night.
  @Test func aDayMissingOneTemperatureIsStillADay() {
    let edge = MeshWXForecast(
      pointIndex: 1, issuedMinutes: 0, firstPeriod: 0,
      periods: [MeshWXForecastPeriod(highF: 90, lowF: 70), MeshWXForecastPeriod(lowF: 68)])
    #expect(MeshWXForecastLayout(of: edge) == .days)
    let entries = MeshWXForecastEntry.entries(of: edge)
    #expect(entries.map(\.isNight) == [nil, nil])
    #expect(entries.map(\.dayOffset) == [0, 1])
  }

  /// Spec §7 (revision 3): `first` counts half-days from the issue date, and an evening issue with
  /// no usable rest of today sends 2, so its first entry is tomorrow.
  @Test func anEveningIssueStartsTomorrow() {
    let evening = MeshWXForecast(
      pointIndex: 103, issuedMinutes: 29_823_380, firstPeriod: 2, periods: liveForecast.periods)
    #expect(MeshWXForecastLayout(of: evening) == .days)
    #expect(MeshWXForecastEntry.entries(of: evening).map(\.dayOffset) == [1, 2, 3, 4, 5, 6, 7])
  }

  @Test func wholeDaysFromAnOddFirstAreMixedAndHideNothing() {
    let mixed = MeshWXForecast(
      pointIndex: 1, issuedMinutes: 0, firstPeriod: 1,
      periods: [MeshWXForecastPeriod(highF: 90, lowF: 70), MeshWXForecastPeriod(highF: 91)])
    #expect(MeshWXForecastLayout(of: mixed) == .mixed)
    let entries = MeshWXForecastEntry.entries(of: mixed)
    #expect(entries.map(\.isNight) == [true, false])
    #expect(entries[0].period.highF == 90 && entries[0].period.lowF == 70)
  }

  @Test func singleTemperaturesInTheWrongSlotAreMixed() {
    // Period 0 is a day, but the entry carries only a low.
    let wrongSlot = MeshWXForecast(
      pointIndex: 1, issuedMinutes: 0, firstPeriod: 0,
      periods: [MeshWXForecastPeriod(lowF: 70), MeshWXForecastPeriod(highF: 90)])
    #expect(MeshWXForecastLayout(of: wrongSlot) == .mixed)
  }

  @Test func aForecastWithNoTemperaturesFallsBackToSpecPeriods() {
    let bare = MeshWXForecast(
      pointIndex: 1, issuedMinutes: 0, firstPeriod: 2,
      periods: [MeshWXForecastPeriod(popPercent: 10), MeshWXForecastPeriod(popPercent: 20)])
    #expect(MeshWXForecastLayout(of: bare) == .periods)
    #expect(MeshWXForecastEntry.entries(of: bare).map(\.dayOffset) == [1, 1])
  }
}
