import Foundation
@testable import MC1Services
import SurveyKit
import SwiftData
import Testing

/// The fix gate's two movement clauses and the anchor drop — the parts of §2.2/§2.7 that
/// decide an observation is *not* allowed to exist.
///
/// Age and accuracy were already covered by `SignalMapperCaptureEngineTests`; what is here
/// is everything that can be true of a fix that is fresh and accurate and still wrong about
/// where the phone is.
@Suite("SignalMapperCaptureEngine fix gate")
struct SignalMapperFixGateTests {
  // MARK: - Fixtures

  private func makeStore() throws -> PersistenceStore {
    try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
  }

  private func makeEngine(
    source: ScriptedRxEntrySource,
    store: PersistenceStore,
    fixes: StubMapperFixProvider,
    movementHints: (any MovementHintProvider)? = nil,
    clock: TestClock,
    tuning: MapperTuning
  ) -> SignalMapperCaptureEngine {
    SignalMapperCaptureEngine(
      source: source,
      store: store,
      fixProvider: fixes,
      movementHints: movementHints,
      tuningProvider: StaticMapperTuningProvider(tuning),
      anchorSeedProvider: StaticMapperAnchorSeedProvider(),
      now: clock.provider
    )
  }

  /// Flush triggers pushed out of the way so each test decides when a write happens.
  private func quietTuning(
    fixMaxAge: TimeInterval = 120,
    fixMaxDisplacement: Double = 150,
    anchorMinDistinctDays: Int = 5,
    anchorStationaryShare: Double = 0.6,
    anchorObservationCount: Int = 2000
  ) -> MapperTuning {
    MapperTuning(
      fixMaxAgeSeconds: fixMaxAge,
      fixMaxDisplacementMeters: fixMaxDisplacement,
      anchorMinDistinctDays: anchorMinDistinctDays,
      anchorStationaryShare: anchorStationaryShare,
      anchorObservationCount: anchorObservationCount,
      flushIntervalSeconds: 3600,
      flushEntryCount: 10000
    )
  }

  /// A fake ride-log recorder; the raw rows are where the doubtful-placement rule shows.
  private actor RecordingRawRecorder: MapperRawSampleRecording {
    private(set) var events: [MapperRawSampleEvent] = []

    func record(_ event: MapperRawSampleEvent) async {
      events.append(event)
    }
  }

  // MARK: - Doubtful placements (owner decision, 2026-09-04)

  /// The field defect, at the level it was caused: an inaccurate fix used to write a row
  /// with no cell at all, and the store's cell fetch is an equality match, so the reply was
  /// invisible to the card and to the summaries for ever. The position is kept now, tagged
  /// with why it is doubtful; the aggregate side is untouched.
  @Test
  func `A fix that fails only on accuracy still places its raw row, and still folds nothing`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(accuracy: 500, at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: quietTuning())
    let recorder = RecordingRawRecorder()

    await engine.start()
    await engine.setRawRecorder(recorder)
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()

    let event = try #require(await recorder.events.first)
    let expectedCell = try #require(MapperFixtureLocation.cell(MapperFixtureLocation.plaza))
    #expect(event.cellRaw == expectedCell.rawValue, "the row is placeable, and losing it is the one undoable choice")
    #expect(event.gateOutcome == .inaccurateFix, "so an export can tell a confident row from a doubtful one")
    #expect(event.horizontalAccuracyMeters == 500, "the column that lets a consumer filter it out later")

    #expect(await engine.snapshot().droppedInaccurateFixCount == 1)
    #expect(await engine.snapshot().sampleCount == 0)
    #expect(try await store.countMapperCellObservations() == 0, "a doubtful placement never folds")
    await engine.stop()
  }

  /// The other doubtful case: fresh enough for the flat budget, too old for its own speed.
  @Test
  func `A fix stale only against its own speed still places its raw row`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    // 30 s old at 20 m/s: inside the flat 120 s, well past the 150 m displacement budget.
    let fixes = StubMapperFixProvider(
      mapperFix(accuracy: 10, speed: 20, at: clock.now.addingTimeInterval(-30))
    )
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: quietTuning())
    let recorder = RecordingRawRecorder()

    await engine.start()
    await engine.setRawRecorder(recorder)
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))

    let event = try #require(await recorder.events.first)
    #expect(event.cellRaw != nil)
    #expect(event.gateOutcome == .staleFix)
    #expect(await engine.snapshot().droppedStaleFixCount == 1)
    #expect(try await store.countMapperCellObservations() == 0)
    await engine.stop()
  }

  /// The two cases where no coordinate the row could honestly carry exists. Nothing changed
  /// for them, and nothing may: a cell invented from a fix the phone has walked away from is
  /// worse than a missing cell, because it looks like data.
  @Test
  func `No fix and a moved-away fix still place nothing`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(nil)
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: quietTuning())
    let recorder = RecordingRawRecorder()

    await engine.start()
    await engine.setRawRecorder(recorder)
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))

    let noFix = try #require(await recorder.events.first)
    #expect(noFix.cellRaw == nil)
    #expect(noFix.gateOutcome == .noFix)

    fixes.set(mapperFix(accuracy: 10, movedSinceCapture: true, at: clock.now.addingTimeInterval(-1)))
    source.send(mapperRxEntry(payload: Data([0x02]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 2))

    let moved = try #require(await recorder.events.last)
    #expect(moved.cellRaw == nil, "the fix describes a place the phone has left")
    #expect(moved.gateOutcome == .movedSinceCapture)
    await engine.stop()
  }

  /// The sentinel is *not* a doubtful placement, however much it looks like one.
  ///
  /// `horizontalAccuracy < 0` is CoreLocation saying the latitude and longitude in the same
  /// object are meaningless — in practice (0, 0), which `SurveyGrid` resolves to a perfectly
  /// good res-9 cell in the Gulf of Guinea. Doubt keeps its position because a reader can
  /// filter a vague one out later; there is nothing here to filter, and "fit all" framed the
  /// map from the rider to 0°N 0°E. The drop still counts as an inaccurate one, which is
  /// what the strip's fix-health chip is watching.
  @Test
  func `A negative accuracy is CoreLocation's no-fix sentinel and places nothing`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(
      mapperFix((latitude: 0, longitude: 0), accuracy: -1, at: clock.now)
    )
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: quietTuning())
    let recorder = RecordingRawRecorder()

    await engine.start()
    await engine.setRawRecorder(recorder)
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()

    let event = try #require(await recorder.events.first)
    #expect(event.cellRaw == nil, "there is no position here to keep, only a sentinel")
    #expect(event.gateOutcome == .inaccurateFix)

    let snapshot = await engine.snapshot()
    #expect(snapshot.droppedInaccurateFixCount == 1, "the counter the fix-health chip reads")
    #expect(snapshot.droppedNoFixCount == 0)
    #expect(snapshot.sampleCount == 0)
    #expect(try await store.countMapperCellObservations() == 0)
    await engine.stop()
  }

  /// The shared definition itself: whatever the probe engine will transmit on, the capture
  /// engine can place. Pinned directly on the gate so the invariant cannot drift back apart.
  @Test
  func `Anything placeable is exactly what a probe may be planned on`() {
    let now = Date(timeIntervalSince1970: 1_753_000_000)
    let tuning = quietTuning(fixMaxAge: 120, fixMaxDisplacement: 150)

    let doubtful = [
      mapperFix(accuracy: 500, at: now),
      mapperFix(accuracy: 10, speed: 20, at: now.addingTimeInterval(-30))
    ]
    for fix in doubtful {
      let verdict = MapperFixGate.evaluate(fix: fix, at: now, tuning: tuning)
      #expect(verdict.isPlaceable, "a probe would be sent on this, so its reply must land somewhere")
      #expect(!verdict.isConfident)
    }

    let unplaceable = [
      nil,
      mapperFix(accuracy: 10, movedSinceCapture: true, at: now),
      mapperFix(accuracy: 10, at: now.addingTimeInterval(-121)),
      // CoreLocation's sentinel: the coordinate in this object is not a fix at all.
      mapperFix(accuracy: -1, at: now)
    ]
    for fix in unplaceable {
      #expect(!MapperFixGate.evaluate(fix: fix, at: now, tuning: tuning).isPlaceable)
    }

    let good = MapperFixGate.evaluate(fix: mapperFix(accuracy: 10, at: now), at: now, tuning: tuning)
    #expect(good.isPlaceable)
    #expect(good.isConfident)
  }

  // MARK: - Moved since capture

  @Test
  func `A fresh, accurate fix the phone has moved away from is dropped`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    // One second old and accurate to 10 m — it passes every test the gate had before.
    let fixes = StubMapperFixProvider(
      mapperFix(accuracy: 10, movedSinceCapture: true, at: clock.now.addingTimeInterval(-1))
    )
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: quietTuning())

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()

    let snapshot = await engine.snapshot()
    #expect(snapshot.droppedMovedSinceFixCount == 1)
    #expect(snapshot.droppedStaleFixCount == 0)
    #expect(snapshot.droppedInaccurateFixCount == 0)
    #expect(snapshot.sampleCount == 0)
    #expect(try await store.countMapperCellObservations() == 0)
    await engine.stop()
  }

  @Test
  func `The same fix without the mark is folded`() async throws {
    // The control for the test above: nothing but `movedSinceCapture` differs.
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(accuracy: 10, at: clock.now.addingTimeInterval(-1)))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: quietTuning())

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()

    #expect(await engine.snapshot().droppedMovedSinceFixCount == 0)
    #expect(try await store.countMapperCellObservations() == 1)
    await engine.stop()
  }

  // MARK: - Speed-scaled age budget

  @Test
  func `A stationary phone keeps the whole age budget`() {
    let tuning = quietTuning(fixMaxAge: 120, fixMaxDisplacement: 150)
    let parked = mapperFix(speed: 0, at: Date())
    let unknown = mapperFix(speed: nil, at: Date())

    #expect(SignalMapperCaptureEngine.toleratedAgeSeconds(for: parked, tuning: tuning) == 120)
    #expect(SignalMapperCaptureEngine.toleratedAgeSeconds(for: unknown, tuning: tuning) == 120)
  }

  @Test
  func `A moving phone's budget is displacement over speed`() {
    let tuning = quietTuning(fixMaxAge: 120, fixMaxDisplacement: 150)

    // 15 m/s: 150 m of slack is ten seconds, not the two minutes age alone would allow.
    #expect(SignalMapperCaptureEngine.toleratedAgeSeconds(for: mapperFix(speed: 15, at: Date()), tuning: tuning) == 10)
    // Walking pace never reaches the displacement cap, so the flat age limit still binds.
    #expect(SignalMapperCaptureEngine.toleratedAgeSeconds(for: mapperFix(speed: 1, at: Date()), tuning: tuning) == 120)
  }

  @Test
  func `A 119-second fix at driving speed is dropped where a parked one is kept`() async throws {
    // The auditor's case, end to end: at 15 m/s that fix points about 1.8 km back down the
    // road — roughly five res-9 cells — and used to pass the gate untouched.
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(
      mapperFix(accuracy: 10, speed: 15, at: clock.now.addingTimeInterval(-119))
    )
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: quietTuning())

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))

    #expect(await engine.snapshot().droppedStaleFixCount == 1)
    #expect(await engine.snapshot().sampleCount == 0)

    // Same age, same accuracy, parked: kept.
    fixes.set(mapperFix(accuracy: 10, speed: 0, at: clock.now.addingTimeInterval(-119)))
    source.send(mapperRxEntry(payload: Data([0x02]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 2))
    await engine.flushNow()

    #expect(await engine.snapshot().sampleCount == 1)
    #expect(try await store.countMapperCellObservations() == 1)
    await engine.stop()
  }

  @Test
  func `The displacement budget still binds with motion permission declined`() async throws {
    // No movement hints wired at all — the state a user who said no to Motion & Fitness is
    // in — and the fix is therefore never marked moved. Speed alone has to carry it.
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(
      mapperFix(accuracy: 10, speed: 20, at: clock.now.addingTimeInterval(-30))
    )
    let engine = makeEngine(
      source: source, store: store, fixes: fixes, movementHints: nil, clock: clock, tuning: quietTuning()
    )

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))

    let snapshot = await engine.snapshot()
    #expect(snapshot.droppedMovedSinceFixCount == 0, "no hint provider, so nothing can mark the fix")
    #expect(snapshot.droppedStaleFixCount == 1, "speed alone must still bound the age")
    await engine.stop()
  }

  // MARK: - Dwell counting

  @Test
  func `Observations captured while stationary are counted as dwell`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let hints = StubMovementHintProvider(.stationary)
    let engine = makeEngine(
      source: source,
      store: store,
      fixes: StubMapperFixProvider(mapperFix(at: clock.now)),
      movementHints: hints,
      clock: clock,
      tuning: quietTuning()
    )

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))

    hints.set(.fast)
    source.send(mapperRxEntry(payload: Data([0x02]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 2))
    await engine.flushNow()
    await engine.stop()

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(row.rxCount == 2)
    #expect(row.stationaryObservationCount == 1)
  }

  @Test
  func `With no movement provider nothing is counted as dwell`() async throws {
    // Nil is "we don't know", not "standing still". If it were treated as stationary, a
    // user who declined Motion & Fitness would have every cell they visit for five days —
    // their whole commute — declared an anchor.
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let engine = makeEngine(
      source: source,
      store: store,
      fixes: StubMapperFixProvider(mapperFix(at: clock.now)),
      movementHints: nil,
      clock: clock,
      tuning: quietTuning()
    )

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(row.rxCount == 1)
    #expect(row.stationaryObservationCount == 0)
  }

  // MARK: - Anchor enforcement

  @Test
  func `Observations inside an anchor's disc are dropped before they fold`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let home = try #require(MapperFixtureLocation.cell(MapperFixtureLocation.plaza))

    // Enough prior history at the plaza to make it an anchor the moment the engine looks.
    try await store.upsertMapperCellObservations((0..<6).map { index in
      MapperCellObservationDTO(
        cellRaw: home.rawValue,
        day: String(format: "2025-07-%02d", index + 1),
        packetCount: 10,
        rxCount: 10,
        stationaryObservationCount: 10
      )
    })

    let engine = makeEngine(
      source: source,
      store: store,
      fixes: StubMapperFixProvider(mapperFix(MapperFixtureLocation.plaza, at: clock.now)),
      clock: clock,
      tuning: quietTuning()
    )

    await engine.start()
    // The purge on start clears the history that made it an anchor…
    #expect(await waitForMapper { await engine.snapshot().anchorCount == 1 })
    #expect(try await store.countMapperCellObservations() == 0)

    // …and nothing new lands there either.
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()

    let snapshot = await engine.snapshot()
    #expect(snapshot.droppedAnchorCount == 1)
    #expect(snapshot.sampleCount == 0)
    #expect(snapshot.purgedCellCount == 1)
    #expect(snapshot.excludedCellCount > 0)
    #expect(try await store.countMapperCellObservations() == 0)
    await engine.stop()
  }

  @Test
  func `A cell outside every disc keeps capturing normally`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let home = try #require(MapperFixtureLocation.cell(MapperFixtureLocation.plaza))

    try await store.upsertMapperCellObservations((0..<6).map { index in
      MapperCellObservationDTO(
        cellRaw: home.rawValue,
        day: String(format: "2025-07-%02d", index + 1),
        packetCount: 10,
        rxCount: 10,
        stationaryObservationCount: 10
      )
    })

    // The fix is across town, well outside the plaza's disc (radius ≤ 1200 m).
    let engine = makeEngine(
      source: source,
      store: store,
      fixes: StubMapperFixProvider(mapperFix(MapperFixtureLocation.acrossTown, at: clock.now)),
      clock: clock,
      tuning: quietTuning()
    )

    await engine.start()
    #expect(await waitForMapper { await engine.snapshot().anchorCount == 1 })

    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    #expect(await engine.snapshot().droppedAnchorCount == 0)
    let rows = try await store.fetchMapperCellObservations()
    #expect(rows.count == 1)
    #expect(rows.first?.cellRaw == MapperFixtureLocation.cell(MapperFixtureLocation.acrossTown)?.rawValue)
  }

  @Test
  func `Recomputing anchors purges the buffered cells too`() async throws {
    // A cell can cross the threshold while its own observations are still in the in-memory
    // aggregate. Flushing them after raising the disc would put back what was just deleted.
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let home = try #require(MapperFixtureLocation.cell(MapperFixtureLocation.plaza))

    let engine = makeEngine(
      source: source,
      store: store,
      fixes: StubMapperFixProvider(mapperFix(MapperFixtureLocation.plaza, at: clock.now)),
      clock: clock,
      tuning: quietTuning()
    )

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    #expect(await engine.snapshot().pendingCellCount == 1)

    // History arrives from elsewhere (a previous session's flush) and makes the plaza an
    // anchor; the buffered cell must not survive the recompute.
    try await store.upsertMapperCellObservations((0..<6).map { index in
      MapperCellObservationDTO(
        cellRaw: home.rawValue,
        day: String(format: "2025-06-%02d", index + 1),
        packetCount: 10,
        rxCount: 10,
        stationaryObservationCount: 10
      )
    })
    await engine.recomputeAnchors()

    #expect(await engine.snapshot().pendingCellCount == 0)
    await engine.flushNow()
    #expect(try await store.countMapperCellObservations() == 0)
    await engine.stop()
  }
}
