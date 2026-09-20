import Foundation
import MC1Services
import SwiftData

// MARK: - Filter

/// What the export screen narrows the observation table down to
/// (docs/SIGNAL_MAPPER_V3.md §5: "filterable by hexagon, date, repeater and packet type").
///
/// Every dimension is a *tri-state*: `nil` means "no clause of this kind" while an empty
/// collection means "match nothing". They are different answers and the screen needs both —
/// a user who unticks every kind must get an export button reading `0 rows`, not the whole
/// table. The sentinel-free spelling (`Set?` rather than a `Set` where empty means all) is
/// what keeps that distinction from being an accident.
///
/// Dates are half-open, `since ..< until`, the same convention
/// ``MapperRawLogStore/fetchSamples(cellRaw:since:until:limit:)`` uses, so two consecutive
/// windows tile without double-counting the instant they share.
public struct MapperSampleFilter: Sendable, Equatable, Hashable {
  /// Inclusive lower bound. Nil for "as far back as retention kept".
  public var since: Date?
  /// Exclusive upper bound. Nil for "up to the newest row".
  public var until: Date?
  /// H3 indexes to keep. Nil for every hexagon, including rows recorded with no fix at all
  /// — which an explicit set never matches, because a row with no cell is in no hexagon.
  ///
  /// One `IN` list, not chunked: keep the set well under
  /// ``MapperRawLogStore/maxKeysPerFetch``, the module's own rule for how many keys may ride
  /// in a single `contains` predicate. A whole ride's hexagons can approach that on a long
  /// survey, which is why the export screen scopes a ride by ``runID`` instead.
  public var cellRaws: Set<UInt64>?
  /// One ride's rows, by the id they were stamped with — the export screen's "This ride".
  ///
  /// A separate clause from ``cellRaws`` rather than "the ride's hexagons", for two reasons:
  /// it is exact (a ride row recorded with no fix belongs to the ride but to no hexagon, and
  /// the hexagon spelling would silently drop it), and it is one indexed integer comparison
  /// against `#Index<MapperRawSample>([\.runID])` where the hexagon spelling is an `IN` list
  /// as long as the ride was.
  public var runID: UUID?
  /// Exact hash-width match, the same rule
  /// ``MapperRawLogStore/fetchSamples(repeaterHexID:cellRaw:since:until:limit:)`` states:
  /// a predicate cannot express `NodeHexID.identifiesSameNode`'s bidirectional prefix rule,
  /// so cross-width matching stays a decision for the caller.
  public var repeaterHexID: String?
  /// Kinds to keep. Nil keeps every row, **including one written by a future build whose
  /// kind this one has no case for** — the reason this is not spelled as
  /// `MapperRawSampleKind.allCases`.
  public var kinds: Set<MapperRawSampleKind>?

  public init(
    since: Date? = nil,
    until: Date? = nil,
    cellRaws: Set<UInt64>? = nil,
    runID: UUID? = nil,
    repeaterHexID: String? = nil,
    kinds: Set<MapperRawSampleKind>? = nil
  ) {
    self.since = since
    self.until = until
    self.cellRaws = cellRaws
    self.runID = runID
    self.repeaterHexID = repeaterHexID
    self.kinds = kinds
  }

  /// True when the filter names no clause at all, i.e. it selects the whole table.
  public var isUnfiltered: Bool {
    since == nil && until == nil && cellRaws == nil && runID == nil
      && repeaterHexID == nil && kinds == nil
  }

  /// True when a clause can never match, so a count is knowably zero without asking SQLite.
  public var isEmpty: Bool {
    if let cellRaws, cellRaws.isEmpty { return true }
    if let kinds, kinds.isEmpty { return true }
    if let since, let until, since >= until { return true }
    return false
  }

  // MARK: - Predicate

  /// One `#Predicate` for every combination of clauses, rather than eight hand-written
  /// descriptors.
  ///
  /// Each optional clause is compiled as `!filtersX || <clause>` over a **captured `Bool`**,
  /// so an absent clause is a constant the predicate already knows the answer to rather than
  /// a per-row column test. The alternative — force-unwrapping the optional inside the macro
  /// — is not in the predicate expression set and would not compile.
  ///
  /// `afterSeq` is the export's keyset cursor. `Int64.min` stands in for "from the
  /// beginning" because ``MapperRawSample/seq`` is minted from zero upward and can never
  /// reach it; an offset-based page would re-walk everything it had already skipped, which
  /// on a 40 000-row export is quadratic.
  func predicate(afterSeq: Int64? = nil) -> Predicate<MapperRawSample> {
    let from = since ?? .distantPast
    let to = until ?? .distantFuture
    let cursor = afterSeq ?? Int64.min

    let filtersCells = cellRaws != nil
    // `[Int64?]` rather than `[Int64]`: the column is optional and a predicate has to
    // compare like with like — the idiom `fetchObserverSightings(contentHashes:)` uses.
    let cells: [Int64?] = (cellRaws ?? []).map { Int64(bitPattern: $0) }
    let filtersRun = runID != nil
    let run = runID
    let filtersRepeater = repeaterHexID != nil
    let hexID = repeaterHexID
    let filtersKinds = kinds != nil
    let kindRaws: [Int] = (kinds ?? []).map(\.rawValue)

    return #Predicate<MapperRawSample> { row in
      row.timestamp >= from
        && row.timestamp < to
        && row.seq > cursor
        && (!filtersCells || cells.contains(row.cellRaw))
        && (!filtersRun || row.runID == run)
        && (!filtersRepeater || row.repeaterHexID == hexID)
        && (!filtersKinds || kindRaws.contains(row.kindRaw))
    }
  }
}

// MARK: - Reads added for step 5

/// The export screen's queries (docs/SIGNAL_MAPPER_V3.md §7 step 5). Additive: nothing here
/// changes an existing query.
public extension MapperRawLogStore {
  /// How many rows the filter selects — a count, never a fetch.
  ///
  /// The export footer reads this on every filter change, so it must not materialise the
  /// rows it is counting: a 40 000-row "Everything · all kinds" selection would otherwise
  /// build 40 000 DTOs to print one number.
  func countSamples(matching filter: MapperSampleFilter) throws -> Int {
    guard !filter.isEmpty else { return 0 }
    return try modelContext.fetchCount(
      FetchDescriptor<MapperRawSample>(predicate: filter.predicate())
    )
  }

  /// One page of the filtered table in `seq` order, starting after `seq`.
  ///
  /// Keyset pagination, not offset: the export walks the whole selection, and
  /// `fetchOffset` makes page *n* cost *n* pages of work. `seq` is the only column that can
  /// carry the cursor — it is globally monotonic since v3 (``nextSeq()``) and unique, where
  /// `timestamp` is neither.
  ///
  /// - Parameters:
  ///   - seq: the last `seq` the caller has already written, or nil to start at the top.
  /// - Returns: at most `limit` rows. A short page is the last page.
  func fetchSamples(
    matching filter: MapperSampleFilter,
    after seq: Int64?,
    limit: Int
  ) throws -> [MapperRawSampleDTO] {
    guard limit > 0, !filter.isEmpty else { return [] }
    var descriptor = FetchDescriptor<MapperRawSample>(
      predicate: filter.predicate(afterSeq: seq),
      sortBy: [SortDescriptor(\MapperRawSample.seq, order: .forward)]
    )
    descriptor.fetchLimit = limit
    return try modelContext.fetch(descriptor).map(MapperRawSampleDTO.init(from:))
  }

  /// Every repeater any row credits since `since`, sorted, for the export's repeater picker.
  ///
  /// Distinct-in-Swift over a chunked walk rather than a `GROUP BY`: SwiftData has no
  /// distinct fetch, and what survives a chunk is a set of four-character strings. Rows that
  /// credit nobody (direct-routed packets, breadcrumbs) contribute nothing, which is exactly
  /// what a picker of "repeaters heard in this window" should list.
  func distinctRepeaterHexIDs(since: Date?) throws -> [String] {
    let from = since ?? .distantPast
    var found: Set<String> = []
    var offset = 0
    while true {
      var descriptor = FetchDescriptor<MapperRawSample>(
        predicate: #Predicate<MapperRawSample> {
          $0.repeaterHexID != nil && $0.timestamp >= from
        },
        sortBy: [SortDescriptor(\MapperRawSample.seq, order: .forward)]
      )
      descriptor.fetchOffset = offset
      descriptor.fetchLimit = Self.rebuildChunkSize
      let batch = try modelContext.fetch(descriptor)
      if batch.isEmpty { break }
      for row in batch {
        if let hexID = row.repeaterHexID { found.insert(hexID) }
      }
      offset += batch.count
      if batch.count < Self.rebuildChunkSize { break }
    }
    return found.sorted()
  }

  /// Deletes every row the filter selects, chunked like every other bulk delete here.
  ///
  /// Run *headers* are untouched, the same rule ``deleteSamples(olderThan:)`` states: a ride
  /// whose rows have gone still happened.
  ///
  /// - Returns: how many rows were deleted.
  @discardableResult
  func deleteSamples(matching filter: MapperSampleFilter) throws -> Int {
    guard !filter.isEmpty else { return 0 }
    let predicate = filter.predicate()
    var deleted = 0
    var touched: Set<Int64> = []
    while true {
      var descriptor = FetchDescriptor<MapperRawSample>(predicate: predicate)
      descriptor.fetchLimit = Self.deleteChunkSize
      let batch = try modelContext.fetch(descriptor)
      if batch.isEmpty { break }
      for row in batch {
        if let cellRaw = row.cellRaw { touched.insert(cellRaw) }
        modelContext.delete(row)
      }
      try modelContext.save()
      deleted += batch.count
    }
    // Every cell that lost a row is recomputed from what is left rather than decremented —
    // see ``rebuildSummaries(cellsRaw:)`` for why a maximum cannot be subtracted.
    try rebuildSummaries(cellsRaw: touched)
    return deleted
  }

  /// The newest run's id, or nil when no ride was ever recorded — what the export screen's
  /// "This ride" scope resolves to, and what hides the control when there has been no ride.
  ///
  /// Newest by `startedAt`, because a run reconciled after a jetsam can carry an `endedAt`
  /// stamped from its last sample and two runs would then sort by when they *stopped*
  /// mattering rather than by when they happened.
  func latestRunID() throws -> UUID? {
    var descriptor = FetchDescriptor<MapperSurveyRun>(
      sortBy: [SortDescriptor(\MapperSurveyRun.startedAt, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first?.id
  }
}
