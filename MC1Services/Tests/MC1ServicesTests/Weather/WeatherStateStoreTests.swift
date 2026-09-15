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
}

@Suite("Weather digest margin")
struct WeatherDigestMarginTests {
  private typealias F = WeatherFixture

  /// The bot answers an identical request from its five-minute cache (spec §8.2), so the `>d` a
  /// phone sends after a gap can come back as a list built *before* the gap. The ten-minute
  /// margin is what stops that list clearing the gap. The cost is deliberate: a genuinely fresh
  /// list built within ten minutes of the gap does not clear it either, and the card keeps saying
  /// messages were missed until a later list does.
  @Test
  func `a list built within ten minutes of a gap leaves the gap open`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.warning(seq: 1), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.observations(seq: 3, stations: [(202, 88)]), to: &state, receivedAt: F.t0.addingTimeInterval(60))
    #expect(state.needsDigest)

    // `>d` answered five minutes later with a list built four minutes after t0.
    _ = WeatherStateReducer.apply(
      F.digest(seq: 4, nowMinutes: F.t0Minutes + 4, entries: [(F.svw42, 45)]), to: &state, receivedAt: F.t0.addingTimeInterval(300))
    #expect(state.needsDigest)
    #expect(state.digest?.digest.nowMinutes == F.t0Minutes + 4)

    // Built eleven minutes after the gap: it cannot be a cached list from before it.
    _ = WeatherStateReducer.apply(
      F.digest(seq: 5, nowMinutes: F.t0Minutes + 12, entries: [(F.svw42, 45)]), to: &state, receivedAt: F.t0.addingTimeInterval(750))
    #expect(!state.needsDigest)
  }
}
