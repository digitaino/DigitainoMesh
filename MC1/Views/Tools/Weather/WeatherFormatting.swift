import Foundation
import MC1Services
import MeshWX
import SwiftUI
import UIKit

/// Every word and colour the Weather tool puts on screen, as pure functions.
///
/// `MeshWX` deliberately stops at numbers and enum cases — it names a tint, it does not pick a
/// `Color`; it hands over 1.0 inches of hail, not `"Hail 1.00 in"` — because units, decimal
/// separators and the word for hail are localisation. This is where that turns into text, kept
/// free of any view so each rule in spec §10 is a unit test rather than a screenshot.
enum WeatherFormatting {

  // MARK: - Warnings (spec §10.2)

  /// "expires in 42 min", or "expired" once the phone's clock has passed it.
  ///
  /// Counted against the phone's clock and the absolute expiry, never against receipt: a
  /// warning drained from an offline queue an hour late still has to expire on time.
  static func expiry(expiresMinutes: UInt32, now: Date) -> String {
    let remaining = MeshWXPresentation.minutesUntilExpiry(
      expiresMinutes: expiresMinutes,
      now: MeshWXPresentation.unixMinutes(for: now)
    )
    guard let remaining else { return L10n.Weather.Weather.Warnings.expired }
    guard remaining >= 60 else { return L10n.Weather.Weather.Warnings.expiresIn(remaining) }
    return L10n.Weather.Weather.Warnings.expiresInHours(remaining / 60, remaining % 60)
  }

  /// A warning's tags in the spec's own words, ready to be joined.
  static func tagTexts(for warning: MeshWXWarning, locale: Locale = .autoupdatingCurrent) -> [String] {
    MeshWXPresentation.tags(for: warning).compactMap { tagText($0, locale: locale) }
  }

  static func tagText(_ tag: MeshWXPresentation.Tag, locale: Locale = .autoupdatingCurrent) -> String? {
    switch tag {
    case let .tornado(value):
      switch value {
      case .none: nil
      case .possible: L10n.Weather.Weather.Tag.tornado(L10n.Weather.Weather.TornadoTag.possible)
      case .radarIndicated: L10n.Weather.Weather.Tag.tornado(L10n.Weather.Weather.TornadoTag.radarIndicated)
      case .observed: L10n.Weather.Weather.Tag.tornado(L10n.Weather.Weather.TornadoTag.observed)
      }
    case let .floodSource(value):
      switch value {
      case .none: nil
      case .radar: L10n.Weather.Weather.Tag.floodSource(L10n.Weather.Weather.FloodSourceTag.radar)
      case .radarAndGauge: L10n.Weather.Weather.Tag.floodSource(L10n.Weather.Weather.FloodSourceTag.radarAndGauge)
      case .observed: L10n.Weather.Weather.Tag.floodSource(L10n.Weather.Weather.FloodSourceTag.observed)
      }
    case let .floodDamage(value):
      switch value {
      case .none, .reserved: nil
      case .considerable: L10n.Weather.Weather.Tag.floodDamage(L10n.Weather.Weather.FloodDamageTag.considerable)
      case .catastrophic: L10n.Weather.Weather.Tag.floodDamage(L10n.Weather.Weather.FloodDamageTag.catastrophic)
      }
    case let .hail(inches):
      L10n.Weather.Weather.Tag.hail(inches.formatted(.number.precision(.fractionLength(2)).locale(locale)))
    case let .wind(mph):
      L10n.Weather.Weather.Tag.wind(Int(mph))
    }
  }

  /// The NWS colour convention, resolved against the app's palette.
  ///
  /// The named greens, the lavender and the tan have no system colour that is recognisably
  /// them, so those are literal sRGB — an approximate NWS colour is worse than none, because
  /// a flash flood warning that reads as a plain green is a flood advisory to anyone who knows
  /// the convention.
  static func color(for tint: MeshWXEventTint) -> Color {
    switch tint {
    case .red: .red
    case .yellow: .yellow
    case .orange: .orange
    case .lightOrange: Color(red: 0.97, green: 0.73, blue: 0.42)
    case .darkGreen: Color(red: 0.00, green: 0.42, blue: 0.24)
    case .green: .green
    case .lightGreen: Color(red: 0.52, green: 0.84, blue: 0.47)
    case .orangeRed: Color(red: 0.94, green: 0.33, blue: 0.13)
    case .pink: .pink
    case .purple: .purple
    case .lavender: Color(red: 0.71, green: 0.68, blue: 0.93)
    case .tan: Color(red: 0.76, green: 0.65, blue: 0.48)
    case .magenta: Color(red: 0.86, green: 0.11, blue: 0.60)
    case .blue: .blue
    case .grey: .gray
    }
  }

  /// The same tint for the map, which paints through UIKit.
  static func uiColor(for tint: MeshWXEventTint) -> UIColor {
    UIColor(color(for: tint))
  }

  // MARK: - Areas

  /// "Travis, TX" for a named area; the bare UGC when the bundle is older than the product.
  static func areaName(_ area: MeshWXNamedArea) -> String {
    guard let name = area.name else { return area.ugc }
    return L10n.Weather.Weather.Warnings.area(name, area.state)
  }

  // MARK: - Observations (spec §10.3)

  /// "WNW 15 gusting 26", "Calm", or nil when the station reported no wind at all.
  ///
  /// Nil rather than a zero: a station that did not report is not a station reporting calm.
  static func wind(_ reading: MeshWXWindReading) -> String? {
    guard let speed = reading.speedMph else { return nil }
    guard speed > 0, let direction = reading.direction else {
      return L10n.Weather.Weather.Now.calm
    }
    let base = L10n.Weather.Weather.Wind.speed(direction.abbreviation, Int(speed))
    guard let gust = reading.gustMph else { return base }
    return L10n.Weather.Weather.Wind.gusting(base, Int(gust))
  }

  /// Whole degrees, converted by the locale: the wire is °F, a phone set to metric is not.
  static func temperature(fahrenheit: Int, locale: Locale = .autoupdatingCurrent) -> String {
    Measurement(value: Double(fahrenheit), unit: UnitTemperature.fahrenheit)
      .formatted(
        .measurement(
          width: .narrow,
          usage: .weather,
          numberFormatStyle: .number.precision(.fractionLength(0))
        )
        .locale(locale)
      )
  }

  /// Inches of mercury to two decimals — `29.00 + raw/100`, straight from the wire byte.
  static func pressure(rawPressure: UInt8, locale: Locale = .autoupdatingCurrent) -> String? {
    guard let inHg = MeshWXPresentation.inchesOfMercury(fromRawPressure: rawPressure) else {
      return nil
    }
    return pressure(inchesOfMercury: inHg, locale: locale)
  }

  static func pressure(inchesOfMercury inHg: Double, locale: Locale = .autoupdatingCurrent) -> String {
    inHg.formatted(.number.precision(.fractionLength(2)).locale(locale))
  }

  /// Statute miles, converted by the locale.
  static func visibility(miles: UInt8, locale: Locale = .autoupdatingCurrent) -> String {
    Measurement(value: Double(miles), unit: UnitLength.miles)
      .formatted(.measurement(width: .abbreviated, usage: .general).locale(locale))
  }

  /// Distance to the user, in the units the phone uses for road distances.
  static func distance(metres: Double, locale: Locale = .autoupdatingCurrent) -> String {
    Measurement(value: metres, unit: UnitLength.meters)
      .formatted(.measurement(width: .abbreviated, usage: .road).locale(locale))
  }

  /// The bundle's station names are ALL CAPS, which reads as shouting in a list row.
  /// A name that is already mixed case is left alone — it was not the bundle's to shout.
  static func stationName(_ raw: String) -> String {
    guard raw == raw.uppercased() else { return raw }
    return raw.capitalized
  }

  // MARK: - Forecast periods (spec §7)

  /// "Today", "Tonight", "Tomorrow", "Tomorrow night", then the weekday — the labels a
  /// person reads off a forecast, derived from the period id and the issue date.
  static func periodLabel(
    periodID: UInt8,
    issuedAt: Date,
    calendar: Calendar = .autoupdatingCurrent,
    locale: Locale = .autoupdatingCurrent
  ) -> String {
    let slot = MeshWXPeriodSlot(periodID: periodID)
    switch slot.dayOffset {
    case 0:
      return slot.isNight ? L10n.Weather.Weather.Forecast.Period.tonight : L10n.Weather.Weather.Forecast.Period.today
    case 1:
      return slot.isNight
        ? L10n.Weather.Weather.Forecast.Period.tomorrowNight
        : L10n.Weather.Weather.Forecast.Period.tomorrow
    default:
      let day = calendar.date(byAdding: .day, value: slot.dayOffset, to: issuedAt) ?? issuedAt
      var style = Date.FormatStyle.dateTime.weekday(.wide).locale(locale)
      style.calendar = calendar
      style.timeZone = calendar.timeZone
      let weekday = day.formatted(style)
      return slot.isNight ? L10n.Weather.Weather.Forecast.Period.night(weekday) : weekday
    }
  }

  // MARK: - Text products (spec §8.1)

  static func subjectTitle(_ subject: MeshWXTextSubject) -> String {
    switch subject {
    case .warningNarrative: L10n.Weather.Weather.Text.Subject.warning
    case .forecastDiscussion: L10n.Weather.Weather.Text.Subject.discussion
    case .spaceWeather: L10n.Weather.Weather.Text.Subject.space
    case .stormReports: L10n.Weather.Weather.Text.Subject.storm
    case .rainfall: L10n.Weather.Weather.Text.Subject.rain
    case .metarOrTAF: L10n.Weather.Weather.Text.Subject.metarTaf
    case .hazardousOutlook: L10n.Weather.Weather.Text.Subject.outlook
    case .nowcast: L10n.Weather.Weather.Text.Subject.nowcast
    case .general: L10n.Weather.Weather.Text.Subject.general
    case .other: L10n.Weather.Weather.Text.Subject.other
    }
  }

  // MARK: - Request outcomes (spec §8.3)

  static func notAvailableText(_ reason: MeshWXNotAvailableReason) -> String {
    switch reason {
    case .noData: L10n.Weather.Weather.Request.NotAvailable.noData
    case .unknownLocation: L10n.Weather.Weather.Request.NotAvailable.unknownLocation
    case .unsupported: L10n.Weather.Weather.Request.NotAvailable.unsupported
    case .botError: L10n.Weather.Weather.Request.NotAvailable.botError
    case .rateLimited: L10n.Weather.Weather.Request.NotAvailable.rateLimited
    case .other: L10n.Weather.Weather.Request.NotAvailable.other
    }
  }
}

// MARK: - Asking again

/// Which request would fetch a text product a second time.
///
/// A text reply carries a subject and a group and no echo of what was asked, so recovering a
/// missing chunk means reconstructing the request. Some subjects are their own request; the
/// rest name a station, a state, an office or a warning, and for those the only source of the
/// argument is what the app last sent (``WeatherToolModel/lastTextRequests``).
enum WeatherTextRequests {

  /// The request for a subject that needs no argument, or nil for one that does.
  static func subjectOnlyRequest(for subject: MeshWXTextSubject) -> WeatherRequest? {
    switch subject {
    case .spaceWeather: .spaceWeather
    case .hazardousOutlook: .hazardousOutlook
    case .warningNarrative, .forecastDiscussion, .stormReports, .rainfall, .metarOrTAF,
      .nowcast, .general, .other:
      nil
    }
  }

  /// What "ask again" sends for an incomplete reply: the request that produced it where the
  /// app still remembers it, otherwise the subject's own request.
  static func repeatRequest(
    for subject: MeshWXTextSubject,
    lastRequests: [UInt8: WeatherRequest]
  ) -> WeatherRequest? {
    lastRequests[subject.rawValue] ?? subjectOnlyRequest(for: subject)
  }
}
