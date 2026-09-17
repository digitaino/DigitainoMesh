import XCTest

/// Drives the Weather tool in the real app — the owner's phone with its own radio and its own
/// saved places, or the project simulator.
///
/// **Nothing here fakes anything.** The app is launched with no launch arguments and no launch
/// environment of its own, so it comes up on the state it was left in: the radio it is paired
/// with, the places that are saved, the bells that are on. A test that needs a place it can
/// delete creates it first (see `WeatherPlacesRoundTrip`); nothing else in this bundle removes,
/// renames or unwatches anything.
///
/// Artefacts: every `snap` is attached to the `.xcresult` **and** written as a PNG under a run
/// directory, so they can be collected from the result bundle or straight off disk. The
/// directory is `$WEATHER_UI_SHOT_DIR/<run>` when that environment variable is set and writable
/// (pass it as `TEST_RUNNER_WEATHER_UI_SHOT_DIR=…` on the `xcodebuild` line), otherwise the test
/// runner's own `Documents/WeatherUIShots/<run>`. The chosen path is printed at the start of
/// every run — see docs/Testing.md.
@MainActor
final class WeatherDriver {
  let app = XCUIApplication()

  private unowned let test: XCTestCase
  private let run: String
  private let shotDirectory: URL?
  private var step = 0

  init(_ test: XCTestCase, run: String) {
    self.test = test
    self.run = run
    shotDirectory = Self.makeShotDirectory(run: run)
    log("run \(run)")
    log("WEATHER_UI_SHOT_DIR = \(ProcessInfo.processInfo.environment["WEATHER_UI_SHOT_DIR"] ?? "(unset)")")
    log("screenshots -> \(shotDirectory?.path ?? "attachments only (no writable directory)")")
  }

  // MARK: - Launching

  /// Brings the app up on whatever it already holds.
  ///
  /// `WEATHER_UI_ACTIVATE=1` foregrounds a running app instead of relaunching it, which keeps a
  /// live Bluetooth session — useful when running several of these back to back on the phone.
  func launch() {
    let activates = ProcessInfo.processInfo.environment["WEATHER_UI_ACTIVATE"] == "1"
    if activates, app.state == .runningForeground || app.state == .runningBackground {
      app.activate()
    } else {
      app.launch()
    }
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: WeatherTimeout.screen),
      "the app did not reach the foreground")
  }

  /// Launch, get to Tools → Weather, and wait for the pager.
  ///
  /// Places opens by itself on a first visit with no permission and no saved place; it is
  /// dismissed with its own Done, which saves nothing and changes nothing.
  @discardableResult
  func openWeather() -> Bool {
    launch()

    // Already inside the tool: the app's tab bar is hidden for every weather screen
    // (docs/MESHWX_UI.md §4), so there is no Tools tab to wait for — and nothing to tap.
    if exists(WeatherID.pager, timeout: 2) {
      log("the Weather tool is already on screen")
      dismissPlacesIfOpen()
      settle(1)
      return true
    }

    let tools = app.tabBars.buttons[WeatherLabel.toolsTab]
    if waitFor(tools, WeatherTimeout.screen, "the Tools tab") {
      // A coordinate, not `tap()`: SwiftUI's tab bar buttons report a hit point of {-1, -1} and
      // a plain tap on one lands nowhere at all.
      tapCentre(tools)
      settle(1.5)
    }

    // The Tools stack remembers the tool it was left on, so Weather may already be on screen —
    // or some other tool may be, in which case the stack has to be popped first.
    if !exists(WeatherID.pager, timeout: 2) {
      var weather = app.buttons[WeatherLabel.weatherTool].firstMatch
      if !weather.waitForExistence(timeout: 3), goBack() {
        log("popped another tool off the Tools stack")
        weather = app.buttons[WeatherLabel.weatherTool].firstMatch
      }
      if waitFor(weather, WeatherTimeout.screen, "the Weather row in Tools") {
        tapCentre(weather)
      }
    }

    let opened = waitFor(element(WeatherID.pager), WeatherTimeout.screen, "the Weather pager")
    dismissPlacesIfOpen()
    settle(1.5)
    return opened
  }

  /// Closes the Places sheet if it opened itself. Done only dismisses — every change in Places
  /// is already saved, and this makes none.
  func dismissPlacesIfOpen() {
    let done = element(WeatherID.placesDone)
    guard done.exists, done.isHittable else { return }
    log("Places was open; closing it with Done")
    done.tap()
    settle(1)
  }

  // MARK: - Finding things

  /// Any element with this identifier, whatever kind SwiftUI made of it. A `Button` in a list
  /// row, a scroll container and a plain `Text` all answer to the same call.
  func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  func exists(_ identifier: String, timeout: TimeInterval) -> Bool {
    element(identifier).waitForExistence(timeout: timeout)
  }

  /// Like `exists`, but for a row that a long list has not built yet: it scrolls looking for it.
  func existsAfterScrolling(_ identifier: String) -> Bool {
    reveal(element(identifier))
  }

  /// The Places search field: by identifier when `.searchable` passed it through, else the one
  /// search field on screen.
  func placesSearchField() -> XCUIElement {
    let byID = app.searchFields[WeatherID.placesSearch]
    if byID.exists { return byID }
    return app.searchFields.firstMatch
  }

  @discardableResult
  func waitFor(_ element: XCUIElement, _ timeout: TimeInterval, _ what: String) -> Bool {
    let found = element.waitForExistence(timeout: timeout)
    if !found { log("MISSING after \(Int(timeout)) s: \(what)") }
    return found
  }

  @discardableResult
  func waitForDisappearance(_ element: XCUIElement, _ timeout: TimeInterval, _ what: String) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !element.exists { return true }
      settle(0.5)
    }
    log("STILL THERE after \(Int(timeout)) s: \(what)")
    return false
  }

  /// The tool's bar is its two buttons: Update at one end, Places at the other, in the same two
  /// places on every page (docs/MESHWX_UI.md §4). The bar has no element of its own to ask for.
  var hasBottomBar: Bool {
    element(WeatherID.updateButton).exists && element(WeatherID.placesButton).exists
  }

  @discardableResult
  func waitForBottomBar(_ timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if hasBottomBar { return true }
      settle(0.5)
    }
    log("MISSING after \(Int(timeout)) s: the tool's bottom bar (Update and Places)")
    return false
  }

  /// Scrolls the page until `element` can be tapped. A list row below the fold does not exist at
  /// all until it is scrolled to — the radio row at the foot of a place page is the usual case —
  /// so this searches rather than waits.
  ///
  /// **Upwards only.** A downward swipe at the top of a place page is the pull-to-refresh
  /// gesture, and that spends airtime (docs/MESHWX_UI.md §11.1). Tests are written to walk down
  /// a page, never back up it.
  @discardableResult
  func reveal(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
    if isOnScreen(element) { return true }
    _ = element.waitForExistence(timeout: 2)
    for _ in 0..<maxSwipes {
      if isOnScreen(element) { return true }
      app.swipeUp()
      settle(0.5)
    }
    return isOnScreen(element)
  }

  /// Hittable — or, failing that, existing with its frame inside the window. A button in an
  /// iOS 26 glass toolbar reports no hit point at all, so "not hittable" alone used to send the
  /// driver scrolling for a Places button that was on screen the whole time; `tap` already taps
  /// the centre of such an element's frame, which is where a thumb lands.
  private func isOnScreen(_ element: XCUIElement) -> Bool {
    guard element.exists else { return false }
    if element.isHittable { return true }
    let frame = element.frame
    return !frame.isEmpty && app.frame.contains(frame)
  }

  /// Taps an element, scrolling to it first when it is off the fold.
  ///
  /// A plain `tap()` is tried first; an element SwiftUI gives no usable hit point is tapped at
  /// the centre of its own frame instead, which is the same place a thumb would land.
  @discardableResult
  func tap(_ element: XCUIElement, _ what: String) -> Bool {
    guard reveal(element) else {
      log("CANNOT TAP: \(what)")
      return false
    }
    if element.isHittable {
      element.tap()
    } else {
      tapCentre(element)
    }
    settle(1)
    return true
  }

  /// Taps the middle of an element's frame, bypassing the hit-point test.
  func tapCentre(_ element: XCUIElement) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
  }

  // MARK: - The pager

  /// The place the pager is on, which is the navigation title.
  var pageTitle: String {
    let bar = app.navigationBars.firstMatch
    guard bar.exists else { return "" }
    if !bar.identifier.isEmpty { return bar.identifier }
    let text = bar.staticTexts.firstMatch
    return text.exists ? text.label : ""
  }

  /// The title on a pushed screen, read the same way.
  var navigationTitle: String { pageTitle }

  /// `(index, count)` read off the page dots, which say "Page 2 of 3". With one page there are
  /// no dots at all, and that is the answer.
  var page: (index: Int, count: Int) {
    let dots = element(WeatherID.pageDots)
    if dots.exists {
      let numbers = Self.numbers(in: dots.label)
      if numbers.count >= 2 { return (numbers[0], numbers[1]) }
    }
    let indicator = app.pageIndicators.firstMatch
    if indicator.exists, let value = indicator.value as? String {
      let numbers = Self.numbers(in: value)
      if numbers.count >= 2 { return (numbers[0], numbers[1]) }
    }
    return (1, 1)
  }

  var pageCount: Int { page.count }
  var pageIndex: Int { page.index }

  /// Swipes to the next page and reports whether the pager actually moved. The drag starts well
  /// away from the screen edges: one that begins within about 20 pt of the left edge is the
  /// system's interactive-pop gesture and leaves the tool instead of paging.
  @discardableResult
  func pageForward() -> Bool { swipePage(from: 0.85, to: 0.15, forward: true) }

  @discardableResult
  func pageBack() -> Bool { swipePage(from: 0.30, to: 0.95, forward: false) }

  /// Swipes back until the pager is on the first page.
  func goToFirstPage() {
    for _ in 0..<(max(pageCount, 1) + 2) where pageIndex > 1 {
      pageBack()
    }
  }

  private func swipePage(from: Double, to: Double, forward: Bool) -> Bool {
    let before = pageIndex
    app.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.28))
      .press(
        forDuration: 0.03,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.28)))
    settle(1.5)
    let after = pageIndex
    let moved = forward ? after > before : after < before
    log("swipe \(forward ? "forward" : "back"): page \(before) -> \(after)")
    return moved
  }

  /// Waits for the pager to hold `count` pages — a page added or removed in Places lands here.
  @discardableResult
  func waitForPageCount(_ count: Int, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if pageCount == count { return true }
      settle(0.5)
    }
    log("page count is \(pageCount), expected \(count)")
    return false
  }

  // MARK: - Navigation

  /// The back button of the screen on top.
  @discardableResult
  func goBack() -> Bool {
    let bar = app.navigationBars.firstMatch
    guard bar.exists else { return false }
    let named = bar.buttons["BackButton"]
    let button = named.exists ? named : bar.buttons.element(boundBy: 0)
    guard button.exists, button.isHittable else {
      log("no back button on \"\(pageTitle)\"")
      return false
    }
    button.tap()
    settle(1.2)
    return true
  }

  func openPlaces() -> Bool {
    guard tap(element(WeatherID.placesButton), "the Places button") else { return false }
    return waitFor(element(WeatherID.placesDone), WeatherTimeout.screen, "the Places sheet")
  }

  // MARK: - The Update caption

  /// The one caption at the top of the page on screen.
  var pageCaption: String {
    let caption = element(WeatherID.pageCaption)
    return caption.exists ? caption.label : ""
  }

  /// Polls the caption until the run it describes is over, or `timeout` passes.
  ///
  /// "Over" means the sentence is one of the endings in `WeatherCaption.isSettled` and has stopped
  /// changing — an answer, a refusal, a silence, or "everything is current".
  func waitForCaptionToSettle(timeout: TimeInterval) -> String {
    let deadline = Date().addingTimeInterval(timeout)
    var last = pageCaption
    var stable = 0
    while Date() < deadline {
      settle(1)
      let now = pageCaption
      if now != last {
        log("caption: \(now)")
        last = now
        stable = 0
        continue
      }
      guard WeatherCaption.isSettled(now), !now.isEmpty else {
        stable = 0
        continue
      }
      stable += 1
      if stable >= 2 { return now }
    }
    log("caption did not settle within \(Int(timeout)) s: \(last)")
    return last
  }

  // MARK: - Artefacts

  /// A screenshot, attached to the result bundle and written to disk.
  func snap(_ name: String) {
    step += 1
    let stamped = String(format: "%02d-%@", step, name)
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = stamped
    attachment.lifetime = .keepAlways
    test.add(attachment)
    if let url = shotDirectory?.appendingPathComponent("\(stamped).png") {
      do {
        try screenshot.pngRepresentation.write(to: url)
        log("shot -> \(url.path)")
      } catch {
        log("shot -> attachment only (\(error.localizedDescription))")
      }
    }
  }

  /// The whole accessibility tree of the app, as the tests see it. The first thing to read when
  /// a query stops matching.
  func dumpTree(_ name: String) {
    step += 1
    let stamped = String(format: "%02d-%@.tree.txt", step, name)
    let tree = app.debugDescription
    let attachment = XCTAttachment(string: tree)
    attachment.name = stamped
    attachment.lifetime = .keepAlways
    test.add(attachment)
    if let url = shotDirectory?.appendingPathComponent(stamped) {
      try? tree.write(to: url, atomically: true, encoding: .utf8)
      log("tree -> \(url.path) (\(tree.count) chars)")
    }
  }

  /// Every line this driver prints also lands in the run directory, so a device run can be read
  /// back without the console.
  func log(_ message: String) {
    let line = "WXUI| \(message)"
    print(line)
    guard let url = shotDirectory?.appendingPathComponent("run.log") else { return }
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    try? (text + line + "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  // MARK: - Small things

  /// Lets the app get on with it without blocking the main thread the queries run on.
  func settle(_ seconds: TimeInterval) {
    let expectation = XCTestExpectation(description: "settle")
    _ = XCTWaiter.wait(for: [expectation], timeout: seconds)
  }

  private static func numbers(in text: String) -> [Int] {
    text.split(whereSeparator: { !$0.isNumber })
      .compactMap { Int($0) }
  }

  /// The run directory, or nil when nothing is writable and the attachments are all there is.
  private static func makeShotDirectory(run: String) -> URL? {
    let manager = FileManager.default
    var bases: [URL] = []
    if let raw = ProcessInfo.processInfo.environment["WEATHER_UI_SHOT_DIR"], !raw.isEmpty {
      bases.append(URL(fileURLWithPath: raw, isDirectory: true))
    }
    if let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
      bases.append(documents.appendingPathComponent("WeatherUIShots", isDirectory: true))
    }
    let stamp = Self.stamp()
    for base in bases {
      let directory = base.appendingPathComponent("\(run)-\(stamp)", isDirectory: true)
      do {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if manager.isWritableFile(atPath: directory.path) { return directory }
      } catch {
        continue
      }
    }
    return nil
  }

  private static func stamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }
}
