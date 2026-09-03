import Foundation
import SurveyKit

// MARK: - The open run's own map

public extension SignalMapperCoverageBuilder {
  /// The same coverage map, drawn over one run's contribution instead of everything ever
  /// captured — plus the scope the map rings and the legend counts.
  ///
  /// The ride's figures are *residuals*: each stored row minus the row as it stood at run
  /// start (``SignalMapperSessionBaseline``). Nothing extra is stored to make this work and
  /// nothing extra is uploaded; the baseline is a memory-only copy of rows already on disk
  /// and dies with the run.
  ///
  /// A row is classified three ways:
  ///
  /// - **No baseline row for its `(cell, day)`** — the row itself was created during the
  ///   run, so all of it is the ride's, maxima included: they *are* the ride's maxima.
  /// - **A baseline row** — only the difference is the ride's, and a row that has since
  ///   shrunk (the anchor purge deleted its history) clamps to nothing and drops out.
  /// A row whose stored cell index is corrupt is left to the shared path, which counts it
  /// and does not draw it; the scope sets are intersected with what was actually drawn, so
  /// nothing unreadable can reach them.
  ///
  /// `fresh` is the stricter claim of the two: a hexagon is fresh only when the baseline
  /// held *no* row for it on any day, so a ride that crosses midnight and re-covers
  /// yesterday's cells does not report them as newly mapped.
  ///
  /// - Returns: the ride's snapshot and its scope. Both are `.empty`-shaped when the ride
  ///   has folded nothing yet.
  func buildSession(
    rows: [MapperCellObservationDTO],
    baseline: SignalMapperSessionBaseline,
    candidates: [AnyResolvableNode] = [],
    now: Date,
    overrides: NodeIdentityOverrides = [:]
  ) -> (snapshot: SignalMapperCoverageSnapshot, scope: SignalMapperSessionScope) {
    // Cell-level presence, not `(cell, day)` presence: freshness is a claim about the
    // hexagon having never been mapped, which any stored day of it disproves.
    let knownCells = Set(baseline.rows.keys.map(\.cellRaw))

    var residuals: [MapperCellObservationDTO] = []
    residuals.reserveCapacity(rows.count)
    var fresh: Set<UInt64> = []

    for row in rows {
      guard let before = baseline[row.cellRaw, row.day] else {
        residuals.append(row)
        if !knownCells.contains(row.cellRaw) { fresh.insert(row.cellRaw) }
        continue
      }
      guard let residual = row.residual(since: before, startedAt: baseline.startedAt) else {
        continue
      }
      residuals.append(residual)
    }

    // Weights ramp against the *ride's* busiest hexagon, which `assembled` derives from
    // the rows it is handed: a ride's best cell is fully lit however modest it looks
    // beside a season of history.
    let snapshot = assembled(
      rows: residuals,
      candidates: candidates,
      now: now,
      overrides: overrides
    )
    let touched = Set(snapshot.cells.map(\.cell.rawValue))

    return (
      snapshot,
      SignalMapperSessionScope(touched: touched, fresh: fresh.intersection(touched))
    )
  }
}
