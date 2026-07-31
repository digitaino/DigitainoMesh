import Foundation
@testable import MC1Services
import SurveyKit
import SwiftData
import Testing

/// Anchor detection and exclusion (docs/SIGNAL_MAPPER_V2.md §2.7): which cells get called a
/// place-you-stay, what shape gets excluded around them, and that the shape does not move.
///
/// A pure suite — rows in, discs out, no store and no engine — except for the purge tests,
/// which need the real `PersistenceStore` because deleting rows is the point.
@Suite("MapperAnchorPolicy")
struct MapperAnchorPolicyTests {
  // MARK: - Fixtures

  private let seed: UInt64 = 0xA5A5_1234_DEAD_BEEF

  private func cell(_ location: (latitude: Double, longitude: Double)) throws -> H3Cell {
    try #require(MapperFixtureLocation.cell(location))
  }

  private func tuning(
    minDistinctDays: Int = 5,
    stationaryShare: Double = 0.6,
    observationCount: Int = 2000,
    offset: ClosedRange<Double> = 300...600,
    radius: ClosedRange<Double> = 700...1200
  ) -> MapperTuning {
    MapperTuning(
      anchorMinDistinctDays: minDistinctDays,
      anchorStationaryShare: stationaryShare,
      anchorObservationCount: observationCount,
      anchorOffsetMinMeters: offset.lowerBound,
      anchorOffsetMaxMeters: offset.upperBound,
      anchorRadiusMinMeters: radius.lowerBound,
      anchorRadiusMaxMeters: radius.upperBound
    )
  }

  /// `days` rows for one cell, each carrying `rx` observations of which `stationary` were
  /// captured standing still.
  private func rows(
    cell: H3Cell,
    days: Int,
    rxPerDay: Int,
    stationaryPerDay: Int
  ) -> [MapperCellObservationDTO] {
    (0..<days).map { index in
      MapperCellObservationDTO(
        cellRaw: cell.rawValue,
        day: String(format: "2025-07-%02d", index + 1),
        packetCount: rxPerDay,
        rxCount: rxPerDay,
        stationaryObservationCount: stationaryPerDay
      )
    }
  }

  // MARK: - Thresholds

  @Test
  func `A cell seen on enough days with a high stationary share is an anchor`() throws {
    let home = try cell(MapperFixtureLocation.plaza)
    let policy = MapperAnchorPolicy(tuning: tuning(), seed: seed)

    let anchors = policy.anchors(in: rows(cell: home, days: 5, rxPerDay: 10, stationaryPerDay: 9))

    #expect(anchors.count == 1)
    let anchor = try #require(anchors.first)
    #expect(anchor.cell == home)
    #expect(anchor.distinctDayCount == 5)
    #expect(anchor.observationCount == 50)
    #expect(anchor.reason == .dwell)
  }

  @Test
  func `One day short of the threshold is not an anchor`() throws {
    let home = try cell(MapperFixtureLocation.plaza)
    let policy = MapperAnchorPolicy(tuning: tuning(), seed: seed)

    #expect(policy.anchors(in: rows(cell: home, days: 4, rxPerDay: 10, stationaryPerDay: 10)).isEmpty)
  }

  @Test
  func `A cell passed through every day is not an anchor, however many days`() throws {
    // The commute case, and the one the whole stationary share exists to protect: thirty
    // days of the same cell is not a home if the phone was moving through it every time.
    let street = try cell(MapperFixtureLocation.acrossTown)
    let policy = MapperAnchorPolicy(tuning: tuning(), seed: seed)

    #expect(policy.anchors(in: rows(cell: street, days: 30, rxPerDay: 10, stationaryPerDay: 0)).isEmpty)
  }

  @Test
  func `A stationary share exactly at the threshold is not enough`() throws {
    let home = try cell(MapperFixtureLocation.plaza)
    let policy = MapperAnchorPolicy(tuning: tuning(stationaryShare: 0.6), seed: seed)

    // 6 of 10 is 0.6, and the predicate is strictly greater.
    #expect(policy.anchors(in: rows(cell: home, days: 5, rxPerDay: 10, stationaryPerDay: 6)).isEmpty)
    #expect(!policy.anchors(in: rows(cell: home, days: 5, rxPerDay: 10, stationaryPerDay: 7)).isEmpty)
  }

  @Test
  func `Sheer volume makes a cell an anchor with no stationary evidence at all`() throws {
    // The fallback for a phone that declined Motion & Fitness: nothing is ever marked
    // stationary, so the dwell test can never fire and only the count is left.
    let home = try cell(MapperFixtureLocation.plaza)
    let policy = MapperAnchorPolicy(tuning: tuning(observationCount: 2000), seed: seed)

    let quiet = policy.anchors(in: rows(cell: home, days: 2, rxPerDay: 900, stationaryPerDay: 0))
    #expect(quiet.isEmpty)

    let loud = policy.anchors(in: rows(cell: home, days: 2, rxPerDay: 1000, stationaryPerDay: 0))
    #expect(loud.count == 1)
    #expect(loud.first?.reason == .volume)
  }

  @Test
  func `An empty store yields no anchors and an exclusion that contains nothing`() throws {
    let policy = MapperAnchorPolicy(tuning: tuning(), seed: seed)
    let exclusion = policy.exclusion(for: [])

    #expect(exclusion.isEmpty)
    #expect(try !exclusion.contains(cell: cell(MapperFixtureLocation.plaza)))
  }

  // MARK: - Disc geometry

  @Test
  func `The disc is offset from the anchor and sized inside the configured ranges`() throws {
    let home = try cell(MapperFixtureLocation.plaza)
    let policy = MapperAnchorPolicy(tuning: tuning(), seed: seed)

    let disc = policy.disc(for: home)
    let offset = SurveyGrid.distanceMeters(from: SurveyGrid.center(of: home), to: disc.center)

    // The whole point: the disc's centre is *not* the anchor's centre, so the centroid of
    // the void is not the home.
    #expect(offset >= 300)
    #expect(offset <= 600)
    #expect(disc.radiusMeters >= 700)
    #expect(disc.radiusMeters <= 1200)
  }

  @Test
  func `The same seed and cell always produce the same disc`() throws {
    // Stability is the security property, not a convenience: two differently-placed voids
    // over one home intersect much closer to the truth than either alone.
    let home = try cell(MapperFixtureLocation.plaza)
    let first = MapperAnchorPolicy(tuning: tuning(), seed: seed).disc(for: home)
    let second = MapperAnchorPolicy(tuning: tuning(), seed: seed).disc(for: home)

    #expect(first == second)
  }

  @Test
  func `Recomputing an exclusion over unchanged rows reproduces it exactly`() throws {
    let home = try cell(MapperFixtureLocation.plaza)
    let policy = MapperAnchorPolicy(tuning: tuning(), seed: seed)
    let stored = rows(cell: home, days: 6, rxPerDay: 10, stationaryPerDay: 9)

    #expect(policy.exclusion(for: stored) == policy.exclusion(for: stored))
    // …and independent of the order rows come back from the store in.
    #expect(policy.exclusion(for: stored) == policy.exclusion(for: stored.reversed()))
  }

  @Test
  func `A different install seed produces a different disc for the same cell`() throws {
    let home = try cell(MapperFixtureLocation.plaza)
    let mine = MapperAnchorPolicy(tuning: tuning(), seed: seed).disc(for: home)
    let theirs = MapperAnchorPolicy(tuning: tuning(), seed: seed &+ 1).disc(for: home)

    #expect(mine != theirs)
  }

  @Test
  func `Two anchors get independent draws`() throws {
    let home = try cell(MapperFixtureLocation.plaza)
    let work = try cell(MapperFixtureLocation.acrossTown)
    let policy = MapperAnchorPolicy(tuning: tuning(), seed: seed)

    let homeDisc = policy.disc(for: home)
    let workDisc = policy.disc(for: work)

    // Same offset and radius for both would mean one draw shared, and one measured disc
    // would then give away the geometry of every other.
    #expect(homeDisc.radiusMeters != workDisc.radiusMeters)
  }

  // MARK: - Membership

  @Test
  func `A cell inside a disc is excluded and one well outside it is not`() throws {
    let home = try cell(MapperFixtureLocation.plaza)
    let policy = MapperAnchorPolicy(tuning: tuning(), seed: seed)
    let exclusion = policy.exclusion(for: rows(cell: home, days: 5, rxPerDay: 10, stationaryPerDay: 9))
    let disc = try #require(exclusion.discs.first)

    // The anchor itself is always inside: max offset (600 m) is below min radius (700 m).
    #expect(exclusion.contains(cell: home))

    // A point at the disc's centre is inside; one well beyond its radius is not.
    let inside = try #require(SurveyGrid.cell(containing: disc.center))
    #expect(exclusion.contains(cell: inside))

    let far = SurveyGrid.coordinate(
      from: disc.center,
      bearingRadians: 0,
      distanceMeters: disc.radiusMeters + 2000
    )
    #expect(try !exclusion.contains(cell: #require(SurveyGrid.cell(containing: far))))
  }

  @Test
  func `Enumerating a disc agrees with testing its cells one at a time`() throws {
    let home = try cell(MapperFixtureLocation.plaza)
    let policy = MapperAnchorPolicy(tuning: tuning(), seed: seed)
    let exclusion = policy.exclusion(for: rows(cell: home, days: 5, rxPerDay: 10, stationaryPerDay: 9))

    let covered = exclusion.coveredCells()
    #expect(!covered.isEmpty)
    #expect(covered.allSatisfy { exclusion.contains(cell: $0) })
    #expect(covered.contains(home))
  }

  @Test
  func `Excluding a set keeps only the cells inside a disc`() throws {
    let home = try cell(MapperFixtureLocation.plaza)
    let elsewhere = try cell(MapperFixtureLocation.acrossTown)
    let policy = MapperAnchorPolicy(tuning: tuning(), seed: seed)
    let exclusion = policy.exclusion(for: rows(cell: home, days: 5, rxPerDay: 10, stationaryPerDay: 9))

    #expect(exclusion.excluded(from: [home, elsewhere]) == [home])
  }

  // MARK: - Purge

  @Test
  func `Purging a disc removes the rows that predate its detection`() async throws {
    // The case that matters on a phone already in the field: the observations that made the
    // cell detectable are on disk by the time it is detected, and they are the revealing
    // ones. Refusing to capture from here on would protect nobody.
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let home = try cell(MapperFixtureLocation.plaza)
    let elsewhere = try cell(MapperFixtureLocation.acrossTown)

    let stored = rows(cell: home, days: 6, rxPerDay: 10, stationaryPerDay: 9)
      + [MapperCellObservationDTO(cellRaw: elsewhere.rawValue, day: "2025-07-01", packetCount: 1, rxCount: 1)]
    try await store.upsertMapperCellObservations(stored)
    #expect(try await store.countMapperCellObservations() == 7)

    let policy = MapperAnchorPolicy(tuning: tuning(), seed: seed)
    let exclusion = try await policy.exclusion(for: store.fetchMapperCellObservations())
    let doomed = try await exclusion.excluded(from: store.fetchMapperCellObservations().compactMap(\.cell))
    try await store.deleteMapperCellObservations(cellsRaw: Set(doomed.map(\.rawValue)))

    let survivors = try await store.fetchMapperCellObservations()
    // Every one of the home cell's six days is gone — not just the days after detection.
    #expect(survivors.count == 1)
    #expect(survivors.first?.cellRaw == elsewhere.rawValue)
  }

  @Test
  func `Purging an empty set is a no-op`() async throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let home = try cell(MapperFixtureLocation.plaza)
    try await store.upsertMapperCellObservations(rows(cell: home, days: 2, rxPerDay: 1, stationaryPerDay: 1))

    try await store.deleteMapperCellObservations(cellsRaw: [])

    #expect(try await store.countMapperCellObservations() == 2)
  }

  // MARK: - Dwell column

  @Test
  func `Merging two cell-days adds their stationary counts`() throws {
    let home = try cell(MapperFixtureLocation.plaza)
    let morning = MapperCellObservationDTO(
      cellRaw: home.rawValue, day: "2025-07-20", rxCount: 4, stationaryObservationCount: 3
    )
    let evening = MapperCellObservationDTO(
      cellRaw: home.rawValue, day: "2025-07-20", rxCount: 6, stationaryObservationCount: 5
    )

    #expect(morning.merged(with: evening).stationaryObservationCount == 8)
  }

  @Test
  func `The stationary count survives a store round trip`() async throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let home = try cell(MapperFixtureLocation.plaza)

    try await store.upsertMapperCellObservations([
      MapperCellObservationDTO(
        cellRaw: home.rawValue, day: "2025-07-20", rxCount: 9, stationaryObservationCount: 7
      )
    ])

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(row.stationaryObservationCount == 7)
  }
}
