import Foundation
@testable import MC1Services
import MeshCore
import SurveyKit
import Testing

/// The manual-mode survey engine (M3): probe discipline, reply correlation, and the
/// no-flood rule.
///
/// The session loop is parked by injecting a sleep that never wakes inside the test
/// budget; each test steps the engine with `tick()` and feeds events through `ingest`,
/// so every probe decision is driven by the test's own clock.
@Suite("SignalMapperProbeEngine")
struct SignalMapperProbeEngineTests {
  private static let parkedSleep: @Sendable (Duration) async -> Void = { _ in
    try? await Task.sleep(for: .seconds(3600))
  }

  /// A sink that records what folds, standing in for the capture engine.
  private actor RecordingSink: MapperActiveSampleSink {
    private(set) var results: [MapperProbeResult] = []

    func ingestProbeResult(_ result: MapperProbeResult) async {
      results.append(result)
    }
  }

  private struct StubTargetSource: MapperProbeTargetSource {
    let targets: [MapperProbeTarget]

    func probeTargets() async -> [MapperProbeTarget] {
      targets
    }
  }

  private func makeTuning(
    probeInterval: TimeInterval = 10,
    probeBurst: Int = 3,
    freshnessDays: Int = 7
  ) -> MapperTuning {
    MapperTuning(
      probeIntervalSeconds: probeInterval,
      probeBurst: probeBurst,
      communityFreshnessDays: freshnessDays
    )
  }

  private func makeTarget(prefix: [UInt8] = [0xAB]) throws -> MapperProbeTarget {
    let key = SignalBarsFixtures.publicKey(prefix)
    let id = try #require(NodeHexID(data: key.prefix(1)))
    return MapperProbeTarget(id: id, publicKey: key, lastHeard: nil)
  }

  private func makeEngine(
    session: MockSignalBarsSession,
    sink: RecordingSink,
    warmTargets: [MapperProbeTarget] = [],
    store: PersistenceStore? = nil,
    fixes: StubMapperFixProvider,
    clock: TestClock,
    tuning: MapperTuning
  ) -> SignalMapperProbeEngine {
    SignalMapperProbeEngine(
      session: session,
      sink: sink,
      warmTargets: warmTargets.isEmpty ? nil : StubTargetSource(targets: warmTargets),
      store: store,
      fixProvider: fixes,
      tuningProvider: StaticMapperTuningProvider(tuning),
      now: clock.provider,
      sleep: Self.parkedSleep
    )
  }

  // MARK: - Probe cycle

  @Test
  func `A probe cycle sends a zero-hop discover and a directed trace to a known target`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let session = MockSignalBarsSession()
    let sink = RecordingSink()
    let target = try makeTarget()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      session: session, sink: sink, warmTargets: [target], fixes: fixes, clock: clock,
      tuning: makeTuning()
    )

    await engine.startSession(pathHashMode: 0)
    await engine.tick()

    let discovers = await session.discoverRequests
    #expect(discovers.count == 1)
    #expect(discovers.first?.prefixOnly == true)
    let traces = await session.traces
    #expect(traces.count == 1)
    // A zero-mode trace is addressed with the key's leading byte — a source route, never
    // a flood.
    #expect(traces.first?.path == target.publicKey.prefix(1))
    #expect(traces.first?.flags == 0)

    let snapshot = await engine.snapshot()
    #expect(snapshot.probesSent == 1)
    #expect(snapshot.discoversSent == 1)
    #expect(snapshot.tracesSent == 1)
    #expect(snapshot.cellsProbed == 1)
    await engine.stopSession()
  }

  @Test
  func `Without a target the cycle still discovers, and never traces blind`() async {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let session = MockSignalBarsSession()
    let sink = RecordingSink()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      session: session, sink: sink, fixes: fixes, clock: clock, tuning: makeTuning()
    )

    await engine.startSession(pathHashMode: 0)
    await engine.tick()

    #expect(await session.discoverRequests.count == 1)
    #expect(await session.traces.isEmpty)
    await engine.stopSession()
  }

  @Test
  func `A tick with no usable fix transmits nothing`() async {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let session = MockSignalBarsSession()
    let sink = RecordingSink()
    let engine = makeEngine(
      session: session, sink: sink, fixes: StubMapperFixProvider(nil), clock: clock,
      tuning: makeTuning()
    )

    await engine.startSession(pathHashMode: 0)
    await engine.tick()

    #expect(await session.discoverRequests.isEmpty)
    #expect(await session.traces.isEmpty)
    #expect(await engine.snapshot().skippedNoFixCount == 1)
    await engine.stopSession()
  }

  // MARK: - Replies

  @Test
  func `A discover response folds both link legs and becomes a traceable target`() async {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let session = MockSignalBarsSession()
    let sink = RecordingSink()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      session: session, sink: sink, fixes: fixes, clock: clock, tuning: makeTuning()
    )

    await engine.startSession(pathHashMode: 0)
    await engine.tick()

    let key = SignalBarsFixtures.publicKey([0xCD])
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: key, snr: 6.0, snrIn: 3.0, rssi: -70
    )))

    let results = await sink.results
    #expect(results.count == 1)
    #expect(results.first?.rxSnr == 6.0)
    #expect(results.first?.txSnr == 3.0)
    #expect(results.first?.rssi == -70)
    #expect(results.first?.repeaterID?.hex == "CD")

    // The response's key is now a target: the next novel cell gets a directed trace.
    fixes.set(mapperFix(MapperFixtureLocation.acrossTown, at: clock.now))
    clock.advance(30)
    await engine.tick()
    let traces = await session.traces
    #expect(traces.count == 1)
    #expect(traces.first?.path == key.prefix(1))
    await engine.stopSession()
  }

  @Test
  func `A trace reply is claimed by tag and folds with the repeater's reading of us`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let session = MockSignalBarsSession()
    let sink = RecordingSink()
    let target = try makeTarget()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      session: session, sink: sink, warmTargets: [target], fixes: fixes, clock: clock,
      tuning: makeTuning()
    )

    await engine.startSession(pathHashMode: 0)
    await engine.tick()
    let tag = try #require(await session.traces.first?.tag)

    await engine.ingest(.rxLogData(SignalBarsFixtures.traceReply(
      tag: tag, localSnr: 5.0, remoteSnrX4: 12
    )))

    let results = await sink.results
    #expect(results.count == 1)
    #expect(results.first?.repeaterID == target.id)
    #expect(results.first?.rxSnr == 5.0)
    #expect(results.first?.txSnr == 3.0)

    let snapshot = await engine.snapshot()
    #expect(snapshot.traceRepliesHeard == 1)
    #expect(snapshot.probesLost == 0)

    // The same tag again is not ours any more: nothing folds twice.
    await engine.ingest(.rxLogData(SignalBarsFixtures.traceReply(tag: tag)))
    #expect(await sink.results.count == 1)
    await engine.stopSession()
  }

  @Test
  func `A reply that never comes is written off as lost, not left outstanding`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let session = MockSignalBarsSession()
    let sink = RecordingSink()
    let target = try makeTarget()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      session: session, sink: sink, warmTargets: [target], fixes: fixes, clock: clock,
      tuning: makeTuning()
    )

    await engine.startSession(pathHashMode: 0)
    await engine.tick()
    #expect(await session.traces.count == 1)

    // Past the suggested timeout, the sweep on the next tick writes the probe off.
    clock.advance(30)
    await engine.tick()
    #expect(await engine.snapshot().probesLost == 1)
    await engine.stopSession()
  }

  // MARK: - Budget

  @Test
  func `The token bucket refuses a cycle once the burst is spent`() async {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let session = MockSignalBarsSession()
    let sink = RecordingSink()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    // Burst of 1: capacity covers exactly one cycle, refilling one cycle per 10 s.
    let engine = makeEngine(
      session: session, sink: sink, fixes: fixes, clock: clock,
      tuning: makeTuning(probeInterval: 10, probeBurst: 1)
    )

    await engine.startSession(pathHashMode: 0)
    await engine.tick()
    #expect(await engine.snapshot().probesSent == 1)

    // A brand-new cell moments later: novel, but the bucket is empty.
    fixes.set(mapperFix(MapperFixtureLocation.acrossTown, at: clock.now))
    clock.advance(6)
    await engine.tick()
    #expect(await engine.snapshot().probesSent == 1)

    // Once the refill has restored a cycle's worth, the same cell probes.
    clock.advance(10)
    await engine.tick()
    #expect(await engine.snapshot().probesSent == 2)
    await engine.stopSession()
  }

  @Test
  func `A probed cell does not probe again, and the spot check may spend the reserve`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let session = MockSignalBarsSession()
    let sink = RecordingSink()
    let target = try makeTarget()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      session: session, sink: sink, warmTargets: [target], fixes: fixes, clock: clock,
      tuning: makeTuning()
    )

    await engine.startSession(pathHashMode: 0)
    await engine.tick()
    let tag = try #require(await session.traces.first?.tag)
    await engine.ingest(.rxLogData(SignalBarsFixtures.traceReply(tag: tag)))

    // Sampled now: hours of standing here trigger nothing further automatically.
    clock.advance(120)
    await engine.tick()
    #expect(await engine.snapshot().probesSent == 1)

    // The user's own spot check is exempt from novelty — same cell, another cycle.
    await engine.spotCheck()
    #expect(await engine.snapshot().probesSent == 2)
    await engine.stopSession()
  }

  @Test
  func `Fresh local coverage is skipped instead of probed`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let session = MockSignalBarsSession()
    let sink = RecordingSink()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)

    // Yesterday's coverage for the very cell the session starts in.
    let cell = try #require(MapperFixtureLocation.cell(MapperFixtureLocation.plaza))
    var aggregate = AggregatedCell(cell: cell)
    CellAggregator.fold(
      SurveySample(
        timestamp: clock.now.addingTimeInterval(-86400),
        coordinate: GeoCoordinate(
          latitude: MapperFixtureLocation.plaza.latitude,
          longitude: MapperFixtureLocation.plaza.longitude
        ),
        snr: 5,
        route: .direct,
        isActiveProbe: false
      ),
      into: &aggregate
    )
    try await store.upsertMapperCellObservations([MapperCellObservationDTO(
      day: MapperDayKey.key(for: clock.now.addingTimeInterval(-86400)),
      aggregate: aggregate,
      rxCount: 1,
      txHeardCount: 0,
      ackCount: 0,
      stationaryObservationCount: 0,
      rttMsSum: 0,
      rttSampleCount: 0
    )])

    let engine = makeEngine(
      session: session, sink: sink, store: store, fixes: fixes, clock: clock,
      tuning: makeTuning()
    )
    await engine.startSession(pathHashMode: 0)
    await engine.tick()

    #expect(await session.discoverRequests.isEmpty)
    #expect(await session.traces.isEmpty)
    #expect(await engine.snapshot().probesSent == 0)
    await engine.stopSession()
  }

  // MARK: - The no-flood rule

  @Test
  func `The policy configuration pins the flood quota to zero whatever the tuning says`() {
    let config = SignalMapperProbeEngine.policyConfig(from: MapperTuning())
    #expect(config.floodsPerTierCell == 0)

    let extreme = SignalMapperProbeEngine.policyConfig(
      from: MapperTuning(probeIntervalSeconds: 1, probeBurst: 10)
    )
    #expect(extreme.floodsPerTierCell == 0)
  }

  // MARK: - Session lifecycle

  @Test
  func `Stopping a session writes off outstanding probes and freezes the counters`() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_753_000_000))
    let session = MockSignalBarsSession()
    let sink = RecordingSink()
    let target = try makeTarget()
    let fixes = StubMapperFixProvider(mapperFix(at: clock.now))
    let engine = makeEngine(
      session: session, sink: sink, warmTargets: [target], fixes: fixes, clock: clock,
      tuning: makeTuning()
    )

    await engine.startSession(pathHashMode: 0)
    await engine.tick()

    let summary = await engine.stopSession()
    #expect(summary.isRunning == false)
    #expect(summary.probesSent == 1)
    #expect(summary.probesLost == 1)

    // A stopped session ignores stragglers.
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0xEF])
    )))
    #expect(await sink.results.isEmpty)
  }
}
