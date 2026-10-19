import XCTest

/// Every page the pager holds, swiped through and photographed.
///
/// The structural claim of docs/MESHWX_UI.md §4: one page per place, the same bar on all of them,
/// and the title bar naming the place you are on. Nothing here asks the radio for anything.
@MainActor
final class WeatherPagerSmoke: XCTestCase {
  func testEveryPageIsNamedAndKeepsTheBottomBar() throws {
    continueAfterFailure = true
    let driver = WeatherDriver(self, run: "WeatherPagerSmoke")

    XCTAssertTrue(driver.openWeather(), "the Weather tool never opened")
    XCTAssertTrue(
      driver.waitForBottomBar(WeatherTimeout.screen),
      "the tool's bottom bar (Update · dots · Places) is not on screen")
    driver.dumpTree("weather-open")

    driver.goToFirstPage()
    let count = driver.pageCount
    driver.log("pages: \(count)")
    XCTAssertGreaterThanOrEqual(count, 1, "the pager holds no pages at all")

    var titles: [String] = []
    for number in 1...count {
      let title = driver.pageTitle
      driver.log("page \(number)/\(count): \"\(title)\"")
      driver.snap("page-\(number)")

      XCTAssertFalse(
        title.isEmpty,
        "page \(number) of \(count) has no title: the bar should name the place")
      XCTAssertTrue(
        driver.waitForBottomBar(WeatherTimeout.short),
        "the bottom bar is missing on page \(number) of \(count)")
      if let previous = titles.last {
        XCTAssertNotEqual(
          title, previous,
          "the title did not change between page \(number - 1) and page \(number): \(titles + [title])")
      }
      titles.append(title)

      guard number < count else { break }
      XCTAssertTrue(
        driver.pageForward(),
        "the pager did not move from page \(number) to page \(number + 1)")
    }

    XCTAssertEqual(titles.count, count, "did not reach every page: \(titles)")
  }
}
