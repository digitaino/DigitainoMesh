import Foundation
@testable import MapperRawLog
import MC1Services
import Testing

@Suite("Raw ride log recorder")
struct MapperRawSampleRecorderTests {
  private let start = Date(timeIntervalSince1970: 1_753_000_000)

  // MARK: - Batching

  @Test
  func `A batch's worth of events flushes and a batch minus one does not`() async throws {
    let clock = TestClock(start)
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let recorder = MapperRawSampleRecorder(store: store, runID: runID, now: clock.provider)

    for _ in 0..<99 {
      await recorder.record(rawEvent(at: clock.now))
    }
    #expect(try await store.sampleCount(runID: runID) == 0)
    var snapshot = await recorder.snapshot()
    #expect(snapshot.bufferedCount == 99)
    #expect(snapshot.recordedCount == 99)

    await recorder.record(rawEvent(at: clock.now))

    #expect(try await store.sampleCount(runID: runID) == 100)
    snapshot = await recorder.snapshot()
    #expect(snapshot.bufferedCount == 0)
    #expect(snapshot.nextSeq == 100)
  }

  @Test
  func `A partial batch flushes once the interval has passed, and only on the next event`() async throws {
    // The deadline is checked lazily, on `record`, rather than by a timer: there is no
    // task to leak when a BLE rewire abandons a half-built session, and nothing wakes a
    // phone that has stopped hearing packets. The cost — a trailing partial batch waits
    // for the next event — is the behaviour asserted here rather than an accident.
    let clock = TestClock(start)
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let recorder = MapperRawSampleRecorder(store: store, runID: runID, now: clock.provider)

    await recorder.record(rawEvent(at: clock.now))
    clock.advance(6)
    #expect(try await store.sampleCount(runID: runID) == 0, "time alone must not flush; there is no timer")

    await recorder.record(rawEvent(at: clock.now))
    #expect(try await store.sampleCount(runID: runID) == 2)

    // The window reopens with the next buffered event rather than staying expired.
    await recorder.record(rawEvent(at: clock.now))
    #expect(try await store.sampleCount(runID: runID) == 2)
    clock.advance(4.9)
    await recorder.record(rawEvent(at: clock.now))
    #expect(try await store.sampleCount(runID: runID) == 2, "4.9 s is inside the window")
    clock.advance(0.2)
    await recorder.record(rawEvent(at: clock.now))
    #expect(try await store.sampleCount(runID: runID) == 5)
  }

  @Test
  func `flushNow writes the trailing partial batch`() async throws {
    let clock = TestClock(start)
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let recorder = MapperRawSampleRecorder(store: store, runID: runID, now: clock.provider)

    for _ in 0..<7 {
      await recorder.record(rawEvent(at: clock.now))
    }
    await recorder.flushNow()

    #expect(try await store.sampleCount(runID: runID) == 7)
    #expect(await recorder.snapshot().bufferedCount == 0)

    // A flush with nothing buffered is a no-op, not an empty batch.
    await recorder.flushNow()
    #expect(try await store.sampleCount(runID: runID) == 7)
  }

  @Test
  func `finish flushes and reports the sequence a resumed session continues from`() async throws {
    let clock = TestClock(start)
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let first = MapperRawSampleRecorder(store: store, runID: runID, now: clock.provider)

    for _ in 0..<12 {
      await first.record(rawEvent(at: clock.now))
    }
    let finalSeq = await first.finish()
    #expect(finalSeq == 12)
    #expect(try await store.sampleCount(runID: runID) == 12)

    // The BLE-rewire case: a new recorder for the same run picks the numbering up rather
    // than colliding with the rows already written (§2.6).
    let second = MapperRawSampleRecorder(store: store, runID: runID, startingSeq: finalSeq, now: clock.provider)
    await second.record(rawEvent(at: clock.now))
    await second.flushNow()

    let seqs = try await store.fetchSamples(runID: runID, offset: 0, limit: 200).map(\.seq)
    #expect(seqs == Array(0..<13).map(Int64.init))
  }

  // MARK: - Sequencing

  @Test
  func `Sequence numbers stay monotonic across many flushes`() async throws {
    let clock = TestClock(start)
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let recorder = MapperRawSampleRecorder(store: store, runID: runID, now: clock.provider)

    for offset in 0..<250 {
      await recorder.record(rawEvent(at: clock.now.addingTimeInterval(Double(offset))))
    }
    #expect(try await store.sampleCount(runID: runID) == 200, "two full batches written, 50 still buffered")
    await recorder.flushNow()

    var seqs: [Int64] = []
    var offset = 0
    while true {
      let page = try await store.fetchSamples(runID: runID, offset: offset, limit: 100)
      if page.isEmpty { break }
      seqs += page.map(\.seq)
      offset += page.count
    }

    #expect(seqs == Array(0..<250).map(Int64.init))
    #expect(Set(seqs).count == seqs.count, "a duplicate seq breaks the run-local correlation key")
    #expect(await recorder.snapshot().nextSeq == 250)
  }

  @Test
  func `A recorder honours the sequence it was started at`() async throws {
    let clock = TestClock(start)
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let recorder = MapperRawSampleRecorder(store: store, runID: runID, startingSeq: 5000, now: clock.provider)

    await recorder.record(rawEvent(at: clock.now))
    await recorder.flushNow()

    let row = try #require(try await store.fetchSamples(runID: runID, offset: 0, limit: 1).first)
    #expect(row.seq == 5000)
  }

  // MARK: - Cap

  @Test
  func `The cap stops recording and says so`() async throws {
    // `rawSampleCapPerSession` is a runaway backstop (§2.9). Hitting it has to be visible
    // in the HUD's session detail — a silent cap looks exactly like a quiet mesh.
    let clock = TestClock(start)
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let recorder = MapperRawSampleRecorder(store: store, runID: runID, cap: 3, now: clock.provider)

    for _ in 0..<10 {
      await recorder.record(rawEvent(at: clock.now))
    }
    await recorder.flushNow()

    #expect(try await store.sampleCount(runID: runID) == 3)
    let snapshot = await recorder.snapshot()
    #expect(snapshot.recordedCount == 3)
    #expect(snapshot.droppedCount == 7)
    #expect(snapshot.didHitCap)
    #expect(snapshot.nextSeq == 3)
    #expect(snapshot.flushFailureCount == 0)
  }

  @Test
  func `A run below its cap reports no drops`() async throws {
    let clock = TestClock(start)
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let recorder = MapperRawSampleRecorder(store: store, runID: runID, cap: 50, now: clock.provider)

    for _ in 0..<10 {
      await recorder.record(rawEvent(at: clock.now))
    }

    let snapshot = await recorder.snapshot()
    #expect(!snapshot.didHitCap)
    #expect(snapshot.droppedCount == 0)
    #expect(snapshot.runID == runID)
  }

  // MARK: - Boundary conformance

  @Test
  func `The recorder is usable through the MC1Services-side protocol`() async throws {
    // The engines see only `MapperRawSampleRecording`; the implementation is on this side
    // of the dependency edge and the app wires the two (§2.4). If this stops compiling,
    // the boundary has drifted.
    let clock = TestClock(start)
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let recorder = MapperRawSampleRecorder(store: store, runID: runID, now: clock.provider)
    let sink: any MapperRawSampleRecording = recorder

    await sink.record(breadcrumbEvent(at: clock.now))
    await recorder.flushNow()

    #expect(try await store.sampleCount(runID: runID) == 1)
  }
}
