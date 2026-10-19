import Foundation
import SurveyKit

/// Finds the places a person *stays* and refuses to map them.
///
/// ## The problem this exists for
///
/// Passive capture volume is proportional to dwell time, and dwell time is wildly uneven.
/// A person sleeps, eats and works in two or three res-9 cells and merely passes through
/// every other one. Left alone, an automatic mapper therefore draws a dense island around
/// each user's home and workplace and a thin thread along everything between — and the
/// islands are not a map of the mesh, they are a map of where people live. No amount of
/// aggregation upstream fixes that, because the shape is already in the data before it is
/// aggregated.
///
/// ## Why the exclusion is a *randomised* disc and not a ring around the cell
///
/// The obvious fix — drop the anchor cell and its neighbours — is worse than useless. It
/// replaces a bright island with a hole of known shape, and the centroid of that hole *is*
/// the person's home to within a cell. Suppression becomes a pointer: the attacker no
/// longer has to find the densest cell, only the emptiest one, and the answer is more
/// precise than what was suppressed.
///
/// So the disc that gets excluded is deliberately not centred on the anchor. Its centre is
/// displaced by a random bearing and a random distance (``MapperTuning/anchorOffsetMinMeters``
/// … ``MapperTuning/anchorOffsetMaxMeters``), and its radius is drawn from its own range
/// (``MapperTuning/anchorRadiusMinMeters`` … ``MapperTuning/anchorRadiusMaxMeters``). The
/// void that appears on the map still exists, but its centroid is a few hundred metres from
/// the home, in a direction nothing in the data reveals, and its size does not say how much
/// was hidden. That error is irreducible: it is not noise on top of the answer, it is the
/// absence of the answer.
///
/// ## Why the draws are stable per install
///
/// A disc that moved or resized between runs would be catastrophic rather than merely
/// useless. Two overlapping voids with different centres intersect, and the intersection is
/// closer to the truth than either; enough re-draws and the anchor is recovered exactly.
/// So the draws come from a seed persisted once per install and are a pure function of
/// `(seed, cell)` — the same anchor yields the same disc forever, whatever order anchors
/// are discovered in and however often this is recomputed.
///
/// **The seed and the disc geometry never leave the device and are never displayed.**
/// Publishing either would undo the whole construction: the offset is only protective while
/// it is unknown.
///
/// ## Where it is enforced
///
/// At capture, not at upload — the engine drops observations inside a disc before they are
/// folded, and purges already-stored rows when a cell newly crosses the threshold. Data that
/// was accumulated before the anchor became detectable must not survive its detection, or
/// the exclusion would only ever protect people who installed the feature after their home
/// was already known to it.
public struct MapperAnchorPolicy: Sendable {
  // MARK: - Types

  /// A cell the policy has decided is somewhere the user stays.
  public struct Anchor: Sendable, Equatable {
    public let cell: H3Cell
    /// Distinct UTC days this cell was observed on. The store is already one row per
    /// `(cell, day)`, so this needs no column of its own — which is deliberate: a
    /// finer-grained residency signal (a within-day presence bitmap, say) would be a
    /// calendar of when somebody is home, and we would rather it not exist.
    public let distinctDayCount: Int
    public let observationCount: Int
    public let stationaryObservationCount: Int
    /// Why this cell qualified. Both reasons can hold; the panel shows the count, not this.
    public let reason: Reason

    public enum Reason: Sendable, Equatable {
      /// Seen on enough days, and mostly while the phone was not moving.
      case dwell
      /// Sheer volume. The backstop that still works with no motion authorization.
      case volume
    }

    public var stationaryShare: Double {
      observationCount > 0 ? Double(stationaryObservationCount) / Double(observationCount) : 0
    }
  }

  /// The area actually excluded around one anchor. See the type's rationale above for why
  /// this is offset and randomly sized rather than centred on ``anchor``.
  public struct ExclusionDisc: Sendable, Equatable {
    /// The cell that caused the disc. Never rendered, never uploaded — it is here so the
    /// purge can explain itself in a log line and so recomputation is idempotent.
    public let anchor: H3Cell
    public let center: GeoCoordinate
    public let radiusMeters: Double

    public init(anchor: H3Cell, center: GeoCoordinate, radiusMeters: Double) {
      self.anchor = anchor
      self.center = center
      self.radiusMeters = radiusMeters
    }

    /// Whether a cell's centre falls inside the disc. Centre-membership, matching
    /// ``SurveyKit/SurveyGrid/cells(within:of:resolution:)``, so testing one cell and
    /// enumerating the whole disc can never disagree.
    public func contains(cell: H3Cell) -> Bool {
      SurveyGrid.distanceMeters(from: center, to: SurveyGrid.center(of: cell)) <= radiusMeters
    }
  }

  // MARK: - Dependencies

  private let tuning: MapperTuning
  private let seed: UInt64

  /// - Parameters:
  ///   - tuning: the §2.7 thresholds and disc ranges.
  ///   - seed: the per-install random seed the disc draws derive from. Stable for the life
  ///     of the install; see the type's rationale for why that matters.
  public init(tuning: MapperTuning = .defaults, seed: UInt64) {
    self.tuning = tuning
    self.seed = seed
  }

  // MARK: - Detection

  /// The anchor cells in a set of stored rows.
  ///
  /// A cell is an anchor when **either**:
  ///
  /// - it has been observed on at least ``MapperTuning/anchorMinDistinctDays`` distinct days
  ///   *and* more than ``MapperTuning/anchorStationaryShare`` of its observations were
  ///   captured while the movement hint said the phone was not moving — the direct reading
  ///   of "somewhere I go back to and stay put in"; **or**
  /// - it holds at least ``MapperTuning/anchorObservationCount`` observations, whatever the
  ///   movement hints said. This is the backstop for a phone that declined Motion & Fitness,
  ///   where every observation looks stationary and the share test therefore says nothing.
  ///
  /// Rows are grouped by cell across days, so the caller passes whatever it has and the
  /// grouping happens here.
  public func anchors(in rows: [MapperCellObservationDTO]) -> [Anchor] {
    var tallies: [UInt64: Tally] = [:]
    for row in rows {
      guard let cell = row.cell else { continue }
      tallies[row.cellRaw, default: Tally(cell: cell)].fold(row)
    }

    return tallies.values
      .compactMap(anchor(from:))
      // Sorted so a recomputation over unchanged data produces an identical list, which is
      // what lets the engine compare two exclusions for equality and skip a purge.
      .sorted { $0.cell.rawValue < $1.cell.rawValue }
  }

  private func anchor(from tally: Tally) -> Anchor? {
    guard tally.observationCount > 0 else { return nil }

    let isVolume = tally.observationCount >= tuning.anchorObservationCount
    let isDwell = tally.days.count >= tuning.anchorMinDistinctDays
      && Double(tally.stationaryCount) / Double(tally.observationCount) > tuning.anchorStationaryShare
    guard isDwell || isVolume else { return nil }

    return Anchor(
      cell: tally.cell,
      distinctDayCount: tally.days.count,
      observationCount: tally.observationCount,
      stationaryObservationCount: tally.stationaryCount,
      // Dwell is the more specific claim, so it wins the label when both hold.
      reason: isDwell ? .dwell : .volume
    )
  }

  // MARK: - Discs

  /// The exclusion disc for an anchor cell.
  ///
  /// A pure function of `(seed, cell)`: recomputing produces the identical disc, and two
  /// anchors never share a draw. Three independent draws come out of one stream — bearing,
  /// offset, radius — so nudging one range does not correlate the others.
  public func disc(for cell: H3Cell) -> ExclusionDisc {
    // The cell index is mixed into the seed rather than appended to it, so neighbouring
    // cells (whose raw indexes differ in the low bits) get uncorrelated draws.
    var rng = SplitMix64(state: seed ^ (cell.rawValue &* 0x9E37_79B9_7F4A_7C15))

    let bearing = rng.nextUnitInterval() * 2 * .pi
    let offset = interpolate(
      rng.nextUnitInterval(),
      from: tuning.anchorOffsetMinMeters,
      to: tuning.anchorOffsetMaxMeters
    )
    let radius = interpolate(
      rng.nextUnitInterval(),
      from: tuning.anchorRadiusMinMeters,
      to: tuning.anchorRadiusMaxMeters
    )

    return ExclusionDisc(
      anchor: cell,
      center: SurveyGrid.coordinate(
        from: SurveyGrid.center(of: cell),
        bearingRadians: bearing,
        distanceMeters: offset
      ),
      radiusMeters: radius
    )
  }

  /// Detection and disc construction in one step: what the engine actually calls.
  public func exclusion(for rows: [MapperCellObservationDTO]) -> MapperAnchorExclusion {
    let anchors = anchors(in: rows)
    return MapperAnchorExclusion(anchors: anchors, discs: anchors.map { disc(for: $0.cell) })
  }

  // MARK: - Helpers

  /// Guards against a reversed or degenerate range rather than trusting the tuning panel,
  /// which can hand over anything a stepper can reach.
  private func interpolate(_ fraction: Double, from lower: Double, to upper: Double) -> Double {
    let low = Swift.min(lower, upper)
    let high = Swift.max(lower, upper)
    return low + (high - low) * fraction
  }

  /// One cell's rows, collapsed.
  private struct Tally {
    let cell: H3Cell
    var days: Set<String> = []
    var observationCount = 0
    var stationaryCount = 0

    mutating func fold(_ row: MapperCellObservationDTO) {
      days.insert(row.day)
      observationCount += row.observationCount
      stationaryCount += row.stationaryObservationCount
    }
  }
}

// MARK: - Exclusion

/// The anchor discs in force, and the one question the capture path asks them.
///
/// A value type so the engine can hold it across a fold without touching the store, and so
/// two recomputations can be compared to decide whether anything actually changed.
public struct MapperAnchorExclusion: Sendable, Equatable {
  public let anchors: [MapperAnchorPolicy.Anchor]
  public let discs: [MapperAnchorPolicy.ExclusionDisc]

  /// Nothing excluded. The state a fresh install and an unconfigured engine are both in.
  public static let none = MapperAnchorExclusion(anchors: [], discs: [])

  public init(anchors: [MapperAnchorPolicy.Anchor], discs: [MapperAnchorPolicy.ExclusionDisc]) {
    self.anchors = anchors
    self.discs = discs
  }

  public var isEmpty: Bool {
    discs.isEmpty
  }

  /// Whether an observation in this cell must be dropped. The hot path — one distance
  /// comparison per disc, and there are only ever a handful of discs.
  public func contains(cell: H3Cell) -> Bool {
    discs.contains { $0.contains(cell: cell) }
  }

  /// Which of `cells` fall inside a disc. What the purge and the debug panel's
  /// excluded-count both want: the answer restricted to cells that actually exist locally,
  /// rather than the far larger set of cells the discs cover.
  public func excluded(from cells: some Sequence<H3Cell>) -> Set<H3Cell> {
    Set(cells.filter(contains(cell:)))
  }

  /// Every res-9 cell the discs cover, whether or not anything was ever observed there.
  ///
  /// Enumeration is not needed to enforce the exclusion — ``contains(cell:)`` answers that
  /// one cell at a time — so this exists for tests and for a future zone-review UI, and is
  /// deliberately not on any capture path.
  public func coveredCells() -> Set<H3Cell> {
    discs.reduce(into: Set<H3Cell>()) { result, disc in
      result.formUnion(SurveyGrid.cells(within: disc.radiusMeters, of: disc.center))
    }
  }
}

// MARK: - Deterministic randomness

/// SplitMix64: a tiny, well-distributed, fully deterministic generator.
///
/// Not `SystemRandomNumberGenerator` for the reason the type's doc comment gives — a disc
/// that changes between runs leaks more than it hides — and not `seed &+ counter` because
/// adjacent seeds must not produce adjacent draws. Reproducibility across OS versions is a
/// requirement here, which rules out anything the platform owns.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(state: UInt64) {
    self.state = state
  }

  mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// A draw in `[0, 1)`. Built from the top 53 bits so it is exactly representable as a
  /// `Double` and uniformly spaced.
  mutating func nextUnitInterval() -> Double {
    Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
  }
}

// MARK: - Seed

/// Supplies the per-install anchor seed.
///
/// Its own protocol rather than a field on ``MapperTuning`` on purpose: the tuning struct is
/// displayed in the debug panel, persisted per-field and resettable, and the seed must be
/// none of those things. Resetting the tuning to defaults must not reshuffle every disc.
public protocol MapperAnchorSeedProviding: Sendable {
  /// The seed. Stable for the life of the install; created on first read.
  var anchorSeed: UInt64 { get }
}

/// A fixed seed, for tests and for an engine wired without a store.
public struct StaticMapperAnchorSeedProvider: MapperAnchorSeedProviding {
  public let anchorSeed: UInt64

  public init(_ seed: UInt64 = 0x5DEE_CE66_D1CE_B00C) {
    anchorSeed = seed
  }
}
