import Foundation

/// Store operations for signal-mapper cell observations (docs/SIGNAL_MAPPER_V2.md §2.1).
///
/// Deliberately a role of its own rather than a member of ``PersistenceStoreProtocol``,
/// for the reason ``MessageSearching`` gives: the capture engine and the debug panel are
/// the only consumers, and declaring `any MapperCellPersisting` keeps their signatures
/// honest about how little of the store they touch.
///
/// Everything here is keyed by `(cell, day)`. There is no radio ID: coverage is a property
/// of where the phone was, not of which radio was paired at the time, and folding the two
/// together would fragment a cell the moment someone switched radios mid-walk.
public protocol MapperCellPersisting: Actor {
  /// Folds a batch of freshly captured cell-days into the store.
  ///
  /// Upsert, not insert: an existing `(cell, day)` row has the incoming aggregates added
  /// to it via ``MapperCellObservationDTO/merged(with:)``, so the engine can flush the
  /// same cell every 30 seconds all day and end with one row. Rows within the batch that
  /// share a `(cell, day)` are merged before the write.
  func upsertMapperCellObservations(_ observations: [MapperCellObservationDTO]) async throws

  /// Every stored cell-day, newest day first.
  func fetchMapperCellObservations() async throws -> [MapperCellObservationDTO]

  /// Stored cell-days whose UTC day label falls in `fromDay...toDay` (inclusive),
  /// newest day first. Labels compare lexicographically, which for `"YYYY-MM-DD"` is
  /// chronological.
  func fetchMapperCellObservations(fromDay: String, toDay: String) async throws -> [MapperCellObservationDTO]

  /// How many cell-day rows exist. Cheap enough for a status row to poll.
  func countMapperCellObservations() async throws -> Int

  /// Drops every stored row for the given cells, across all days.
  ///
  /// How anchor exclusion reaches backwards (``MapperAnchorPolicy``). A cell only becomes
  /// detectable as somebody's home *after* it has accumulated enough observations to give
  /// it away, so refusing to capture from that moment on is not enough — the rows that made
  /// the detection possible are exactly the ones worth deleting, and they are already on
  /// disk. Called with the cells inside a newly-raised exclusion disc.
  ///
  /// Cells with no stored rows are ignored; passing an empty set is a no-op.
  func deleteMapperCellObservations(cellsRaw: Set<UInt64>) async throws

  /// Drops every mapper observation. The debug panel's reset, and the shape the
  /// user-facing "delete my local data" action will take in M2.
  func deleteAllMapperCellObservations() async throws
}
