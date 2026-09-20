import Foundation
import MC1Services
import SwiftData

// MARK: - Ride totals

/// What one ride's rows add up to, for the completion sheet (docs/SIGNAL_MAPPER_V3.md §8).
///
/// Every field is a count of rows the ride wrote, which is the point: the old sheet showed
/// the probe engine's in-memory tallies, and an engine that was rebuilt by a BLE rewire
/// could disagree with the log it had been writing to. These cannot disagree — they *are*
/// the log.
public struct MapperRideTotals: Sendable, Equatable {
  /// Distinct hexagons any row of this ride was placed in.
  public let hexagonCount: Int
  /// Distinct repeaters heard directly (§1) anywhere on the ride — rows that credit a
  /// repeater *and* carry our own reading of it.
  public let repeatersHeard: Int
  /// Passively received packets, the same rows ``MapperCellSummaryDTO/heardCount`` folds.
  public let observationCount: Int
  public let probesSent: Int
  public let probeReplies: Int

  public init(
    hexagonCount: Int = 0,
    repeatersHeard: Int = 0,
    observationCount: Int = 0,
    probesSent: Int = 0,
    probeReplies: Int = 0
  ) {
    self.hexagonCount = hexagonCount
    self.repeatersHeard = repeatersHeard
    self.observationCount = observationCount
    self.probesSent = probesSent
    self.probeReplies = probeReplies
  }
}

// MARK: - Reads added for step 4

/// Reads the map, the card and the completion sheet needed and the store did not yet have
/// (docs/SIGNAL_MAPPER_V3.md §7 step 4). Additive: nothing here changes an existing query.
public extension MapperRawLogStore {
  /// How many rows of one kind fall in a window — a count, never a fetch.
  ///
  /// The legend's "This ride · N hexagons · M observations" needs M every refresh while a
  /// ride is open, and M is a count of `passiveRx` rows. Materialising them to count them
  /// would be a full ride's worth of DTOs every 20 seconds; `fetchCount` asks SQLite.
  ///
  /// `until` is exclusive, matching ``fetchSamples(cellRaw:since:until:limit:)``.
  ///
  /// - Parameter placedOnly: restrict the count to rows that carry a cell. The legend needs
  ///   it: its all-time half is a sum over the summaries, which fold only placed rows, so a
  ///   ride line that also counted the unplaced ones described a different population under
  ///   the same word "observations" — and a ride begun in a garage could report *more* this
  ///   ride than all time. Everything else wants the unfiltered "how much arrived" reading.
  func countSamples(
    kind: MapperRawSampleKind,
    since: Date,
    until: Date,
    placedOnly: Bool = false
  ) throws -> Int {
    let kindRaw = kind.rawValue
    let from = since
    let to = until
    let filtersPlaced = placedOnly
    return try modelContext.fetchCount(FetchDescriptor<MapperRawSample>(
      predicate: #Predicate<MapperRawSample> {
        $0.kindRaw == kindRaw && $0.timestamp >= from && $0.timestamp < to
          && (!filtersPlaced || $0.cellRaw != nil)
      }
    ))
  }

  /// Everything the ride completion sheet shows, folded from that ride's own rows.
  ///
  /// Chunked for the reason every other whole-table walk in this module is: a long ride is
  /// tens of thousands of rows, and the sheet needs five integers out of them, not the
  /// rows. What survives a chunk is two hash sets of short strings.
  func rideTotals(runID: UUID) throws -> MapperRideTotals {
    let id = runID
    var cells: Set<Int64> = []
    var repeaters: Set<String> = []
    var observations = 0
    var probesSent = 0
    var probeReplies = 0

    var offset = 0
    while true {
      var descriptor = FetchDescriptor<MapperRawSample>(
        predicate: #Predicate<MapperRawSample> { $0.runID == id },
        sortBy: [SortDescriptor(\MapperRawSample.seq, order: .forward)]
      )
      descriptor.fetchOffset = offset
      descriptor.fetchLimit = Self.rebuildChunkSize
      let batch = try modelContext.fetch(descriptor)
      if batch.isEmpty { break }
      for row in batch {
        if let cellRaw = row.cellRaw { cells.insert(cellRaw) }
        // §1's "heard directly": a credit *and* our own reading of it. A row that credits
        // nobody (a direct-routed packet) proves the ride was somewhere, not who it heard.
        if let hexID = row.repeaterHexID, row.rxSnr != nil { repeaters.insert(hexID) }
        switch MapperRawSampleKind(rawValue: row.kindRaw) {
        case .passiveRx: observations += 1
        case .probeAttempt: probesSent += 1
        case .probeTraceReply, .probeDiscoverResponse: probeReplies += 1
        default: break
        }
      }
      offset += batch.count
      if batch.count < Self.rebuildChunkSize { break }
    }

    return MapperRideTotals(
      hexagonCount: cells.count,
      repeatersHeard: repeaters.count,
      observationCount: observations,
      probesSent: probesSent,
      probeReplies: probeReplies
    )
  }
}
