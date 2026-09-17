import XCTest

/// From a page that is **not** the first one, open everything that page offers and come back.
///
/// The bug this guards is docs/MESHWX_UI.md §3.1 U-18 / P-1: a screen pushed from a place page is
/// built from *that page's* build, not from whatever the pager has since landed on. So:
///
/// * the station screen, opened from the honesty line, names the page's place in so many words;
/// * every drill-in returns to the page it was opened from, with the same place in the title bar.
///
/// The forecast discussion and the radio page carry no place name of their own by design — the
/// discussion is a Weather Service office's text and the radio page is about the radio — so what
/// is asserted for those two is that the right screen opened and that the pager did not move
/// underneath it.
@MainActor
final class WeatherDrillInsStayOnPage: XCTestCase {
  func testDrillInsComeBackToTheSamePlace() throws {
    continueAfterFailure = true
    let driver = WeatherDriver(self, run: "WeatherDrillInsStayOnPage")

    XCTAssertTrue(driver.openWeather(), "the Weather tool never opened")
    driver.goToFirstPage()
    try XCTSkipUnless(
      driver.pageCount > 1,
      "this phone holds one page; there is no non-first page to drill in from")

    XCTAssertTrue(driver.pageForward(), "the pager did not leave the first page")
    let place = driver.pageTitle
    XCTAssertFalse(place.isEmpty, "the page the drill-ins run from has no title")
    driver.log("drilling in from \"\(place)\" (page \(driver.pageIndex) of \(driver.pageCount))")
    driver.snap("page-\(place)")

    // Top of the page downwards, in the order the rows sit in: the honesty line is under the
    // temperature, the report rows are below the forecast, and the radio row is the last one.
    // Nothing here ever scrolls back up — a downward swipe at the top of a page is the
    // pull-to-refresh gesture, and this test spends no airtime.
    try openStationFromHonestyLine(driver, place: place)
    try openForecastDiscussion(driver, place: place)
    try openRadioPage(driver, place: place)
  }

  // MARK: - The forecast discussion

  private func openForecastDiscussion(_ driver: WeatherDriver, place: String) throws {
    let row = driver.element(WeatherID.reportDiscussion)
    guard driver.tap(row, "the Forecast discussion row") else {
      return XCTFail("the Forecast discussion row is not on \"\(place)\"")
    }
    XCTAssertEqual(
      driver.navigationTitle, WeatherLabel.forecastDiscussion,
      "the row opened something else")
    driver.snap("discussion")
    XCTAssertTrue(driver.goBack(), "could not leave the forecast discussion")
    XCTAssertEqual(
      driver.pageTitle, place,
      "the pager moved while the forecast discussion was open")
  }

  // MARK: - The station, via the honesty line

  private func openStationFromHonestyLine(_ driver: WeatherDriver, place: String) throws {
    let line = driver.element(WeatherID.honestyLine)
    guard line.waitForExistence(timeout: WeatherTimeout.short) else {
      driver.log("no honesty line on \"\(place)\": no station reading is held for it")
      return
    }
    driver.log("honesty line: \(line.label)")
    guard driver.tap(line, "the honesty line") else {
      return XCTFail("the honesty line on \"\(place)\" would not open")
    }
    driver.snap("station")

    // The station screen says how far it is **from the page this was opened on**.
    let namesThePlace = driver.app.staticTexts
      .containing(NSPredicate(format: "label CONTAINS[c] %@", place))
      .firstMatch
    XCTAssertTrue(
      namesThePlace.waitForExistence(timeout: WeatherTimeout.screen),
      "the station screen opened from \"\(place)\" does not name it")

    XCTAssertTrue(driver.goBack(), "could not leave the station screen")
    XCTAssertEqual(driver.pageTitle, place, "the pager moved while the station was open")
  }

  // MARK: - The radio page

  private func openRadioPage(_ driver: WeatherDriver, place: String) throws {
    let row = driver.element(WeatherID.radioRow)
    guard driver.tap(row, "the radio row") else {
      return XCTFail("the radio row is not on \"\(place)\"")
    }
    XCTAssertTrue(
      driver.existsAfterScrolling(WeatherID.radioNotifications),
      "the radio row opened something that is not the radio page")
    XCTAssertNotEqual(
      driver.navigationTitle, place,
      "the radio page should be titled for the radio, not for the place")
    driver.snap("radio-page")

    XCTAssertTrue(driver.goBack(), "could not leave the radio page")
    XCTAssertEqual(driver.pageTitle, place, "the pager moved while the radio page was open")
  }
}
