import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// What the channel carried, and what the phone kept of it (docs/MESHWX_UI.md §12).
///
/// Both lists are read from the held state alone, which records no requester: a scheduled
/// broadcast and an answer to somebody's question are the same thing on a broadcast channel, and
/// nothing here tells them apart or claims to.
@Suite("Weather channel history")
struct WeatherChannelHistoryTests {
  private typealias F = WeatherFixture

  /// One of each kind, oldest first, all inside the day the page looks back over.
  private func state() -> WeatherBotState {
    var state = WeatherBotState(botID: F.botID)
    func apply(_ message: MeshWXMessage, secondsAgo: TimeInterval) {
      _ = WeatherStateReducer.apply(message, to: &state, receivedAt: F.t0.addingTimeInterval(-secondsAgo))
    }
    apply(F.digest(seq: 1, entries: [(F.svw42, 45)]), secondsAgo: 600)
    apply(F.warning(seq: 2), secondsAgo: 500)
    apply(F.observations(seq: 3, stations: [(202, 88), (860, 84)]), secondsAgo: 400)
    apply(F.forecast(seq: 4, point: 102), secondsAgo: 300)
    apply(F.text(seq: 5, subject: .metarOrTAF, group: 7, index: 0, total: 1, text: "METAR KAUS"), secondsAgo: 200)
    apply(F.coverage(seq: 6), secondsAgo: 100)
    return state
  }

  // MARK: - Heard

  /// Fourteen readings arrived as one message; fourteen rows would bury everything else the
  /// channel carried, so a batch is one row that says how many stations it held.
  @Test
  func `the channel's traffic is listed newest first, a batch as one row`() {
    let heard = WeatherHeard.make(states: [F.botID: state()], now: F.t0)
    #expect(heard.count == 6)
    #expect(heard.map(\.subject) == [
      .coverage,
      .text(subject: .metarOrTAF, request: nil),
      .forecast(point: 102, label: nil),
      .readings(stations: 2),
      .warning(F.svw42),
      .alertList(entries: 1)
    ])
    #expect(heard.map(\.receivedAt) == heard.map(\.receivedAt).sorted(by: >))
  }

  /// Since revision 5 each reading carries when *that station* reported, so one hourly batch
  /// holds as many times as it has stations. The row is still one row: it is keyed by the batch's
  /// own time, not by the stations'.
  @Test
  func `a batch whose stations reported at different times is still one row`() throws {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(
      F.observations(seq: 3, stations: [(202, 88), (860, 84), (194, 86)], ages: [0, 17, 41]),
      to: &state, receivedAt: F.t0.addingTimeInterval(-400))
    #expect(Set(state.observations.values.map(\.timestampMinutes)).count == 3)

    let heard = WeatherHeard.make(states: [F.botID: state], now: F.t0)
    #expect(heard.map(\.subject) == [.readings(stations: 3)])
    #expect(heard[0].contentAt == Date(unixMinutes: F.t0Minutes))
  }

  /// Every number names its own time and its age: the content's time on the bot's clock where
  /// the message carries one, and receipt where it does not.
  @Test
  func `content times come from the message, and only where it carries one`() throws {
    let heard = WeatherHeard.make(states: [F.botID: state()], now: F.t0)
    let list = try #require(heard.first { $0.subject == .alertList(entries: 1) })
    #expect(list.contentAt == Date(unixMinutes: F.t0Minutes))
    #expect(list.receivedAt == F.t0.addingTimeInterval(-600))
    // A warning, a text reply and a statement carry no time of their own (spec §3, §7A, §8.1).
    #expect(heard.first { $0.subject == .warning(F.svw42) }?.contentAt == nil)
    #expect(heard.first { $0.subject == .coverage }?.contentAt == nil)
  }

  @Test
  func `nothing older than a day is listed`() {
    let heard = WeatherHeard.make(states: [F.botID: state()], now: F.t0.addingTimeInterval(25 * 3600))
    #expect(heard.isEmpty)
  }

  @Test
  func `the list is a page, not a history`() {
    var state = WeatherBotState(botID: F.botID)
    for point in 0..<40 {
      state.forecasts[UInt16(point)] = WeatherStoredForecast(
        forecast: MeshWXForecast(pointIndex: UInt16(point), issuedMinutes: F.t0Minutes, firstPeriod: 0, periods: []),
        receivedAt: F.t0.addingTimeInterval(-Double(point)))
    }
    #expect(WeatherHeard.make(states: [F.botID: state], now: F.t0).count == WeatherHeard.limit)
  }

  // MARK: - Cache

  private func cache(_ state: WeatherBotState, place: WeatherPlace? = nil) -> WeatherCache {
    let states = [F.botID: state]
    let readings = WeatherStations.readings(
      states: states,
      coverage: WeatherCoverage.make(states: states, tables: .shared, now: F.t0),
      place: place, tables: .shared, now: F.t0)
    let alerts = WeatherAlertItems.make(
      states: states, place: place, geometry: MeshWXGeometry.shared, tables: .shared, now: F.t0)
    return WeatherCache.make(states: states, readings: readings, alerts: alerts, tables: .shared)
  }

  @Test
  func `the cache groups what the phone is holding and counts it`() {
    let cache = cache(state())
    #expect(cache.groups.map(\.group) == [.readings, .forecasts, .airportReports, .warningsElsewhere])
    #expect(cache.total == cache.groups.reduce(0) { $0 + $1.count })
    #expect(cache.groups.first { $0.group == .forecasts }?.count == 1)
    #expect(cache.groups.first { $0.group == .airportReports }?.count == 1)
    #expect(cache.groups.first { $0.group == .warningsElsewhere }?.count == 1)
  }

  /// The Weather Service products have a screen of their own; this page accounts for what would
  /// otherwise go unaccounted for.
  @Test
  func `a product reply is not cache, it is the reports screen`() {
    var state = state()
    state.texts[9] = WeatherTextAssembly(
      subject: .forecastDiscussion, group: 9, total: 1, chunks: [0: "AFD"],
      firstReceivedAt: F.t0, lastReceivedAt: F.t0)
    #expect(cache(state).groups.first { $0.group == .airportReports }?.count == 1)
    #expect(!cache(state).groups.contains { $0.count > 1 && $0.group == .airportReports })
  }

  /// A reply nobody here asked for names only its subject, so it gets no destination rather than
  /// a guessed one — a station screen reached from somebody else's METAR would be a claim.
  @Test
  func `a row opens the screen that shows it, and guesses none where it cannot know`() throws {
    let overheard = try #require(cache(state()).groups.first { $0.group == .airportReports }?.items.first)
    #expect(overheard.destination == nil)

    var state = state()
    state.texts[7]?.request = .metar(station: "KAUS")
    let index = try #require(MeshWXTables.shared.stationIndex(forICAO: "KAUS"))
    let owned = try #require(cache(state).groups.first { $0.group == .airportReports }?.items.first)
    #expect(owned.destination == .station(index))

    // A forecast has no screen of its own: a point becomes a place in Places, not here.
    #expect(cache(state).groups.first { $0.group == .forecasts }?.items.first?.destination == nil)
  }

  @Test
  func `a warning elsewhere opens its own alert`() throws {
    let item = try #require(cache(state()).groups.first { $0.group == .warningsElsewhere }?.items.first)
    #expect(item.destination == .alert(F.svw42))
    #expect(item.subject == .warning(F.svw42))
  }

  @Test
  func `nothing held is an empty cache`() {
    #expect(cache(WeatherBotState(botID: F.botID)).total == 0)
  }
}
