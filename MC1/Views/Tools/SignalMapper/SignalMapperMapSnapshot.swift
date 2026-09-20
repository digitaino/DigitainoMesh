import Foundation
import MapperRawLog
import SurveyKit

// What the coverage map draws, built from the raw log's per-cell summaries
// (docs/SIGNAL_MAPPER_V3.md §7 step 4).
//
// This replaces `SignalMapperCoverageSnapshot` as the map's data source. The difference is
// not cosmetic: the old snapshot was folded from `MapperCellObservation` aggregates, which
// §6 retires, and it carried a season of derived statistics — route mixes, probe success
// rates, per-repeater packet splits — that only existed because the aggregate row happened
// to hold them. A summary is a fold of rows that are still there (`MapperCellSummary`), so
// everything here can be re-derived, and the card reads the rows directly rather than
// asking the map for numbers.
//
// Nothing in this file knows about MapLibre or SwiftUI: it is the arithmetic, and
// ``SignalMapperCoverageRenderer`` turns it into overlays.

// MARK: - Layer states

/// What the Reach layer has to say about one hexagon (§1's TX layer).
///
/// Three states rather than an optional SNR, because "they heard me but nobody said how
/// well" and "I asked and nobody heard me" are different facts, and both are different from
/// a hexagon we simply never transmitted from — which is this enum being nil.
enum SignalMapperReachState: Hashable, Sendable {
  /// A repeater reported the SNR it received us at (§1 (b)) — the only evidence with a
  /// number, and the only state the quality scale can colour.
  case reported(SignalQuality)
  /// Our own packet came back through somebody (§1 (a)): proof they heard us, no number.
  case heardYou
  /// We probed from here and nothing ever heard us. The map's most important cells.
  case noReach
}

/// How a hexagon relates to the ride currently in progress (§3, screen 3 of the mockup).
enum SignalMapperRideRing: Hashable, Sendable {
  /// Seen again this ride, but the hexagon was already on the map.
  case touched
  /// First ever evidence in this hexagon landed during this ride.
  case fresh
}

// MARK: - Cell

/// One hexagon as the map draws it.
struct SignalMapperMapCell: Identifiable, Hashable, Sendable {
  let cell: H3Cell
  /// Boundary vertices in ring order, from ``SurveyGrid/boundary(of:)``.
  let boundary: [GeoCoordinate]
  let center: GeoCoordinate

  /// The Hear layer's colour: the best SNR we heard any repeater directly at here (§1).
  /// `.unknown` for a hexagon with rows but no attributed reading — a place we stood in
  /// with nothing to grade, which is honest rather than absent.
  let hearQuality: SignalQuality
  /// The Reach layer's state, or nil for a hexagon that layer has nothing to say about.
  let reach: SignalMapperReachState?

  /// This cell's `heardCount` as a fraction of the busiest cell's, `0...1` — the fill's
  /// opacity ramp. Packets *heard* rather than rows: a cell is well surveyed when the
  /// radio listened there a lot, and counting every breadcrumb would make a slow ride
  /// through nowhere look as solid as a night parked under a repeater.
  let weight: Double

  let heardCount: Int
  let rxBestSnr: Double?
  let rxLastAt: Date?
  let txBestSnr: Double?
  let txSnrCount: Int
  let txLastAt: Date?
  let echoCount: Int
  let probesSent: Int
  let sentCount: Int
  let firstAt: Date?
  let lastAt: Date?

  var id: UInt64 {
    cell.rawValue
  }

  /// A hexagon the map has no summary for: geometry, and nothing claimed.
  ///
  /// The live card's stand-in while the rider is in a hexagon whose first rows have not been
  /// folded into a summary yet. Every count is zero and every reading nil, which the card
  /// already renders as "we know nothing here" rather than as a grade — the alternative was
  /// no card at all, which is what the rider actually saw (2026-09-04).
  ///
  /// It is never handed to ``SignalMapperCoverageRenderer``: the map draws
  /// `SignalMapperMapSnapshot.cells`, and this belongs to no snapshot.
  static func placeholder(_ cell: H3Cell) -> SignalMapperMapCell {
    SignalMapperMapCell(
      cell: cell,
      boundary: SurveyGrid.boundary(of: cell),
      center: SurveyGrid.center(of: cell),
      hearQuality: .unknown,
      reach: nil,
      weight: 0,
      heardCount: 0,
      rxBestSnr: nil,
      rxLastAt: nil,
      txBestSnr: nil,
      txSnrCount: 0,
      txLastAt: nil,
      echoCount: 0,
      probesSent: 0,
      sentCount: 0,
      firstAt: nil,
      lastAt: nil
    )
  }

  /// Whether this hexagon appears on the given layer at all.
  ///
  /// The Hear layer draws everything (an unheard hexagon is still a place we were); the
  /// Reach layer draws only hexagons with uplink evidence or a refused probe, so a tap on
  /// one of the others is a tap on bare map.
  func isDrawn(on layer: SignalMapperMapLayer) -> Bool {
    switch layer {
    case .heard: true
    case .reach: reach != nil
    }
  }

  /// Which ring this hexagon wears while a ride is open, from the ride's start instant.
  ///
  /// Both tests are on the summary's own `firstAt`/`lastAt`, which is the whole of §3's
  /// ride filter: "touched" is evidence stamped since the ride began, "fresh" is a
  /// hexagon whose *first* evidence ever is this ride's.
  func rideRing(since start: Date?) -> SignalMapperRideRing? {
    guard let start, let lastAt, lastAt >= start else { return nil }
    if let firstAt, firstAt >= start { return .fresh }
    return .touched
  }
}

// MARK: - Snapshot

/// One pass of ``SignalMapperSnapshotBuilder``.
struct SignalMapperMapSnapshot: Hashable, Sendable {
  /// Busiest first, then by cell index, so an unchanged store rebuilds identically.
  let cells: [SignalMapperMapCell]
  /// Sum of every cell's `heardCount` — the legend's "M observations".
  let observationCount: Int
  /// Summaries whose stored index no longer parses as an H3 cell. Non-zero means a corrupt
  /// row, not an empty map.
  let unreadableCellCount: Int

  static let empty = SignalMapperMapSnapshot(cells: [], observationCount: 0, unreadableCellCount: 0)

  var isEmpty: Bool {
    cells.isEmpty
  }

  var hexagonCount: Int {
    cells.count
  }

  /// How many hexagons carry evidence stamped since `start` — the legend's ride line.
  func rideHexagonCount(since start: Date) -> Int {
    cells.count { $0.rideRing(since: start) != nil }
  }

  func cell(containing coordinate: GeoCoordinate) -> SignalMapperMapCell? {
    guard let target = SurveyGrid.cell(containing: coordinate) else { return nil }
    return cells.first { $0.cell == target }
  }
}

// MARK: - Builder

/// Summaries in, map cells out. A pure function of its argument, so §3's layer rules are
/// testable without a store, a radio or a map.
enum SignalMapperSnapshotBuilder {
  static func build(summaries: [MapperCellSummaryDTO]) -> SignalMapperMapSnapshot {
    var cells: [SignalMapperMapCell] = []
    cells.reserveCapacity(summaries.count)
    var unreadable = 0

    // Relative to the busiest cell in *this* snapshot, so the opacity ramp always spans its
    // full range however little or much has been captured.
    let heaviest = summaries.map(\.heardCount).max() ?? 0

    for summary in summaries {
      guard let cell = H3Cell(rawValue: summary.cellRaw) else {
        unreadable += 1
        continue
      }
      cells.append(SignalMapperMapCell(
        cell: cell,
        boundary: SurveyGrid.boundary(of: cell),
        center: SurveyGrid.center(of: cell),
        hearQuality: SignalQuality(snr: summary.rxBestSnr),
        reach: reachState(for: summary),
        weight: heaviest > 0 ? Double(summary.heardCount) / Double(heaviest) : 0,
        heardCount: summary.heardCount,
        rxBestSnr: summary.rxBestSnr,
        rxLastAt: summary.rxLastAt,
        txBestSnr: summary.txBestSnr,
        txSnrCount: summary.txSnrCount,
        txLastAt: summary.txLastAt,
        echoCount: summary.echoCount,
        probesSent: summary.probesSent,
        sentCount: summary.sentCount,
        firstAt: summary.firstAt,
        lastAt: summary.lastAt
      ))
    }

    let sorted = cells.sorted { lhs, rhs in
      if lhs.heardCount != rhs.heardCount { return lhs.heardCount > rhs.heardCount }
      return lhs.cell.rawValue < rhs.cell.rawValue
    }

    return SignalMapperMapSnapshot(
      cells: sorted,
      observationCount: sorted.reduce(0) { $0 + $1.heardCount },
      unreadableCellCount: unreadable
    )
  }

  /// §1's TX layer, in precedence order: a reported number beats an echo, an echo beats a
  /// refused probe, and a hexagon with none of the three is not on the layer at all.
  private static func reachState(for summary: MapperCellSummaryDTO) -> SignalMapperReachState? {
    if summary.txSnrCount > 0 {
      return .reported(SignalQuality(snr: summary.txBestSnr))
    }
    if summary.hasHeardYou {
      return .heardYou
    }
    if summary.isUnreachedProbed {
      return .noReach
    }
    return nil
  }
}
