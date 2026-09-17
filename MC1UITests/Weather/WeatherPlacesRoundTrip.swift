import XCTest

/// Adds one place and takes it away again.
///
/// **The only test in this bundle that writes anything**, and it only ever touches the place it
/// created. If "Llano, TX" is already saved on this phone the test skips rather than add a
/// duplicate — and it never swipes a row it did not add.
@MainActor
final class WeatherPlacesRoundTrip: XCTestCase {
  /// The town searched for, and the label it is saved under
  /// (`WeatherNames.placeLabel(name:state:)` — "Llano, TX").
  private let query = "Llano"
  private let label = "Llano, TX"

  func testAddAPlaceThenRemoveIt() throws {
    continueAfterFailure = false
    let driver = WeatherDriver(self, run: "WeatherPlacesRoundTrip")

    XCTAssertTrue(driver.openWeather(), "the Weather tool never opened")
    let pagesBefore = driver.pageCount
    driver.log("pages before: \(pagesBefore)")

    XCTAssertTrue(driver.openPlaces(), "Places did not open")
    driver.snap("places-before")

    // Guard: a place the owner saved himself is not this test's to delete.
    if driver.element(WeatherID.placesRow(label)).exists {
      driver.log("\(label) is already saved on this phone")
      driver.dismissPlacesIfOpen()
      throw XCTSkip("\(label) is already saved; this test only removes a place it added itself")
    }

    try add(driver)
    XCTAssertTrue(
      driver.waitForPageCount(pagesBefore + 1, timeout: WeatherTimeout.screen),
      "no page appeared for \(label)")
    driver.log("page after adding: \"\(driver.pageTitle)\" (\(driver.pageCount) pages)")
    driver.snap("page-added")

    try remove(driver)
    XCTAssertTrue(
      driver.waitForPageCount(pagesBefore, timeout: WeatherTimeout.screen),
      "the page for \(label) is still in the pager")
    driver.snap("page-removed")
  }

  // MARK: - Adding

  private func add(_ driver: WeatherDriver) throws {
    let search = driver.placesSearchField()
    XCTAssertTrue(
      driver.waitFor(search, WeatherTimeout.screen, "the Places search field"),
      "Places has no search field")
    search.tap()
    search.typeText(query)
    driver.settle(2)

    let result = driver.element(WeatherID.placesResult(label))
    XCTAssertTrue(
      driver.waitFor(result, WeatherTimeout.screen, "the \(label) search result"),
      "searching for \"\(query)\" did not offer \(label)")
    driver.snap("search-\(query)")
    XCTAssertTrue(driver.tap(result, "the \(label) result"), "the \(label) result would not take a tap")
    driver.settle(2)
  }

  // MARK: - Removing

  /// Swipe-to-delete on the row this test added, and nothing else.
  ///
  /// A full swipe removes the row on its own (`allowsFullSwipe: true`); a shorter one reveals
  /// Remove. Both are accepted, because both are what a thumb does.
  ///
  /// Two gestures are tried, twice each. A swipe that is read as a *tap* instead picks the place
  /// and closes Places without removing anything, and is retried rather than reported — see
  /// docs/Testing.md for the known limitation behind that, and for what to do if this fails and
  /// leaves the place behind.
  private func remove(_ driver: WeatherDriver) throws {
    var removed = false
    var tried: [String] = []
    for attempt in 1...4 where !removed {
      XCTAssertTrue(driver.openPlaces(), "Places did not open for the removal")
      let row = driver.element(WeatherID.placesRow(label))
      guard driver.reveal(row) else {
        driver.log("\(label) is no longer in Places")
        removed = true
        break
      }
      if attempt == 1 { driver.snap("places-with-\(query)") }

      let gesture = attempt <= 2 ? "swipeLeft()" : "slow drag across the row"
      tried.append(gesture)
      driver.log("attempt \(attempt): \(gesture)")
      if attempt <= 2 {
        row.swipeLeft()
      } else {
        let frame = row.frame
        let origin = driver.app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: frame.maxX, dy: frame.midY))
          .press(
            forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: frame.minX, dy: frame.midY)),
            withVelocity: .slow,
            thenHoldForDuration: 0.6)
      }
      driver.settle(1.5)

      let remove = driver.app.buttons[WeatherLabel.remove]
      if remove.waitForExistence(timeout: WeatherTimeout.short) {
        driver.snap("row-swiped")
        remove.tap()
        driver.settle(1.5)
      }

      guard driver.element(WeatherID.placesDone).exists else {
        driver.log("attempt \(attempt): the swipe closed Places instead of removing the row")
        continue
      }
      removed = driver.waitForDisappearance(row, WeatherTimeout.short, "the \(label) row")
      driver.snap("places-after")
    }
    driver.dismissPlacesIfOpen()
    XCTAssertTrue(
      removed,
      """
      \(label) could not be swiped away (tried: \(tried.joined(separator: ", "))). \
      It is still saved on this phone — remove it by hand in Places. See docs/Testing.md.
      """)
  }
}
