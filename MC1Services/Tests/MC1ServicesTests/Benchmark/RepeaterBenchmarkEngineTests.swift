import Foundation
@testable import MC1Services
import MeshCore
import Testing

@Suite("Repeater benchmark engine")
struct RepeaterBenchmarkEngineTests {
  private let tower = benchmarkTarget("Tower", prefix: [0x0A])
  private let ridge = benchmarkTarget("Ridge", prefix: [0x0C])
  private let barn = benchmarkTarget("Barn", prefix: [0x1F])

  private func makeEngine(
    session: MockBenchmarkSession,
    sleeper: GatedSleeper,
    tags: TagSequence,
    clock: TestClock,
    traceHashSize: Int = 1,
    traceFlags: UInt8 = 0,
    makeTag: (@Sendable () -> UInt32)? = nil
  ) -> RepeaterBenchmarkEngine {
    RepeaterBenchmarkEngine(
      session: session,
      configuration: RepeaterBenchmarkEngine.Configuration(
        traceHashSize: traceHashSize,
        traceFlags: traceFlags,
        localNodeName: "My Radio"
      ),
      now: clock.provider,
      sleep: sleeper.provider,
      makeTag: makeTag ?? tags.provider
    )
  }

  // MARK: - Plan

  @Test
  func `A repeater cannot be its own target`() async {
    let engine = makeEngine(
      session: MockBenchmarkSession(),
      sleeper: GatedSleeper(),
      tags: TagSequence(),
      clock: TestClock()
    )

    await engine.setTargets([ridge, barn])
    await engine.setTestRepeater(ridge)

    let plan = await engine.currentPlan()
    #expect(plan.targets.map(\.name) == ["Barn"])

    await engine.toggleTarget(ridge)
    #expect(await engine.currentPlan().targets.map(\.name) == ["Barn"])
  }

  @Test
  func `Batch size snaps to an offered option`() async {
    let engine = makeEngine(
      session: MockBenchmarkSession(),
      sleeper: GatedSleeper(),
      tags: TagSequence(),
      clock: TestClock()
    )

    await engine.setTracesPerTarget(7)
    #expect(await RepeaterBenchmarkPolicy.traceCountOptions.contains(engine.currentPlan().tracesPerTarget))

    await engine.setTracesPerTarget(3)
    #expect(await engine.currentPlan().tracesPerTarget == 3)
  }

  @Test
  func `An unrunnable plan does nothing`() async {
    let session = MockBenchmarkSession()
    let engine = makeEngine(
      session: session,
      sleeper: GatedSleeper(),
      tags: TagSequence(),
      clock: TestClock()
    )

    await engine.setTestRepeater(tower)
    await engine.run()

    #expect(await session.traceCount == 0)
  }

  // MARK: - Sequencing

  @Test
  func `Each target is probed the configured number of times, in order`() async throws {
    let session = MockBenchmarkSession()
    let sleeper = GatedSleeper()
    let engine = makeEngine(
      session: session,
      sleeper: sleeper,
      tags: TagSequence(),
      clock: TestClock()
    )

    await engine.setTestRepeater(tower)
    await engine.setTargets([ridge, barn])
    await engine.setTracesPerTarget(3)

    let run = Task { await engine.run() }
    // Every probe times out, which is the fastest way to walk the whole sequence.
    try await waitForBenchmarkCondition("run did not finish") {
      await sleeper.releaseAll()
      return await session.traceCount == 6
    }
    await run.value

    // Path is test → target → test, one byte per hop at pathHashMode 0.
    let paths = await session.traces.map(\.path)
    #expect(paths.count == 6)
    #expect(paths.prefix(3) == ArraySlice(repeatElement(Data([0x0A, 0x0C, 0x0A]), count: 3)))
    #expect(paths.suffix(3) == ArraySlice(repeatElement(Data([0x0A, 0x1F, 0x0A]), count: 3)))

    let snapshot = await engine.currentSnapshot()
    let allComplete = snapshot.results.allSatisfy(\.isComplete)
    let outcomeCounts = snapshot.results.map(\.outcomes.count)
    let failures = snapshot.results.flatMap { $0.outcomes.map(\.failure) }

    #expect(snapshot.results.count == 2)
    #expect(allComplete)
    #expect(outcomeCounts == [3, 3])
    #expect(failures.allSatisfy { $0 == .timeout })
    #expect(!snapshot.isRunning)

    await engine.shutdown()
    await sleeper.releaseAll()
  }

  @Test
  func `Path hops widen with the trace hash size`() async throws {
    let session = MockBenchmarkSession()
    let sleeper = GatedSleeper()
    let engine = makeEngine(
      session: session,
      sleeper: sleeper,
      tags: TagSequence(),
      clock: TestClock(),
      traceHashSize: 2,
      traceFlags: 1
    )

    await engine.setTestRepeater(tower)
    await engine.setTargets([ridge])
    await engine.setTracesPerTarget(1)

    let run = Task { await engine.run() }
    try await waitForBenchmarkCondition("probe not sent") {
      await sleeper.releaseAll()
      return await session.traceCount == 1
    }
    await run.value

    let trace = try #require(await session.traces.first)
    #expect(trace.flags == 1)
    #expect(trace.path == Data([0x0A, 0xEE, 0x0C, 0xEE, 0x0A, 0xEE]))

    await engine.shutdown()
    await sleeper.releaseAll()
  }

  // MARK: - Replies

  @Test
  func `A reply is correlated by tag and becomes a measured outcome`() async throws {
    let session = MockBenchmarkSession()
    let sleeper = GatedSleeper()
    let clock = TestClock()
    let engine = makeEngine(session: session, sleeper: sleeper, tags: TagSequence(), clock: clock)

    await engine.setTestRepeater(tower)
    await engine.setTargets([ridge])
    await engine.setTracesPerTarget(1)

    let run = Task { await engine.run() }
    try await waitForBenchmarkCondition("probe not sent") { await session.traceCount == 1 }

    clock.advance(0.25)
    // A reply carrying another probe's tag must not resolve this one.
    await engine.ingest(.traceData(BenchmarkFixtures.reply(tag: 999, hops: [(0x0A, 1)])))
    await engine.ingest(.traceData(BenchmarkFixtures.reply(
      tag: 1,
      hops: [(0x0A, 9.0), (0x0C, 4.0), (0x0A, 6.0)]
    )))
    await run.value

    let result = try #require(await engine.currentSnapshot().results.first)
    let outcome = try #require(result.outcomes.first)

    #expect(outcome.success)
    #expect(outcome.durationMs == 250)
    #expect(outcome.intermediateSNRs == [9, 4, 6])
    #expect(result.txSNR == 4)
    #expect(result.rxSNR == 6)
    // Endpoints are this radio; the middle hops resolve from the plan's own participants.
    #expect(outcome.hops.map(\.label) == ["My Radio", "Tower", "Ridge", "Tower", "My Radio"])

    await engine.shutdown()
    await sleeper.releaseAll()
  }

  @Test
  func `A reply that lands before the sender waits for it is not lost`() async throws {
    let session = MockBenchmarkSession()
    let sleeper = GatedSleeper()
    let engine = makeEngine(session: session, sleeper: sleeper, tags: TagSequence(), clock: TestClock())

    // Answered while the send is still in flight, so the reply is buffered before the probe
    // installs its waiter — the case `earlyReplies` exists for.
    await session.setOnSend { [weak engine] tag in
      guard let engine, let tag else { return }
      await engine.ingest(.traceData(BenchmarkFixtures.reply(
        tag: tag,
        hops: [(0x0A, 9.0), (0x0C, 4.0), (0x0A, 6.0)]
      )))
    }

    await engine.setTestRepeater(tower)
    await engine.setTargets([ridge])
    await engine.setTracesPerTarget(1)
    await engine.run()

    let outcome = try #require(await engine.currentSnapshot().results.first?.outcomes.first)
    #expect(outcome.success)
    #expect(outcome.intermediateSNRs == [9, 4, 6])

    await engine.shutdown()
    await sleeper.releaseAll()
  }

  @Test
  func `A reply buffered between runs cannot answer the next run's probe`() async throws {
    let session = MockBenchmarkSession()
    let sleeper = GatedSleeper()
    let engine = makeEngine(session: session, sleeper: sleeper, tags: TagSequence(), clock: TestClock())

    await engine.setTestRepeater(tower)
    await engine.setTargets([ridge])
    await engine.setTracesPerTarget(1)

    // Someone else's trace, arriving while the tool is idle. The first probe of the next run
    // takes tag 1 too, and must not be credited with this measurement.
    await engine.ingest(.traceData(BenchmarkFixtures.reply(tag: 1, hops: [(0x0A, 9.0)])))

    let run = Task { await engine.run() }
    try await waitForBenchmarkCondition("run did not finish") {
      await sleeper.releaseAll()
      let sent = await session.traceCount
      let isRunning = await engine.currentSnapshot().isRunning
      return sent == 1 && !isRunning
    }
    await run.value

    let outcome = try #require(await engine.currentSnapshot().results.first?.outcomes.first)
    #expect(outcome.failure == .timeout)

    await engine.shutdown()
    await sleeper.releaseAll()
  }

  @Test
  func `A resolved probe leaves no expiry behind for a later probe`() async throws {
    let session = MockBenchmarkSession()
    let sleeper = GatedSleeper()
    // One tag for every probe, so an expiry left over from the first probe's cancelled
    // deadline would fail the second one before it could be answered.
    let engine = makeEngine(
      session: session,
      sleeper: sleeper,
      tags: TagSequence(),
      clock: TestClock(),
      makeTag: { 7 }
    )

    await engine.setTestRepeater(tower)
    await engine.setTargets([ridge])
    await engine.setTracesPerTarget(3)

    let run = Task { await engine.run() }
    for probe in 1...3 {
      try await waitForBenchmarkCondition("probe \(probe) not sent") {
        await session.traceCount == probe
      }
      await engine.ingest(.traceData(BenchmarkFixtures.reply(
        tag: 7,
        hops: [(0x0A, 9.0), (0x0C, 4.0), (0x0A, 6.0)]
      )))
    }
    await run.value

    let result = try #require(await engine.currentSnapshot().results.first)
    let allSucceeded = result.outcomes.allSatisfy(\.success)
    #expect(result.outcomes.count == 3)
    #expect(allSucceeded)

    await engine.shutdown()
    await sleeper.releaseAll()
  }

  @Test
  func `A refused send is recorded without waiting for a reply`() async throws {
    let session = MockBenchmarkSession()
    await session.setTraceError(BenchmarkTestError())
    let sleeper = GatedSleeper()
    let engine = makeEngine(session: session, sleeper: sleeper, tags: TagSequence(), clock: TestClock())

    await engine.setTestRepeater(tower)
    await engine.setTargets([ridge])
    await engine.setTracesPerTarget(3)
    await engine.run()

    let result = try #require(await engine.currentSnapshot().results.first)
    #expect(result.outcomes.map(\.failure) == [.sendFailed, .sendFailed, .sendFailed])
    #expect(result.successRate == 0)
    // Nothing parked on a deadline: a send that never happened has nothing to wait for.
    let waitedOnAReply = await sleeper.recorded.contains { $0 >= .seconds(1) }
    #expect(!waitedOnAReply)

    await engine.shutdown()
  }

  // MARK: - Cancellation

  @Test
  func `Cancelling stops after the probe in flight and keeps what was measured`() async throws {
    let session = MockBenchmarkSession()
    let sleeper = GatedSleeper()
    let engine = makeEngine(session: session, sleeper: sleeper, tags: TagSequence(), clock: TestClock())

    await engine.setTestRepeater(tower)
    await engine.setTargets([ridge, barn])
    await engine.setTracesPerTarget(5)

    let run = Task { await engine.run() }
    try await waitForBenchmarkCondition("first probe not sent") { await session.traceCount == 1 }
    await engine.ingest(.traceData(BenchmarkFixtures.reply(
      tag: 1,
      hops: [(0x0A, 9.0), (0x0C, 4.0), (0x0A, 6.0)]
    )))
    await engine.cancel()
    await run.value

    let snapshot = await engine.currentSnapshot()
    #expect(!snapshot.isRunning)
    #expect(await session.traceCount == 1)
    #expect(snapshot.results.first?.outcomes.count == 1)
    #expect(snapshot.results.first?.outcomes.first?.success == true)

    await engine.shutdown()
    await sleeper.releaseAll()
  }

  @Test
  func `Cancelling resolves the targets the run never reached`() async throws {
    let session = MockBenchmarkSession()
    let sleeper = GatedSleeper()
    let engine = makeEngine(session: session, sleeper: sleeper, tags: TagSequence(), clock: TestClock())

    await engine.setTestRepeater(tower)
    await engine.setTargets([ridge, barn])
    await engine.setTracesPerTarget(5)

    let run = Task { await engine.run() }
    try await waitForBenchmarkCondition("first probe not sent") { await session.traceCount == 1 }
    await engine.ingest(.traceData(BenchmarkFixtures.reply(
      tag: 1,
      hops: [(0x0A, 9.0), (0x0C, 4.0), (0x0A, 6.0)]
    )))
    await engine.cancel()
    await run.value

    let snapshot = await engine.currentSnapshot()
    // Barn was never probed; a row that is not complete spins forever.
    #expect(snapshot.results.map(\.isComplete) == [true, true])
    #expect(snapshot.results.last?.outcomes.isEmpty == true)

    await engine.shutdown()
    await sleeper.releaseAll()
  }

  // MARK: - Editing the plan

  @Test
  func `Changing the target set drops the previous run's results`() async throws {
    let session = MockBenchmarkSession()
    let sleeper = GatedSleeper()
    let engine = makeEngine(session: session, sleeper: sleeper, tags: TagSequence(), clock: TestClock())

    await engine.setTestRepeater(tower)
    await engine.setTargets([ridge])
    await engine.setTracesPerTarget(1)

    let run = Task { await engine.run() }
    try await waitForBenchmarkCondition("run did not finish") {
      await sleeper.releaseAll()
      let sent = await session.traceCount
      let isRunning = await engine.currentSnapshot().isRunning
      return sent == 1 && !isRunning
    }
    await run.value
    #expect(await engine.currentSnapshot().hasResults)

    // Measurements taken against a different set of targets must not be savable as this one's.
    await engine.toggleTarget(barn)
    let afterToggle = await engine.currentSnapshot()
    #expect(!afterToggle.hasResults)

    await engine.setTargets([ridge, barn])
    let afterSet = await engine.currentSnapshot()
    #expect(!afterSet.hasResults)
    #expect(afterSet.completedAt == nil)

    await engine.shutdown()
    await sleeper.releaseAll()
  }

  // MARK: - Progress

  @Test
  func `Progress counts probes finished over probes planned`() {
    let plan = BenchmarkPlan(testRepeater: tower, targets: [ridge, barn], tracesPerTarget: 5)
    // Eight of ten probes resolved, the ninth in flight: progress follows the outcomes, not
    // the index of the probe being sent.
    let midRun = RepeaterBenchmarkSnapshot(
      plan: plan,
      results: [
        BenchmarkTargetResult(target: ridge, outcomes: outcomes(5), isComplete: true),
        BenchmarkTargetResult(target: barn, outcomes: outcomes(3)),
      ],
      isRunning: true,
      currentTargetIndex: 2,
      currentTraceIndex: 4,
      completedAt: nil
    )

    #expect(midRun.progressFraction == 0.8)
    #expect(RepeaterBenchmarkSnapshot.idle().progressFraction == 0)
  }

  private func outcomes(_ count: Int) -> [BenchmarkTraceOutcome] {
    (1...count).map {
      BenchmarkFixtures.outcome(sequence: $0, durationMs: 400, intermediateSNRs: [9, 4, 6])
    }
  }
}
