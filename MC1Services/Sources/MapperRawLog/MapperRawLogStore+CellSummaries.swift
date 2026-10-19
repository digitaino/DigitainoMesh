import Foundation
import MC1Services
import SwiftData

/// The derived per-cell cache: how it is maintained, read and rebuilt
/// (docs/SIGNAL_MAPPER_V3.md §7 step 3).
///
/// Every entry point here is either a *fold of rows that exist* or a read of one. Nothing
/// in this file is a source of truth, and the suite asserts that by comparing the table
/// against a from-scratch fold after a mix of inserts and a purge.
public extension MapperRawLogStore {
  /// How many rows one rebuild pass holds at a time.
  ///
  /// The same argument ``deleteChunkSize`` makes: a launch rebuild walks the whole table,
  /// and materialising 400 000 rows to add up a few thousand cells would be the one
  /// allocation this module cannot afford. The folds themselves are value types, so what
  /// survives a pass is a dictionary of small structs.
  internal static var rebuildChunkSize: Int {
    1000
  }

  // MARK: - Reads

  /// Every cell's summary, ordered by cell so a snapshot diffs against the previous one.
  ///
  /// The map's whole data source: two layers, one colour per hexagon, no row scan. A
  /// phone that has ridden for months holds a few thousand of these — orders of magnitude
  /// less than the rows behind them.
  func fetchCellSummaries() throws -> [MapperCellSummaryDTO] {
    let descriptor = FetchDescriptor<MapperCellSummary>(
      sortBy: [SortDescriptor(\MapperCellSummary.cellRaw, order: .forward)]
    )
    return try modelContext.fetch(descriptor).map(MapperCellSummaryDTO.init(from:))
  }

  /// One cell's summary, or nil for a hexagon nothing has ever been recorded in.
  func fetchCellSummary(cellRaw: UInt64) throws -> MapperCellSummaryDTO? {
    try summary(cellRaw: Int64(bitPattern: cellRaw)).map(MapperCellSummaryDTO.init(from:))
  }

  // MARK: - Rebuilds

  /// Recomputes the named cells' summaries from the rows that remain.
  ///
  /// **Rebuild rather than subtract**, and this is the reason the cache is safe to keep at
  /// all: `rxBestSnr` and `txBestSnr` are maxima, and a maximum whose row has just been
  /// purged cannot be undone arithmetically — the second-best reading is not recoverable
  /// from the summary, only from the rows. Counts and sums *could* be decremented; doing
  /// half the fields one way and half the other is how a cache starts disagreeing with its
  /// source, so every delete path funnels through here.
  ///
  /// A cell whose last row is gone loses its summary entirely: an all-zero row would draw
  /// a hexagon on the map for a place with no evidence left.
  ///
  /// - Returns: how many cells were recomputed.
  @discardableResult
  func rebuildSummaries(cells: Set<UInt64>) throws -> Int {
    try rebuildSummaries(cellsRaw: Set(cells.map { Int64(bitPattern: $0) }))
  }

  /// Rebuilds the whole table from the rows, in one pass.
  ///
  /// Two callers, both rare: the first launch after this change, when rows exist and the
  /// summary table does not (``rebuildAllSummariesIfEmpty()``), and a debug affordance for
  /// "prove the cache is honest". Ordinary operation never needs it — inserts fold and
  /// deletes rebuild the cells they touched.
  ///
  /// - Returns: how many cells the table ended up with.
  @discardableResult
  func rebuildAllSummaries() throws -> Int {
    var folds: [Int64: MapperCellSummaryFold] = [:]
    var offset = 0
    while true {
      var descriptor = FetchDescriptor<MapperRawSample>(
        sortBy: [SortDescriptor(\MapperRawSample.seq, order: .forward)]
      )
      descriptor.fetchOffset = offset
      descriptor.fetchLimit = Self.rebuildChunkSize
      let batch = try modelContext.fetch(descriptor)
      if batch.isEmpty { break }
      for row in batch {
        guard let input = MapperCellSummaryInput(model: row) else { continue }
        folds[input.cellRaw, default: MapperCellSummaryFold()].fold(input)
      }
      offset += batch.count
      if batch.count < Self.rebuildChunkSize { break }
    }

    // Cleared and saved *before* the fresh rows go in. The unique constraint on `cellRaw`
    // resolves an insert that collides with an existing key as an upsert, and a delete
    // waiting in the same transaction is exactly the situation where "which row won" stops
    // being obvious. Two transactions cost one extra save on a path that runs once.
    for stale in try modelContext.fetch(FetchDescriptor<MapperCellSummary>()) {
      modelContext.delete(stale)
    }
    try modelContext.save()

    for (cellRaw, fold) in folds {
      let model = MapperCellSummary(cellRaw: cellRaw)
      fold.apply(to: model)
      modelContext.insert(model)
    }
    try modelContext.save()
    return folds.count
  }

  /// The launch call: rebuild only when the table is empty and rows exist.
  ///
  /// That is the first run after this change — the rows have been accumulating since step
  /// 1 and nothing has folded them yet. Cheap on every other launch: two counts.
  ///
  /// - Returns: how many cells were rebuilt; 0 when there was nothing to do.
  @discardableResult
  func rebuildAllSummariesIfEmpty() throws -> Int {
    guard try modelContext.fetchCount(FetchDescriptor<MapperCellSummary>()) == 0 else { return 0 }
    guard try modelContext.fetchCount(FetchDescriptor<MapperRawSample>()) > 0 else { return 0 }
    return try rebuildAllSummaries()
  }

  // MARK: - Internals

  /// Folds a batch of events into their cells' summaries. Called from
  /// ``insertSamples(_:runID:startingSeq:)`` inside the same transaction as the rows, so
  /// the cache cannot survive a save the rows did not.
  internal func foldIntoSummaries(_ events: [MapperRawSampleEvent]) throws {
    // One `(row, fold)` slot per distinct cell, so a 100-event flush that crossed two
    // hexagons costs two summary fetches rather than a hundred.
    var pending: [Int64: (model: MapperCellSummary, fold: MapperCellSummaryFold)] = [:]
    for event in events {
      // Rows with no fix have no cell to belong to. They are still rows — "the radio link
      // dropped and we do not know where" is evidence — they just cannot colour a hexagon.
      guard let input = MapperCellSummaryInput(event: event) else { continue }
      var slot: (model: MapperCellSummary, fold: MapperCellSummaryFold)
      if let existing = pending[input.cellRaw] {
        slot = existing
      } else if let stored = try summary(cellRaw: input.cellRaw) {
        slot = (stored, MapperCellSummaryFold(model: stored))
      } else {
        let fresh = MapperCellSummary(cellRaw: input.cellRaw)
        modelContext.insert(fresh)
        slot = (fresh, MapperCellSummaryFold())
      }
      slot.fold.fold(input)
      pending[input.cellRaw] = slot
    }
    for slot in pending.values {
      slot.fold.apply(to: slot.model)
    }
  }

  @discardableResult
  internal func rebuildSummaries(cellsRaw cells: Set<Int64>) throws -> Int {
    guard !cells.isEmpty else { return 0 }
    for cellRaw in cells {
      var fold = MapperCellSummaryFold()
      var offset = 0
      while true {
        var descriptor = FetchDescriptor<MapperRawSample>(
          predicate: #Predicate<MapperRawSample> { $0.cellRaw == cellRaw },
          sortBy: [SortDescriptor(\MapperRawSample.seq, order: .forward)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = Self.rebuildChunkSize
        let batch = try modelContext.fetch(descriptor)
        if batch.isEmpty { break }
        for row in batch {
          guard let input = MapperCellSummaryInput(model: row) else { continue }
          fold.fold(input)
        }
        offset += batch.count
        if batch.count < Self.rebuildChunkSize { break }
      }

      let stored = try summary(cellRaw: cellRaw)
      if fold.isEmpty {
        if let stored { modelContext.delete(stored) }
        continue
      }
      if let stored {
        fold.apply(to: stored)
      } else {
        let fresh = MapperCellSummary(cellRaw: cellRaw)
        fold.apply(to: fresh)
        modelContext.insert(fresh)
      }
    }
    try modelContext.save()
    return cells.count
  }

  /// Drops the derived table. Three callers: ``deleteAll()``, where the rows are going too;
  /// ``purgeExpired(retentionDays:now:)``, which restores the emptiness it found so the
  /// launch rebuild still runs; and the suite that checks a rebuild really rebuilds.
  internal func deleteAllSummaries() throws {
    for row in try modelContext.fetch(FetchDescriptor<MapperCellSummary>()) {
      modelContext.delete(row)
    }
    try modelContext.save()
  }

  private func summary(cellRaw: Int64) throws -> MapperCellSummary? {
    let target = cellRaw
    var descriptor = FetchDescriptor<MapperCellSummary>(
      predicate: #Predicate<MapperCellSummary> { $0.cellRaw == target }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }
}
