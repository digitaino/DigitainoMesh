import Foundation
@testable import MapperRawLog
import MC1Services
import SwiftData
import Testing

/// The v3 store: always on, ride-optional, queried by hexagon and repeater
/// (docs/SIGNAL_MAPPER_V3.md §2, §7 step 1).
///
/// Every date here is fixed. The store's own clock parameters (`now:`) are the only time
/// source, so nothing in this suite can flake on a slow machine.
@Suite("Raw log, always on")
struct MapperRawLogAlwaysOnTests {
  private let start = Date(timeIntervalSince1970: 1_753_000_000)
  /// Two res-9 cells far enough apart that no fixture can accidentally land in both.
  private let cellA: UInt64 = 0x0892_8308_280F_FFFF
  private let cellB: UInt64 = 0x0892_2D6C_2D3F_FFFF

  private func heardEvent(
    at timestamp: Date,
    cell: UInt64?,
    repeaterHexID: String? = "0C13",
    kind: MapperRawSampleKind = .passiveRx
  ) -> MapperRawSampleEvent {
    MapperRawSampleEvent(
      timestamp: timestamp,
      kind: kind,
      rxSnr: 6.25,
      rssi: -91,
      hopCount: 2,
      routeTypeRaw: 1,
      payloadTypeRaw: 5,
      pathHashes: ["0C", "42"],
      rawHex: Data([0x15, 0x01, 0x02, 0x03]),
      repeaterHexID: repeaterHexID,
      latitude: 37.7749,
      longitude: -122.4194,
      horizontalAccuracyMeters: 8,
      cellRaw: cell,
      gateOutcome: .accepted
    )
  }

  private func sentEvent(at timestamp: Date, cell: UInt64?, messageID: UUID?) -> MapperRawSampleEvent {
    MapperRawSampleEvent(
      timestamp: timestamp,
      kind: .sent,
      payloadTypeRaw: 2,
      messageID: messageID,
      latitude: 37.7749,
      longitude: -122.4194,
      cellRaw: cell,
      gateOutcome: cell == nil ? .noFix : .accepted
    )
  }

  // MARK: - No ride at all

  @Test
  func `Rows recorded outside a ride insert, come back and are not attached to anything`() async throws {
    let store = try MapperRawLogStore.inMemory()

    try await store.insertSamples(
      (0..<3).map { heardEvent(at: start.addingTimeInterval(Double($0)), cell: cellA) },
      runID: nil,
      startingSeq: 0
    )

    let rows = try await store.fetchSamples(
      cellRaw: cellA,
      since: start,
      until: start.addingTimeInterval(60),
      limit: 10
    )
    #expect(rows.count == 3)
    #expect(rows.allSatisfy { $0.runID == nil })
    // The header table stays empty: no ride was opened, and a row does not invent one.
    #expect(try await store.fetchRuns().isEmpty)
  }

  @Test
  func `Retention purges ride-less rows, which is the only way they can ever expire`() async throws {
    let store = try MapperRawLogStore.inMemory()

    try await store.insertSamples(
      [heardEvent(at: start, cell: cellA)],
      runID: nil,
      startingSeq: 0
    )
    let fresh = start.addingTimeInterval(86400 * 89)
    try await store.insertSamples(
      [heardEvent(at: fresh, cell: cellA)],
      runID: nil,
      startingSeq: 1
    )

    // A second past 90 days after the old row, so the cutoff falls just inside it — the
    // boundary is exclusive, and a row exactly on the cutoff is kept.
    let now = start.addingTimeInterval(86400 * 90 + 1)
    let purgedRuns = try await store.purgeExpired(retentionDays: 90, now: now)

    #expect(purgedRuns == 0, "there were no runs to purge — the rows are the point")
    let remaining = try await store.fetchSamples(
      cellRaw: cellA,
      since: start,
      until: now,
      limit: 10
    )
    #expect(remaining.count == 1)
    #expect(remaining.first?.timestamp == fresh)
  }

  @Test
  func `Delete-older-than reports what it removed and spares the rest`() async throws {
    let store = try MapperRawLogStore.inMemory()
    // More than one delete chunk, so the chunked path is the one exercised.
    try await store.insertSamples(
      (0..<600).map { heardEvent(at: start.addingTimeInterval(Double($0)), cell: cellA) },
      runID: nil,
      startingSeq: 0
    )
    try await store.insertSamples(
      [heardEvent(at: start.addingTimeInterval(1000), cell: cellA)],
      runID: nil,
      startingSeq: 600
    )

    let deleted = try await store.deleteSamples(olderThan: start.addingTimeInterval(600))
    #expect(deleted == 600)
    #expect(try await store.storageSummary().rowCount == 1)
  }

  // MARK: - Cell and repeater queries

  @Test
  func `A cell query returns that hexagon's rows in the window, newest first`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples(
      [
        heardEvent(at: start, cell: cellA),
        heardEvent(at: start.addingTimeInterval(10), cell: cellA),
        heardEvent(at: start.addingTimeInterval(20), cell: cellB),
        // Outside the window on the exclusive end: `until` must not include its own instant,
        // or two adjacent windows would double-count the row they share.
        heardEvent(at: start.addingTimeInterval(30), cell: cellA)
      ],
      runID: nil,
      startingSeq: 0
    )

    let rows = try await store.fetchSamples(
      cellRaw: cellA,
      since: start,
      until: start.addingTimeInterval(30),
      limit: 10
    )
    #expect(rows.map(\.timestamp) == [start.addingTimeInterval(10), start])
  }

  @Test
  func `A cell query honours its limit and keeps the newest rows`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples(
      (0..<10).map { heardEvent(at: start.addingTimeInterval(Double($0)), cell: cellA) },
      runID: nil,
      startingSeq: 0
    )

    let rows = try await store.fetchSamples(
      cellRaw: cellA,
      since: start,
      until: start.addingTimeInterval(100),
      limit: 3
    )
    #expect(rows.map(\.timestamp) == [
      start.addingTimeInterval(9), start.addingTimeInterval(8), start.addingTimeInterval(7)
    ])
    #expect(try await store.fetchSamples(cellRaw: cellA, since: start, until: start, limit: 0).isEmpty)
  }

  @Test
  func `A repeater query answers for one hexagon or for everywhere`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples(
      [
        heardEvent(at: start, cell: cellA, repeaterHexID: "0C13"),
        heardEvent(at: start.addingTimeInterval(10), cell: cellB, repeaterHexID: "0C13"),
        heardEvent(at: start.addingTimeInterval(20), cell: cellA, repeaterHexID: "42FF")
      ],
      runID: nil,
      startingSeq: 0
    )

    let window = (since: start, until: start.addingTimeInterval(100))
    let everywhere = try await store.fetchSamples(
      repeaterHexID: "0C13",
      cellRaw: nil,
      since: window.since,
      until: window.until,
      limit: 10
    )
    #expect(everywhere.count == 2)

    let here = try await store.fetchSamples(
      repeaterHexID: "0C13",
      cellRaw: cellA,
      since: window.since,
      until: window.until,
      limit: 10
    )
    #expect(here.count == 1)
    #expect(here.first?.cellRaw == cellA)

    // Exact match, not the bidirectional prefix rule: "0C" is a different key here, and
    // reconciling hash widths is a decision that belongs above the store.
    let narrower = try await store.fetchSamples(
      repeaterHexID: "0C",
      cellRaw: nil,
      since: window.since,
      until: window.until,
      limit: 10
    )
    #expect(narrower.isEmpty)
  }

  // MARK: - Our own transmissions

  @Test
  func `Sent rows come back oldest first, filtered to the hexagon asked for`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples(
      [
        sentEvent(at: start.addingTimeInterval(20), cell: cellA, messageID: UUID()),
        sentEvent(at: start, cell: cellA, messageID: UUID()),
        sentEvent(at: start.addingTimeInterval(10), cell: cellB, messageID: UUID()),
        // Not a transmission: a heard packet from the same cell must not answer "when did
        // we transmit from here".
        heardEvent(at: start.addingTimeInterval(5), cell: cellA)
      ],
      runID: nil,
      startingSeq: 0
    )

    let fromA = try await store.fetchSentSamples(
      since: start,
      until: start.addingTimeInterval(100),
      cellRaw: cellA
    )
    #expect(fromA.map(\.timestamp) == [start, start.addingTimeInterval(20)])

    let anywhere = try await store.fetchSentSamples(
      since: start,
      until: start.addingTimeInterval(100),
      cellRaw: nil
    )
    #expect(anywhere.count == 3)
  }

  @Test
  func `A sent row with no fix is still recorded, as a row that says so`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples(
      [sentEvent(at: start, cell: nil, messageID: UUID())],
      runID: nil,
      startingSeq: 0
    )

    let rows = try await store.fetchSentSamples(
      since: start,
      until: start.addingTimeInterval(1),
      cellRaw: nil
    )
    let row = try #require(rows.first)
    #expect(row.cellRaw == nil)
    #expect(row.gateOutcome == .noFix)
  }

  @Test
  func `The hash back-fill stamps every sent row for one message and nothing else`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let messageID = UUID()
    let otherID = UUID()

    try await store.insertSamples(
      [
        // Two transmissions of the same message: an original and its resend.
        sentEvent(at: start, cell: cellA, messageID: messageID),
        sentEvent(at: start.addingTimeInterval(30), cell: cellA, messageID: messageID),
        sentEvent(at: start.addingTimeInterval(40), cell: cellA, messageID: otherID),
        // Same message id on a non-`sent` row: the back-fill is about transmissions.
        MapperRawSampleEvent(
          timestamp: start.addingTimeInterval(50),
          kind: .ackResolved,
          messageID: messageID,
          cellRaw: cellA,
          gateOutcome: .accepted
        )
      ],
      runID: nil,
      startingSeq: 0
    )

    let stamped = try await store.setContentHash(messageID: messageID, contentHash: "a1b2c3d4e5f60718")
    #expect(stamped == 2)

    let rows = try await store.fetchSamples(
      cellRaw: cellA,
      since: start,
      until: start.addingTimeInterval(100),
      limit: 10
    )
    let hashed = rows.filter { $0.contentHash != nil }
    #expect(hashed.count == 2)
    #expect(hashed.allSatisfy { $0.messageID == messageID && $0.kind == .sent })

    // Idempotent: a second echo for the same message re-stamps nothing, because the first
    // one is the authority and a disagreement would mean the correlation is wrong.
    #expect(try await store.setContentHash(messageID: messageID, contentHash: "ffffffffffffffff") == 0)
    #expect(try await store.setContentHash(messageID: UUID(), contentHash: "a1b2c3d4e5f60718") == 0)
  }

  // MARK: - Size and sequence

  @Test
  func `storageSummary counts the table and names its oldest row`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let empty = try await store.storageSummary()
    #expect(empty.rowCount == 0)
    #expect(empty.oldest == nil)
    #expect(empty.approximateBytes == 0)

    try await store.insertSamples(
      [
        heardEvent(at: start.addingTimeInterval(100), cell: cellA),
        heardEvent(at: start, cell: cellA),
        heardEvent(at: start.addingTimeInterval(50), cell: cellB)
      ],
      runID: nil,
      startingSeq: 0
    )

    let summary = try await store.storageSummary()
    #expect(summary.rowCount == 3)
    #expect(summary.oldest == start)
    #expect(summary.approximateBytes == 3 * MapperRawLogStore.approximateBytesPerRow)
  }

  @Test
  func `nextSeq continues the table's numbering across recorders`() async throws {
    let store = try MapperRawLogStore.inMemory()
    #expect(try await store.nextSeq() == 0, "an empty table starts at zero")

    try await store.insertSamples(
      (0..<5).map { heardEvent(at: start.addingTimeInterval(Double($0)), cell: cellA) },
      runID: nil,
      startingSeq: 0
    )
    #expect(try await store.nextSeq() == 5)

    // A recorder rebuilt at the next launch picks up from there rather than colliding with
    // rows already on disk — the property that makes `seq` an ordering key at all now that
    // the table outlives every session.
    let resumed = try await store.nextSeq()
    try await store.insertSamples(
      [heardEvent(at: start.addingTimeInterval(10), cell: cellA)],
      runID: nil,
      startingSeq: resumed
    )
    #expect(try await store.nextSeq() == 6)
  }

  // MARK: - Ride scoping

  @Test
  func `A ride labels only the rows recorded while it is open`() async throws {
    let clock = TestClock(start)
    let store = try MapperRawLogStore.inMemory()
    let recorder = MapperRawSampleRecorder(store: store, runID: nil, now: clock.provider)

    await recorder.record(heardEvent(at: start, cell: cellA))
    await recorder.flushNow()

    let runID = try await store.createRun(
      radioID: nil, frequency: nil, bandwidth: nil, spreadingFactor: nil,
      codingRate: nil, txPower: nil, focusTargetHexIDs: [], startedAt: start
    )
    await recorder.setRunID(runID)
    await recorder.record(heardEvent(at: start.addingTimeInterval(10), cell: cellA))
    await recorder.flushNow()

    await recorder.setRunID(nil)
    await recorder.record(heardEvent(at: start.addingTimeInterval(20), cell: cellA))
    await recorder.flushNow()

    let rows = try await store.fetchSamples(
      cellRaw: cellA,
      since: start,
      until: start.addingTimeInterval(100),
      limit: 10
    )
    #expect(rows.count == 3)
    #expect(rows.filter { $0.runID == runID }.map(\.timestamp) == [start.addingTimeInterval(10)])
    #expect(rows.filter { $0.runID == nil }.count == 2)

    // The ride's own counter saw exactly its own row.
    let run = try #require(try await store.fetchRun(runID))
    #expect(run.sampleCount == 1)

    // And `seq` never restarted: the ride joined a numbering already in progress.
    #expect(rows.map(\.seq).sorted() == [0, 1, 2])
  }

  @Test
  func `The sample cap bounds a ride and nothing else`() async throws {
    let clock = TestClock(start)
    let store = try MapperRawLogStore.inMemory()
    let recorder = MapperRawSampleRecorder(store: store, runID: nil, cap: 2, now: clock.provider)

    // Outside a ride the cap does not apply: the always-on log must not stop recording
    // one afternoon and never start again (§2).
    for offset in 0..<5 {
      await recorder.record(heardEvent(at: start.addingTimeInterval(Double(offset)), cell: cellA))
    }
    await recorder.flushNow()
    var snapshot = await recorder.snapshot()
    #expect(snapshot.recordedCount == 5)
    #expect(snapshot.droppedCount == 0)
    #expect(!snapshot.didHitCap)

    let runID = try await store.createRun(
      radioID: nil, frequency: nil, bandwidth: nil, spreadingFactor: nil,
      codingRate: nil, txPower: nil, focusTargetHexIDs: [], startedAt: start
    )
    await recorder.setRunID(runID)
    for offset in 10..<15 {
      await recorder.record(heardEvent(at: start.addingTimeInterval(Double(offset)), cell: cellA))
    }
    await recorder.flushNow()
    snapshot = await recorder.snapshot()
    #expect(snapshot.runRecordedCount == 2, "the ride is capped at two")
    #expect(snapshot.droppedCount == 3)
    #expect(snapshot.didHitCap)

    // Ending the ride clears the cap with it — the next ride starts fresh and ambient
    // capture is unbounded again.
    await recorder.setRunID(nil)
    await recorder.record(heardEvent(at: start.addingTimeInterval(20), cell: cellA))
    await recorder.flushNow()
    snapshot = await recorder.snapshot()
    #expect(!snapshot.didHitCap)
    #expect(snapshot.droppedCount == 0)
    #expect(try await store.storageSummary().rowCount == 8)
  }

  /// Where ``MapperRawLogStore/approximateBytesPerRow`` comes from, and the guard that
  /// keeps it honest.
  ///
  /// Writes 5 000 rows of production shape — a passive-RX row with a fix, a path, a
  /// repeater and ~100 bytes of packet — into a real on-disk store, checkpoints the WAL by
  /// closing the container, and divides the sqlite file (plus its `-wal`) by the row count.
  /// The constant is the measured figure rounded to a round number; the assertion allows a
  /// generous band because sqlite page granularity, index fill factors and the SwiftData
  /// version all move it, and the readout it feeds answers "megabytes or gigabytes", not
  /// "how many bytes exactly".
  ///
  /// If this fails, the fix is to re-measure and move the constant, not to widen the band.
  @Test
  func `The per-row size estimate matches what a real store costs`() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("MapperRawLogSize-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let rowCount = 5000
    // A packet body at the size §9 budgets for, and a full 32-byte key: the widest row the
    // production producers actually write.
    let packet = Data((0..<100).map { UInt8($0 % 251) })
    do {
      let store = try MapperRawLogStore.live(directory: directory)
      for chunk in stride(from: 0, to: rowCount, by: 500) {
        let events = (chunk..<Swift.min(chunk + 500, rowCount)).map { index -> MapperRawSampleEvent in
          var event = heardEvent(at: start.addingTimeInterval(Double(index)), cell: cellA)
          event.rawHex = packet
          event.repeaterPublicKey = Data(repeating: 0xAB, count: 32)
          event.perHopSnrs = [6.25, -3.5]
          return event
        }
        try await store.insertSamples(events, runID: nil, startingSeq: Int64(chunk))
      }
      #expect(try await store.storageSummary().rowCount == rowCount)
    }

    var bytes = 0
    for name in ["store.sqlite", "store.sqlite-wal"] {
      let path = directory.appendingPathComponent(name).path
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      bytes += (attributes?[.size] as? Int) ?? 0
    }
    let measured = bytes / rowCount

    // 403 bytes/row when this was written (2026-09-03). Recorded in the failure message so
    // a drift is actionable without re-running the measurement by hand.
    #expect(
      measured >= (MapperRawLogStore.approximateBytesPerRow * 6) / 10
        && measured <= (MapperRawLogStore.approximateBytesPerRow * 16) / 10,
      """
      measured \(measured) bytes/row against a constant of \
      \(MapperRawLogStore.approximateBytesPerRow); re-measure and move the constant
      """
    )
  }

  // MARK: - Migration

  /// **No pre-change fixture exists**, so this cannot open a v2 store and read it back.
  /// The store is created fresh on every install and has never shipped a versioned
  /// migration plan; there is no captured `store.sqlite` in the repo to migrate from, and
  /// synthesising one would mean checking in a binary that only this test can read.
  ///
  /// What is checkable — and is what lightweight migration actually requires — is that
  /// every column v3 added is optional and that the one column whose *nullability changed*
  /// went from required to optional (the safe direction: existing rows keep their value,
  /// new ones may omit it). A column added non-optional with no default is precisely what
  /// makes SwiftData refuse to open an existing store, so this fails the moment somebody
  /// adds one.
  @Test
  func `Every column v3 added is nullable, which is what lightweight migration needs`() throws {
    let entity = try #require(
      MapperRawLogStore.schema.entities.first { $0.name == "MapperRawSample" }
    )
    let attributes = Dictionary(
      uniqueKeysWithValues: entity.attributes.map { ($0.name, $0) }
    )

    for name in ["pathHashesData", "rawHex", "contentHash", "messageID"] {
      let attribute = try #require(attributes[name], "\(name) is missing from the schema")
      #expect(attribute.isOptional, "\(name) must be optional or an existing store cannot open")
    }

    // Required → optional. Rows written before v3 all carry a run; rows written after it
    // mostly do not.
    let runID = try #require(attributes["runID"])
    #expect(runID.isOptional)

    // And the columns that were already there kept their names, so lightweight migration
    // sees a rename as nothing at all.
    for name in ["seq", "timestamp", "kindRaw", "cellRaw", "repeaterHexID", "gateOutcomeRaw"] {
      #expect(attributes[name] != nil, "\(name) disappeared; that is a destructive migration")
    }
  }
}
