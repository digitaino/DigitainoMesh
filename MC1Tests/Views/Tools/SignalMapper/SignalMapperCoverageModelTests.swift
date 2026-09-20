import Foundation
import MapperRawLog
@testable import MC1
@testable import MC1Services
import SurveyKit
import Testing

/// The card's refresh path (docs/SIGNAL_MAPPER_V3.md §12, 2026-09-04).
///
/// The defect these pin: rows landed throughout a ride and the card under the HUD never
/// reread them, because the only two things that could ask again were a cell/scope change
/// and a timer that slept first. `setCardTarget` refuses an unchanged target on purpose — it
/// is what stops a re-render clearing the card mid-fetch — so the arrival path has to reach
/// the reload without going through it.
@Suite("Signal mapper coverage model")
@MainActor
struct SignalMapperCoverageModelTests {
  private let cellRaw: UInt64 = 0x0892_8308_280F_FFFF
  private let start = Date(timeIntervalSince1970: 1_753_000_000)

  private func at(_ offset: TimeInterval) -> Date {
    start.addingTimeInterval(offset)
  }

  private func event(_ offset: TimeInterval, rxSnr: Double, hexID: String) -> MapperRawSampleEvent {
    MapperRawSampleEvent(
      timestamp: at(offset),
      kind: .passiveRx,
      rxSnr: rxSnr,
      repeaterHexID: hexID,
      cellRaw: cellRaw,
      gateOutcome: .accepted
    )
  }

  /// A row the fix gate could not place: a real reception, in no hexagon, invisible to the
  /// summaries and therefore to the map.
  private func unplacedEvent(_ offset: TimeInterval, kind: MapperRawSampleKind) -> MapperRawSampleEvent {
    MapperRawSampleEvent(
      timestamp: at(offset),
      kind: kind,
      cellRaw: nil,
      gateOutcome: .noFix
    )
  }

  /// An app state whose raw log is an in-memory store, so nothing here touches the real one.
  private func makeAppState() throws -> AppState {
    let appState = AppState()
    appState.mapperRawLogStore = try MapperRawLogStore.inMemory()
    return appState
  }

  /// Waits for `condition`, polling — the observer coalesces on a 750 ms sleep, so the
  /// assertion has to outlast one window without pinning the exact instant.
  private func waitFor(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
  }

  @Test
  func `A row arriving after the card is built rebuilds it, unchanged target and all`() async throws {
    let appState = try makeAppState()
    let store = try #require(appState.mapperRawLogStore)
    let cell = try #require(H3Cell(rawValue: cellRaw))
    let model = SignalMapperCoverageModel()

    try await store.insertSamples([event(0, rxSnr: 5, hexID: "0C13")], runID: nil, startingSeq: 0)
    await model.setCardTarget(cell: cell, scope: .allTime, appState: appState)
    #expect(model.card?.repeaters.map(\.hexID) == ["0C13"])

    let observer = Task { await model.observeRowArrivals(appState: appState) }
    defer { observer.cancel() }
    // The subscription is opened inside the task; give it the turn it needs before writing,
    // or the signal is emitted to nobody.
    try await Task.sleep(for: .milliseconds(200))

    try await store.insertSamples([event(10, rxSnr: 9, hexID: "9A21")], runID: nil, startingSeq: 1)

    #expect(
      await waitFor { model.card?.repeaters.count == 2 },
      "the target never changed, so only the arrival path could have refreshed this"
    )
    #expect(model.card?.repeaters.map(\.hexID) == ["9A21", "0C13"])
  }

  /// A burst is one rebuild, not one per batch: the store's stream keeps only the newest
  /// signal and the observer sleeps through the rest of the burst before reading.
  @Test
  func `A burst of arrivals collapses into a single card rebuild`() async throws {
    let appState = try makeAppState()
    let store = try #require(appState.mapperRawLogStore)
    let cell = try #require(H3Cell(rawValue: cellRaw))
    let model = SignalMapperCoverageModel()

    await model.setCardTarget(cell: cell, scope: .allTime, appState: appState)
    let observer = Task { await model.observeRowArrivals(appState: appState) }
    defer { observer.cancel() }
    try await Task.sleep(for: .milliseconds(200))

    for index in 0..<10 {
      try await store.insertSamples(
        [event(Double(index), rxSnr: 5, hexID: String(format: "%04X", index))],
        runID: nil,
        startingSeq: Int64(index)
      )
    }

    // One rebuild lands, and it holds every row the burst wrote — a per-batch rebuild would
    // have shown partial lists on the way there, and ten detached builds to get here.
    #expect(await waitFor { model.card?.repeaters.count == 10 })
  }

  /// The card follows a hexagon the map has no summary for. `setCardTarget` is what the
  /// view calls when the rider crosses a boundary, and it must read rows for a cell the
  /// snapshot has never heard of.
  @Test
  func `A hexagon with no summary still gets a card`() async throws {
    let appState = try makeAppState()
    let cell = try #require(H3Cell(rawValue: cellRaw))
    let model = SignalMapperCoverageModel()

    await model.setCardTarget(cell: cell, scope: .allTime, appState: appState)

    let card = try #require(model.card)
    #expect(card.cell == cell)
    #expect(card.repeaters.isEmpty)
    #expect(model.snapshot.isEmpty, "nothing has been folded into a summary yet")
    #expect(SignalMapperMapCell.placeholder(cell).cell == cell)
    #expect(SignalMapperMapCell.placeholder(cell).heardCount == 0)
  }

  // MARK: - The ride's two numbers

  /// The legend's ride line and the card's "has this ride captured anything" test are
  /// different questions, and one count could not answer both.
  ///
  /// The legend prints "This ride · N hexagons · M observations" directly under the all-time
  /// line, whose M is a sum over the summaries — placed rows only. Counting the unplaced ones
  /// there described a different population under the same word, and on a ride that began in
  /// a garage the ride line could exceed the all-time line that contains it. The empty-state
  /// test needs the opposite reading: every evidence kind, placed or not.
  @Test
  func `The legend counts what the map could place and the empty-state test counts every kind`() async throws {
    let appState = try makeAppState()
    let store = try #require(appState.mapperRawLogStore)
    appState.signalMapperRideSession = SignalMapperRideSession(
      runID: UUID(),
      startedAt: at(0),
      focusTargets: [],
      recorder: nil
    )

    try await store.insertSamples([
      event(1, rxSnr: 5, hexID: "0C13"),
      event(2, rxSnr: 4, hexID: "0C13"),
      // The GPS warm-up rows: heard, real, and in no hexagon, so no summary folds them.
      unplacedEvent(3, kind: .passiveRx),
      unplacedEvent(4, kind: .passiveRx),
      // A probe reply is evidence of the ride and is never a `passiveRx` row.
      unplacedEvent(5, kind: .probeTraceReply)
    ], runID: nil, startingSeq: 0)

    let model = SignalMapperCoverageModel()
    await model.load(appState: appState)

    #expect(model.rideObservationCount == 2, "the two rows the summaries actually folded")
    #expect(model.snapshot.observationCount == 2)
    #expect(
      model.rideObservationCount <= model.snapshot.observationCount,
      "the ride line is inside the all-time line and can never report more than it"
    )
    #expect(model.rideEvidenceCount == 5, "everything the radio brought in, placed or not")
  }

  /// Finding 7's ride, end to end: probes out, replies back, no other RF. The legend's
  /// observation count is honestly zero; the card must not read that as "nothing captured".
  @Test
  func `A probe-reply-only ride counts no observations and plenty of evidence`() async throws {
    let appState = try makeAppState()
    let store = try #require(appState.mapperRawLogStore)
    appState.signalMapperRideSession = SignalMapperRideSession(
      runID: UUID(),
      startedAt: at(0),
      focusTargets: [],
      recorder: nil
    )

    try await store.insertSamples([
      unplacedEvent(1, kind: .probeTraceReply),
      unplacedEvent(2, kind: .probeDiscoverResponse),
      unplacedEvent(3, kind: .txHeard),
      // Our own transmissions are not evidence that anything was captured.
      unplacedEvent(4, kind: .probeAttempt),
      unplacedEvent(5, kind: .sent)
    ], runID: nil, startingSeq: 0)

    let model = SignalMapperCoverageModel()
    await model.load(appState: appState)

    #expect(model.rideObservationCount == 0)
    #expect(model.rideEvidenceCount == 3)
  }

  /// Outside a ride both are zero — the legend prints no ride line and the card falls
  /// through to the hexagon's own answer.
  @Test
  func `Both ride counts are cleared when no ride is open`() async throws {
    let appState = try makeAppState()
    let store = try #require(appState.mapperRawLogStore)
    try await store.insertSamples([event(1, rxSnr: 5, hexID: "0C13")], runID: nil, startingSeq: 0)

    let model = SignalMapperCoverageModel()
    await model.load(appState: appState)

    #expect(model.rideObservationCount == 0)
    #expect(model.rideEvidenceCount == 0)
    #expect(model.snapshot.observationCount == 1, "the map still has it")
  }
}
