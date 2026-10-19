import Foundation

/// The accessibility identifiers the Weather tool carries for these tests, and the handful of
/// on-screen words that have no identifier behind them.
///
/// A UI test bundle does not link the app, so it cannot read `L10n` or the app's own constants:
/// this file is the mirror of the `.accessibilityIdentifier(…)` calls in
/// `MC1/Views/Tools/Weather/`. Change one and change the other.
enum WeatherID {
  // The pager and its bar (WeatherToolView.swift).
  //
  // The bar itself carries no identifier: an identifier on a SwiftUI container is handed down to
  // every child that has one of its own, so naming the bar erased the names of the two buttons
  // inside it. The bar *is* those two buttons — see `WeatherDriver.hasBottomBar`.
  static let pager = "weather.pager"
  static let pageDots = "weather.pageDots"
  static let placesButton = "weather.places.button"

  // Update (WeatherUpdateControl.swift, WeatherPlacePageView.swift)
  static let updateButton = "weather.update.button"
  /// The caption under a station screen's Update button; hidden from accessibility unless it is
  /// carrying a blocking reason.
  static let updateCaption = "weather.update.caption"
  /// The one caption at the top of a place page: what Update would ask for, and what the last
  /// run did ask for.
  static let pageCaption = "weather.page.caption"

  // Rows on a place page (WeatherPlacePageView.swift, WeatherConditionsSection.swift)
  static let warningBanner = "weather.warningBanner"
  static let honestyLine = "weather.honestyLine"
  static let radioRow = "weather.radioRow"

  // The five text-report rows (WeatherReportsView.swift)
  static let reportDiscussion = "weather.report.discussion"
  static let reportOutlook = "weather.report.outlook"
  static let reportStormReports = "weather.report.stormReports"
  static let reportRainfall = "weather.report.rainfall"
  static let reportSpaceWeather = "weather.report.spaceWeather"

  // Places (WeatherPlacePickerView.swift)
  static let placesSearch = "weather.places.search"
  static let placesDone = "weather.places.done"
  static let placesMyLocationRow = "weather.places.row.myLocation"
  /// A saved place's row, named by the label the place was saved under ("Llano, TX").
  static func placesRow(_ label: String) -> String { "weather.places.row.\(label)" }
  /// A search result's row, named by the same label the pick would save.
  static func placesResult(_ label: String) -> String { "weather.places.result.\(label)" }
  static func placesStation(_ icao: String) -> String { "weather.places.station.\(icao)" }
  static func placesBell(_ placeName: String) -> String { "weather.places.bell.\(placeName)" }

  // The radio page (WeatherRadioView.swift, WeatherAlertNotificationsView.swift)
  static let radioAlerts = "weather.radio.alerts"
  static let radioStations = "weather.radio.stations"
  static let radioNotifications = "weather.radio.notifications"
  static let radioCached = "weather.radio.cached"
  static let notificationsPromise = "weather.notifications.promise"
}

/// Words that appear on screen with no identifier of their own. English only: these tests run
/// against the owner's phone and the project's own simulator, both in English.
enum WeatherLabel {
  static let toolsTab = "Tools"
  static let weatherTool = "Weather"
  static let done = "Done"
  static let remove = "Remove"
  static let places = "Places"
  static let alertNotifications = "Alert notifications"
  static let forecastDiscussion = "Forecast discussion"
  static let myLocation = "My location"
}

/// How long a step is given. A radio is on the other end of some of these, so the numbers are
/// the bot's, not a local view's.
enum WeatherTimeout {
  /// A control that is already on screen.
  static let short: TimeInterval = 5
  /// A screen being pushed, a sheet being presented, a page being built.
  static let screen: TimeInterval = 20
  /// A radio reconnecting after a launch.
  static let radio: TimeInterval = 30
  /// A request on the air: two channel sends 10 s apart, or the DM fallback's three sends 15 s apart; 60 leaves room to settle.
  static let answer: TimeInterval = 60
}

/// Reading the Update caption without the app's string table.
///
/// Mirrors `Weather.strings`: `weather.request.*` and `weather.update.*`. Matching is on the
/// distinctive part of each sentence, so a reworded prefix does not break the test.
enum WeatherCaption {
  /// A request is on the air, or is being held back for one that is.
  static func isPending(_ text: String) -> Bool {
    let t = text.lowercased()
    // "Asking WX-AUS… (up to 30 s)" — and not "Asking WX-AUS for: conditions", which is the
    // plan a tap *would* send.
    return t.contains("up to 30 s")
      || t.contains("asking again")
      || t.contains("waiting for another answer")
      || t.contains("wait a few seconds")
  }

  /// The run is over, one way or another: an answer, a refusal, a silence, or "nothing to ask".
  static func isSettled(_ text: String) -> Bool {
    guard !isPending(text) else { return false }
    let t = text.lowercased()
    let endings = [
      "answered", // "… answered at 8:24 PM", "… answered in the last 5 minutes"
      "didn't answer",
      "no answer",
      "no newer",
      "received",
      "everything is current",
      "couldn't send",
      "no data for that",
      "didn't recognize",
      "is busy",
      "had an error",
      "can't answer",
      "can't do that"
    ]
    return endings.contains { t.contains($0) }
  }
}
