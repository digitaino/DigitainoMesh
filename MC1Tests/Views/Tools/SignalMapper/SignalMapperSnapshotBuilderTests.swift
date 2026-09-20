import Foundation
import MapperRawLog
@testable import MC1
import SurveyKit
import Testing

/// The map's construction rules (docs/SIGNAL_MAPPER_V3.md §7 step 4): per-cell summaries in,
/// hexagons with a state on each layer out.
///
/// Pure throughout — no store, no radio, no map — so every rule in §1's layer definitions is
/// pinned against fixed summaries rather than against whatever a device happened to record.
@Suite("Signal mapper snapshot builder")
struct SignalMapperSnapshotBuilderTests {
  /// Two real res-9 indexes, taken from the grid rather than written out: an index that
  /// does not parse is the builder's *unreadable* path, and a fixture that quietly took it
  /// would make every layer assertion below vacuously true.
  private let cellA = SurveyGrid.cell(
    containing: GeoCoordinate(latitude: 37.7749, longitude: -122.4194)
  )!.rawValue
  private let cellB = SurveyGrid.cell(
    containing: GeoCoordinate(latitude: 30.2672, longitude: -97.7431)
  )!.rawValue
  private let start = Date(timeIntervalSince1970: 1_753_000_000)

  private func at(_ offset: TimeInterval) -> Date {
    start.addingTimeInterval(offset)
  }

  private func summary(
    _ cellRaw: UInt64,
    rxBestSnr: Double? = nil,
    txBestSnr: Double? = nil,
    txSnrCount: Int = 0,
    echoCount: Int = 0,
    probesSent: Int = 0,
    heardCount: Int = 0,
    firstAt: Date? = nil,
    lastAt: Date? = nil
  ) -> MapperCellSummaryDTO {
    MapperCellSummaryDTO(
      cellRaw: cellRaw,
      rxBestSnr: rxBestSnr,
      rxSnrCount: rxBestSnr == nil ? 0 : 1,
      txBestSnr: txBestSnr,
      txSnrCount: txSnrCount,
      echoCount: echoCount,
      probesSent: probesSent,
      heardCount: heardCount,
      firstAt: firstAt ?? at(0),
      lastAt: lastAt ?? at(60)
    )
  }

  // MARK: - Hear layer

  @Test
  func `Hear quality grades the best SNR we heard a repeater at`() throws {
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [
      summary(cellA, rxBestSnr: 12, heardCount: 10),
      summary(cellB, rxBestSnr: 1, heardCount: 5)
    ])
    let a = try #require(snapshot.cells.first { $0.cell.rawValue == cellA })
    let b = try #require(snapshot.cells.first { $0.cell.rawValue == cellB })
    #expect(a.hearQuality == .excellent)
    #expect(b.hearQuality == .fair)
  }

  @Test
  func `A cell with rows but no attributed reading grades unknown, and still draws`() throws {
    // Direct-routed packets credit nobody (§1), so a hexagon can hold hundreds of rows and
    // no `rxBestSnr` at all. It is a place we were: it stays on the Hear layer, greyed.
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [summary(cellA, heardCount: 300)])
    let cell = try #require(snapshot.cells.first)
    #expect(cell.hearQuality == .unknown)
    #expect(cell.isDrawn(on: .heard) == true)
  }

  // MARK: - Reach layer

  @Test
  func `A reported number colours the reach layer and outranks an echo`() {
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [
      summary(cellA, txBestSnr: 6, txSnrCount: 2, echoCount: 4, probesSent: 3, heardCount: 1)
    ])
    #expect(snapshot.cells.first?.reach == .reported(.good))
  }

  @Test
  func `An echo with no number is the neutral heard-you fill`() {
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [
      summary(cellA, echoCount: 1, probesSent: 5, heardCount: 1)
    ])
    #expect(snapshot.cells.first?.reach == .heardYou)
  }

  @Test
  func `Probed with nothing heard is no reach, and never probing is not on the layer`() throws {
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [
      summary(cellA, probesSent: 4, heardCount: 2),
      summary(cellB, rxBestSnr: 9, heardCount: 1)
    ])
    let probed = try #require(snapshot.cells.first { $0.cell.rawValue == cellA })
    let quiet = try #require(snapshot.cells.first { $0.cell.rawValue == cellB })
    #expect(probed.reach == .noReach)
    #expect(quiet.reach == nil)
    // A hexagon the reach layer has nothing to say about is bare map there, not a tap target.
    #expect(quiet.isDrawn(on: .reach) == false)
    #expect(quiet.isDrawn(on: .heard) == true)
  }

  @Test
  func `A reported reading with no SNR value still colours, as unknown`() {
    // `txSnrCount > 0` with a nil best is not reachable through the fold, but the builder
    // must not silently demote a reported reading to "echo only" if it ever became so.
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [
      summary(cellA, txBestSnr: nil, txSnrCount: 1, heardCount: 1)
    ])
    #expect(snapshot.cells.first?.reach == .reported(.unknown))
  }

  // MARK: - Weight and order

  @Test
  func `Weight is heard packets relative to the busiest cell, and order is busiest first`() {
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [
      summary(cellA, heardCount: 25),
      summary(cellB, heardCount: 100)
    ])
    #expect(snapshot.cells.map(\.cell.rawValue) == [cellB, cellA])
    #expect(snapshot.cells[0].weight == 1)
    #expect(snapshot.cells[1].weight == 0.25)
    #expect(snapshot.observationCount == 125)
    #expect(snapshot.hexagonCount == 2)
  }

  @Test
  func `A snapshot with nothing heard anywhere weights every cell at zero rather than dividing by it`() {
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [
      summary(cellA, probesSent: 1),
      summary(cellB, echoCount: 1)
    ])
    #expect(snapshot.cells.allSatisfy { $0.weight == 0 })
    #expect(snapshot.observationCount == 0)
  }

  @Test
  func `A summary whose index is not a cell is counted, not drawn`() {
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [
      summary(cellA, heardCount: 3),
      summary(0x0000_0000_0000_0001, heardCount: 9)
    ])
    #expect(snapshot.cells.count == 1)
    #expect(snapshot.unreadableCellCount == 1)
    // The corrupt row's packets do not join the legend's total either.
    #expect(snapshot.observationCount == 3)
  }

  @Test
  func `Geometry comes from the grid, not from the summary`() throws {
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [summary(cellA, heardCount: 1)])
    let cell = try #require(snapshot.cells.first)
    let index = try #require(H3Cell(rawValue: cellA))
    #expect(cell.boundary.count == 6)
    #expect(cell.center == SurveyGrid.center(of: index))
  }

  @Test
  func `An empty store is an empty snapshot`() {
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [])
    #expect(snapshot.isEmpty)
    #expect(snapshot.observationCount == 0)
  }

  // MARK: - Ride rings

  @Test
  func `Touched is evidence since the ride started, fresh is a hexagon the ride discovered`() throws {
    let rideStart = at(1000)
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [
      // Known before the ride, seen again during it.
      summary(cellA, heardCount: 10, firstAt: at(0), lastAt: at(1500)),
      // First evidence ever landed after the ride opened.
      summary(cellB, heardCount: 5, firstAt: at(1200), lastAt: at(1600))
    ])
    let a = try #require(snapshot.cells.first { $0.cell.rawValue == cellA })
    let b = try #require(snapshot.cells.first { $0.cell.rawValue == cellB })
    #expect(a.rideRing(since: rideStart) == .touched)
    #expect(b.rideRing(since: rideStart) == .fresh)
    #expect(snapshot.rideHexagonCount(since: rideStart) == 2)
  }

  @Test
  func `A hexagon last seen before the ride wears no ring`() {
    let rideStart = at(1000)
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [
      summary(cellA, heardCount: 10, firstAt: at(0), lastAt: at(900))
    ])
    #expect(snapshot.cells.first?.rideRing(since: rideStart) == nil)
    #expect(snapshot.rideHexagonCount(since: rideStart) == 0)
  }

  @Test
  func `The ride's own start instant counts as inside the ride`() {
    // The filter is `>= startedAt` (§3), so a row stamped in the same instant the run
    // opened belongs to it — a half-open window the other way would drop the first packet
    // of every ride that starts while the radio is already talking.
    let rideStart = at(1000)
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [
      summary(cellA, heardCount: 1, firstAt: rideStart, lastAt: rideStart)
    ])
    #expect(snapshot.cells.first?.rideRing(since: rideStart) == .fresh)
  }

  @Test
  func `With no ride open nothing is ringed`() {
    let snapshot = SignalMapperSnapshotBuilder.build(summaries: [summary(cellA, heardCount: 1)])
    #expect(snapshot.cells.first?.rideRing(since: nil) == nil)
  }
}
