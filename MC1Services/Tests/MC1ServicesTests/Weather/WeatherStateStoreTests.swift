import Foundation
@testable import MC1Services
import MeshWX
import Testing

@Suite("Weather state store")
struct WeatherStateStoreTests {
  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("weather-\(UUID().uuidString)/state.json")
  }

  @Test
  func `every caller of a file gets the one store`() {
    let url = temporaryURL()
    #expect(FileWeatherStateStore.shared(url: url) === FileWeatherStateStore.shared(url: url))
    #expect(FileWeatherStateStore.default() === FileWeatherStateStore.default())
    #expect(FileWeatherStateStore(url: url) !== FileWeatherStateStore.shared(url: url))
  }

  /// Forty writers each adding one bot: with load-then-save from separate callers some would be
  /// lost; `modify` keeps every one.
  @Test
  func `concurrent edits through modify are all kept`() async throws {
    let url = temporaryURL()
    let store = FileWeatherStateStore.shared(url: url)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for id in 1...40 {
        group.addTask {
          try await FileWeatherStateStore.shared(url: url).modify { states in
            states[UInt16(id)] = WeatherBotState(botID: UInt16(id))
          }
        }
      }
      try await group.waitForAll()
    }
    #expect(try await store.load().count == 40)
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  @Test
  func `live hearing round-trips, and a file from before it decodes with it absent`() throws {
    var state = WeatherBotState(botID: 7)
    state.lastHeardAt = Date(timeIntervalSince1970: 1_000_000)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970

    let old = try encoder.encode(state)
    let object = try #require(try JSONSerialization.jsonObject(with: old) as? [String: Any])
    #expect(object["lastLiveHeardAt"] == nil)
    #expect(try decoder.decode(WeatherBotState.self, from: old).lastLiveHeardAt == nil)

    state.lastLiveHeardAt = Date(timeIntervalSince1970: 999_000)
    #expect(try decoder.decode(WeatherBotState.self, from: encoder.encode(state)) == state)
  }

  /// Spec §3, revision 5. A file written before the app could read the issue time — or one
  /// holding a warning from a bot that does not send it — is still the last picture the bot sent:
  /// the field decodes as absent, and the warning shows its arrival as it always did.
  @Test
  func `a warning's issue time round-trips, and a file from before it decodes with it absent`() throws {
    var state = WeatherBotState(botID: 7)
    let issued = Date(timeIntervalSince1970: 1_789_436_700)
    guard case let .warning(warning) = WeatherFixture.warning(seq: 1).payload else {
      Issue.record("expected a warning")
      return
    }
    state.warnings[warning.identity] = WeatherStoredWarning(
      warning: warning, receivedAt: Date(timeIntervalSince1970: 1_789_440_000), seq: 1)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970

    let old = try encoder.encode(state)
    #expect(!String(decoding: old, as: UTF8.self).contains("issuedAt"))
    let fromOldFile = try decoder.decode(WeatherBotState.self, from: old)
    #expect(fromOldFile.warnings[warning.identity]?.issuedAt == nil)
    #expect(fromOldFile == state)

    state.warnings[warning.identity]?.issuedAt = issued
    let decoded = try decoder.decode(WeatherBotState.self, from: encoder.encode(state))
    #expect(decoded == state)
    #expect(decoded.warnings[warning.identity]?.issuedAt == issued)
  }

  /// Spec §7A. A file written before the bot could state its coverage is still the last picture
  /// it sent: the field decodes as absent, which falls back to the station footprint.
  @Test
  func `a coverage statement round-trips, and a file from before it decodes with it absent`() throws {
    var state = WeatherBotState(botID: 7)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970

    let old = try encoder.encode(state)
    let object = try #require(try JSONSerialization.jsonObject(with: old) as? [String: Any])
    #expect(object["coverage"] == nil)
    #expect(try decoder.decode(WeatherBotState.self, from: old).coverage == nil)

    state.coverage = WeatherStoredCoverage(
      coverage: WeatherFixture.austinCoverage, receivedAt: Date(timeIntervalSince1970: 1_789_000_000))
    let decoded = try decoder.decode(WeatherBotState.self, from: encoder.encode(state))
    #expect(decoded == state)
    #expect(decoded.coverage?.coverage.radiusKilometres == 120)
    #expect(decoded.coverage?.coverage.covers(ugc: "TXZ192", states: MeshWXTables.shared.states) == true)
  }
}

@Suite("Weather digest margin")
struct WeatherDigestMarginTests {
  private typealias F = WeatherFixture

  /// The bot keeps no answer cache (spec §8.2, revision 2): a list is built when it is sent, so the
  /// margin only absorbs the phone's and the bot's clocks disagreeing and the minute `now` is
  /// truncated to. A list built within two minutes of the gap could still, on those clocks, be
  /// from before it; the card keeps saying messages were missed until a later list clears it.
  @Test
  func `a list built within two minutes of a gap leaves the gap open`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.warning(seq: 1), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.observations(seq: 3, stations: [(202, 88)]), to: &state, receivedAt: F.t0.addingTimeInterval(60))
    #expect(state.needsDigest)

    // `>d` answered at once, with a list built in the gap's own minute.
    _ = WeatherStateReducer.apply(
      F.digest(seq: 4, nowMinutes: F.t0Minutes + 1, entries: [(F.svw42, 45)]), to: &state, receivedAt: F.t0.addingTimeInterval(70))
    #expect(state.needsDigest)
    #expect(state.digest?.digest.nowMinutes == F.t0Minutes + 1)

    // Built four minutes after t0, three after the gap: it was built after it.
    _ = WeatherStateReducer.apply(
      F.digest(seq: 5, nowMinutes: F.t0Minutes + 4, entries: [(F.svw42, 45)]), to: &state, receivedAt: F.t0.addingTimeInterval(240))
    #expect(!state.needsDigest)
  }
}
