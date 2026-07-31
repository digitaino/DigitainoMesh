import Foundation
@testable import MC1Services
import SurveyKit
import SwiftData
import Testing

/// Persistence for the mapper's `(cell, UTC day)` rows: upsert-folding, range fetches, and
/// the round trip through the JSON aggregate columns.
@Suite("MapperCellObservation store")
struct MapperCellObservationStoreTests {
  private func makeStore() throws -> PersistenceStore {
    let container = try PersistenceStore.createContainer(inMemory: true)
    return PersistenceStore(modelContainer: container)
  }

  private func cell(_ location: (latitude: Double, longitude: Double)) throws -> H3Cell {
    try #require(MapperFixtureLocation.cell(location))
  }

  private func observation(
    cell: H3Cell,
    day: String,
    packets: Int = 1,
    snr: Double? = nil,
    hopHistogram: [Int: Int] = [:],
    repeaters: [String: MapperRepeaterStats] = [:],
    at timestamp: Date = Date(timeIntervalSince1970: 1_753_000_000)
  ) -> MapperCellObservationDTO {
    MapperCellObservationDTO(
      cellRaw: cell.rawValue,
      day: day,
      packetCount: packets,
      passivePacketCount: packets,
      snrSum: snr ?? 0,
      snrCount: snr == nil ? 0 : 1,
      minSnr: snr,
      maxSnr: snr,
      floodCount: packets,
      earliest: timestamp,
      latest: timestamp,
      hopHistogram: hopHistogram,
      repeaters: repeaters
    )
  }

  // MARK: - Round trip

  @Test
  func `A stored row round-trips every aggregate, including the JSON columns`() async throws {
    let store = try makeStore()
    let target = try cell(MapperFixtureLocation.plaza)
    let heard = Date(timeIntervalSince1970: 1_753_000_000)
    let stats = MapperRepeaterStats(
      id: "0C13",
      rxPacketCount: 3,
      rxSnrSum: 12,
      rxSnrCount: 2,
      rssiSum: -180,
      rssiCount: 2,
      firstHeard: heard,
      lastHeard: heard.addingTimeInterval(60)
    )
    let dto = observation(
      cell: target,
      day: "2025-07-20",
      packets: 3,
      snr: 6,
      hopHistogram: [0: 1, 2: 2],
      repeaters: ["0C13": stats]
    )

    try await store.upsertMapperCellObservations([dto])

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(row.cellRaw == target.rawValue)
    #expect(row.cell == target)
    #expect(row.day == "2025-07-20")
    #expect(row.packetCount == 3)
    #expect(row.hopHistogram == [0: 1, 2: 2])
    #expect(row.repeaters["0C13"] == stats)
    #expect(row.avgSnr == 6)
    #expect(row.quality == .good)
  }

  @Test
  func `The SurveyKit aggregate survives the trip through storage`() async throws {
    let store = try makeStore()
    let target = try cell(MapperFixtureLocation.plaza)
    let at = Date(timeIntervalSince1970: 1_753_000_000)
    var aggregate = AggregatedCell(cell: target)
    CellAggregator.fold(
      SurveySample(
        timestamp: at,
        coordinate: GeoCoordinate(
          latitude: MapperFixtureLocation.plaza.latitude,
          longitude: MapperFixtureLocation.plaza.longitude
        ),
        snr: 7,
        rssi: -75,
        route: .direct,
        isActiveProbe: false,
        hopCount: 1,
        repeaters: [SurveySample.RepeaterSighting(id: "42", rxSnr: 7, rssi: -75)]
      ),
      into: &aggregate
    )

    try await store.upsertMapperCellObservations([
      MapperCellObservationDTO(day: MapperDayKey.key(for: at), aggregate: aggregate)
    ])

    let row = try #require(try await store.fetchMapperCellObservations().first)
    let restored = try #require(row.aggregate)
    #expect(restored.cell == aggregate.cell)
    #expect(restored.packetCount == aggregate.packetCount)
    #expect(restored.directCount == aggregate.directCount)
    #expect(restored.avgSnr == aggregate.avgSnr)
    #expect(restored.avgRssi == aggregate.avgRssi)
    #expect(restored.hopHistogram == aggregate.hopHistogram)
    #expect(restored.repeaters["42"]?.rxSnrSum == aggregate.repeaters["42"]?.rxSnrSum)
    #expect(restored.dailyCounts == ["2025-07-20": 1])
  }

  // MARK: - Upsert folding

  @Test
  func `Upserting the same cell-day twice sums into one row`() async throws {
    let store = try makeStore()
    let target = try cell(MapperFixtureLocation.plaza)

    try await store.upsertMapperCellObservations([
      observation(cell: target, day: "2025-07-20", packets: 2, snr: 4, hopHistogram: [1: 2])
    ])
    try await store.upsertMapperCellObservations([
      observation(cell: target, day: "2025-07-20", packets: 3, snr: 10, hopHistogram: [1: 1, 3: 1])
    ])

    let rows = try await store.fetchMapperCellObservations()
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.packetCount == 5)
    #expect(row.snrSum == 14)
    #expect(row.snrCount == 2)
    #expect(row.minSnr == 4)
    #expect(row.maxSnr == 10)
    #expect(row.hopHistogram == [1: 3, 3: 1])
  }

  @Test
  func `Duplicate cell-days inside one batch are collapsed before the write`() async throws {
    let store = try makeStore()
    let target = try cell(MapperFixtureLocation.plaza)

    try await store.upsertMapperCellObservations([
      observation(cell: target, day: "2025-07-20", packets: 1, snr: 2),
      observation(cell: target, day: "2025-07-20", packets: 1, snr: 8)
    ])

    let rows = try await store.fetchMapperCellObservations()
    #expect(rows.count == 1)
    #expect(rows.first?.packetCount == 2)
    #expect(rows.first?.minSnr == 2)
    #expect(rows.first?.maxSnr == 8)
  }

  @Test
  func `Direction counters and RTT stats fold across upserts`() async throws {
    let store = try makeStore()
    let target = try cell(MapperFixtureLocation.plaza)

    try await store.upsertMapperCellObservations([
      MapperCellObservationDTO(
        cellRaw: target.rawValue, day: "2025-07-20",
        packetCount: 2, rxCount: 2
      ),
      MapperCellObservationDTO(
        cellRaw: target.rawValue, day: "2025-07-20",
        packetCount: 1, txHeardCount: 1
      )
    ])
    try await store.upsertMapperCellObservations([
      MapperCellObservationDTO(
        cellRaw: target.rawValue, day: "2025-07-20",
        ackCount: 2, rttMsSum: 900, rttSampleCount: 2
      )
    ])

    let rows = try await store.fetchMapperCellObservations()
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.rxCount == 2)
    #expect(row.txHeardCount == 1)
    #expect(row.ackCount == 2)
    #expect(row.packetCount == 3, "ACKs fold no packet")
    #expect(row.observationCount == 5)
    #expect(row.rttSampleCount == 2)
    #expect(row.avgRttMs == 450)
  }

  @Test
  func `A row written before direction counters existed reads back as all RX`() async throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let target = try cell(MapperFixtureLocation.plaza)

    // What an M0 row looks like on disk: packets, no direction attributed to them.
    let context = ModelContext(container)
    context.insert(MapperCellObservation(
      cellRaw: target.rawValue,
      day: "2025-07-20",
      packetCount: 4,
      passivePacketCount: 4
    ))
    try context.save()

    let row = try #require(try await store.fetchMapperCellObservations().first)
    #expect(row.rxCount == 4)
    #expect(row.txHeardCount == 0)
    #expect(row.ackCount == 0)
  }

  @Test
  func `A SurveyKit aggregate with no direction given is taken as all RX`() throws {
    let target = try cell(MapperFixtureLocation.plaza)
    var aggregate = AggregatedCell(cell: target)
    aggregate.packetCount = 7

    let dto = MapperCellObservationDTO(day: "2025-07-20", aggregate: aggregate)

    #expect(dto.rxCount == 7)
    #expect(dto.txHeardCount == 0)
    #expect(dto.ackCount == 0)
  }

  @Test
  func `Different days and different cells stay separate rows`() async throws {
    let store = try makeStore()
    let plaza = try cell(MapperFixtureLocation.plaza)
    let distant = try cell(MapperFixtureLocation.acrossTown)

    try await store.upsertMapperCellObservations([
      observation(cell: plaza, day: "2025-07-20"),
      observation(cell: plaza, day: "2025-07-21"),
      observation(cell: distant, day: "2025-07-20")
    ])

    #expect(try await store.countMapperCellObservations() == 3)
  }

  @Test
  func `Merging a mismatched identity is refused rather than corrupting either row`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let distant = try cell(MapperFixtureLocation.acrossTown)
    let base = observation(cell: plaza, day: "2025-07-20", packets: 1)

    #expect(base.merged(with: observation(cell: distant, day: "2025-07-20", packets: 5)) == base)
    #expect(base.merged(with: observation(cell: plaza, day: "2025-07-21", packets: 5)) == base)
  }

  @Test
  func `An empty batch is a no-op`() async throws {
    let store = try makeStore()
    try await store.upsertMapperCellObservations([])
    #expect(try await store.countMapperCellObservations() == 0)
  }

  // MARK: - Fetch

  @Test
  func `A day-range fetch returns only the days inside it, newest first`() async throws {
    let store = try makeStore()
    let target = try cell(MapperFixtureLocation.plaza)

    for day in ["2025-07-18", "2025-07-19", "2025-07-20", "2025-07-21"] {
      try await store.upsertMapperCellObservations([observation(cell: target, day: day)])
    }

    let window = try await store.fetchMapperCellObservations(fromDay: "2025-07-19", toDay: "2025-07-20")
    #expect(window.map(\.day) == ["2025-07-20", "2025-07-19"])

    let reversed = try await store.fetchMapperCellObservations(fromDay: "2025-07-20", toDay: "2025-07-19")
    #expect(reversed.map(\.day) == ["2025-07-20", "2025-07-19"], "a backwards range is normalized")

    let all = try await store.fetchMapperCellObservations()
    #expect(all.map(\.day) == ["2025-07-21", "2025-07-20", "2025-07-19", "2025-07-18"])
  }

  @Test
  func `deleteAll clears every row`() async throws {
    let store = try makeStore()
    let target = try cell(MapperFixtureLocation.plaza)
    try await store.upsertMapperCellObservations([
      observation(cell: target, day: "2025-07-20"),
      observation(cell: target, day: "2025-07-21")
    ])
    #expect(try await store.countMapperCellObservations() == 2)

    try await store.deleteAllMapperCellObservations()

    #expect(try await store.countMapperCellObservations() == 0)
    #expect(try await store.fetchMapperCellObservations().isEmpty)
  }

  // MARK: - Day keys

  @Test
  func `Day keys are UTC, not local`() {
    // 2025-07-20 23:30 UTC is already the 21st in CEST and still the 20th in UTC.
    let lateEvening = Date(timeIntervalSince1970: 1_753_054_200)
    #expect(MapperDayKey.key(for: lateEvening) == "2025-07-20")
    #expect(MapperDayKey.key(for: lateEvening.addingTimeInterval(1800)) == "2025-07-21")
  }

  // MARK: - Build 40 isolation

  @Test
  func `Adding mapper rows leaves the dormant Build 40 survey tables untouched`() async throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let target = try cell(MapperFixtureLocation.plaza)

    try await store.upsertMapperCellObservations([observation(cell: target, day: "2025-07-20")])

    let context = ModelContext(container)
    #expect(try context.fetchCount(FetchDescriptor<SurveySession>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<SignalSurveyPoint>()) == 0)
    #expect(try await store.countMapperCellObservations() == 1)
  }
}
