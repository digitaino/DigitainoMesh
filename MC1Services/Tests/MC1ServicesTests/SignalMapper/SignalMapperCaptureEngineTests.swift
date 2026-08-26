import Foundation
@testable import MC1Services
import MeshCore
import SurveyKit
import SwiftData
import Testing

/// Capture-core behaviour (docs/SIGNAL_MAPPER_V2.md §2.1–2.3), driven entirely from an
/// injected clock, an injected fix provider and a hand-fed entry stream — no radio, no
/// CoreLocation, no waiting on wall-clock time.
@Suite("SignalMapperCaptureEngine")
struct SignalMapperCaptureEngineTests {
  // MARK: - Fixtures

  private func makeStore() throws -> PersistenceStore {
    let container = try PersistenceStore.createContainer(inMemory: true)
    return PersistenceStore(modelContainer: container)
  }

  /// Flush thresholds are set out of the way by default so each test decides when a write
  /// happens by calling `flushNow()`, rather than racing the engine's own triggers.
  private func makeTuning(
    fixMaxAge: TimeInterval = 120,
    fixMaxAccuracy: Double = 100,
    flushInterval: TimeInterval = 3600,
    flushEntryCount: Int = 10000
  ) -> MapperTuning {
    MapperTuning(
      fixMaxAgeSeconds: fixMaxAge,
      fixMaxAccuracyMeters: fixMaxAccuracy,
      flushIntervalSeconds: flushInterval,
      flushEntryCount: flushEntryCount
    )
  }

  private func makeEngine(
    source: ScriptedRxEntrySource,
    txHeard: ScriptedTxHeardSource? = nil,
    acks: ScriptedAckSource? = nil,
    store: PersistenceStore,
    fixes: StubMapperFixProvider,
    clock: TestClock,
    tuning: MapperTuning
  ) -> SignalMapperCaptureEngine {
    SignalMapperCaptureEngine(
      source: source,
      txHeardSource: txHeard,
      ackSource: acks,
      store: store,
      fixProvider: fixes,
      tuningProvider: StaticMapperTuningProvider(tuning),
      // Pinned so the suite never touches `UserDefaults.standard` for the real per-install
      // seed, and so any disc these tests do raise is reproducible.
      anchorSeedProvider: StaticMapperAnchorSeedProvider(),
      now: clock.provider
    )
  }

  // MARK: - (a) Good fix → right cell, right UTC day

  @Test
  func `An entry with a usable fix lands in the res-9 cell and UTC day of that fix`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000)) // 2025-07-20 UTC
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now, snr: 6, rssi: -80))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let rows = try await store.fetchMapperCellObservations()
    let expectedCell = try #require(MapperFixtureLocation.cell(MapperFixtureLocation.plaza))
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.cellRaw == expectedCell.rawValue)
    #expect(row.cell?.resolution == SurveyGrid.baseResolution)
    #expect(row.day == MapperDayKey.key(for: clock.now))
    #expect(row.packetCount == 1)
    #expect(row.passivePacketCount == 1)
    #expect(row.activePacketCount == 0, "M0 capture is passive; nothing is an active probe")
    #expect(row.floodCount == 1)
    #expect(row.snrSum == 6)
    #expect(row.snrCount == 1)
    #expect(row.rssiSum == -80)
    #expect(row.rxCount == 1)
    #expect(row.txHeardCount == 0)
    #expect(row.ackCount == 0)
  }

  @Test
  func `Two entries a few meters apart fold into one cell, a distant one opens a second`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))

    fixes.set(mapperFix(MapperFixtureLocation.plazaNudged, at: clock.now))
    source.send(mapperRxEntry(payload: Data([0x02]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 2))

    fixes.set(mapperFix(MapperFixtureLocation.acrossTown, at: clock.now))
    source.send(mapperRxEntry(payload: Data([0x03]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 3))

    await engine.flushNow()
    await engine.stop()

    let rows = try await store.fetchMapperCellObservations()
    #expect(rows.count == 2)
    let plazaCell = try #require(MapperFixtureLocation.cell(MapperFixtureLocation.plaza))
    let plazaRow = try #require(rows.first { $0.cellRaw == plazaCell.rawValue })
    #expect(plazaRow.packetCount == 2, "the nudged fix is the same res-9 cell")
    let distantCell = try #require(MapperFixtureLocation.cell(MapperFixtureLocation.acrossTown))
    #expect(rows.contains { $0.cellRaw == distantCell.rawValue })
  }

  @Test
  func `Repeater sightings carry the packet's SNR on the hop we heard directly`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    source.send(mapperRxEntry(
      payload: Data([0x01]),
      receivedAt: clock.now,
      snr: 4,
      rssi: -95,
      pathNodes: [0x0C, 0x42]
    ))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(Set(row.repeaters.keys) == ["0C", "42"], "hex identity comes from NodeHexID")
    let firstHop = try #require(row.repeaters["0C"])
    #expect(firstHop.rxSnrCount == 0, "an upstream hop was heard by someone else, not by us")
    #expect(firstHop.rxPacketCount == 1)
    let lastHop = try #require(row.repeaters["42"])
    #expect(lastHop.rxSnrCount == 1)
    #expect(lastHop.rxSnrSum == 4)
    #expect(lastHop.rssiSum == -95)
    #expect(row.hopHistogram == [2: 1])
  }

  // MARK: - (a2) TX-heard: our own packet, rebroadcast

  @Test
  func `A heard repeat folds as a txHeard observation, not as an rx one`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let repeats = ScriptedTxHeardSource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      source: source, txHeard: repeats, store: store, fixes: fixes, clock: clock, tuning: makeTuning()
    )

    await engine.start()
    repeats.send(mapperHeardRepeat(receivedAt: clock.now, snr: 7, rssi: -75))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(row.txHeardCount == 1)
    #expect(row.rxCount == 0)
    #expect(row.ackCount == 0)
    #expect(row.packetCount == 1, "an echo is a packet we measured")
    #expect(row.floodCount == 1)
    #expect(row.snrSum == 7)
    #expect(await engine.snapshot().txHeardSampleCount == 1)
  }

  @Test
  func `A heard repeat's SNR is the repeater's rxSnr, never its txSnr`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let repeats = ScriptedTxHeardSource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      source: source, txHeard: repeats, store: store, fixes: fixes, clock: clock, tuning: makeTuning()
    )

    await engine.start()
    repeats.send(mapperHeardRepeat(
      receivedAt: clock.now,
      snr: 3,
      rssi: -90,
      pathNodes: [0x0C, 0x42]
    ))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(row.txSnrCount == 0, "txSnr means the repeater told us how well it heard us")
    let rebroadcaster = try #require(row.repeaters["42"])
    #expect(rebroadcaster.rxSnrCount == 1)
    #expect(rebroadcaster.rxSnrSum == 3)
    #expect(rebroadcaster.rssiSum == -90)
    #expect(rebroadcaster.txSnrCount == 0)
    let upstream = try #require(row.repeaters["0C"])
    #expect(upstream.rxSnrCount == 0, "an earlier hop was heard by someone else, not by us")
    #expect(row.hopHistogram == [2: 1])
  }

  @Test
  func `A heard repeat with no usable fix is dropped like any other observation`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let repeats = ScriptedTxHeardSource()
    let engine = makeEngine(
      source: source, txHeard: repeats, store: store,
      fixes: StubMapperFixProvider(nil), clock: clock, tuning: makeTuning()
    )

    await engine.start()
    repeats.send(mapperHeardRepeat(receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let snapshot = await engine.snapshot()
    #expect(snapshot.txHeardSampleCount == 0)
    #expect(snapshot.droppedNoFixCount == 1)
    #expect(try await store.countMapperCellObservations() == 0)
  }

  @Test
  func `An RX packet and a heard repeat in one cell-day keep their directions apart`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let repeats = ScriptedTxHeardSource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      source: source, txHeard: repeats, store: store, fixes: fixes, clock: clock, tuning: makeTuning()
    )

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    repeats.send(mapperHeardRepeat(receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 2))
    await engine.flushNow()
    await engine.stop()

    let rows = try await store.fetchMapperCellObservations()
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.rxCount == 1)
    #expect(row.txHeardCount == 1)
    #expect(row.packetCount == 2)
    #expect(row.observationCount == 2)
  }

  // MARK: - (a3) ACK: a send from here completed

  @Test
  func `A delivered ACK folds with its round-trip time and no packet`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let acks = ScriptedAckSource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      source: source, acks: acks, store: store, fixes: fixes, clock: clock, tuning: makeTuning()
    )

    await engine.start()
    acks.send(.statusResolved(messageID: UUID(), status: .delivered, roundTripTime: 842))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(row.ackCount == 1)
    #expect(row.rttSampleCount == 1)
    #expect(row.rttMsSum == 842)
    #expect(row.avgRttMs == 842)
    #expect(row.packetCount == 0, "an ACK is not a packet and folds no radio measurement")
    #expect(row.floodCount == 0)
    #expect(row.directCount == 0)
    #expect(row.snrCount == 0)
    #expect(row.earliest == clock.now, "the row still spans when the ACK landed")
    #expect(await engine.snapshot().ackSampleCount == 1)
  }

  @Test
  func `A delivered ACK without a round-trip time still counts as coverage`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let acks = ScriptedAckSource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      source: source, acks: acks, store: store, fixes: fixes, clock: clock, tuning: makeTuning()
    )

    await engine.start()
    acks.send(.statusResolved(messageID: UUID(), status: .delivered, roundTripTime: nil))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(row.ackCount == 1)
    #expect(row.rttSampleCount == 0)
    #expect(row.avgRttMs == nil)
  }

  @Test
  func `Only delivered resolutions are ACKs; sent, failed and the rest are ignored`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let acks = ScriptedAckSource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      source: source, acks: acks, store: store, fixes: fixes, clock: clock, tuning: makeTuning()
    )

    await engine.start()
    acks.send(.statusResolved(messageID: UUID(), status: .sent, roundTripTime: nil))
    acks.send(.resent(messageID: UUID()))
    acks.send(.failed(messageID: UUID()))
    acks.send(.retrying(messageID: UUID(), attempt: 1, maxAttempts: 3))
    acks.send(.routingChanged(contactID: UUID(), isFlood: true))
    // A delivered one behind them all, so the assertion below waits on something that
    // definitely arrives rather than on the absence of an event.
    acks.send(.statusResolved(messageID: UUID(), status: .delivered, roundTripTime: 100))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let snapshot = await engine.snapshot()
    #expect(snapshot.ackSampleCount == 1)
    #expect(snapshot.sampleCount == 1)
    #expect(snapshot.droppedCount == 0, "a status that is not an ACK is not a dropped observation")
    #expect(try await store.fetchMapperCellObservations().first?.ackCount == 1)
  }

  @Test
  func `An ACK with no usable fix is dropped rather than placed on a guess`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let acks = ScriptedAckSource()
    let stale = mapperFix(at: clock.now.addingTimeInterval(-121))
    let engine = makeEngine(
      source: source, acks: acks, store: store,
      fixes: StubMapperFixProvider(stale), clock: clock, tuning: makeTuning()
    )

    await engine.start()
    acks.send(.statusResolved(messageID: UUID(), status: .delivered, roundTripTime: 500))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let snapshot = await engine.snapshot()
    #expect(snapshot.ackSampleCount == 0)
    #expect(snapshot.droppedStaleFixCount == 1)
    #expect(try await store.countMapperCellObservations() == 0)
  }

  @Test
  func `An ACK is tagged where the phone stands when it resolves, not where the send left`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let acks = ScriptedAckSource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      source: source, acks: acks, store: store, fixes: fixes, clock: clock, tuning: makeTuning()
    )

    await engine.start()
    // The phone moves between the send and the ACK; only the ACK's own moment is observed.
    fixes.set(mapperFix(MapperFixtureLocation.acrossTown, at: clock.now))
    acks.send(.statusResolved(messageID: UUID(), status: .delivered, roundTripTime: 300))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let row = try #require(try await store.fetchMapperCellObservations().first)
    let expected = try #require(MapperFixtureLocation.cell(MapperFixtureLocation.acrossTown))
    #expect(row.cellRaw == expected.rawValue)
  }

  // MARK: - (b) Unusable fixes are dropped, never guessed

  @Test
  func `No fix at all drops the observation`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let engine = makeEngine(
      source: source, store: store, fixes: StubMapperFixProvider(nil), clock: clock, tuning: makeTuning()
    )

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let snapshot = await engine.snapshot()
    #expect(snapshot.sampleCount == 0)
    #expect(snapshot.droppedNoFixCount == 1)
    #expect(try await store.countMapperCellObservations() == 0)
  }

  @Test
  func `A fix older than fixMaxAge drops the observation`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let stale = mapperFix(at: clock.now.addingTimeInterval(-121))
    let engine = makeEngine(
      source: source, store: store, fixes: StubMapperFixProvider(stale), clock: clock, tuning: makeTuning()
    )

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.stop()

    let snapshot = await engine.snapshot()
    #expect(snapshot.sampleCount == 0)
    #expect(snapshot.droppedStaleFixCount == 1)
    #expect(try await store.countMapperCellObservations() == 0)
  }

  @Test
  func `A fix worse than fixMaxAccuracy drops the observation`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let vague = mapperFix(accuracy: 150, at: clock.now)
    let engine = makeEngine(
      source: source, store: store, fixes: StubMapperFixProvider(vague), clock: clock, tuning: makeTuning()
    )

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.stop()

    let snapshot = await engine.snapshot()
    #expect(snapshot.sampleCount == 0)
    #expect(snapshot.droppedInaccurateFixCount == 1)
    #expect(try await store.countMapperCellObservations() == 0)
  }

  @Test
  func `A negative accuracy is treated as no fix, not as perfect accuracy`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let invalid = mapperFix(accuracy: -1, at: clock.now)
    let engine = makeEngine(
      source: source, store: store, fixes: StubMapperFixProvider(invalid), clock: clock, tuning: makeTuning()
    )

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.stop()

    #expect(await engine.snapshot().droppedInaccurateFixCount == 1)
    #expect(try await store.countMapperCellObservations() == 0)
  }

  @Test
  func `A fix going stale mid-session stops capture without disturbing what was captured`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()

    // The phone stops updating its fix and time passes it by.
    clock.advance(300)
    source.send(mapperRxEntry(payload: Data([0x02]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 2))
    await engine.flushNow()
    await engine.stop()

    let rows = try await store.fetchMapperCellObservations()
    #expect(rows.count == 1)
    #expect(rows.first?.packetCount == 1, "the stale-fix packet must not join the earlier cell")
    #expect(await engine.snapshot().droppedStaleFixCount == 1)
  }

  // MARK: - (c) Day rollover

  @Test
  func `Packets either side of UTC midnight split into two rows for the same cell`() async throws {
    // 2025-07-20 23:59:00 UTC.
    let beforeMidnight = Date(timeIntervalSince1970: 1_753_055_940)
    let clock = TestClock(beforeMidnight)
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))

    clock.advance(120) // over midnight
    fixes.set(mapperFix(at: clock.now))
    source.send(mapperRxEntry(payload: Data([0x02]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 2))

    await engine.flushNow()
    await engine.stop()

    let rows = try await store.fetchMapperCellObservations()
    let cell = try #require(MapperFixtureLocation.cell(MapperFixtureLocation.plaza))
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.cellRaw == cell.rawValue }, "same place, different day")
    #expect(Set(rows.map(\.day)) == ["2025-07-20", "2025-07-21"])
    #expect(rows.allSatisfy { $0.packetCount == 1 })
  }

  // MARK: - (d) Flush upserts merge

  @Test
  func `A second flush of the same cell-day adds to the stored row instead of duplicating it`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now, snr: 4, rssi: -70))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()

    source.send(mapperRxEntry(payload: Data([0x02]), receivedAt: clock.now, snr: 10, rssi: -60))
    #expect(await waitForMapperAccounted(engine, count: 2))
    await engine.flushNow()
    await engine.stop()

    let rows = try await store.fetchMapperCellObservations()
    #expect(rows.count == 1, "one (cell, day) is one row no matter how many flushes touched it")
    let row = try #require(rows.first)
    #expect(row.packetCount == 2)
    #expect(row.snrCount == 2)
    #expect(row.snrSum == 14)
    #expect(row.minSnr == 4)
    #expect(row.maxSnr == 10)
    #expect(row.rssiSum == -130)
    #expect(row.repeaters["42"]?.rxPacketCount == 2)
  }

  @Test
  func `Buffered entries reach the store when the count threshold trips, without a manual flush`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      source: source, store: store, fixes: fixes, clock: clock,
      tuning: makeTuning(flushEntryCount: 3)
    )

    await engine.start()
    for byte in UInt8(1)...3 {
      source.send(mapperRxEntry(payload: Data([byte]), receivedAt: clock.now))
    }
    #expect(await waitForMapperAccounted(engine, count: 3))
    #expect(await waitForMapper { await (try? store.countMapperCellObservations()) == 1 })
    await engine.stop()

    #expect(await engine.snapshot().pendingCellCount == 0)
    #expect(try await store.fetchMapperCellObservations().first?.packetCount == 3)
  }

  @Test
  func `stop() writes out the tail of a session`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.stop()

    #expect(try await store.countMapperCellObservations() == 1)
    #expect(await engine.snapshot().isRunning == false)
  }

  // MARK: - (e) Dedup

  @Test
  func `The same packetHash is folded once per session`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    let entry = mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now)
    source.send(entry)
    // Same payload → same packetHash, but a distinct row id, exactly as a re-decryption
    // pass or a second path would surface it.
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 2))
    await engine.flushNow()
    await engine.stop()

    let snapshot = await engine.snapshot()
    #expect(snapshot.sampleCount == 1)
    #expect(snapshot.duplicateCount == 1)
    #expect(try await store.fetchMapperCellObservations().first?.packetCount == 1)
    #expect(entry.packetHash == mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now).packetHash)
  }

  @Test
  func `A restarted session re-counts a packet the previous one had seen`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.stop()

    // A new subscription is created on restart, so the scripted source needs a fresh one
    // too — this mirrors the per-connection `RxLogService` the app wires.
    let secondSource = ScriptedRxEntrySource()
    let restarted = makeEngine(
      source: secondSource, store: store, fixes: fixes, clock: clock, tuning: makeTuning()
    )
    await restarted.start()
    secondSource.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(restarted, count: 1))
    await restarted.stop()

    let rows = try await store.fetchMapperCellObservations()
    #expect(rows.count == 1)
    #expect(rows.first?.packetCount == 2, "dedup memory is session-scoped, not permanent")
  }

  // MARK: - (f) deleteAll

  @Test
  func `deleteAll empties the store`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()
    #expect(try await store.countMapperCellObservations() == 1)

    try await store.deleteAllMapperCellObservations()

    #expect(try await store.countMapperCellObservations() == 0)
    #expect(try await store.fetchMapperCellObservations().isEmpty)
  }

  // MARK: - Capture gate

  @Test
  func `An engine that was never started ignores entries`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    try? await Task.sleep(for: .milliseconds(50))

    let snapshot = await engine.snapshot()
    #expect(snapshot.isRunning == false)
    #expect(snapshot.sampleCount == 0)
    #expect(try await store.countMapperCellObservations() == 0)
  }

  // MARK: - Active samples (M3)

  @Test
  func `Trace packets do not fold on the passive path`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    // A trace reply's path bytes are per-hop SNR readings; folded as a route they would
    // mint repeater IDs out of signal levels. The engine must refuse the whole entry.
    let trace = SignalBarsFixtures.traceReply(tag: 0xBEEF, localSnr: 5.0, remoteSnrX4: 12)
    source.send(RxLogEntryDTO(radioID: UUID(), receivedAt: clock.now, from: trace))
    // A normal packet behind it proves the stream itself is being consumed.
    source.send(mapperRxEntry(payload: Data([0x01]), receivedAt: clock.now))
    #expect(await waitForMapperAccounted(engine, count: 1))
    await engine.flushNow()
    await engine.stop()

    let rows = try await store.fetchMapperCellObservations()
    #expect(rows.count == 1)
    #expect(rows.first?.packetCount == 1)
    #expect(rows.first?.activePacketCount == 0)
    #expect(rows.first?.repeaters.keys.contains("42") == true)
    #expect(rows.first?.repeaters.count == 1)
  }

  @Test
  func `A probe result folds as an active rx sample with the TX leg attached`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    let repeater = try #require(NodeHexID(data: Data([0xAB])))
    await engine.ingestProbeResult(MapperProbeResult(
      repeaterID: repeater,
      rxSnr: 5.0,
      txSnr: 3.0,
      rssi: -75,
      hopCount: 1,
      at: clock.now
    ))
    await engine.flushNow()
    await engine.stop()

    let snapshot = await engine.snapshot()
    #expect(snapshot.activeSampleCount == 1)
    #expect(snapshot.rxSampleCount == 1)

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(row.activePacketCount == 1)
    #expect(row.rxCount == 1)
    #expect(row.txSnrSum == 3.0)
    #expect(row.txSnrCount == 1)
    let stats = try #require(row.repeaters["AB"])
    #expect(stats.txSnrSum == 3.0)
    #expect(stats.txSnrCount == 1)
  }

  @Test
  func `A probe result is gated by the fix policy like any packet`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let store = try makeStore()
    let source = ScriptedRxEntrySource()
    let fixes = StubMapperFixProvider(nil)
    let engine = makeEngine(source: source, store: store, fixes: fixes, clock: clock, tuning: makeTuning())

    await engine.start()
    await engine.ingestProbeResult(MapperProbeResult(
      repeaterID: nil, rxSnr: 5.0, txSnr: nil, rssi: nil, hopCount: 1, at: clock.now
    ))
    await engine.flushNow()
    await engine.stop()

    let snapshot = await engine.snapshot()
    #expect(snapshot.activeSampleCount == 0)
    #expect(snapshot.droppedNoFixCount == 1)
    #expect(try await store.countMapperCellObservations() == 0)
  }
}
