import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// The tool is a pager of places, and everything it shows belongs to **one** of them
/// (docs/MESHWX_UI.md §4, §13).
///
/// The bug these are written against: one snapshot and one context for the whole visit, with
/// every screen reached from a page reading them. Swipe to Round Rock, open the forecast
/// discussion, and Austin's discussion was on it — same subject, wrong place, and the blurb above
/// it naming Round Rock's office while the header named Austin's.
@Suite("Weather paged screen")
struct WeatherPagedScreenTests {
  private typealias P = WeatherPhoneFixture

  private let wxAus = WeatherBot(
    publicKey: Data([0x1D, 0x04]) + Data(repeating: 0x55, count: 30),
    name: "WX-AUS", latitude: 0, longitude: 0, lastAdvert: nil)

  private func snapshot(
    place: WeatherPlace?,
    pageID: String,
    state: WeatherBotState = P.state(),
    now: Date = P.now
  ) -> WeatherScreenSnapshot {
    WeatherScreenSnapshot.make(
      WeatherScreenSnapshot.Inputs(
        states: [P.botID: state], bots: [wxAus], preferredBotID: nil, place: place, pageID: pageID,
        isRadioConnected: true, firmwareSupportsWeather: true, firmwareVersion: "v1.15.0",
        hasWeatherChannel: true, session: WeatherSessionInfo(startedAt: now.addingTimeInterval(-3600)),
        now: now, calendar: P.calendar),
      geometry: MeshWXGeometry.shared, tables: .shared)
  }

  private func saved(_ label: String, lat: Double, lon: Double, watched: Bool = false) -> WeatherSavedPlace {
    WeatherSavedPlace(label: label, latitude: lat, longitude: lon, chosenAt: P.now, isWatched: watched)
  }

  // MARK: - One snapshot, one page

  /// The key travels inside the value: nothing downstream has to be told separately which place
  /// it is looking at, and a build that lands after a swipe cannot be read as the new page's.
  @Test
  func `a snapshot says which page it was built for, and carries that page's place`() {
    let austin = P.place(P.austin)
    let dallas = P.place(P.dallas, label: "Dallas, TX")
    let here = snapshot(place: austin, pageID: WeatherPage.myLocationID)
    let saved = snapshot(place: dallas, pageID: "at:32.777,-96.797")

    #expect(here.page.pageID == "here")
    #expect(here.page.place == austin)
    #expect(saved.page.pageID == "at:32.777,-96.797")
    #expect(saved.page.place == dallas)
    // Same held state, two pages: the snapshots differ by the place they answer for, and each
    // says which page that is.
    #expect(here.page != saved.page)
    #expect(here.place != saved.place)
  }

  /// Update plans one page's requests from that page's own build. Austin's forecast point is not
  /// Dallas's, and during a swipe the button must not send the one under the other's name.
  @Test
  func `the plan for one page is never the other page's`() {
    let state = P.state()
    func plan(_ place: WeatherPlace, pageID: String, county: String?) -> WeatherUpdatePlan {
      WeatherUpdatePlan.make(
        snapshot: snapshot(place: place, pageID: pageID, state: state), sourceState: state,
        placeCountyUGC: county, placeOffice: nil, coverageAlreadyAsked: true, tables: .shared, now: P.now)
    }
    let austin = plan(P.place(P.austin), pageID: "here", county: "TXC453")
    let dallas = plan(P.place(P.dallas, label: "Dallas, TX"), pageID: "at:32.777,-96.797", county: "TXC113")

    #expect(austin != dallas)
    // Austin holds a current forecast for its own point; Dallas holds none, so its plan asks for
    // one — and for Dallas's point, never Austin's.
    let austinForecast = austin.steps.first { $0.item == .forecast }?.request
    let dallasForecast = dallas.steps.first { $0.item == .forecast }?.request
    #expect(dallasForecast != nil)
    #expect(austinForecast != dallasForecast)
  }

  // MARK: - Text reports (§12, §14 Q5)

  private func text(
    _ subject: MeshWXTextSubject,
    group: UInt8,
    request: WeatherRequest?,
    body: String,
    minutesAgo: Double = 0
  ) -> WeatherTextItem {
    WeatherTextItem(
      botID: P.botID,
      assembly: WeatherTextAssembly(
        subject: subject, group: group, total: 1, chunks: [0: body],
        firstReceivedAt: P.now.addingTimeInterval(-minutesAgo * 60),
        lastReceivedAt: P.now.addingTimeInterval(-minutesAgo * 60),
        request: request))
  }

  /// The owner's bug, in one assertion: a discussion this phone asked Fort Worth for is not the
  /// discussion for a page whose office is Austin/San Antonio — however new it is.
  @Test
  func `a discussion answered for another office is not this page's`() {
    let fortWorth = text(.forecastDiscussion, group: 1, request: .forecastDiscussion(office: "FWD"), body: "FWD AFD")
    let austin = text(.forecastDiscussion, group: 2, request: .forecastDiscussion(office: "EWX"), body: "EWX AFD", minutesAgo: 90)

    let chosen = WeatherReportSelection.choose(
      texts: [fortWorth, austin], subject: .forecastDiscussion,
      request: .forecastDiscussion(office: "EWX"), isByArea: true)
    #expect(chosen?.item.assembly.request == .forecastDiscussion(office: "EWX"))
    #expect(chosen?.isOwn == true)

    // With nothing held for this office, the other office's reply is not borrowed: the screen
    // says nothing rather than something about somewhere else.
    #expect(WeatherReportSelection.choose(
      texts: [fortWorth], subject: .forecastDiscussion,
      request: .forecastDiscussion(office: "EWX"), isByArea: true) == nil)
  }

  /// A reply nobody here asked for carries only its subject, so it is shown as somebody else's
  /// and its area is not claimed — for a product asked for by area, it is not even known.
  @Test
  func `an overheard reply is shown as somebody else's, for an area this phone can't name`() {
    let overheard = text(.stormReports, group: 3, request: nil, body: "SPOTTER REPORTS")
    let chosen = WeatherReportSelection.choose(
      texts: [overheard], subject: .stormReports, request: .stormReports(state: "PR"), isByArea: true)
    #expect(chosen?.isOwn == false)
    #expect(chosen?.isUnknownArea == true)

    // `>hwo` and `>space` take no place: an overheard one is the same product this page would
    // have asked for, so there is no unknown area to admit to.
    let outlook = text(.hazardousOutlook, group: 4, request: nil, body: "HWO")
    let chosenOutlook = WeatherReportSelection.choose(
      texts: [outlook], subject: .hazardousOutlook, request: .hazardousOutlook, isByArea: false)
    #expect(chosenOutlook?.isOwn == false)
    #expect(chosenOutlook?.isUnknownArea == false)
  }

  /// The state override was one visit-wide value: picking Texas on one page sent `>storm TX` for
  /// every page. Per page, one page's answer cannot be shown on another's.
  @Test
  func `a state a page asked about does not answer another page's request`() {
    let texas = text(.stormReports, group: 5, request: .stormReports(state: "TX"), body: "TX STORM REPORTS")
    #expect(WeatherReportSelection.choose(
      texts: [texas], subject: .stormReports, request: .stormReports(state: "TX"), isByArea: true)?.isOwn == true)
    #expect(WeatherReportSelection.choose(
      texts: [texas], subject: .stormReports, request: .stormReports(state: "PR"), isByArea: true) == nil)
    // A page with no place to build a request from can still be shown what the channel carried,
    // and only ever as somebody else's.
    let overheard = text(.stormReports, group: 6, request: nil, body: "SOMEWHERE")
    #expect(WeatherReportSelection.choose(
      texts: [texas, overheard], subject: .stormReports, request: nil, isByArea: true)?.item.assembly.group == 6)
  }

  // MARK: - The pages under the pager (§5, §16)

  /// A bell adds no row, so it trims none. It used to run the list through the ceiling, which
  /// could take a page out from under the pager — including the page the tap came from.
  @Test
  func `turning on a bell keeps every page`() {
    let places = (0..<13).map { saved("Town \($0)", lat: 30 + Double($0) / 10, lon: -97) }
    let watched = WeatherSavedPlaces.setting(watched: true, id: places[3].id, in: places)
    #expect(watched.count == places.count)
    #expect(watched.map(\.id) == places.map(\.id))
    #expect(watched[3].isWatched)
    // And off again, with nothing else touched.
    let off = WeatherSavedPlaces.setting(watched: false, id: places[3].id, in: watched)
    #expect(off == places)
  }

  /// A watched place never falls off the end: the ceiling keeps the sheet a list of places, and
  /// dropping one the user asked to be warned about is not what it is for.
  @Test
  func `the ceiling never drops a watched place`() {
    var places = (0..<20).map { saved("Town \($0)", lat: 30 + Double($0) / 10, lon: -97) }
    places[19].isWatched = true
    let ordered = WeatherSavedPlaces.ordered(places)
    #expect(ordered.contains { $0.id == places[19].id })
    #expect(ordered.count == WeatherSavedPlaces.limit)
  }

  /// The selection is resolved and **written back**, so `selectedPageID` never names a page that
  /// is not there — which was a snapshot nothing could be built for, and a spinner that never
  /// ended on every page until the next swipe.
  @Test
  func `a selection naming a page that is gone resolves to the first one`() {
    let austin = saved("Austin, TX", lat: 30.27, lon: -97.74)
    let pages = WeatherPages.make(saved: [austin])
    #expect(WeatherPages.selection(austin.id, in: pages) == austin.id)
    #expect(WeatherPages.selection(austin.id, in: WeatherPages.make(saved: [])) == WeatherPage.myLocationID)
    #expect(WeatherPages.selection("at:0.000,0.000", in: pages) == WeatherPage.myLocationID)
  }

  /// The two pages a swipe can reach next, which are the ones built ahead so the swipe lands on a
  /// page rather than on a spinner.
  @Test
  func `a page's neighbours are the pages either side of it`() {
    let list = [saved("A", lat: 30, lon: -97), saved("B", lat: 31, lon: -97), saved("C", lat: 32, lon: -97)]
    let pages = WeatherPages.make(saved: list)
    #expect(WeatherPages.neighbours(of: WeatherPage.myLocationID, in: pages) == [list[0].id])
    #expect(WeatherPages.neighbours(of: list[0].id, in: pages) == [WeatherPage.myLocationID, list[1].id])
    #expect(WeatherPages.neighbours(of: list[2].id, in: pages) == [list[1].id])
    #expect(WeatherPages.neighbours(of: "at:0.000,0.000", in: pages).isEmpty)
  }

  /// A notification is raised for one watched place and says so. The tap opens that place's page
  /// first, so "Covers Austin" is not computed for Dallas.
  @Test
  func `a notification's watched place names the page it belongs to`() {
    let dallas = saved("Dallas, TX", lat: 32.7767, lon: -96.7970, watched: true)
    #expect(WeatherPages.pageID(forWatchedPlaceID: dallas.id) == dallas.id)
    #expect(WeatherPages.pageID(forWatchedPlaceID: WeatherWatchedPlace.myLocationID) == WeatherPage.myLocationID)

    let target = WeatherAlertNotificationTap.Target(
      identity: MeshWXWarningIdentity(event: 3, office: 35, etn: 42), botID: P.botID, placeID: dallas.id)
    let pages = WeatherPages.make(saved: [saved("Austin, TX", lat: 30.27, lon: -97.74), dallas])
    let pageID = WeatherPages.pageID(forWatchedPlaceID: target.placeID)
    #expect(WeatherPages.selection(pageID, in: pages) == dallas.id)
  }

  // MARK: - Update runs (§11.1)

  /// Per page, so one place's run does not spin another place's button; one at a time, so a pull
  /// and a tap cannot both be running and the loser's cleanup cannot put the winner's spinner out.
  @Test
  func `an update run belongs to the page that started it, and only one runs at a time`() {
    var runs = WeatherUpdateRuns()
    #expect(!runs.isRunning)

    let started = runs.begin(pageID: "here", requests: [.digest, .observations])
    #expect(started)
    #expect(runs.isRunning(pageID: "here"))
    #expect(!runs.isRunning(pageID: "dallas"))
    #expect(runs.requests(pageID: "here") == [.digest, .observations])
    #expect(runs.requests(pageID: "dallas").isEmpty)

    // A second run anywhere is refused rather than replacing the first.
    let otherPage = runs.begin(pageID: "dallas", requests: [.digest])
    let samePage = runs.begin(pageID: "here", requests: [.digest])
    #expect(!otherPage)
    #expect(!samePage)
    #expect(runs.isRunning(pageID: "here"))

    // A run that is not the one going ends nothing.
    runs.end(pageID: "dallas")
    #expect(runs.isRunning(pageID: "here"))
    runs.end(pageID: "here")
    #expect(!runs.isRunning)
    // What it asked for is kept, so the caption can still say how it went.
    #expect(runs.requests(pageID: "here") == [.digest, .observations])
    let next = runs.begin(pageID: "dallas", requests: [.digest])
    #expect(next)
  }

  /// An empty plan starts nothing: a page with no build has no plan, which is what keeps the
  /// button and the pull inert in the swipe window.
  @Test
  func `an empty plan starts no run`() {
    var runs = WeatherUpdateRuns()
    let started = runs.begin(pageID: "here", requests: WeatherUpdatePlan.empty.requests)
    #expect(!started)
    #expect(!runs.isRunning)
  }
}
