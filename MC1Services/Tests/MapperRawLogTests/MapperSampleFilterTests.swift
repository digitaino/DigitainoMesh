import Foundation
@testable import MapperRawLog
import MC1Services
import Testing

// MARK: - Fixtures

/// Fixed epoch so every window in this suite is arithmetic on a known instant rather than
/// on "now", which would make a 24-hour boundary test flaky once a day.
private let filterEpoch = Date(timeIntervalSince1970: 1_756_800_000)

private let filterCellA: UInt64 = 0x0892_8308_280F_FFFF
private let filterCellB: UInt64 = 0x0892_2D6C_2D3F_FFFF

/// One row, spelled out, because every assertion below is about *which* rows a clause keeps.
private func filterEvent(
  at timestamp: Date,
  kind: MapperRawSampleKind,
  cell: UInt64?,
  hexID: String?
) -> MapperRawSampleEvent {
  MapperRawSampleEvent(
    timestamp: timestamp,
    kind: kind,
    rxSnr: 6.5,
    repeaterHexID: hexID,
    cellRaw: cell,
    gateOutcome: cell == nil ? .noFix : .accepted
  )
}

/// The suite's whole population: nine rows, every one distinguishable from every other on
/// at least one clause.
///
/// | seq | offset | kind             | cell | repeater |
/// |-----|--------|------------------|------|----------|
/// | 0   | +0 h   | passiveRx        | A    | 0C13     |
/// | 1   | +1 h   | passiveRx        | A    | 0C13     |
/// | 2   | +2 h   | passiveRx        | B    | 42AA     |
/// | 3   | +3 h   | txHeard          | A    | 42AA     |
/// | 4   | +4 h   | probeTraceReply  | B    | 0C13     |
/// | 5   | +5 h   | probeAttempt     | A    | nil      |
/// | 6   | +6 h   | breadcrumb       | A    | nil      |
/// | 7   | +7 h   | sent             | nil  | nil      |
/// | 8   | +8 h   | observerSighting | nil  | 99FF     |
private let filterFixtures: [MapperRawSampleEvent] = [
  filterEvent(at: filterEpoch, kind: .passiveRx, cell: filterCellA, hexID: "0C13"),
  filterEvent(at: filterEpoch.addingTimeInterval(3600), kind: .passiveRx, cell: filterCellA, hexID: "0C13"),
  filterEvent(at: filterEpoch.addingTimeInterval(7200), kind: .passiveRx, cell: filterCellB, hexID: "42AA"),
  filterEvent(at: filterEpoch.addingTimeInterval(10800), kind: .txHeard, cell: filterCellA, hexID: "42AA"),
  filterEvent(at: filterEpoch.addingTimeInterval(14400), kind: .probeTraceReply, cell: filterCellB, hexID: "0C13"),
  filterEvent(at: filterEpoch.addingTimeInterval(18000), kind: .probeAttempt, cell: filterCellA, hexID: nil),
  filterEvent(at: filterEpoch.addingTimeInterval(21600), kind: .breadcrumb, cell: filterCellA, hexID: nil),
  filterEvent(at: filterEpoch.addingTimeInterval(25200), kind: .sent, cell: nil, hexID: nil),
  filterEvent(at: filterEpoch.addingTimeInterval(28800), kind: .observerSighting, cell: nil, hexID: "99FF")
]

private func makeFilterStore() async throws -> MapperRawLogStore {
  let store = try MapperRawLogStore.inMemory()
  try await store.insertSamples(filterFixtures, runID: nil, startingSeq: 0)
  return store
}

/// The hand count the store is checked against: the same rules, evaluated in Swift over the
/// fixture array rather than in SQLite over the rows.
private func handCount(_ filter: MapperSampleFilter) -> Int {
  filterFixtures.filter { event in
    if let since = filter.since, event.timestamp < since { return false }
    if let until = filter.until, event.timestamp >= until { return false }
    if let cellRaws = filter.cellRaws {
      guard let cell = event.cellRaw, cellRaws.contains(cell) else { return false }
    }
    if let hexID = filter.repeaterHexID, event.repeaterHexID != hexID { return false }
    if let kinds = filter.kinds, !kinds.contains(event.kind) { return false }
    // The fixtures are all recorded outside a ride, so a run clause matches none of them —
    // the run scope has its own test with rows that actually carry a run id.
    if filter.runID != nil { return false }
    return true
  }.count
}

// MARK: - Suite

@Suite("Mapper sample filter")
struct MapperSampleFilterTests {
  @Test
  func `An empty filter counts every row`() async throws {
    let store = try await makeFilterStore()
    let filter = MapperSampleFilter()
    #expect(filter.isUnfiltered)
    #expect(try await store.countSamples(matching: filter) == handCount(filter))
    #expect(try await store.countSamples(matching: filter) == 9)
  }

  @Test
  func `Each clause counts what a hand count of the same rules does`() async throws {
    let store = try await makeFilterStore()
    let filters: [MapperSampleFilter] = [
      MapperSampleFilter(since: filterEpoch.addingTimeInterval(10800)),
      MapperSampleFilter(until: filterEpoch.addingTimeInterval(10800)),
      MapperSampleFilter(
        since: filterEpoch.addingTimeInterval(3600),
        until: filterEpoch.addingTimeInterval(18000)
      ),
      MapperSampleFilter(cellRaws: [filterCellA]),
      MapperSampleFilter(cellRaws: [filterCellA, filterCellB]),
      MapperSampleFilter(repeaterHexID: "0C13"),
      MapperSampleFilter(kinds: [.passiveRx]),
      MapperSampleFilter(kinds: [.passiveRx, .txHeard, .probeTraceReply]),
      MapperSampleFilter(
        since: filterEpoch.addingTimeInterval(3600),
        cellRaws: [filterCellA],
        repeaterHexID: "42AA",
        kinds: [.txHeard]
      )
    ]
    for filter in filters {
      let counted = try await store.countSamples(matching: filter)
      #expect(counted == handCount(filter), "filter \(filter) counted \(counted)")
    }
  }

  @Test
  func `until is exclusive and since inclusive, so consecutive windows tile`() async throws {
    let store = try await makeFilterStore()
    let split = filterEpoch.addingTimeInterval(10800)
    let before = try await store.countSamples(matching: MapperSampleFilter(until: split))
    let after = try await store.countSamples(matching: MapperSampleFilter(since: split))
    #expect(before == 3)
    #expect(after == 6)
    #expect(before + after == 9)
  }

  @Test
  func `An empty kind set selects nothing, which is not what nil means`() async throws {
    let store = try await makeFilterStore()
    #expect(try await store.countSamples(matching: MapperSampleFilter(kinds: [])) == 0)
    #expect(try await store.countSamples(matching: MapperSampleFilter(kinds: nil)) == 9)
    #expect(try await store.countSamples(matching: MapperSampleFilter(cellRaws: [])) == 0)
  }

  @Test
  func `A cell clause never matches a row that has no cell`() async throws {
    let store = try await makeFilterStore()
    let placed = try await store.countSamples(matching: MapperSampleFilter(cellRaws: [filterCellA, filterCellB]))
    #expect(placed == 7)
  }

  @Test
  func `Paging by seq walks the selection once, in order, with no gaps or repeats`() async throws {
    let store = try await makeFilterStore()
    let filter = MapperSampleFilter(kinds: [.passiveRx, .txHeard, .probeTraceReply, .probeAttempt])
    var cursor: Int64?
    var seqs: [Int64] = []
    while true {
      let page = try await store.fetchSamples(matching: filter, after: cursor, limit: 2)
      if page.isEmpty { break }
      seqs.append(contentsOf: page.map(\.seq))
      cursor = page.last?.seq
    }
    #expect(seqs == [0, 1, 2, 3, 4, 5])
    #expect(seqs.count == handCount(filter))
  }

  @Test
  func `The repeater picker lists every credited repeater in the window, sorted`() async throws {
    let store = try await makeFilterStore()
    #expect(try await store.distinctRepeaterHexIDs(since: nil) == ["0C13", "42AA", "99FF"])
    #expect(
      try await store.distinctRepeaterHexIDs(since: filterEpoch.addingTimeInterval(10800))
        == ["0C13", "42AA", "99FF"]
    )
    #expect(
      try await store.distinctRepeaterHexIDs(since: filterEpoch.addingTimeInterval(25200)) == ["99FF"]
    )
  }

  @Test
  func `Deleting by filter removes exactly the counted rows and rebuilds the summaries`() async throws {
    let store = try await makeFilterStore()
    let filter = MapperSampleFilter(cellRaws: [filterCellB])
    let expected = try await store.countSamples(matching: filter)
    #expect(expected == 2)

    let deleted = try await store.deleteSamples(matching: filter)
    #expect(deleted == expected)
    #expect(try await store.countSamples(matching: MapperSampleFilter()) == 7)
    // The derived table is rebuilt from what is left, not decremented: cell B lost every
    // row it had, so it must be gone rather than sitting at zero.
    #expect(try await store.fetchCellSummary(cellRaw: filterCellB) == nil)
    #expect(try await store.fetchCellSummary(cellRaw: filterCellA) != nil)
  }

  @Test
  func `The newest run is the This ride scope, and it selects that run's rows`() async throws {
    let store = try MapperRawLogStore.inMemory()
    #expect(try await store.latestRunID() == nil)

    let older = try await store.createRun(
      radioID: nil,
      frequency: nil,
      bandwidth: nil,
      spreadingFactor: nil,
      codingRate: nil,
      txPower: nil,
      focusTargetHexIDs: [],
      startedAt: filterEpoch
    )
    let newer = try await store.createRun(
      radioID: nil,
      frequency: nil,
      bandwidth: nil,
      spreadingFactor: nil,
      codingRate: nil,
      txPower: nil,
      focusTargetHexIDs: [],
      startedAt: filterEpoch.addingTimeInterval(86400)
    )
    #expect(try await store.latestRunID() == newer)

    try await store.insertSamples(
      [filterEvent(at: filterEpoch, kind: .passiveRx, cell: filterCellA, hexID: "0C13")],
      runID: older,
      startingSeq: 0
    )
    try await store.insertSamples(
      [
        filterEvent(at: filterEpoch.addingTimeInterval(86400), kind: .passiveRx, cell: filterCellB, hexID: "42AA"),
        filterEvent(at: filterEpoch.addingTimeInterval(86460), kind: .sent, cell: nil, hexID: nil)
      ],
      runID: newer,
      startingSeq: 1
    )
    // Two rows for the newer run, and one of them has no fix — the reason the scope is the
    // run id rather than the run's hexagons, which would silently drop it.
    #expect(try await store.countSamples(matching: MapperSampleFilter(runID: newer)) == 2)
    #expect(try await store.countSamples(matching: MapperSampleFilter(runID: older)) == 1)
    #expect(try await store.countSamples(matching: MapperSampleFilter(runID: UUID())) == 0)
    // A run clause combines with the others rather than replacing them.
    #expect(
      try await store.countSamples(matching: MapperSampleFilter(runID: newer, kinds: [.sent])) == 1
    )
    let rows = try await store.fetchSamples(
      matching: MapperSampleFilter(runID: newer),
      after: nil,
      limit: 10
    )
    #expect(rows.map(\.seq) == [1, 2])
    #expect(rows.allSatisfy { $0.runID == newer })
  }
}
