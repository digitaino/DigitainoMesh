import Foundation
@testable import MapperRawLog
import MC1Services
import Testing

@Suite("Raw ride log store")
struct MapperRawLogStoreTests {
  private let start = Date(timeIntervalSince1970: 1_753_000_000)

  // MARK: - Runs

  @Test
  func `A created run round-trips its radio snapshot and focus set`() async throws {
    let (store, runID) = try await makeStoreWithRun(startedAt: start, focusTargetHexIDs: ["0C13", "A17F"])

    let run = try #require(try await store.fetchRun(runID))
    #expect(run.startedAt == start)
    #expect(run.endedAt == nil)
    #expect(run.frequency == 869_525_000)
    #expect(run.bandwidth == 250_000)
    #expect(run.spreadingFactor == 11)
    #expect(run.codingRate == 5)
    #expect(run.txPower == 22)
    #expect(run.focusTargetHexIDs == ["0C13", "A17F"])
    #expect(run.sampleCount == 0)
    #expect(run.duration == nil)
  }

  @Test
  func `Ending a run stamps its end and gives it a duration`() async throws {
    let (store, runID) = try await makeStoreWithRun(startedAt: start)

    try await store.endRun(runID, at: start.addingTimeInterval(3600))

    let run = try #require(try await store.fetchRun(runID))
    #expect(run.endedAt == start.addingTimeInterval(3600))
    #expect(run.duration == 3600)
  }

  @Test
  func `Counter accumulation adds deltas rather than assigning`() async throws {
    // The rewire case: two engine generations each report what they counted, and the run
    // has to end up holding the sum (§2.6).
    let (store, runID) = try await makeStoreWithRun(startedAt: start)

    try await store.accumulateCounters(
      runID: runID,
      probesSent: 12,
      tracesSent: 7,
      discoversSent: 5,
      repliesHeard: 9,
      probesLost: 3,
      cellsProbed: 4
    )
    try await store.accumulateCounters(
      runID: runID,
      probesSent: 8,
      tracesSent: 5,
      discoversSent: 3,
      repliesHeard: 6,
      probesLost: 2,
      cellsProbed: 1
    )

    let run = try #require(try await store.fetchRun(runID))
    #expect(run.probesSent == 20)
    #expect(run.tracesSent == 12)
    #expect(run.discoversSent == 8)
    #expect(run.repliesHeard == 15)
    #expect(run.probesLost == 5)
    #expect(run.cellsProbed == 5)
  }

  @Test
  func `Focus targets are replaced wholesale`() async throws {
    let (store, runID) = try await makeStoreWithRun(startedAt: start, focusTargetHexIDs: ["0C13"])

    try await store.updateFocusTargets(runID: runID, hexIDs: ["A17F", "B200"])

    let run = try #require(try await store.fetchRun(runID))
    #expect(run.focusTargetHexIDs == ["A17F", "B200"])
  }

  @Test
  func `A write naming an unknown run reports it rather than inventing one`() async throws {
    let store = try MapperRawLogStore.inMemory()

    await #expect(throws: MapperRawLogStoreError.runNotFound) {
      try await store.endRun(UUID(), at: self.start)
    }
    await #expect(throws: MapperRawLogStoreError.runNotFound) {
      try await store.accumulateCounters(runID: UUID(), probesSent: 1)
    }
    await #expect(throws: MapperRawLogStoreError.runNotFound) {
      try await store.updateFocusTargets(runID: UUID(), hexIDs: ["0C13"])
    }
  }

  @Test
  func `Runs come back newest first`() async throws {
    let store = try MapperRawLogStore.inMemory()
    var ids: [UUID] = []
    for offset in 0..<3 {
      try await ids.append(store.createRun(
        radioID: nil,
        frequency: nil,
        bandwidth: nil,
        spreadingFactor: nil,
        codingRate: nil,
        txPower: nil,
        focusTargetHexIDs: [],
        startedAt: start.addingTimeInterval(Double(offset) * 3600)
      ))
    }

    let runs = try await store.fetchRuns()
    #expect(runs.map(\.id) == ids.reversed())
  }

  // MARK: - Samples

  @Test
  func `Inserting samples bumps the run's sample count`() async throws {
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let events = (0..<7).map { rawEvent(at: start.addingTimeInterval(Double($0))) }

    try await store.insertSamples(events, runID: runID, startingSeq: 0)

    #expect(try await store.sampleCount(runID: runID) == 7)
    let run = try #require(try await store.fetchRun(runID))
    #expect(run.sampleCount == 7)

    // A second batch adds rather than replaces — same argument as the counters.
    try await store.insertSamples(events, runID: runID, startingSeq: 7)
    let updated = try #require(try await store.fetchRun(runID))
    #expect(updated.sampleCount == 14)
  }

  @Test
  func `Every column survives the round trip`() async throws {
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let event = rawEvent(at: start, kind: .probeDiscoverResponse, gateOutcome: .staleFix)

    try await store.insertSamples([event], runID: runID, startingSeq: 41)

    let row = try #require(try await store.fetchSamples(runID: runID, offset: 0, limit: 1).first)
    #expect(row.runID == runID)
    #expect(row.seq == 41)
    #expect(row.timestamp == start)
    #expect(row.kind == .probeDiscoverResponse)
    #expect(row.rxSnr == 6.25)
    #expect(row.txSnr == -3.5)
    #expect(row.rssi == -91)
    #expect(row.hopCount == 2)
    #expect(row.rttMs == 840)
    #expect(row.routeTypeRaw == 1)
    #expect(row.payloadTypeRaw == 4)
    #expect(row.perHopSnrs == [6.25, -3.5])
    #expect(row.repeaterHexID == "0C13")
    #expect(row.repeaterPublicKey == Data(repeating: 0xAB, count: 32))
    #expect(row.wasFocused)
    #expect(row.latitude == 37.7749)
    #expect(row.longitude == -122.4194)
    #expect(row.horizontalAccuracyMeters == 8)
    #expect(row.speedMetersPerSecond == 6.4)
    #expect(row.courseDegrees == 271.5)
    #expect(row.fixAgeSeconds == 1.2)
    #expect(row.cellRaw == 0x0892_8308_280F_FFFF)
    #expect(row.gateOutcome == .staleFix)
  }

  @Test
  func `A cell index with the high bit set survives the signed column`() async throws {
    // The reason `cellRaw` is stored as an `Int64` bit pattern: SwiftData is
    // value-preserving across the signed SQLite column, so a `UInt64` above `Int64.max`
    // would not come back the way it went in. Nothing H3 emits today sets bit 63, which is
    // exactly why an accidental regression here would go unnoticed without this.
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let event = rawEvent(at: start, cell: UInt64.max)

    try await store.insertSamples([event], runID: runID, startingSeq: 0)

    let row = try #require(try await store.fetchSamples(runID: runID, offset: 0, limit: 1).first)
    #expect(row.cellRaw == UInt64.max)
  }

  @Test
  func `A breadcrumb keeps its nils rather than gaining zeroes`() async throws {
    // "Record what was known, never guess": an absent SNR must read back absent, or the
    // log grows a fleet of 0 dB readings that never happened.
    let (store, runID) = try await makeStoreWithRun(startedAt: start)

    try await store.insertSamples([breadcrumbEvent(at: start)], runID: runID, startingSeq: 0)

    let row = try #require(try await store.fetchSamples(runID: runID, offset: 0, limit: 1).first)
    #expect(row.kind == .breadcrumb)
    #expect(row.rxSnr == nil)
    #expect(row.txSnr == nil)
    #expect(row.rssi == nil)
    #expect(row.perHopSnrs == nil)
    #expect(row.repeaterPublicKey == nil)
    #expect(row.cellRaw == nil)
    #expect(!row.wasFocused)
  }

  @Test
  func `Pagination walks the run in sequence order`() async throws {
    // The export streams pages rather than fetching a whole ride (§2.8), so the pages have
    // to tile the run exactly once and in order.
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let events = (0..<250).map { rawEvent(at: start.addingTimeInterval(Double($0))) }
    try await store.insertSamples(events, runID: runID, startingSeq: 0)

    var seen: [Int64] = []
    var offset = 0
    while true {
      let page = try await store.fetchSamples(runID: runID, offset: offset, limit: 100)
      if page.isEmpty { break }
      seen += page.map(\.seq)
      offset += page.count
    }

    #expect(seen == Array(0..<250).map(Int64.init))

    // And a page really is a window into that order, not a re-sorted subset.
    let middle = try await store.fetchSamples(runID: runID, offset: 100, limit: 5)
    #expect(middle.map(\.seq) == [100, 101, 102, 103, 104])
    #expect(try await store.fetchSamples(runID: runID, offset: 0, limit: 0).isEmpty)
  }

  @Test
  func `One run's rows are invisible to another`() async throws {
    let (store, runA) = try await makeStoreWithRun(startedAt: start)
    let runB = try await store.createRun(
      radioID: nil, frequency: nil, bandwidth: nil, spreadingFactor: nil,
      codingRate: nil, txPower: nil, focusTargetHexIDs: [], startedAt: start.addingTimeInterval(60)
    )

    try await store.insertSamples([rawEvent(at: start)], runID: runA, startingSeq: 0)
    try await store.insertSamples(
      (0..<3).map { rawEvent(at: start.addingTimeInterval(Double($0))) },
      runID: runB,
      startingSeq: 0
    )

    #expect(try await store.sampleCount(runID: runA) == 1)
    #expect(try await store.sampleCount(runID: runB) == 3)
  }

  // MARK: - Maintenance

  @Test
  func `Orphan reconciliation stamps a run's end from its last sample`() async throws {
    // Jetsam mid-ride: the run row never got its `endedAt` (§2.6). Left open it would
    // never expire and the recording indicator would claim a ride days later.
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    let events = (0..<5).map { rawEvent(at: start.addingTimeInterval(Double($0) * 120)) }
    try await store.insertSamples(events, runID: runID, startingSeq: 0)

    let closed = try await store.reconcileOrphanRuns(now: start.addingTimeInterval(86400))
    #expect(closed == 1)

    let run = try #require(try await store.fetchRun(runID))
    #expect(run.endedAt == start.addingTimeInterval(480))

    // Idempotent: a closed run is not an orphan, so a second launch closes nothing.
    #expect(try await store.reconcileOrphanRuns(now: start.addingTimeInterval(86400)) == 0)
  }

  @Test
  func `An orphan run with no samples falls back to its start`() async throws {
    let (store, runID) = try await makeStoreWithRun(startedAt: start)

    #expect(try await store.reconcileOrphanRuns(now: start.addingTimeInterval(3600)) == 1)

    let run = try #require(try await store.fetchRun(runID))
    #expect(run.endedAt == start)
  }

  @Test
  func `Reconciliation never stamps a run into the future`() async throws {
    // A sample carrying a skewed clock would otherwise produce a run that ends after now
    // and outlives every retention window.
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    try await store.insertSamples(
      [rawEvent(at: start.addingTimeInterval(86400 * 365))],
      runID: runID,
      startingSeq: 0
    )

    let now = start.addingTimeInterval(600)
    #expect(try await store.reconcileOrphanRuns(now: now) == 1)

    let run = try #require(try await store.fetchRun(runID))
    #expect(run.endedAt == now)
  }

  @Test
  func `A retention of zero days keeps everything`() async throws {
    // Zero means "keep forever" — an explicit user choice, deliberately not the default
    // (§2.9). Reading it as "expire immediately" would silently delete the ride the user
    // asked to keep.
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    try await store.insertSamples([rawEvent(at: start)], runID: runID, startingSeq: 0)
    try await store.endRun(runID, at: start.addingTimeInterval(60))

    let purged = try await store.purgeExpired(retentionDays: 0, now: start.addingTimeInterval(86400 * 3650))

    #expect(purged == 0)
    #expect(try await store.fetchRuns().count == 1)
    #expect(try await store.sampleCount(runID: runID) == 1)
  }

  @Test
  func `Purging removes expired runs and their rows and spares the rest`() async throws {
    let store = try MapperRawLogStore.inMemory()

    let old = try await store.createRun(
      radioID: nil, frequency: nil, bandwidth: nil, spreadingFactor: nil,
      codingRate: nil, txPower: nil, focusTargetHexIDs: [], startedAt: start
    )
    try await store.insertSamples(
      (0..<600).map { rawEvent(at: start.addingTimeInterval(Double($0))) },
      runID: old,
      startingSeq: 0
    )
    try await store.endRun(old, at: start.addingTimeInterval(3600))

    let recent = try await store.createRun(
      radioID: nil, frequency: nil, bandwidth: nil, spreadingFactor: nil,
      codingRate: nil, txPower: nil, focusTargetHexIDs: [], startedAt: start.addingTimeInterval(86400 * 29)
    )
    try await store.insertSamples([rawEvent(at: start)], runID: recent, startingSeq: 0)
    try await store.endRun(recent, at: start.addingTimeInterval(86400 * 29 + 3600))

    // A 30-day cutoff that falls between the two: 31 days after the old run ended, 2 days
    // after the recent one.
    let now = start.addingTimeInterval(86400 * 31)
    let purged = try await store.purgeExpired(retentionDays: 30, now: now)

    #expect(purged == 1)
    #expect(try await store.fetchRuns().map(\.id) == [recent])
    // More rows than one delete chunk, so the chunked path is the one exercised.
    #expect(try await store.sampleCount(runID: old) == 0)
    #expect(try await store.sampleCount(runID: recent) == 1)
  }

  @Test
  func `An unfinished run expires on its start date`() async throws {
    // Belt and braces for a store whose reconciliation never ran: a run with no `endedAt`
    // still has to age out rather than pinning a movement log forever.
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    try await store.insertSamples([rawEvent(at: start)], runID: runID, startingSeq: 0)

    #expect(try await store.purgeExpired(retentionDays: 30, now: start.addingTimeInterval(86400 * 31)) == 1)
    #expect(try await store.fetchRuns().isEmpty)
  }

  @Test
  func `Deleting one run leaves the others alone`() async throws {
    let (store, runA) = try await makeStoreWithRun(startedAt: start)
    let runB = try await store.createRun(
      radioID: nil, frequency: nil, bandwidth: nil, spreadingFactor: nil,
      codingRate: nil, txPower: nil, focusTargetHexIDs: [], startedAt: start.addingTimeInterval(60)
    )
    try await store.insertSamples([rawEvent(at: start)], runID: runA, startingSeq: 0)
    try await store.insertSamples([rawEvent(at: start)], runID: runB, startingSeq: 0)

    try await store.deleteRun(runA)

    #expect(try await store.fetchRuns().map(\.id) == [runB])
    #expect(try await store.sampleCount(runID: runA) == 0)
    #expect(try await store.sampleCount(runID: runB) == 1)
  }

  @Test
  func `Delete-all empties both tables`() async throws {
    let (store, runID) = try await makeStoreWithRun(startedAt: start)
    try await store.insertSamples(
      (0..<600).map { rawEvent(at: start.addingTimeInterval(Double($0))) },
      runID: runID,
      startingSeq: 0
    )

    try await store.deleteAll()

    #expect(try await store.fetchRuns().isEmpty)
    #expect(try await store.sampleCount(runID: runID) == 0)
  }
}
