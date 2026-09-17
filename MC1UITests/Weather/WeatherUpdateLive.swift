import XCTest

/// One real request, on the air, to whatever weather radio the phone is hearing.
///
/// This is the only test in the bundle that spends airtime, and it spends it **once**: a single
/// tap on Update on the My location page, then the caption is watched until the run it describes
/// is over — answered, refused, or unanswered — for up to 60 s: three sends, 15 s apart, the last
/// by flood (docs/MESHWX_UI.md §11).
///
/// Nothing is asserted about the weather itself. What is asserted is that the tool said what it
/// was going to ask for, asked, and then said how it went.
@MainActor
final class WeatherUpdateLive: XCTestCase {
  func testOneUpdateSaysWhatItAskedAndHowItWent() throws {
    continueAfterFailure = true
    let driver = WeatherDriver(self, run: "WeatherUpdateLive")

    XCTAssertTrue(driver.openWeather(), "the Weather tool never opened")
    driver.goToFirstPage()
    let place = driver.pageTitle
    driver.log("my location page: \"\(place)\" (page \(driver.pageIndex) of \(driver.pageCount))")

    XCTAssertTrue(
      driver.exists(WeatherID.pageCaption, timeout: WeatherTimeout.screen),
      "the page has no Update caption; it should always say what a tap would ask for")
    let before = driver.pageCaption
    driver.log("caption before: \(before)")
    XCTAssertFalse(before.isEmpty, "the Update caption is empty")
    driver.snap("before-update")

    let update = driver.element(WeatherID.updateButton)
    XCTAssertTrue(
      driver.waitFor(update, WeatherTimeout.screen, "the Update button"),
      "the bottom bar has no Update button")

    // A radio that is still reconnecting after the launch is not a failure: give it a moment.
    let enabledBy = Date().addingTimeInterval(WeatherTimeout.radio)
    while !update.isEnabled, Date() < enabledBy {
      driver.settle(1)
    }
    try XCTSkipUnless(
      update.isEnabled,
      "Update is disabled on \"\(place)\", so there is nothing to send: \(before)")

    XCTAssertTrue(driver.tap(update, "Update"), "the Update button would not take a tap")
    driver.log("Update tapped — one request, no retries from this test")
    driver.settle(2)

    let settled = driver.waitForCaptionToSettle(timeout: WeatherTimeout.answer)
    driver.log("caption after: \(settled)")
    driver.snap("after-update")

    XCTAssertFalse(settled.isEmpty, "the caption went blank after the request")
    XCTAssertTrue(
      WeatherCaption.isSettled(settled),
      "the caption never settled within \(Int(WeatherTimeout.answer)) s — it still reads: \(settled)")
  }
}
