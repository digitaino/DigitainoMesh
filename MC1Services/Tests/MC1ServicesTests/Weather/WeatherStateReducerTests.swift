import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// Every rule in spec §2.3 (duplicates, gaps), §3–§5 (warnings, cancel, digest), §6–§7
/// (newest wins) and §8.1 (text reassembly), one test each.
@Suite("WeatherStateReducer")
struct WeatherStateReducerTests {
  private typealias F = WeatherFixture

  private func fresh() -> WeatherBotState { WeatherBotState(botID: F.botID) }

  // MARK: - Sequence

  @Test
  func `the first message is accepted without a gap`() {
    var state = fresh()
    let changes = WeatherStateReducer.apply(F.warning(seq: 17), to: &state, receivedAt: F.t0)
    #expect(changes == [.warningStored(F.svw42, replacedExisting: false)])
    #expect(state.lastSeq == 17)
    #expect(state.lastHeardAt == F.t0)
    #expect(!state.needsDigest)
  }

  @Test
  func `the same seq twice is a duplicate and changes nothing`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 17), to: &state, receivedAt: F.t0)
    let before = state
    let changes = WeatherStateReducer.apply(F.cancel(seq: 17), to: &state, receivedAt: F.t0.addingTimeInterval(1))
    #expect(changes == [.duplicate(seq: 17)])
    #expect(state == before)
  }

  @Test
  func `a skipped seq is a gap that asks for the digest, and wrapping 255 to 0 is not`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 255), to: &state, receivedAt: F.t0)
    var changes = WeatherStateReducer.apply(F.warning(seq: 0, identity: F.svw43), to: &state, receivedAt: F.t0)
    #expect(changes == [.warningStored(F.svw43, replacedExisting: false)])
    #expect(!state.needsDigest)

    changes = WeatherStateReducer.apply(F.warning(seq: 3, identity: F.wsw7), to: &state, receivedAt: F.t0)
    #expect(changes.first == .sequenceGap(expected: 1, received: 3))
    #expect(state.needsDigest)
    #expect(state.lastSeq == 3)
  }

  // MARK: - Warnings

  @Test
  func `a warning with a known identity replaces the stored one whatever the flag says`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 1, windMph: 60), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(
      F.warning(seq: 2, expiresMinutes: F.t0Minutes + 90, isUpdate: false, windMph: 70),
      to: &state,
      receivedAt: F.t0.addingTimeInterval(60)
    )
    #expect(changes == [.warningStored(F.svw42, replacedExisting: true)])
    #expect(state.warnings.count == 1)
    let stored = try! #require(state.warnings[F.svw42])
    #expect(stored.warning.windMph == 70)
    #expect(stored.warning.expiresMinutes == F.t0Minutes + 90)
    #expect(stored.updateCount == 1)
    #expect(stored.receivedAt == F.t0.addingTimeInterval(60))
  }

  @Test
  func `a cancel removes the identity and says why`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 1), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(F.cancel(seq: 2, reason: .upgraded), to: &state, receivedAt: F.t0)
    #expect(changes == [.warningRemoved(F.svw42, reason: .upgraded)])
    #expect(state.warnings.isEmpty)
  }

  @Test
  func `a cancel for an unknown identity is reported and harmless`() {
    var state = fresh()
    let changes = WeatherStateReducer.apply(F.cancel(seq: 1, identity: F.wsw7), to: &state, receivedAt: F.t0)
    #expect(changes == [.cancelForUnknown(F.wsw7)])
  }

  @Test
  func `expiry is judged by the phone's clock`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 1, expiresMinutes: F.t0Minutes + 45), to: &state, receivedAt: F.t0)
    let stored = try! #require(state.warnings[F.svw42])
    #expect(!stored.isExpired(at: F.t0.addingTimeInterval(44 * 60)))
    #expect(stored.isExpired(at: F.t0.addingTimeInterval(45 * 60)))
    #expect(state.activeWarnings(at: F.t0, severity: { _ in nil }).count == 1)
    #expect(state.activeWarnings(at: F.t0.addingTimeInterval(3600), severity: { _ in nil }).isEmpty)
  }

  @Test
  func `active warnings sort by severity then soonest expiry`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 1, identity: F.svw42, expiresMinutes: F.t0Minutes + 45), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.warning(seq: 2, identity: F.svw43, expiresMinutes: F.t0Minutes + 20), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.warning(seq: 3, identity: F.wsw7, expiresMinutes: F.t0Minutes + 5), to: &state, receivedAt: F.t0)
    // Pretend the winter storm (event 24) is a lower severity than the thunderstorms (event 3).
    let ordered = state.activeWarnings(at: F.t0) { event in event == 3 ? .warning : .advisory }
    #expect(ordered.map(\.identity) == [F.svw43, F.svw42, F.wsw7])
  }

  @Test
  func `pruning drops only warnings expired before the cutoff`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 1, identity: F.svw42, expiresMinutes: F.t0Minutes + 45), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.warning(seq: 2, identity: F.svw43, expiresMinutes: F.t0Minutes + 200), to: &state, receivedAt: F.t0)
    let pruned = WeatherStateReducer.pruneExpired(&state, expiredBefore: F.t0.addingTimeInterval(100 * 60))
    #expect(pruned == [F.svw42])
    #expect(state.warnings.keys.contains(F.svw43))
  }

  // MARK: - Digest

  @Test
  func `a digest removes what it omits, lists what the app lacks, and clears the gap flag`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 1, identity: F.svw42), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.warning(seq: 5, identity: F.wsw7), to: &state, receivedAt: F.t0)
    #expect(state.needsDigest)

    let changes = WeatherStateReducer.apply(
      F.digest(seq: 6, entries: [(F.svw42, 45), (F.svw43, 20)]),
      to: &state,
      receivedAt: F.t0
    )
    #expect(changes == [.digestApplied(missing: [F.svw43], removed: [F.wsw7])])
    #expect(Set(state.warnings.keys) == [F.svw42])
    #expect(state.missingFromDigest == [F.svw43])
    #expect(!state.needsDigest)
    #expect(state.digest?.digest.feedHealth == 7)
    #expect(state.digest?.receivedAt == F.t0)
  }

  @Test
  func `a digest refreshes a held warning's expiry from its absolute entry`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 1, expiresMinutes: F.t0Minutes + 45), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.digest(seq: 2, nowMinutes: F.t0Minutes + 10, entries: [(F.svw42, 50)]), to: &state, receivedAt: F.t0)
    #expect(state.warnings[F.svw42]?.warning.expiresMinutes == F.t0Minutes + 60)
  }

  @Test
  func `a warning that arrives after the digest clears its missing entry`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.digest(seq: 1, entries: [(F.svw43, 20)]), to: &state, receivedAt: F.t0)
    #expect(state.missingFromDigest == [F.svw43])
    _ = WeatherStateReducer.apply(F.warning(seq: 2, identity: F.svw43), to: &state, receivedAt: F.t0)
    #expect(state.missingFromDigest.isEmpty)
  }

  @Test
  func `feed staleness follows the four-hour threshold`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.digest(seq: 1, feedHealth: 60, entries: []), to: &state, receivedAt: F.t0)
    #expect(state.digest?.isFeedStale == false)
    _ = WeatherStateReducer.apply(F.digest(seq: 2, feedHealth: 61, entries: []), to: &state, receivedAt: F.t0)
    #expect(state.digest?.isFeedStale == true)
  }

  // MARK: - Observations and forecasts

  @Test
  func `observations merge per station and an older batch never rolls one back`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(
      F.observations(seq: 1, timestampMinutes: F.t0Minutes, stations: [(202, 88), (860, 84)]),
      to: &state, receivedAt: F.t0
    )
    // A single-station answer for KAUS from a newer batch.
    var changes = WeatherStateReducer.apply(
      F.observations(seq: 2, timestampMinutes: F.t0Minutes + 30, stations: [(202, 90)]),
      to: &state, receivedAt: F.t0
    )
    #expect(changes == [.observationsStored(stations: [202])])
    #expect(state.observations[202]?.observation.tempF == 90)
    #expect(state.observations[860]?.observation.tempF == 84)

    // A cached re-send of the first batch, older than what is held for 202.
    changes = WeatherStateReducer.apply(
      F.observations(seq: 3, timestampMinutes: F.t0Minutes, stations: [(202, 88), (976, 70)]),
      to: &state, receivedAt: F.t0
    )
    #expect(changes == [.observationsStored(stations: [976])])
    #expect(state.observations[202]?.observation.tempF == 90)
    #expect(state.latestObservationMinutes == F.t0Minutes + 30)
  }

  @Test
  func `observation staleness is two hours from the batch time`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.observations(seq: 1, timestampMinutes: F.t0Minutes, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    let held = try! #require(state.observations[202])
    #expect(!held.isStale(at: F.t0.addingTimeInterval(119 * 60)))
    #expect(held.isStale(at: F.t0.addingTimeInterval(121 * 60)))
  }

  @Test
  func `forecasts are keyed by point and an older issue is ignored`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.forecast(seq: 1, point: 102, issuedMinutes: F.t0Minutes), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.forecast(seq: 2, point: 0xFFFF, issuedMinutes: F.t0Minutes), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(F.forecast(seq: 3, point: 102, issuedMinutes: F.t0Minutes - 60), to: &state, receivedAt: F.t0)
    #expect(changes == [.forecastIgnoredOlder(point: 102)])
    #expect(state.forecasts[102]?.forecast.issuedMinutes == F.t0Minutes)
    #expect(state.forecasts[0xFFFF]?.forecast.isUnbundledPoint == true)
    #expect(state.forecasts.count == 2)
  }

  // MARK: - Text

  @Test
  func `text chunks assemble by group in index order and report the missing part`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.text(seq: 23, group: 23, index: 0, total: 3, text: "SEVERE "), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(F.text(seq: 25, group: 23, index: 2, total: 3, text: "indicated."), to: &state, receivedAt: F.t0)
    #expect(changes.contains(.textChunkStored(group: 23, index: 2, isComplete: false)))
    let assembly = try! #require(state.texts[23])
    #expect(assembly.missingIndexes == [1])
    #expect(assembly.orderedChunks == ["SEVERE ", nil, "indicated."])
    #expect(!assembly.isComplete)

    // The re-sent reply carries the original group byte and fills the hole.
    _ = WeatherStateReducer.apply(F.text(seq: 30, group: 23, index: 1, total: 3, text: "THUNDERSTORM "), to: &state, receivedAt: F.t0)
    let complete = try! #require(state.texts[23])
    #expect(complete.isComplete)
    #expect(complete.orderedChunks.compactMap { $0 }.joined() == "SEVERE THUNDERSTORM indicated.")
  }

  @Test
  func `a new subject under a reused group byte starts a fresh assembly`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.text(seq: 1, subject: .warningNarrative, group: 9, index: 0, total: 2, text: "old"), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.text(seq: 2, subject: .forecastDiscussion, group: 9, index: 0, total: 1, text: "new"), to: &state, receivedAt: F.t0)
    let assembly = try! #require(state.texts[9])
    #expect(assembly.subject == .forecastDiscussion)
    #expect(assembly.isComplete)
    #expect(assembly.orderedChunks == ["new"])
  }

  // MARK: - Other types

  @Test
  func `not-available and unknown types touch nothing but the sequence`() {
    var state = fresh()
    var changes = WeatherStateReducer.apply(F.notAvailable(seq: 1, letter: "f", reason: .unknownLocation), to: &state, receivedAt: F.t0)
    #expect(changes == [.notAvailable(MeshWXNotAvailable(requestCode: 102, reason: .unknownLocation))])

    let unknown = MeshWXMessage(header: MeshWXHeader(seq: 2, bot: F.botID, rawType: 12, flags: 0), payload: .unknown)
    changes = WeatherStateReducer.apply(unknown, to: &state, receivedAt: F.t0)
    #expect(changes == [.unknownType(rawType: 12)])
    #expect(state.lastSeq == 2)
    #expect(state.warnings.isEmpty)
  }

  // MARK: - Persistence shape

  @Test
  func `state round-trips through the file store`() async throws {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 1), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.digest(seq: 2, entries: [(F.svw42, 45), (F.svw43, 20)]), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.observations(seq: 3, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.forecast(seq: 4), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.text(seq: 5, group: 5, index: 0, total: 1, text: "Ünïcode ✓"), to: &state, receivedAt: F.t0)

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("weather-\(UUID().uuidString)/state.json")
    let store = FileWeatherStateStore(url: url)
    try await store.save([F.botID: state])
    let loaded = try await store.load()
    #expect(loaded == [F.botID: state])
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  @Test
  func `a missing or unreadable file loads as empty`() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("weather-\(UUID().uuidString)/state.json")
    let store = FileWeatherStateStore(url: url)
    #expect(try await store.load().isEmpty)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: url)
    #expect(try await store.load().isEmpty)
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }
}
