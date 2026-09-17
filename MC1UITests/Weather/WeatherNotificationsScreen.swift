import XCTest

/// Opens the alert-notifications screen and photographs it. **Read-only**: no bell is touched,
/// no toggle is flipped, nothing is asked of the radio (docs/MESHWX_UI.md §16).
///
/// The way in is the one the app offers: the radio row at the foot of a place page, then Alert
/// notifications on the radio page.
@MainActor
final class WeatherNotificationsScreen: XCTestCase {
  func testAlertNotificationsOpensAndChangesNothing() throws {
    continueAfterFailure = true
    let driver = WeatherDriver(self, run: "WeatherNotificationsScreen")

    XCTAssertTrue(driver.openWeather(), "the Weather tool never opened")
    let place = driver.pageTitle
    driver.log("from \"\(place)\"")

    XCTAssertTrue(
      driver.tap(driver.element(WeatherID.radioRow), "the radio row"),
      "the radio row is not on \"\(place)\"")
    // Six sections down the radio page, so it has to be scrolled to before it exists at all.
    let notifications = driver.element(WeatherID.radioNotifications)
    XCTAssertTrue(driver.reveal(notifications), "the radio page has no Alert notifications row")
    driver.snap("radio-page")

    XCTAssertTrue(driver.tap(notifications, "Alert notifications"), "Alert notifications would not open")
    XCTAssertTrue(
      driver.exists(WeatherID.notificationsPromise, timeout: WeatherTimeout.screen),
      "the alert-notifications screen did not appear")
    XCTAssertEqual(
      driver.navigationTitle, WeatherLabel.alertNotifications,
      "something other than Alert notifications opened")
    driver.snap("alert-notifications")
    driver.dumpTree("alert-notifications")

    // Out the way we came in, touching nothing.
    XCTAssertTrue(driver.goBack(), "could not leave the alert-notifications screen")
    XCTAssertTrue(driver.goBack(), "could not leave the radio page")
    XCTAssertEqual(driver.pageTitle, place, "the pager moved while the screens were open")
  }
}
