import Foundation
import SwiftData

extension PersistenceStore: MapperCellPersisting {}

public extension PersistenceStore {
  // MARK: - Upsert

  /// Folds a batch of freshly captured cell-days into the store.
  ///
  /// The batch is collapsed by `(cell, day)` first, so a single write touches each row
  /// once no matter how the caller grouped its flush. Each surviving entry is then either
  /// merged onto the existing row or inserted, and the whole batch is committed in one
  /// `save()` — a partial flush would double-count on retry, since the engine clears its
  /// in-memory aggregate on success.
  func upsertMapperCellObservations(_ observations: [MapperCellObservationDTO]) throws {
    guard !observations.isEmpty else { return }

    var collapsed: [String: MapperCellObservationDTO] = [:]
    for observation in observations {
      let key = "\(observation.cellRaw)|\(observation.day)"
      collapsed[key] = collapsed[key].map { $0.merged(with: observation) } ?? observation
    }

    for observation in collapsed.values {
      let cellRaw = observation.cellRaw
      let day = observation.day
      var descriptor = FetchDescriptor<MapperCellObservation>(
        predicate: #Predicate { $0.cellRaw == cellRaw && $0.day == day }
      )
      descriptor.fetchLimit = 1

      if let existing = try modelContext.fetch(descriptor).first {
        existing.apply(MapperCellObservationDTO(from: existing).merged(with: observation))
      } else {
        modelContext.insert(MapperCellObservation(dto: observation))
      }
    }

    try modelContext.save()
  }

  // MARK: - Fetch

  /// Every stored cell-day, newest day first.
  func fetchMapperCellObservations() throws -> [MapperCellObservationDTO] {
    let descriptor = FetchDescriptor<MapperCellObservation>(
      sortBy: [SortDescriptor(\.day, order: .reverse), SortDescriptor(\.cellRaw, order: .forward)]
    )
    return try modelContext.fetch(descriptor).map { MapperCellObservationDTO(from: $0) }
  }

  /// Stored cell-days inside an inclusive UTC day range, newest day first.
  func fetchMapperCellObservations(fromDay: String, toDay: String) throws -> [MapperCellObservationDTO] {
    // Normalized so a caller passing the range backwards still gets the days between them
    // rather than a silently empty result.
    let lower = Swift.min(fromDay, toDay)
    let upper = Swift.max(fromDay, toDay)
    let descriptor = FetchDescriptor<MapperCellObservation>(
      predicate: #Predicate { $0.day >= lower && $0.day <= upper },
      sortBy: [SortDescriptor(\.day, order: .reverse), SortDescriptor(\.cellRaw, order: .forward)]
    )
    return try modelContext.fetch(descriptor).map { MapperCellObservationDTO(from: $0) }
  }

  /// How many cell-day rows exist.
  func countMapperCellObservations() throws -> Int {
    try modelContext.fetchCount(FetchDescriptor<MapperCellObservation>())
  }

  // MARK: - Delete

  /// Drops every stored row for the given cells, across all days.
  ///
  /// One fetch and one `save()` for the whole set: the anchor purge runs right after a
  /// recomputation decided a cell is somebody's home, and leaving half of it behind on a
  /// mid-loop failure would be the worst possible outcome.
  func deleteMapperCellObservations(cellsRaw: Set<UInt64>) throws {
    guard !cellsRaw.isEmpty else { return }

    // `#Predicate` cannot capture a Set, so the membership test runs over an Array — the
    // set is a handful of cells, and this is not a hot path.
    let cells = Array(cellsRaw)
    let descriptor = FetchDescriptor<MapperCellObservation>(
      predicate: #Predicate { cells.contains($0.cellRaw) }
    )
    for row in try modelContext.fetch(descriptor) {
      modelContext.delete(row)
    }
    try modelContext.save()
  }

  /// Drops every mapper observation.
  func deleteAllMapperCellObservations() throws {
    try modelContext.delete(model: MapperCellObservation.self)
    try modelContext.save()
  }
}
