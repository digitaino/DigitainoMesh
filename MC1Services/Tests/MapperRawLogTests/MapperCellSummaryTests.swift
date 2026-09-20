import Foundation
@testable import MapperRawLog
import MC1Services
import Testing

// MARK: - Shared fixtures

/// Two res-9 cells far enough apart that no fixture can land in both by accident — the
/// same pair `MapperRawLogAlwaysOnTests` uses.
let summaryCellA: UInt64 = 0x0892_8308_280F_FFFF
let summaryCellB: UInt64 = 0x0892_2D6C_2D3F_FFFF

/// One event, spelled out field by field, because every test in these two suites is about
/// *which* columns a row does and does not contribute.
func cellEvent(
  at timestamp: Date,
  kind: MapperRawSampleKind,
  cell: UInt64? = summaryCellA,
  hexID: String? = nil,
  rxSnr: Double? = nil,
  txSnr: Double? = nil,
  rssi: Int? = nil,
  pathHashes: [String]? = nil,
  contentHash: String? = nil,
  gateOutcome: MapperGateOutcome? = nil
) -> MapperRawSampleEvent {
  MapperRawSampleEvent(
    timestamp: timestamp,
    kind: kind,
    rxSnr: rxSnr,
    txSnr: txSnr,
    rssi: rssi,
    pathHashes: pathHashes,
    contentHash: contentHash,
    repeaterHexID: hexID,
    cellRaw: cell,
    // Defaults to the confident reading of whether a cell was derived, which is what almost
    // every fixture wants; passed explicitly by the tests about doubtful placements, where a
    // cell and a non-accepted outcome coexist on purpose.
    gateOutcome: gateOutcome ?? (cell == nil ? .noFix : .accepted)
  )
}

/// A second implementation of the fold, written from docs/SIGNAL_MAPPER_V3.md §7 step 3
/// rather than from ``MapperCellSummaryFold``.
///
/// The point of a derived cache is that it never disagrees with the rows, and checking that
/// with the production folder would only prove the folder is deterministic. This one is
/// dumb on purpose: no incremental state, no maxima to unwind, one pass over whatever rows
/// are actually in the store.
func independentSummary(of rows: [MapperRawSampleDTO], cellRaw: UInt64) -> MapperCellSummaryDTO? {
  let cellRows = rows.filter { $0.cellRaw == cellRaw }
  guard !cellRows.isEmpty else { return nil }

  let rxRows = cellRows.filter { $0.rxSnr != nil && $0.repeaterHexID != nil }
  let txRows = cellRows.filter { row in
    guard let kind = row.kind, row.txSnr != nil else { return false }
    return kind == .probeTraceReply || kind == .probeDiscoverResponse
  }
  let echoes = cellRows.filter { $0.kind == .txHeard }

  return MapperCellSummaryDTO(
    cellRaw: cellRaw,
    rxBestSnr: rxRows.compactMap(\.rxSnr).max(),
    rxSnrSum: rxRows.compactMap(\.rxSnr).reduce(0, +),
    rxSnrCount: rxRows.count,
    rxLastAt: rxRows.map(\.timestamp).max(),
    txBestSnr: txRows.compactMap(\.txSnr).max(),
    txSnrSum: txRows.compactMap(\.txSnr).reduce(0, +),
    txSnrCount: txRows.count,
    txLastAt: txRows.map(\.timestamp).max(),
    echoCount: echoes.count,
    echoLastAt: echoes.map(\.timestamp).max(),
    probesSent: cellRows.count { $0.kind == .probeAttempt },
    sentCount: cellRows.count { $0.kind == .sent },
    heardCount: cellRows.count { $0.kind == .passiveRx },
    firstAt: cellRows.map(\.timestamp).min(),
    lastAt: cellRows.map(\.timestamp).max()
  )
}

/// Every row in the store, whatever cell it names — the input the independent fold works
/// from. Unbounded because the fixtures here are a handful of rows.
func allRows(_ store: MapperRawLogStore, from: Date, to: Date) async throws -> [MapperRawSampleDTO] {
  var rows: [MapperRawSampleDTO] = []
  for cell in [summaryCellA, summaryCellB] {
    rows += try await store.fetchSamples(cellRaw: cell, since: from, until: to, limit: 10000)
  }
  return rows
}

// MARK: - Suite

/// The per-cell summary cache (docs/SIGNAL_MAPPER_V3.md §7 step 3): what it folds, what it
/// refuses to fold, and that it can always be rebuilt from the rows.
@Suite("Mapper cell summaries")
struct MapperCellSummaryTests {
  private let start = Date(timeIntervalSince1970: 1_753_000_000)

  private func at(_ offset: TimeInterval) -> Date {
    start.addingTimeInterval(offset)
  }

  // MARK: - The fold on the write path

  @Test
  func `A batch of every kind folds into one summary, field by field`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples([
      cellEvent(at: at(0), kind: .passiveRx, hexID: "0C13", rxSnr: 6, rssi: -91),
      // A direct-routed packet: the row keeps its path and credits nobody (§1), so it is
      // heard traffic and not an RX reading of anyone.
      cellEvent(at: at(10), kind: .passiveRx, hexID: nil, rxSnr: 9, rssi: -80),
      cellEvent(at: at(20), kind: .probeTraceReply, hexID: "0C13", rxSnr: 2, txSnr: 5),
      cellEvent(at: at(30), kind: .probeDiscoverResponse, hexID: "42", rxSnr: 4, txSnr: -1),
      cellEvent(at: at(40), kind: .txHeard, hexID: "0C13", rxSnr: 1, pathHashes: ["42", "0C13"]),
      cellEvent(at: at(50), kind: .probeAttempt, hexID: "0C13"),
      cellEvent(at: at(60), kind: .sent),
      cellEvent(at: at(70), kind: .breadcrumb)
    ], runID: nil, startingSeq: 0)

    let summary = try #require(try await store.fetchCellSummary(cellRaw: summaryCellA))

    // RX: the four rows that credit a repeater *and* carry our reading of it. The
    // direct-routed 9.0 dB is the loudest number in the fixture and must not be the best.
    #expect(summary.rxBestSnr == 6)
    #expect(summary.rxSnrSum == 13)
    #expect(summary.rxSnrCount == 4)
    #expect(summary.rxLastAt == at(40))
    #expect(summary.rxAverage == 3.25)

    // TX: replies only.
    #expect(summary.txBestSnr == 5)
    #expect(summary.txSnrSum == 4)
    #expect(summary.txSnrCount == 2)
    #expect(summary.txLastAt == at(30))
    #expect(summary.txAverage == 2)

    #expect(summary.echoCount == 1)
    #expect(summary.echoLastAt == at(40))
    #expect(summary.probesSent == 1)
    #expect(summary.sentCount == 1)
    #expect(summary.heardCount == 2)

    // The breadcrumb contributes nothing but presence — which is the point of it.
    #expect(summary.firstAt == at(0))
    #expect(summary.lastAt == at(70))

    #expect(summary.hasHeardYou)
    #expect(!summary.isUnreachedProbed)
  }

  @Test
  func `A direct-routed row is heard traffic and never an RX reading`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples([
      cellEvent(at: at(0), kind: .passiveRx, hexID: nil, rxSnr: 11, rssi: -70, pathHashes: ["0C", "42"])
    ], runID: nil, startingSeq: 0)

    let summary = try #require(try await store.fetchCellSummary(cellRaw: summaryCellA))
    #expect(summary.heardCount == 1)
    #expect(summary.rxSnrCount == 0)
    #expect(summary.rxBestSnr == nil)
    #expect(summary.rxAverage == nil)
    #expect(summary.lastAt == at(0))
  }

  @Test
  func `Later batches continue the same summary rather than restarting it`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples(
      [cellEvent(at: at(0), kind: .passiveRx, hexID: "0C13", rxSnr: 3)],
      runID: nil,
      startingSeq: 0
    )
    try await store.insertSamples(
      [cellEvent(at: at(100), kind: .passiveRx, hexID: "0C13", rxSnr: 7)],
      runID: nil,
      startingSeq: 1
    )

    let summary = try #require(try await store.fetchCellSummary(cellRaw: summaryCellA))
    #expect(summary.rxSnrCount == 2)
    #expect(summary.rxBestSnr == 7)
    #expect(summary.firstAt == at(0))
    #expect(summary.lastAt == at(100))
    // And exactly one summary exists for the cell: the second batch found the first row.
    #expect(try await store.fetchCellSummaries().count == 1)
  }

  @Test
  func `Cells are kept apart, and a row with no fix folds into nothing`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples([
      cellEvent(at: at(0), kind: .passiveRx, cell: summaryCellA, hexID: "0C13", rxSnr: 3),
      cellEvent(at: at(1), kind: .passiveRx, cell: summaryCellB, hexID: "0C13", rxSnr: 8),
      // No fix: still a row, still evidence, but there is no hexagon to colour with it.
      cellEvent(at: at(2), kind: .passiveRx, cell: nil, hexID: "0C13", rxSnr: 12)
    ], runID: nil, startingSeq: 0)

    let summaries = try await store.fetchCellSummaries()
    #expect(summaries.count == 2)
    #expect(try await store.fetchCellSummary(cellRaw: summaryCellA)?.rxBestSnr == 3)
    #expect(try await store.fetchCellSummary(cellRaw: summaryCellB)?.rxBestSnr == 8)
  }

  @Test
  func `Rows arriving out of order still produce the same summary`() async throws {
    // A probe reply settles after the packets heard while waiting for it, and an echo can
    // back-fill minutes late: the fold has to be a set operation, not a running "last one
    // wins".
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples([
      cellEvent(at: at(300), kind: .passiveRx, hexID: "0C13", rxSnr: 2),
      cellEvent(at: at(100), kind: .passiveRx, hexID: "0C13", rxSnr: 9),
      cellEvent(at: at(200), kind: .passiveRx, hexID: "0C13", rxSnr: 5)
    ], runID: nil, startingSeq: 0)

    let summary = try #require(try await store.fetchCellSummary(cellRaw: summaryCellA))
    #expect(summary.rxBestSnr == 9)
    #expect(summary.rxLastAt == at(300))
    #expect(summary.firstAt == at(100))
    #expect(summary.lastAt == at(300))
  }

  /// Since 2026-09-04 a row can carry a cell *and* a non-accepted gate outcome — the
  /// capture engine keeps the position of a doubtful fix rather than throwing it away. The
  /// summary is defined as a fold of the rows that are there, so it folds those too, and the
  /// invariant that makes the cache trustworthy has to survive it.
  @Test
  func `A doubtful placement folds like any other row, and the cache still equals a fresh fold`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples([
      cellEvent(at: at(0), kind: .passiveRx, hexID: "0C13", rxSnr: 4, gateOutcome: .inaccurateFix),
      cellEvent(at: at(10), kind: .probeTraceReply, hexID: "0C13", rxSnr: 2, txSnr: 9, gateOutcome: .staleFix),
      cellEvent(at: at(20), kind: .passiveRx, hexID: "0C13", rxSnr: 6)
    ], runID: nil, startingSeq: 0)

    let summary = try #require(try await store.fetchCellSummary(cellRaw: summaryCellA))
    #expect(summary.rxSnrCount == 3, "a doubtful position is still a real reading")
    #expect(summary.rxBestSnr == 6)
    #expect(summary.txSnrCount == 1)

    let rows = try await allRows(store, from: at(-1), to: at(100))
    #expect(summary == independentSummary(of: rows, cellRaw: summaryCellA))
  }

  // MARK: - Retention

  @Test
  func `A purge rebuilds the surviving cells instead of subtracting from them`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let now = at(0)
    let old = now.addingTimeInterval(-100 * 86400)
    let recent = now.addingTimeInterval(-1 * 86400)

    try await store.insertSamples([
      // The best RX reading and the best TX reading are both in the expired half, which is
      // exactly the case a decrement cannot handle: neither maximum can be undone.
      cellEvent(at: old, kind: .passiveRx, hexID: "0C13", rxSnr: 12),
      cellEvent(at: old.addingTimeInterval(1), kind: .probeTraceReply, hexID: "0C13", rxSnr: 3, txSnr: 9),
      cellEvent(at: old.addingTimeInterval(2), kind: .txHeard, hexID: "0C13", rxSnr: 1, pathHashes: ["0C13"]),
      cellEvent(at: recent, kind: .passiveRx, hexID: "0C13", rxSnr: 4),
      cellEvent(at: recent.addingTimeInterval(1), kind: .probeTraceReply, hexID: "0C13", rxSnr: 2, txSnr: -3)
    ], runID: nil, startingSeq: 0)

    _ = try await store.purgeExpired(retentionDays: 90, now: now)

    let summary = try #require(try await store.fetchCellSummary(cellRaw: summaryCellA))
    #expect(summary.rxBestSnr == 4, "the purged 12 dB reading must not still be the best")
    #expect(summary.rxSnrCount == 2)
    #expect(summary.txBestSnr == -3)
    #expect(summary.txSnrCount == 1)
    #expect(summary.echoCount == 0)
    #expect(summary.echoLastAt == nil)
    #expect(summary.firstAt == recent)

    // And it equals a fold computed from scratch by a different implementation.
    let rows = try await allRows(store, from: old.addingTimeInterval(-1), to: now.addingTimeInterval(1))
    #expect(summary == independentSummary(of: rows, cellRaw: summaryCellA))
  }

  @Test
  func `A cell that loses its last row loses its summary`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let now = at(0)
    try await store.insertSamples([
      cellEvent(at: now.addingTimeInterval(-100 * 86400), kind: .passiveRx, cell: summaryCellA, hexID: "0C13", rxSnr: 5),
      cellEvent(at: now.addingTimeInterval(-86400), kind: .passiveRx, cell: summaryCellB, hexID: "0C13", rxSnr: 5)
    ], runID: nil, startingSeq: 0)
    #expect(try await store.fetchCellSummaries().count == 2)

    _ = try await store.purgeExpired(retentionDays: 90, now: now)

    // An all-zero summary would draw a hexagon on the map for a place with no evidence
    // left behind it.
    #expect(try await store.fetchCellSummary(cellRaw: summaryCellA) == nil)
    #expect(try await store.fetchCellSummaries().map(\.cellRaw) == [summaryCellB])
  }

  @Test
  func `Deleting everything takes the derived table with it`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples(
      [cellEvent(at: at(0), kind: .passiveRx, hexID: "0C13", rxSnr: 5)],
      runID: nil,
      startingSeq: 0
    )
    try await store.deleteAll()
    #expect(try await store.fetchCellSummaries().isEmpty)
  }

  // MARK: - Rebuilds

  @Test
  func `The launch rebuild fills an empty table from rows written before it existed`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples([
      cellEvent(at: at(0), kind: .passiveRx, cell: summaryCellA, hexID: "0C13", rxSnr: 5),
      cellEvent(at: at(1), kind: .passiveRx, cell: summaryCellB, hexID: "42", rxSnr: 7)
    ], runID: nil, startingSeq: 0)

    // Simulate the first launch after this change: rows, no summaries.
    try await store.rebuildSummaries(cells: [])
    let cleared = try await store.rebuildAllSummaries()
    #expect(cleared == 2)

    // The guarded launch call is a no-op once the table is populated…
    #expect(try await store.rebuildAllSummariesIfEmpty() == 0)

    // …and does the work when it is not.
    try await store.deleteAllSummaries()
    #expect(try await store.rebuildAllSummariesIfEmpty() == 2)

    let rows = try await allRows(store, from: at(-1), to: at(60))
    for cell in [summaryCellA, summaryCellB] {
      #expect(try await store.fetchCellSummary(cellRaw: cell) == independentSummary(of: rows, cellRaw: cell))
    }
  }

  @Test
  func `The launch rebuild does nothing when there are no rows at all`() async throws {
    let store = try MapperRawLogStore.inMemory()
    #expect(try await store.rebuildAllSummariesIfEmpty() == 0)
    #expect(try await store.fetchCellSummaries().isEmpty)
  }

  /// The migration launch, in order: purge, then the guarded rebuild.
  ///
  /// A purge that starts with an empty cache must not leave a populated one. Every delete
  /// path rebuilds the cells it touched, and a cell that straddles the cutoff folds
  /// non-empty and is *inserted* — one such row makes `rebuildAllSummariesIfEmpty()` see a
  /// populated table and return 0, so every hexagon the purge did not touch is absent from
  /// the map for good, and the cache disagrees with the rows permanently.
  @Test
  func `A purge that begins with no cache leaves none, so the launch rebuild still runs`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let now = at(0)

    try await store.insertSamples([
      // Cell A straddles the cutoff: it loses a row and keeps one, so the purge rebuilds it.
      cellEvent(at: now.addingTimeInterval(-100 * 86400), kind: .passiveRx, cell: summaryCellA, hexID: "0C13", rxSnr: 12),
      cellEvent(at: now.addingTimeInterval(-86400), kind: .passiveRx, cell: summaryCellA, hexID: "0C13", rxSnr: 4),
      // Cell B is entirely inside the window, so nothing about it is touched.
      cellEvent(at: now.addingTimeInterval(-86400), kind: .passiveRx, cell: summaryCellB, hexID: "0C13", rxSnr: 7)
    ], runID: nil, startingSeq: 0)

    // The state the first launch of the build that added this table is in: rows, no cache.
    try await store.deleteAllSummaries()

    _ = try await store.purgeExpired(retentionDays: 90, now: now)
    #expect(
      try await store.fetchCellSummaries().isEmpty,
      "the straddling cell must not have been silently re-inserted on its own"
    )

    #expect(try await store.rebuildAllSummariesIfEmpty() == 2, "both surviving cells, not just the touched one")

    let rows = try await allRows(store, from: now.addingTimeInterval(-101 * 86400), to: now.addingTimeInterval(1))
    for cell in [summaryCellA, summaryCellB] {
      #expect(try await store.fetchCellSummary(cellRaw: cell) == independentSummary(of: rows, cellRaw: cell))
    }
  }

  @Test
  func `A purge that begins with a cache keeps it`() async throws {
    // The control: the ordinary launch, where the cache is already the map's data source
    // and dropping it would blank the map until something rebuilt it.
    let store = try MapperRawLogStore.inMemory()
    let now = at(0)
    try await store.insertSamples([
      cellEvent(at: now.addingTimeInterval(-100 * 86400), kind: .passiveRx, cell: summaryCellA, hexID: "0C13", rxSnr: 12),
      cellEvent(at: now.addingTimeInterval(-86400), kind: .passiveRx, cell: summaryCellA, hexID: "0C13", rxSnr: 4),
      cellEvent(at: now.addingTimeInterval(-86400), kind: .passiveRx, cell: summaryCellB, hexID: "0C13", rxSnr: 7)
    ], runID: nil, startingSeq: 0)

    _ = try await store.purgeExpired(retentionDays: 90, now: now)

    #expect(try await store.fetchCellSummaries().count == 2)
    #expect(try await store.fetchCellSummary(cellRaw: summaryCellA)?.rxBestSnr == 4)
  }

  // MARK: - The legend's two lines

  /// The ride line and the all-time line have to describe the same population.
  ///
  /// "This ride · N hexagons · M observations" sits directly under "All time · … · M
  /// observations", and the all-time half is a sum of `heardCount` over the summaries, which
  /// fold only rows that carry a cell. Counting the unplaced rows in the ride line put two
  /// different populations under one word — and on an early ride that began with a stretch
  /// of GPS warm-up, the ride line could report *more* observations than all time.
  @Test
  func `The placed-only count is exactly what the summaries folded`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples([
      cellEvent(at: at(0), kind: .passiveRx, cell: summaryCellA, hexID: "0C13", rxSnr: 6),
      cellEvent(at: at(1), kind: .passiveRx, cell: summaryCellB, hexID: "0C13", rxSnr: 5),
      // The warm-up rows: heard, real, and in no hexagon.
      cellEvent(at: at(2), kind: .passiveRx, cell: nil, hexID: "0C13", rxSnr: 4),
      cellEvent(at: at(3), kind: .passiveRx, cell: nil, hexID: "0C13", rxSnr: 3),
      // A kind the "observations" word does not cover either way.
      cellEvent(at: at(4), kind: .probeTraceReply, cell: summaryCellA, hexID: "0C13", txSnr: 2)
    ], runID: nil, startingSeq: 0)

    let allTime = try await store.fetchCellSummaries().reduce(0) { $0 + $1.heardCount }
    let placed = try await store.countSamples(
      kind: .passiveRx, since: at(-1), until: at(100), placedOnly: true
    )
    let everything = try await store.countSamples(kind: .passiveRx, since: at(-1), until: at(100))

    #expect(placed == allTime, "the ride line must count what the all-time line contains")
    #expect(placed == 2)
    #expect(everything == 4, "the unfiltered reading is still available for 'did we hear anything at all'")
  }

  // MARK: - Observer sightings

  @Test
  func `Observer sightings come back by content hash and nothing else does`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples([
      // Two observers heard the same packet; one heard a second packet.
      cellEvent(at: at(0), kind: .observerSighting, cell: nil, hexID: "AA01", rxSnr: -4, contentHash: "aaaa111122223333"),
      cellEvent(at: at(1), kind: .observerSighting, cell: nil, hexID: "BB02", rxSnr: -9, contentHash: "aaaa111122223333"),
      cellEvent(at: at(2), kind: .observerSighting, cell: nil, hexID: "AA01", rxSnr: -2, contentHash: "bbbb444455556666"),
      // A sighting of a packet nobody asked about.
      cellEvent(at: at(3), kind: .observerSighting, cell: nil, hexID: "CC03", rxSnr: 0, contentHash: "cccc777788889999"),
      // A `sent` row carrying the same hash: it is ours, not a sighting, and must not come
      // back from a query about who heard us.
      cellEvent(at: at(4), kind: .sent, contentHash: "aaaa111122223333")
    ], runID: nil, startingSeq: 0)

    let found = try await store.fetchObserverSightings(contentHashes: ["aaaa111122223333", "bbbb444455556666"])
    #expect(found.count == 3)
    #expect(found.allSatisfy { $0.kind == .observerSighting })
    #expect(found.map(\.timestamp) == [at(0), at(1), at(2)], "oldest first")
    #expect(Set(found.compactMap(\.repeaterHexID)) == ["AA01", "BB02"])

    #expect(try await store.fetchObserverSightings(contentHashes: []).isEmpty)
    #expect(try await store.fetchObserverSightings(contentHashes: ["not-a-hash"]).isEmpty)
  }

  @Test
  func `Observer sightings do not colour a hexagon`() async throws {
    // §2: a sighting row records what somebody else heard, and carries no position. It must
    // not fold into any cell — least of all the one we happened to be standing in.
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples([
      cellEvent(at: at(0), kind: .observerSighting, cell: nil, hexID: "AA01", rxSnr: 20, contentHash: "aaaa111122223333")
    ], runID: nil, startingSeq: 0)
    #expect(try await store.fetchCellSummaries().isEmpty)
  }
}
