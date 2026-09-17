import Foundation
import MC1Services
import MeshWX
import SwiftUI
import UIKit

/// Words, units and colours the Weather tool puts on screen, as pure functions.
///
/// `MeshWX` stops at numbers and enum cases; this is where they become text. Kept free of any
/// view so each rule is a unit test rather than a screenshot.
enum WeatherFormatting {
  // MARK: - Clock and durations

  /// "11:02 PM" for today and for anything up to twelve hours ahead (a warning ending at 12:40 AM
  /// is "until 12:40 AM"); "yesterday 2:00 PM" for yesterday; "Sep 13, 8:02 PM" otherwise.
  static func clockTime(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
    let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    let time = date.formatted(base.hour().minute())
    if calendar.isDate(date, inSameDayAs: now) { return time }
    if date > now, date.timeIntervalSince(now) < 12 * 3600 { return time }
    if date < now, let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
       calendar.isDate(date, inSameDayAs: yesterday) {
      return L10n.Weather.Weather.Time.yesterday(time)
    }
    return date.formatted(base.month(.abbreviated).day().hour().minute())
  }

  /// "40 s", "2 min", "3 h", "2 d": the largest unit that fits, rounded down.
  static func duration(seconds: TimeInterval) -> String {
    let seconds = max(0, Int(seconds))
    if seconds < 60 { return L10n.Weather.Weather.Unit.seconds(seconds) }
    if seconds < 3600 { return L10n.Weather.Weather.Unit.minutes(seconds / 60) }
    if seconds < 48 * 3600 { return L10n.Weather.Weather.Unit.hours(seconds / 3600) }
    return L10n.Weather.Weather.Unit.days(seconds / 86_400)
  }

  /// "just now", "40 s ago", "2 min ago", "3 h ago".
  static func ago(_ date: Date, now: Date) -> String {
    let elapsed = now.timeIntervalSince(date)
    guard elapsed >= 5 else { return L10n.Weather.Weather.Time.justNow }
    return L10n.Weather.Weather.Time.ago(duration(seconds: elapsed))
  }

  /// "3 h old".
  static func age(_ date: Date, now: Date) -> String {
    L10n.Weather.Weather.Time.old(duration(seconds: now.timeIntervalSince(date)))
  }

  /// "in 40 min", "in 1 h 20 min", "in 2 h".
  static func countdown(minutes: Int) -> String {
    let minutes = max(0, minutes)
    if minutes < 60 { return L10n.Weather.Weather.Time.within(L10n.Weather.Weather.Unit.minutes(minutes)) }
    let hours = minutes / 60
    let rest = minutes % 60
    let words = rest == 0
      ? L10n.Weather.Weather.Unit.hours(hours)
      : L10n.Weather.Weather.Unit.hoursMinutes(hours, rest)
    return L10n.Weather.Weather.Time.within(words)
  }

  /// "45 min" or "5 h", for how long a feed has been quiet.
  static func quietDuration(minutes: Int) -> String {
    minutes < 60
      ? L10n.Weather.Weather.Unit.minutes(max(0, minutes))
      : L10n.Weather.Weather.Unit.hours(minutes / 60)
  }

  /// "until 11:41 PM · in 40 min".
  static func untilLine(expiresAt: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
    let minutes = Int(ceil(expiresAt.timeIntervalSince(now) / 60))
    return L10n.Weather.Weather.Alerts.until(
      clockTime(expiresAt, now: now, calendar: calendar, locale: locale), countdown(minutes: minutes))
  }

  // MARK: - Distance

  /// "3 km", "under 1 km".
  static func kilometres(_ kilometres: Double) -> String {
    guard kilometres >= 0.5 else { return L10n.Weather.Weather.Unit.underOneKilometre }
    return L10n.Weather.Weather.Unit.kilometres(Int(kilometres.rounded()))
  }

  /// "25 km N".
  static func distance(_ kilometres: Double, direction: MeshWXCompass?) -> String {
    let distance = Self.kilometres(kilometres)
    guard let direction else { return distance }
    return L10n.Weather.Weather.Unit.distanceDirection(distance, direction.abbreviation)
  }

  /// The 16-point compass direction from one coordinate towards another.
  static func direction(from: MeshWXCoordinate, to: MeshWXCoordinate) -> MeshWXCompass {
    let lat1 = from.latitude * .pi / 180
    let lat2 = to.latitude * .pi / 180
    let dLon = (to.longitude - from.longitude) * .pi / 180
    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    let degrees = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    return MeshWXCompass(degrees: degrees)
  }

  // MARK: - Names

  /// "WX-AUS", or "Weather radio 041D" for a bot heard without an advert.
  static func botName(botID: UInt16, bot: WeatherBot?) -> String {
    bot?.name ?? L10n.Weather.Weather.Bot.heardOnly(String(format: "%04X", botID))
  }

  /// A name at the start of a sentence: "the weather radio" becomes "The weather radio".
  static func sentenceStart(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
  }

  /// **The one way a place is named**, everywhere the app names one (docs/MESHWX_UI.md §3.1 U-12).
  ///
  /// One tap used to produce three names: "Austin" in the title bar, "Austin, TX" in Places and
  /// the station's own town in the line under the temperature, and nothing on screen said they
  /// were the same place. The label the place carries is that name — the state stays on, because
  /// it is what tells two Austins apart — and it is not shortened for one screen and not another.
  static func placeName(_ label: String) -> String {
    label.trimmingCharacters(in: .whitespaces)
  }

  /// "v1.14.0" → "1.14"; anything unrecognised is returned as it is.
  static func firmwareVersion(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespaces)
    if text.lowercased().hasPrefix("v") { text.removeFirst() }
    var parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return raw }
    while parts.count > 2, parts.last == "0" { parts.removeLast() }
    return parts.joined(separator: ".")
  }

  // A forecast point is named by `WeatherNames.pointLabel`, which is the one function every site
  // that names one now calls (docs/MESHWX_UI.md §3.1 U-25). The two that used to live here —
  // a state reader and a label builder — were the second and third spellings of "Austin Camp
  // Mabry".

  static func eventName(_ event: UInt8, tables: MeshWXTables) -> String {
    tables.eventName(for: event)?.long ?? tables.eventLabel(for: event)
  }

  /// "Travis, TX" for a named area; the bare UGC when the bundle is older than the product.
  static func areaName(_ area: MeshWXNamedArea) -> String {
    guard let name = area.name else { return area.ugc }
    return L10n.Weather.Weather.Alerts.area(name, area.state)
  }

  /// "Llano County" for a county, the zone's own name for a zone.
  static func shortAreaName(_ area: MeshWXNamedArea) -> String {
    guard let name = area.name else { return area.ugc }
    return area.isCounty ? L10n.Weather.Weather.Area.county(name) : name
  }

  /// Areas once each, in the order the product names them.
  static func uniqueAreas(_ areas: [MeshWXNamedArea]) -> [MeshWXNamedArea] {
    var seen: Set<String> = []
    return areas.filter { seen.insert($0.ugc).inserted }
  }

  // MARK: - Weather values

  /// Whole degrees, converted by the locale: the wire is °F, a phone set to metric is not.
  static func temperature(fahrenheit: Int, locale: Locale = .autoupdatingCurrent) -> String {
    Measurement(value: Double(fahrenheit), unit: UnitTemperature.fahrenheit)
      .formatted(
        .measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0)))
          .locale(locale))
  }

  /// "SSE 12 gusting 21", "calm", or nil when the station reported no wind at all.
  static func wind(_ reading: MeshWXWindReading) -> String? {
    guard let speed = reading.speedMph else { return nil }
    guard speed > 0, let direction = reading.direction else { return L10n.Weather.Weather.Wind.calm }
    let base = L10n.Weather.Weather.Wind.speed(direction.abbreviation, Int(speed))
    guard let gust = reading.gustMph, gust > 0 else { return base }
    return L10n.Weather.Weather.Wind.gusting(base, Int(gust))
  }

  static func pressure(inchesOfMercury inHg: Double, locale: Locale = .autoupdatingCurrent) -> String {
    inHg.formatted(.number.precision(.fractionLength(2)).locale(locale))
  }

  /// "10 mi"; 0 reads "under 1 mi", since the bot sends whole miles rounded down (spec §6,
  /// revision 3: 1/2SM is 0).
  static func visibility(miles: UInt8, locale: Locale = .autoupdatingCurrent) -> String {
    func formatted(_ value: Double) -> String {
      Measurement(value: value, unit: UnitLength.miles)
        .formatted(.measurement(width: .abbreviated, usage: .asProvided).locale(locale))
    }
    return miles == 0 ? L10n.Weather.Weather.Unit.under(formatted(1)) : formatted(Double(miles))
  }

  /// The word for a sky code; nil for "other", which names nothing.
  static func condition(_ sky: MeshWXSky) -> String? {
    switch sky {
    case .clear: L10n.Weather.Weather.Sky.clear
    case .few: L10n.Weather.Weather.Sky.few
    case .scattered: L10n.Weather.Weather.Sky.scattered
    case .broken: L10n.Weather.Weather.Sky.broken
    case .overcast: L10n.Weather.Weather.Sky.overcast
    case .fog: L10n.Weather.Weather.Sky.fog
    case .smoke: L10n.Weather.Weather.Sky.smoke
    case .haze: L10n.Weather.Weather.Sky.haze
    case .rain: L10n.Weather.Weather.Sky.rain
    case .snow: L10n.Weather.Weather.Sky.snow
    case .thunderstorm: L10n.Weather.Weather.Sky.thunderstorm
    case .drizzle: L10n.Weather.Weather.Sky.drizzle
    case .mist: L10n.Weather.Weather.Sky.mist
    case .squall: L10n.Weather.Weather.Sky.squall
    case .sandOrDust: L10n.Weather.Weather.Sky.dust
    case .other: nil
    }
  }

  /// An observation taken between 7 PM and 6 AM on the phone's clock draws the night icon.
  static func isNight(_ date: Date, calendar: Calendar) -> Bool {
    let hour = calendar.component(.hour, from: date)
    return hour < 6 || hour >= 19
  }

  // MARK: - Tags

  static func tagTexts(for warning: MeshWXWarning, locale: Locale = .autoupdatingCurrent) -> [String] {
    MeshWXPresentation.tags(for: warning).compactMap { tagText($0, locale: locale) }
  }

  /// Every tag on one line, for a row that truncates.
  static func tagLine(for warning: MeshWXWarning, locale: Locale = .autoupdatingCurrent) -> String {
    tagTexts(for: warning, locale: locale).joined(separator: " · ")
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

  // MARK: - Colour

  /// The NWS colour convention. The named greens, the lavender and the tan have no system
  /// colour that is recognisably them, so those are literal sRGB.
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

  static func uiColor(for tint: MeshWXEventTint) -> UIColor {
    UIColor(color(for: tint))
  }

  static func tint(for event: UInt8, tables: MeshWXTables) -> MeshWXEventTint {
    MeshWXPresentation.tint(forVTEC: tables.vtec(for: event) ?? "")
  }

  static func symbol(for event: UInt8, tables: MeshWXTables) -> String {
    MeshWXPresentation.symbolName(forVTEC: tables.vtec(for: event) ?? "")
  }
}
