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
    // An hour before the list was built, so the list speaks for both.
    let earlier = F.t0.addingTimeInterval(-3600)
    _ = WeatherStateReducer.apply(F.warning(seq: 1, identity: F.svw42), to: &state, receivedAt: earlier)
    _ = WeatherStateReducer.apply(F.warning(seq: 5, identity: F.wsw7), to: &state, receivedAt: earlier)
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

/// Ordering on a shared, lossy channel: late copies, cached re-sends, lists drained from the
/// radio's queue hours late, and upgrades whose replacement never arrives. Every case here is a
/// way the phone could otherwise report calm while something is active.
@Suite("WeatherStateReducer ordering")
struct WeatherStateReducerOrderingTests {
  private typealias F = WeatherFixture

  private func minutes(_ value: Double) -> TimeInterval { value * 60 }

  private func warning(
    seq: UInt8, identity: MeshWXWarningIdentity, areas: [MeshWXAreaRun], polygon: [MeshWXCoordinate]? = nil
  ) -> MeshWXMessage {
    MeshWXMessage(
      header: F.header(seq: seq, type: .warning),
      payload: .warning(MeshWXWarning(
        identity: identity, expiresMinutes: F.t0Minutes + 120, polygon: polygon, areas: areas)))
  }

  @Test
  func `a cached empty list re-sent after a new warning does not remove it`() {
    var state = WeatherBotState(botID: F.botID)
    // 23:00 list, empty. 23:02 tornado warning. 23:04 the bot's cache re-sends the 23:00 list.
    _ = WeatherStateReducer.apply(F.digest(seq: 1, nowMinutes: F.t0Minutes, entries: []), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.warning(seq: 2, identity: F.svw43), to: &state, receivedAt: F.t0.addingTimeInterval(minutes(2)))
    let changes = WeatherStateReducer.apply(
      F.digest(seq: 3, nowMinutes: F.t0Minutes, entries: []), to: &state, receivedAt: F.t0.addingTimeInterval(minutes(4)))
    #expect(changes == [.digestApplied(missing: [], removed: [])])
    #expect(state.warnings[F.svw43] != nil)
  }

  @Test
  func `a list built before the one held changes nothing`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.warning(seq: 1, identity: F.svw42), to: &state, receivedAt: F.t0.addingTimeInterval(-minutes(60)))
    _ = WeatherStateReducer.apply(F.digest(seq: 2, nowMinutes: F.t0Minutes, entries: [(F.svw42, 45)]), to: &state, receivedAt: F.t0)
    // An eight-hour-old list drained late from the radio's queue.
    let changes = WeatherStateReducer.apply(
      F.digest(seq: 3, nowMinutes: F.t0Minutes - 480, entries: []), to: &state, receivedAt: F.t0.addingTimeInterval(60))
    #expect(changes == [.digestIgnoredOlder(builtMinutes: F.t0Minutes - 480)])
    #expect(state.warnings[F.svw42] != nil)
    #expect(state.digest?.digest.nowMinutes == F.t0Minutes)
  }

  @Test
  func `a list may extend but not shorten a warning that arrived after it was built`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.warning(seq: 1, expiresMinutes: F.t0Minutes + 90), to: &state, receivedAt: F.t0)
    // Built three minutes before that warning arrived, with an earlier expiry.
    _ = WeatherStateReducer.apply(
      F.digest(seq: 2, nowMinutes: F.t0Minutes - 3, entries: [(F.svw42, 30)]), to: &state, receivedAt: F.t0.addingTimeInterval(60))
    #expect(state.warnings[F.svw42]?.warning.expiresMinutes == F.t0Minutes + 90)
  }

  @Test
  func `a gap seen after the list was built survives a cached re-send of it`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.digest(seq: 1, nowMinutes: F.t0Minutes, entries: []), to: &state, receivedAt: F.t0)
    // seq 2 is lost; seq 3 reveals the gap three minutes later.
    _ = WeatherStateReducer.apply(F.observations(seq: 3, stations: [(202, 88)]), to: &state, receivedAt: F.t0.addingTimeInterval(minutes(3)))
    #expect(state.needsDigest)
    _ = WeatherStateReducer.apply(F.digest(seq: 4, nowMinutes: F.t0Minutes, entries: []), to: &state, receivedAt: F.t0.addingTimeInterval(minutes(4)))
    #expect(state.needsDigest, "the re-sent list was built before the gap and cannot vouch for it")
    // A list built well after the gap clears it.
    _ = WeatherStateReducer.apply(F.digest(seq: 5, nowMinutes: F.t0Minutes + 180, entries: []), to: &state, receivedAt: F.t0.addingTimeInterval(minutes(180)))
    #expect(!state.needsDigest)
  }

  @Test
  func `an upgrade leaves a marker until an overlapping replacement arrives`() {
    var state = WeatherBotState(botID: F.botID)
    let travis = [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1)]
    _ = WeatherStateReducer.apply(warning(seq: 1, identity: F.svw42, areas: travis), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.cancel(seq: 2, identity: F.svw42, reason: .upgraded), to: &state, receivedAt: F.t0)
    #expect(state.warnings.isEmpty)
    #expect(state.pendingUpgrades[F.svw42] != nil)

    let tornado = MeshWXWarningIdentity(event: 1, office: 35, etn: 9)
    _ = WeatherStateReducer.apply(warning(seq: 3, identity: tornado, areas: travis), to: &state, receivedAt: F.t0)
    #expect(state.pendingUpgrades.isEmpty)
  }

  @Test
  func `a warning elsewhere from the same office does not clear an upgrade marker`() {
    var state = WeatherBotState(botID: F.botID)
    let travis = [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1)]
    let llano = [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 299, run: 1)]
    _ = WeatherStateReducer.apply(warning(seq: 1, identity: F.svw42, areas: travis), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.cancel(seq: 2, identity: F.svw42, reason: .upgraded), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(warning(seq: 3, identity: F.svw43, areas: llano), to: &state, receivedAt: F.t0)
    #expect(state.pendingUpgrades[F.svw42] != nil)
  }

  @Test
  func `a cancel that is not an upgrade leaves no marker`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.warning(seq: 1), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.cancel(seq: 2, reason: .cancelled), to: &state, receivedAt: F.t0)
    #expect(state.pendingUpgrades.isEmpty)
  }

  @Test
  func `a late copy of a recent seq is a duplicate, not a gap`() {
    var state = WeatherBotState(botID: F.botID)
    for seq: UInt8 in 5...7 {
      _ = WeatherStateReducer.apply(F.observations(seq: seq, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    }
    let changes = WeatherStateReducer.apply(F.cancel(seq: 6), to: &state, receivedAt: F.t0)
    #expect(changes == [.duplicate(seq: 6)])
    #expect(state.lastSeq == 7)
    #expect(!state.needsDigest)
  }

  @Test
  func `a message far behind is out of order, its warning is not applied, and it asks for a list`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.observations(seq: 100, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(F.warning(seq: 50), to: &state, receivedAt: F.t0)
    #expect(changes == [.outOfOrder(seq: 50)])
    #expect(state.warnings.isEmpty)
    #expect(state.needsDigest)
    #expect(state.lastSeq == 100)
  }

  @Test
  func `after six hours of silence a repeated seq is new, and the silence is a gap`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.observations(seq: 10, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(
      F.observations(seq: 10, timestampMinutes: F.t0Minutes + 420, stations: [(202, 80)]),
      to: &state, receivedAt: F.t0.addingTimeInterval(minutes(420)))
    #expect(changes.first == .sequenceGap(expected: 11, received: 10))
    #expect(state.observations[202]?.observation.tempF == 80)
    #expect(state.needsDigest)
  }

  @Test
  func `a list's age is its build time, not its arrival`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.digest(seq: 1, nowMinutes: F.t0Minutes - 480, entries: []), to: &state, receivedAt: F.t0)
    #expect(state.digest?.builtAt == Date(unixMinutes: F.t0Minutes - 480))
    #expect(state.digest?.receivedAt == F.t0)
  }

  @Test
  func `observations remember how many stations their batch carried`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.observations(seq: 1, stations: [(202, 88), (860, 84)]), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.observations(seq: 2, timestampMinutes: F.t0Minutes + 5, stations: [(976, 80)]), to: &state, receivedAt: F.t0)
    #expect(state.observations[202]?.batchSize == 2)
    #expect(state.observations[976]?.batchSize == 1)
  }

  @Test
  func `a state file written before the new fields still loads`() async throws {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.warning(seq: 1), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.observations(seq: 2, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.forecast(seq: 3), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.text(seq: 4, group: 4, index: 0, total: 1, text: "x"), to: &state, receivedAt: F.t0)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
    for key in ["recentSeqs", "gapDetectedAt", "pendingUpgrades"] { json.removeValue(forKey: key) }
    func strip(_ collection: String, _ field: String) {
      guard var pairs = json[collection] as? [Any] else { return }
      for index in stride(from: 1, to: pairs.count, by: 2) {
        if var record = pairs[index] as? [String: Any] {
          record.removeValue(forKey: field)
          pairs[index] = record
        }
      }
      json[collection] = pairs
    }
    strip("observations", "batchSize")
    strip("forecasts", "requestedHere")
    strip("texts", "request")

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let legacy = try decoder.decode(WeatherBotState.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(legacy.warnings.count == 1)
    #expect(legacy.recentSeqs.isEmpty)
    #expect(legacy.observations[202]?.batchSize == 1)
    #expect(legacy.forecasts[102]?.requestedHere == false)
    #expect(legacy.texts[4]?.request == nil)
  }
}
