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
  func `the same message twice is a duplicate and changes nothing`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 17), to: &state, receivedAt: F.t0)
    let before = state
    // The bot's resend of an unechoed packet, 9 s later.
    let changes = WeatherStateReducer.apply(F.warning(seq: 17), to: &state, receivedAt: F.t0.addingTimeInterval(9))
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

  /// Spec §3 and §10.5: a warning says when NWS issued it, and that is not when the packet
  /// arrived. A replacement carries its own; one that carries none — an older bot — leaves the
  /// known time alone, since an identity's issuance never moves.
  @Test
  func `a warning's issue time is stored, replaced, and never erased by a message without one`() {
    var state = fresh()
    // Heard 21 minutes after NWS issued it, which is the line the phone must show.
    _ = WeatherStateReducer.apply(
      F.warning(seq: 1, issuedMinutes: F.t0Minutes - 21), to: &state,
      receivedAt: F.t0.addingTimeInterval(180 * 60)
    )
    var stored = try! #require(state.warnings[F.svw42])
    #expect(stored.issuedAt == Date(unixMinutes: F.t0Minutes - 21))
    #expect(stored.issuedAt != stored.receivedAt, "three hours out of range does not restamp it")
    #expect(stored.warning.isIssueTimeSaturated == false)

    // A re-issued product under the same identity brings its own time.
    _ = WeatherStateReducer.apply(
      F.warning(seq: 2, isUpdate: true, issuedMinutes: F.t0Minutes - 5), to: &state,
      receivedAt: F.t0.addingTimeInterval(181 * 60)
    )
    stored = try! #require(state.warnings[F.svw42])
    #expect(stored.issuedAt == Date(unixMinutes: F.t0Minutes - 5))

    // The revision 4 form of the same warning: no issue time on the wire, and the one already
    // known stands rather than being wiped.
    _ = WeatherStateReducer.apply(
      F.warning(seq: 3, isUpdate: true), to: &state, receivedAt: F.t0.addingTimeInterval(182 * 60)
    )
    stored = try! #require(state.warnings[F.svw42])
    #expect(stored.issuedAt == Date(unixMinutes: F.t0Minutes - 5))
    #expect(stored.warning.issuedMinutes == nil, "the message itself carried none")
  }

  /// The wire states the issue time as minutes *before the expiry*, and a digest may extend that
  /// expiry — so the stored instant is resolved once, on arrival, and does not walk forward with
  /// it.
  @Test
  func `a digest extending the expiry leaves the issue time where it was`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(
      F.warning(seq: 1, expiresMinutes: F.t0Minutes + 45, issuedMinutes: F.t0Minutes - 21),
      to: &state, receivedAt: F.t0
    )
    _ = WeatherStateReducer.apply(
      F.digest(seq: 2, nowMinutes: F.t0Minutes, entries: [(F.svw42, 120)]), to: &state,
      receivedAt: F.t0
    )
    let stored = try! #require(state.warnings[F.svw42])
    #expect(stored.warning.expiresMinutes == F.t0Minutes + 120, "the digest extended it")
    #expect(stored.issuedAt == Date(unixMinutes: F.t0Minutes - 21))
    // Recomputed from the wire's relative field it would now be 75 minutes late, which is exactly
    // why the resolved instant is the one kept.
    #expect(stored.warning.issuedMinutes == F.t0Minutes + 54)
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
  func `feed staleness follows the four-hour threshold, and 255 is never received`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.digest(seq: 1, feedHealth: 60, entries: []), to: &state, receivedAt: F.t0)
    #expect(state.digest?.isFeedStale == false)
    #expect(state.digest?.feed == .recent(minutes: 240))
    _ = WeatherStateReducer.apply(F.digest(seq: 2, feedHealth: 61, entries: []), to: &state, receivedAt: F.t0)
    #expect(state.digest?.isFeedStale == true)
    #expect(state.digest?.feed == .quiet(minutes: 244))
    _ = WeatherStateReducer.apply(F.digest(seq: 3, feedHealth: 255, entries: []), to: &state, receivedAt: F.t0)
    #expect(state.digest?.isFeedStale == true)
    #expect(state.digest?.feed == .neverReceived)
  }

  @Test
  func `a list removes an omitted warning received over two minutes before it was built, not one received since`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 1, identity: F.svw42), to: &state, receivedAt: F.t0.addingTimeInterval(-3 * 60))
    _ = WeatherStateReducer.apply(F.warning(seq: 2, identity: F.svw43), to: &state, receivedAt: F.t0.addingTimeInterval(-60))
    let changes = WeatherStateReducer.apply(F.digest(seq: 3, entries: []), to: &state, receivedAt: F.t0)
    #expect(changes == [.digestApplied(missing: [], removed: [F.svw42])])
    #expect(Set(state.warnings.keys) == [F.svw43])
  }

  @Test
  func `a full list says nothing about a warning expiring after its last entry`() {
    let earlier = F.t0.addingTimeInterval(-3600)
    let late = MeshWXWarningIdentity(event: 3, office: 35, etn: 900)
    let soon = MeshWXWarningIdentity(event: 3, office: 35, etn: 901)
    // Twenty-five heat advisories expiring 61 to 85 minutes after the list, soonest first.
    let entries = (1...MeshWXWire.maxDigestEntries).map { (MeshWXWarningIdentity(event: 14, office: 35, etn: UInt16($0)), UInt16(60 + $0)) }

    func held() -> WeatherBotState {
      var state = WeatherBotState(botID: F.botID)
      _ = WeatherStateReducer.apply(F.warning(seq: 1, identity: late, expiresMinutes: F.t0Minutes + 600), to: &state, receivedAt: earlier)
      _ = WeatherStateReducer.apply(F.warning(seq: 2, identity: soon, expiresMinutes: F.t0Minutes + 30), to: &state, receivedAt: earlier)
      return state
    }

    var full = held()
    let changes = WeatherStateReducer.apply(F.digest(seq: 3, entries: entries), to: &full, receivedAt: F.t0)
    // The one expiring before the last entry would have been listed; the later one may have been cut.
    #expect(changes == [.digestApplied(missing: entries.map(\.0), removed: [soon])])
    #expect(full.warnings[late] != nil)

    var short = held()
    _ = WeatherStateReducer.apply(F.digest(seq: 3, entries: Array(entries.dropLast())), to: &short, receivedAt: F.t0)
    #expect(short.warnings.isEmpty, "a list with room to spare speaks for everything")
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

  /// Spec §6.1: `ts` is the newest station's time and the rest say how far behind they are, so a
  /// reading is stored at the time its own station measured it. Everything a screen asks a
  /// reading — "as of", stale, which copy is newer — reads that one field, so all of it becomes
  /// per station at once.
  @Test
  func `each station is stored at its own report time, and the batch time stays on the row`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(
      F.observations(
        seq: 1, timestampMinutes: F.t0Minutes, stations: [(202, 88), (860, 84), (976, 70)],
        ages: [0, 20, 110]),
      to: &state, receivedAt: F.t0
    )
    #expect(state.observations[202]?.timestampMinutes == F.t0Minutes, "the newest reads the batch time")
    #expect(state.observations[860]?.timestampMinutes == F.t0Minutes - 20)
    #expect(state.observations[976]?.timestampMinutes == F.t0Minutes - 110)
    #expect(state.observations[976]?.observedAt == Date(unixMinutes: F.t0Minutes - 110))
    // The batch time is not lost with them: it is what says these three arrived in one scheduled
    // broadcast, which is what the bot's area is read from.
    #expect(state.observations.values.allSatisfy { $0.lastBatchMinutes == F.t0Minutes })
    #expect(state.latestObservationMinutes == F.t0Minutes)

    // Without the ages a batch states only its `ts`, and every station in it still reads that.
    var old = fresh()
    _ = WeatherStateReducer.apply(
      F.observations(seq: 1, timestampMinutes: F.t0Minutes, stations: [(202, 88), (860, 84)]),
      to: &old, receivedAt: F.t0
    )
    #expect(old.observations.values.allSatisfy { $0.timestampMinutes == F.t0Minutes })
    #expect(old.observations[860]?.observation.ageMinutes == nil)
  }

  /// A station two hours behind its batch is stale two hours before the batch is. Until the ages
  /// it did not look stale until two hours after a time that was never its own.
  @Test
  func `a station far behind its batch goes stale ahead of the rest of it`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(
      F.observations(
        seq: 1, timestampMinutes: F.t0Minutes, stations: [(202, 88), (860, 84)], ages: [0, 120]),
      to: &state, receivedAt: F.t0
    )
    let newest = try! #require(state.observations[202])
    let behind = try! #require(state.observations[860])
    // Two hours is the threshold, measured from each station's own reading.
    #expect(!behind.isStale(at: F.t0))
    #expect(behind.isStale(at: F.t0.addingTimeInterval(2 * 60)))
    #expect(!newest.isStale(at: F.t0.addingTimeInterval(119 * 60)))
    #expect(newest.isStale(at: F.t0.addingTimeInterval(121 * 60)))
  }

  /// Newest wins per station, and "newest" is the station's own time: a later batch whose copy of
  /// a station's report is older than the one held must not roll that row back — though the row
  /// was still named by that batch, which is what the bot's area is read from.
  @Test
  func `a newer batch carrying an older report for one station does not roll it back`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(
      F.observations(
        seq: 1, timestampMinutes: F.t0Minutes, stations: [(202, 88), (860, 84)], ages: [0, 0]),
      to: &state, receivedAt: F.t0
    )
    // The next hour: KAUS filed again, KGTU's newest METAR is now 90 minutes behind the batch —
    // older than the copy already held.
    let changes = WeatherStateReducer.apply(
      F.observations(
        seq: 2, timestampMinutes: F.t0Minutes + 60, stations: [(202, 90), (860, 70)],
        ages: [0, 90]),
      to: &state, receivedAt: F.t0.addingTimeInterval(60 * 60)
    )
    #expect(changes == [.observationsStored(stations: [202])])
    #expect(state.observations[202]?.observation.tempF == 90)
    #expect(state.observations[202]?.timestampMinutes == F.t0Minutes + 60)
    #expect(state.observations[860]?.observation.tempF == 84, "the reading held is the newer one")
    #expect(state.observations[860]?.timestampMinutes == F.t0Minutes)
    #expect(state.observations[860]?.lastBatchMinutes == F.t0Minutes + 60, "it was in that batch all the same")
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

  // MARK: - Where the data came from (spec §2.2, revision 7)

  @Test
  func `the source rides from each message's header into the record the screen reads`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 1, source: .goesSatellite), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.observations(seq: 2, stations: [(202, 88)], source: .internet), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.forecast(seq: 3, source: .mixed), to: &state, receivedAt: F.t0)
    #expect(state.warnings[F.svw42]?.source == .goesSatellite)
    #expect(state.observations[202]?.source == .internet)
    #expect(state.forecasts[102]?.source == .mixed)
  }

  /// A bot older than revision 7 states nothing, and nothing is what the record holds: unstated
  /// is not a fourth source, and no screen may read it as one.
  @Test
  func `a bot that states no source leaves every record unstated`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 1), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.observations(seq: 2, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.forecast(seq: 3), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.text(seq: 4, group: 4, index: 0, total: 1, text: "x"), to: &state, receivedAt: F.t0)
    #expect(state.warnings[F.svw42]?.source == .unstated)
    #expect(state.observations[202]?.source == .unstated)
    #expect(state.forecasts[102]?.source == .unstated)
    #expect(state.texts[4]?.source == .unstated)
    #expect(state.texts[4]?.wasCut == false)
  }

  /// A Cancel's nibble is its reason (spec §4), so nothing about it is a source — and the reason
  /// still decodes as it always did whatever the value.
  @Test
  func `a cancel whose reason fills the source bits is still only a reason`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(F.warning(seq: 1), to: &state, receivedAt: F.t0)
    // Reason 12 has bits 3-2 set: read as a source it would say "mixed".
    let cancel = F.cancel(seq: 2, reason: .other(12))
    #expect(cancel.header.dataSource == .unstated)
    let changes = WeatherStateReducer.apply(cancel, to: &state, receivedAt: F.t0)
    #expect(changes == [.warningRemoved(F.svw42, reason: .other(12))])
  }

  @Test
  func `an assembly takes the source from its chunks and is cut if any chunk says so`() {
    var state = fresh()
    _ = WeatherStateReducer.apply(
      F.text(seq: 7, group: 7, index: 0, total: 3, text: "SEVERE ", wasCut: true, source: .goesSatellite),
      to: &state, receivedAt: F.t0)
    #expect(state.texts[7]?.source == .goesSatellite)
    #expect(state.texts[7]?.wasCut == true)

    // The cut mark is the reply's, not one chunk's: a later chunk without the flag — which the
    // bot never sends, but a lost-and-resent packet could look like — does not unmark it.
    _ = WeatherStateReducer.apply(
      F.text(seq: 8, group: 7, index: 1, total: 3, text: "THUNDERSTORM ", source: .goesSatellite),
      to: &state, receivedAt: F.t0)
    #expect(state.texts[7]?.wasCut == true)

    // A chunk that states nothing never erases a source already stated; one that states
    // something disagreeing is the newest word on it.
    _ = WeatherStateReducer.apply(
      F.text(seq: 9, group: 7, index: 2, total: 3, text: "indicated."), to: &state, receivedAt: F.t0)
    #expect(state.texts[7]?.source == .goesSatellite)
    _ = WeatherStateReducer.apply(
      F.text(seq: 10, group: 7, index: 2, total: 3, text: "indicated.", source: .mixed),
      to: &state, receivedAt: F.t0)
    #expect(state.texts[7]?.source == .mixed)
    #expect(state.texts[7]?.isComplete == true)
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

/// Ordering on a shared, lossy channel: late copies, a bot that restarts its counter, lists
/// drained from the radio's queue hours late, and upgrades whose replacement never arrives. Every
/// case here is a way the phone could otherwise report calm while something is active.
/// Spec §7A: the bot's own statement of what it carries, which has no time of its own.
@Suite("WeatherStateReducer coverage")
struct WeatherStateReducerCoverageTests {
  private typealias F = WeatherFixture

  @Test
  func `a statement is stored with when it arrived`() {
    var state = WeatherBotState(botID: F.botID)
    let changes = WeatherStateReducer.apply(F.coverage(seq: 1), to: &state, receivedAt: F.t0)
    #expect(changes == [.coverageStored])
    #expect(state.coverage?.coverage == F.austinCoverage)
    #expect(state.coverage?.receivedAt == F.t0)
  }

  @Test
  func `the newest statement replaces the one held`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.coverage(seq: 1), to: &state, receivedAt: F.t0)

    var widened = F.austinCoverage
    widened.radiusKilometres = 200
    let changes = WeatherStateReducer.apply(
      F.coverage(seq: 2, widened), to: &state, receivedAt: F.t0.addingTimeInterval(3 * 3600))
    #expect(changes == [.coverageStored])
    #expect(state.coverage?.coverage.radiusKilometres == 200)
    #expect(state.coverage?.receivedAt == F.t0.addingTimeInterval(3 * 3600))
  }

  /// A late resend arriving behind a newer statement was sent first; the held one stands.
  @Test
  func `a statement arriving out of order leaves the newer one alone`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.coverage(seq: 40), to: &state, receivedAt: F.t0)

    var older = F.austinCoverage
    older.radiusKilometres = 80
    let changes = WeatherStateReducer.apply(
      F.coverage(seq: 20, older), to: &state, receivedAt: F.t0.addingTimeInterval(10))
    #expect(changes.contains(.outOfOrder(seq: 20)))
    #expect(changes.contains(.coverageIgnoredOlder))
    #expect(state.coverage?.coverage.radiusKilometres == 120)
  }

  /// The same bytes twice — the bot's resend of an unechoed packet — change nothing.
  @Test
  func `a copy of a statement is a duplicate`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.coverage(seq: 1), to: &state, receivedAt: F.t0)
    let before = state
    let changes = WeatherStateReducer.apply(
      F.coverage(seq: 1), to: &state, receivedAt: F.t0.addingTimeInterval(9))
    #expect(changes == [.duplicate(seq: 1)])
    #expect(state == before)
  }
}

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
  func `an empty list built before a new warning arrived does not remove it, however late it comes`() {
    var state = WeatherBotState(botID: F.botID)
    // 23:00 list, empty. 23:02 tornado warning. 23:04 a copy of the 23:00 list arrives late.
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
  func `a list built within two minutes of a gap does not clear it, one built later does`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.observations(seq: 1, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    // seq 2 is lost; seq 3 reveals the gap at t0.
    _ = WeatherStateReducer.apply(F.observations(seq: 3, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.digest(seq: 4, nowMinutes: F.t0Minutes + 1, entries: []), to: &state, receivedAt: F.t0.addingTimeInterval(60))
    #expect(state.needsDigest, "a minute after the gap, the two clocks could still disagree about the order")
    _ = WeatherStateReducer.apply(F.digest(seq: 5, nowMinutes: F.t0Minutes + 3, entries: []), to: &state, receivedAt: F.t0.addingTimeInterval(180))
    #expect(!state.needsDigest)
  }

  @Test
  func `a gap seen after the list was built survives a late copy of it`() {
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
  func `a late copy of a recent message is a duplicate, not a gap`() {
    var state = WeatherBotState(botID: F.botID)
    for seq: UInt8 in 5...7 {
      _ = WeatherStateReducer.apply(F.observations(seq: seq, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    }
    let changes = WeatherStateReducer.apply(F.observations(seq: 6, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    #expect(changes == [.duplicate(seq: 6)])
    #expect(state.lastSeq == 7)
    #expect(!state.needsDigest)
  }

  @Test
  func `a late warning for an identity held from a newer message is not applied, and asks for a list`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.warning(seq: 98, windMph: 70), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.observations(seq: 100, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(F.warning(seq: 97, windMph: 60), to: &state, receivedAt: F.t0)
    #expect(changes == [.outOfOrder(seq: 97)])
    #expect(state.warnings[F.svw42]?.warning.windMph == 70)
    #expect(state.needsDigest)
    #expect(state.lastSeq == 100)
  }

  @Test
  func `the bot's late resend of an update replaces the older copy it updates`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.warning(seq: 95, windMph: 60), to: &state, receivedAt: F.t0)
    // 96, the update, is missed; 97 arrives; 96's resend follows nine seconds later.
    _ = WeatherStateReducer.apply(F.observations(seq: 97, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(
      F.warning(seq: 96, windMph: 70), to: &state, receivedAt: F.t0.addingTimeInterval(9))
    #expect(changes == [.outOfOrder(seq: 96), .warningStored(F.svw42, replacedExisting: true)])
    #expect(state.warnings[F.svw42]?.warning.windMph == 70)
    #expect(state.warnings[F.svw42]?.seq == 96)
    #expect(state.lastSeq == 97)
  }

  @Test
  func `out of order across the wrap from 255 to 0 is still out of order, not a restart`() {
    var state = WeatherBotState(botID: F.botID)
    for seq: UInt8 in [255, 0, 1] {
      _ = WeatherStateReducer.apply(F.observations(seq: seq, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    }
    let changes = WeatherStateReducer.apply(F.warning(seq: 254, identity: F.svw43), to: &state, receivedAt: F.t0)
    #expect(changes == [.outOfOrder(seq: 254), .warningStored(F.svw43, replacedExisting: false)])
    #expect(state.lastSeq == 1)
  }

  @Test
  func `a late warning for an identity not held is stored, since it is the only copy`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.observations(seq: 100, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(F.warning(seq: 96, identity: F.svw43), to: &state, receivedAt: F.t0)
    #expect(changes == [.outOfOrder(seq: 96), .warningStored(F.svw43, replacedExisting: false)])
    #expect(state.lastSeq == 100)
  }

  @Test
  func `a late warning for an identity cancelled in the last hour is not brought back`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.cancel(seq: 100, identity: F.svw42), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(F.warning(seq: 98, identity: F.svw42), to: &state, receivedAt: F.t0.addingTimeInterval(10))
    #expect(changes == [.outOfOrder(seq: 98)])
    #expect(state.warnings.isEmpty)
    #expect(state.recentCancels[F.svw42] == F.t0)

    _ = WeatherStateReducer.apply(F.observations(seq: 101, stations: [(202, 88)]), to: &state, receivedAt: F.t0.addingTimeInterval(61 * 60))
    #expect(state.recentCancels.isEmpty, "remembered for an hour")
  }

  @Test
  func `a late cancel still ends its warning`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.warning(seq: 10), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.observations(seq: 12, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(F.cancel(seq: 11), to: &state, receivedAt: F.t0)
    #expect(changes == [.outOfOrder(seq: 11), .warningRemoved(F.svw42, reason: .expiredEarly)])
    #expect(state.warnings.isEmpty)
  }

  @Test
  func `a late upgrade cancel leaves no marker when its replacement is already held`() {
    var state = WeatherBotState(botID: F.botID)
    let travis = [MeshWXAreaRun(stateIndex: 42, isCounty: true, start: 453, run: 1)]
    let tornado = MeshWXWarningIdentity(event: 1, office: 35, etn: 9)
    _ = WeatherStateReducer.apply(warning(seq: 10, identity: F.svw42, areas: travis), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(warning(seq: 12, identity: tornado, areas: travis), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.cancel(seq: 11, identity: F.svw42, reason: .upgraded), to: &state, receivedAt: F.t0)
    #expect(Set(state.warnings.keys) == [tornado])
    #expect(state.pendingUpgrades.isEmpty)
  }

  @Test
  func `a late list goes through the build-time check like any other`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.digest(seq: 10, entries: []), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.observations(seq: 12, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    #expect(WeatherStateReducer.apply(F.digest(seq: 11, nowMinutes: F.t0Minutes - 30, entries: []), to: &state, receivedAt: F.t0)
      == [.outOfOrder(seq: 11), .digestIgnoredOlder(builtMinutes: F.t0Minutes - 30)])
    #expect(WeatherStateReducer.apply(F.digest(seq: 9, nowMinutes: F.t0Minutes + 5, entries: [(F.svw43, 30)]), to: &state, receivedAt: F.t0)
      == [.outOfOrder(seq: 9), .digestApplied(missing: [F.svw43], removed: [])])
  }

  @Test
  func `a seq far behind is a restart: a new stream, applied normally, and a gap`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.observations(seq: 100, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
    let changes = WeatherStateReducer.apply(F.warning(seq: 50), to: &state, receivedAt: F.t0.addingTimeInterval(60))
    #expect(changes == [.sequenceRestart(last: 100, received: 50), .warningStored(F.svw42, replacedExisting: false)])
    #expect(state.lastSeq == 50)
    #expect(state.needsDigest)
    #expect(state.recentMessages.map(\.seq) == [50])
    // The new stream goes on from there without another gap.
    #expect(WeatherStateReducer.apply(F.observations(seq: 51, stations: [(202, 88)]), to: &state, receivedAt: F.t0.addingTimeInterval(62))
      == [.observationsStored(stations: [202])])
  }

  @Test
  func `reordering reaches 32 places back, and 33 is a restart`() {
    func after100(_ seq: UInt8) -> WeatherStateChange? {
      var state = WeatherBotState(botID: F.botID)
      _ = WeatherStateReducer.apply(F.observations(seq: 100, stations: [(202, 88)]), to: &state, receivedAt: F.t0)
      return WeatherStateReducer.apply(F.observations(seq: seq, timestampMinutes: F.t0Minutes - 1, stations: [(860, 80)]), to: &state, receivedAt: F.t0).first
    }
    #expect(after100(99) == .outOfOrder(seq: 99))
    #expect(after100(68) == .outOfOrder(seq: 68))
    #expect(after100(67) == .sequenceRestart(last: 100, received: 67))
  }

  @Test
  func `a new message under the newest seq after a restart is not taken for a copy`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.warning(seq: 40), to: &state, receivedAt: F.t0)
    // The bot restarts and its counter lands on 40 again.
    let changes = WeatherStateReducer.apply(F.cancel(seq: 40), to: &state, receivedAt: F.t0.addingTimeInterval(120))
    #expect(changes == [.sequenceRestart(last: 40, received: 40), .warningRemoved(F.svw42, reason: .expiredEarly)])
    #expect(state.warnings.isEmpty)
    // The bot's resend of that cancel is a copy.
    #expect(WeatherStateReducer.apply(F.cancel(seq: 40), to: &state, receivedAt: F.t0.addingTimeInterval(129)) == [.duplicate(seq: 40)])
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

  /// A single-station answer is somebody's `>o KAUS`, broadcast to everyone. The newer reading is
  /// the one to show, but it says nothing about the bot's area, so it must not wipe out the record
  /// that a scheduled batch named the station (docs/MESHWX_UI.md §6).
  @Test
  func `a single-station answer replaces the reading but not the batch it was in`() {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.observations(seq: 1, stations: [(202, 88), (860, 84)]), to: &state, receivedAt: F.t0)
    #expect(state.observations[202]?.lastBatchMinutes == F.t0Minutes)

    _ = WeatherStateReducer.apply(
      F.observations(seq: 2, timestampMinutes: F.t0Minutes + 5, stations: [(202, 90)]), to: &state, receivedAt: F.t0)
    #expect(state.observations[202]?.observation.tempF == 90, "the newer reading is what is shown")
    #expect(state.observations[202]?.batchSize == 1, "and it came in a batch of one")
    #expect(state.observations[202]?.lastBatchMinutes == F.t0Minutes, "it was in the scheduled batch, and still is")

    // A station nothing but a single answer has ever named has no batch behind it.
    _ = WeatherStateReducer.apply(
      F.observations(seq: 3, timestampMinutes: F.t0Minutes + 6, stations: [(976, 70)]), to: &state, receivedAt: F.t0)
    #expect(state.observations[976]?.lastBatchMinutes == nil)

    // A scheduled batch drained late, older than the single answer, is still evidence.
    _ = WeatherStateReducer.apply(
      F.observations(seq: 4, timestampMinutes: F.t0Minutes + 2, stations: [(976, 71), (860, 85)]), to: &state, receivedAt: F.t0)
    #expect(state.observations[976]?.observation.tempF == 70, "the newer single reading stands")
    #expect(state.observations[976]?.lastBatchMinutes == F.t0Minutes + 2)
  }

  /// A state file written before the batch was recorded separately: a reading that came in a batch
  /// is its own evidence, which is exactly what `batchSize` alone used to say.
  @Test
  func `a reading from a file without the batch record keeps its batch`() throws {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.observations(seq: 1, stations: [(202, 88), (860, 84)]), to: &state, receivedAt: F.t0)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
    var pairs = try #require(json["observations"] as? [Any])
    for index in stride(from: 1, to: pairs.count, by: 2) {
      if var record = pairs[index] as? [String: Any] {
        record.removeValue(forKey: "lastBatchMinutes")
        pairs[index] = record
      }
    }
    json["observations"] = pairs

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let legacy = try decoder.decode(WeatherBotState.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(legacy.observations[202]?.lastBatchMinutes == F.t0Minutes)
    #expect(legacy.observations[202]?.batchSize == 2)
  }

  @Test
  func `a state file written before the new fields still loads`() async throws {
    var state = WeatherBotState(botID: F.botID)
    _ = WeatherStateReducer.apply(F.warning(seq: 1, source: .internet), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.observations(seq: 2, stations: [(202, 88)], source: .internet), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(F.forecast(seq: 3, source: .internet), to: &state, receivedAt: F.t0)
    _ = WeatherStateReducer.apply(
      F.text(seq: 4, group: 4, index: 0, total: 1, text: "x", wasCut: true, source: .internet),
      to: &state, receivedAt: F.t0)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
    for key in ["recentMessages", "gapDetectedAt", "pendingUpgrades", "recentCancels"] { json.removeValue(forKey: key) }
    // Before fingerprints the window was bare seq values.
    json["recentSeqs"] = [3, 4]
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
    // Revision 7 (spec §2.2, §8.1): a file from Rafael's phone written before the app could read
    // either of these decodes as "the radio didn't say", not as a failure to load the file.
    for collection in ["warnings", "observations", "forecasts", "texts"] {
      strip(collection, "source")
    }
    strip("texts", "wasCut")

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let legacy = try decoder.decode(WeatherBotState.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(legacy.warnings.count == 1)
    #expect(legacy.recentMessages == [WeatherSeenMessage(seq: 3, fingerprint: nil), WeatherSeenMessage(seq: 4, fingerprint: nil)])
    #expect(legacy.recentCancels.isEmpty)
    #expect(legacy.observations[202]?.batchSize == 1)
    #expect(legacy.forecasts[102]?.requestedHere == false)
    #expect(legacy.texts[4]?.request == nil)
    #expect(legacy.warnings[F.svw42]?.source == .unstated)
    #expect(legacy.observations[202]?.source == .unstated)
    #expect(legacy.forecasts[102]?.source == .unstated)
    #expect(legacy.texts[4]?.source == .unstated)
    #expect(legacy.texts[4]?.wasCut == false)

    // An entry without a fingerprint matches on seq alone, as it did.
    var reloaded = legacy
    #expect(WeatherStateReducer.apply(F.observations(seq: 4, stations: [(202, 70)]), to: &reloaded, receivedAt: F.t0) == [.duplicate(seq: 4)])
  }
}

/// Texts and forecasts get the treatment readings have always had: an age and a ceiling, so the
/// answers the channel carries to everybody else cannot pile up for ever. What a screen would
/// still show survives both rules, however old it is (docs/MESHWX_UI.md §12).
@Suite("Weather retention")
struct WeatherRetentionTests {
  private typealias F = WeatherFixture

  private let cutoff = WeatherFixture.t0.addingTimeInterval(-48 * 3600)

  private func reply(
    group: UInt8,
    subject: MeshWXTextSubject = .hazardousOutlook,
    request: WeatherRequest? = nil,
    hoursAgo: Double
  ) -> WeatherTextAssembly {
    let at = F.t0.addingTimeInterval(-hoursAgo * 3600)
    return WeatherTextAssembly(
      subject: subject, group: group, total: 1, chunks: [0: "text"],
      firstReceivedAt: at, lastReceivedAt: at, request: request)
  }

  private func state(texts: [WeatherTextAssembly]) -> WeatherBotState {
    var state = WeatherBotState(botID: F.botID)
    for text in texts { state.texts[text.group] = text }
    return state
  }

  private func forecast(point: UInt16, hoursAgo: Double, requestedHere: Bool = false) -> WeatherStoredForecast {
    WeatherStoredForecast(
      forecast: MeshWXForecast(
        pointIndex: point, issuedMinutes: F.t0Minutes - UInt32(hoursAgo * 60), firstPeriod: 0, periods: []),
      receivedAt: F.t0.addingTimeInterval(-hoursAgo * 3600),
      requestedHere: requestedHere)
  }

  private func state(forecasts: [WeatherStoredForecast]) -> WeatherBotState {
    var state = WeatherBotState(botID: F.botID)
    for forecast in forecasts { state.forecasts[forecast.forecast.pointIndex] = forecast }
    return state
  }

  // MARK: - Texts

  @Test
  func `a reply the channel carried two days ago goes`() {
    var state = state(texts: [
      reply(group: 1, subject: .stormReports, hoursAgo: 49),
      reply(group: 2, subject: .stormReports, hoursAgo: 1)
    ])
    WeatherStateReducer.pruneTexts(&state, receivedBefore: cutoff, limit: 24)
    #expect(state.texts.keys.sorted() == [2])
  }

  /// The product screen shows the newest reply on its subject, whoever asked for it: dropping it
  /// on age would empty a screen that has something to show.
  @Test
  func `the newest reply on a subject stays however old it is`() {
    var state = state(texts: [reply(group: 1, subject: .stormReports, hoursAgo: 200)])
    WeatherStateReducer.pruneTexts(&state, receivedBefore: cutoff, limit: 24)
    #expect(state.texts.keys.sorted() == [1])
  }

  /// A screen shows this phone's own reply first and falls back to the overheard one, so both
  /// survive — and nothing older than either does.
  @Test
  func `this phone's own reply and the newest overheard one both stay`() {
    var state = state(texts: [
      reply(group: 1, subject: .stormReports, request: .stormReports(state: "TX"), hoursAgo: 60),
      reply(group: 2, subject: .stormReports, hoursAgo: 55),
      reply(group: 3, subject: .stormReports, hoursAgo: 70)
    ])
    WeatherStateReducer.pruneTexts(&state, receivedBefore: cutoff, limit: 24)
    #expect(state.texts.keys.sorted() == [1, 2])
  }

  @Test
  func `the ceiling keeps the newest and never drops what is shown`() {
    var state = state(texts: (0..<30).map { reply(group: UInt8($0), subject: .general, hoursAgo: Double($0)) })
    WeatherStateReducer.pruneTexts(&state, receivedBefore: cutoff, limit: 5)
    #expect(state.texts.count == 5)
    #expect(state.texts.keys.sorted() == [0, 1, 2, 3, 4])
  }

  // MARK: - Forecasts

  @Test
  func `a forecast the channel carried two days ago goes`() {
    var state = state(forecasts: [forecast(point: 500, hoursAgo: 49), forecast(point: 501, hoursAgo: 2)])
    WeatherStateReducer.pruneForecasts(&state, receivedBefore: cutoff, limit: 24)
    #expect(state.forecasts.keys.sorted() == [501])
  }

  /// The place's own forecast is what the Forecast card is showing; its age is said on the card,
  /// and forgetting it would empty the card instead.
  @Test
  func `the forecast this phone asked for stays however old it is`() {
    var state = state(forecasts: [forecast(point: 103, hoursAgo: 200, requestedHere: true)])
    WeatherStateReducer.pruneForecasts(&state, receivedBefore: cutoff, limit: 24)
    #expect(state.forecasts.keys.sorted() == [103])
  }

  @Test
  func `under the ceiling this phone's own forecasts outlast the ones it overheard`() {
    var state = state(forecasts:
      (0..<10).map { forecast(point: UInt16(600 + $0), hoursAgo: Double($0)) }
        + [forecast(point: 103, hoursAgo: 20, requestedHere: true), forecast(point: 104, hoursAgo: 30, requestedHere: true)])
    WeatherStateReducer.pruneForecasts(&state, receivedBefore: cutoff, limit: 3)
    #expect(state.forecasts.keys.sorted() == [103, 104, 600])
  }
}
