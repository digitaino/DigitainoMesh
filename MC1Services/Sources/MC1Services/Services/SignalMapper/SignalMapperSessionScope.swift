import Foundation

/// The store as it stood when a survey run started — the reference every "this ride"
/// figure is measured against.
///
/// A ride's contribution to a hexagon is the difference between the row now and the row
/// then. Keeping that reference on the run object, rather than folding a second copy of
/// every sample inside the capture engine, is what lets the distinction survive a BLE
/// reconnect for free: engine instances are cattle (docs/ACTIVE_SURVEY_M3_5.md §2.6), the
/// run object is not, and `start()` on a fresh engine clears everything it holds.
///
/// **Memory only, deliberately.** Not `Codable`, no SwiftData model, never written
/// anywhere: it is a copy of rows already on disk, keyed the way the store keys them, and
/// it dies with the run. Because it is derived from stored rows the anchor exclusion
/// applies to it automatically — a purge shrinks the current row, the residual clamps to
/// nothing, and the cell silently leaves the session (docs/SIGNAL_MAPPER_V2.md §2.6).
public struct SignalMapperSessionBaseline: Sendable {
  public struct Key: Hashable, Sendable {
    public let cellRaw: UInt64
    public let day: String

    public init(cellRaw: UInt64, day: String) {
      self.cellRaw = cellRaw
      self.day = day
    }
  }

  /// When the run started. Nothing before this instant belongs to the ride.
  public let startedAt: Date
  /// Every stored cell-day at ``startedAt``, keyed as the store keys them.
  public let rows: [Key: MapperCellObservationDTO]

  public init(startedAt: Date, rows: [MapperCellObservationDTO]) {
    self.startedAt = startedAt
    self.rows = Dictionary(
      rows.map { (Key(cellRaw: $0.cellRaw, day: $0.day), $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  public subscript(cellRaw: UInt64, day: String) -> MapperCellObservationDTO? {
    rows[Key(cellRaw: cellRaw, day: day)]
  }
}

/// Which hexagons the open run has touched — what the map rings and the legend counts.
///
/// Two sets rather than one because they draw differently: a hexagon mapped for the very
/// first time on this ride is the ride's real product and gets the heavier ring; one the
/// ride merely re-covered gets the lighter one.
public struct SignalMapperSessionScope: Sendable, Hashable {
  /// Cells with at least one observation folded since the run started.
  public let touched: Set<UInt64>
  /// The subset of ``touched`` that had no stored row at all when the run started.
  public let fresh: Set<UInt64>

  public static let empty = SignalMapperSessionScope(touched: [], fresh: [])

  public init(touched: Set<UInt64>, fresh: Set<UInt64>) {
    self.touched = touched
    self.fresh = fresh
  }

  public var isEmpty: Bool {
    touched.isEmpty
  }

  public func contains(_ cellRaw: UInt64) -> Bool {
    touched.contains(cellRaw)
  }

  public func isFresh(_ cellRaw: UInt64) -> Bool {
    fresh.contains(cellRaw)
  }
}
