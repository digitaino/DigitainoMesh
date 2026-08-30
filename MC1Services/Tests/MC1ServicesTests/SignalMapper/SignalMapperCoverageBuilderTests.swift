import Foundation
@testable import MC1Services
import SurveyKit
import Testing

/// Coverage-map logic: how stored `(cell, day)` rows become the cells a map draws. Pure
/// value types in, pure value types out — no store, no radio, no map.
@Suite("SignalMapperCoverageBuilder")
struct SignalMapperCoverageBuilderTests {
  private let builder = SignalMapperCoverageBuilder()
  private let now = Date(timeIntervalSince1970: 1_753_000_000)

  private func cell(_ location: (latitude: Double, longitude: Double)) throws -> H3Cell {
    try #require(MapperFixtureLocation.cell(location))
  }

  private func row(
    cell: H3Cell,
    day: String,
    rx: Int = 0,
    txHeard: Int = 0,
    ack: Int = 0,
    snr: Double? = nil,
    rssi: Double? = nil,
    rttMs: Double? = nil,
    flood: Int = 0,
    direct: Int = 0,
    repeaters: [String: MapperRepeaterStats] = [:]
  ) -> MapperCellObservationDTO {
    let packets = rx + txHeard
    return MapperCellObservationDTO(
      cellRaw: cell.rawValue,
      day: day,
      packetCount: packets,
      passivePacketCount: packets,
      rxCount: rx,
      txHeardCount: txHeard,
      ackCount: ack,
      rttMsSum: rttMs ?? 0,
      rttSampleCount: rttMs == nil ? 0 : 1,
      snrSum: (snr ?? 0) * Double(packets),
      snrCount: snr == nil ? 0 : packets,
      minSnr: snr,
      maxSnr: snr,
      rssiSum: (rssi ?? 0) * Double(packets),
      rssiCount: rssi == nil ? 0 : packets,
      floodCount: flood,
      directCount: direct,
      repeaters: repeaters
    )
  }

  // MARK: - Merging days

  @Test
  func `Days of one cell merge into a single map cell`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)

    let snapshot = builder.build(
      rows: [
        row(cell: plaza, day: "2025-07-21", rx: 3, snr: 8, flood: 3),
        row(cell: plaza, day: "2025-07-19", rx: 2, txHeard: 1, snr: 2, flood: 3),
        row(cell: plaza, day: "2025-07-20", ack: 2, rttMs: 400)
      ],
      now: now
    )

    #expect(snapshot.cells.count == 1)
    let mapped = try #require(snapshot.cells.first)
    #expect(mapped.cell == plaza)
    #expect(mapped.rxCount == 5)
    #expect(mapped.txHeardCount == 1)
    #expect(mapped.ackCount == 2)
    #expect(mapped.packetCount == 6)
    #expect(mapped.observationCount == 8)
    #expect(mapped.dayCount == 3)
    #expect(mapped.firstDay == "2025-07-19")
    #expect(mapped.lastDay == "2025-07-21")
    #expect(snapshot.dayCount == 3)
    #expect(snapshot.firstDay == "2025-07-19")
    #expect(snapshot.lastDay == "2025-07-21")
    #expect(snapshot.totalObservations == 8)
    #expect(snapshot.totalPackets == 6)
  }

  @Test
  func `Distinct cells stay distinct`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let distant = try cell(MapperFixtureLocation.acrossTown)

    let snapshot = builder.build(
      rows: [
        row(cell: plaza, day: "2025-07-20", rx: 1),
        row(cell: distant, day: "2025-07-20", rx: 1)
      ],
      now: now
    )

    #expect(snapshot.cells.count == 2)
    #expect(Set(snapshot.cells.map(\.cell)) == [plaza, distant])
  }

  @Test
  func `Averages come out of the merged sums, not out of per-day means`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)

    // Nine packets at 10 dB and one at 0 dB: the true mean is 9, not the 5 a mean of
    // per-day means would give.
    let snapshot = builder.build(
      rows: [
        row(cell: plaza, day: "2025-07-20", rx: 9, snr: 10, rssi: -60),
        row(cell: plaza, day: "2025-07-21", rx: 1, snr: 0, rssi: -100)
      ],
      now: now
    )

    let mapped = try #require(snapshot.cells.first)
    #expect(mapped.averageSnr == 9)
    #expect(mapped.averageRssi == -64)
    #expect(mapped.bestSnr == 10)
    #expect(mapped.worstSnr == 0)
    // Colour follows the BEST link since M3.5's second field pass: reaching the mesh
    // at 10 dB from this cell is excellent coverage even though the pooled average
    // (9 dB, still asserted above) sits in "good". Rafael, 2026-08-30.
    #expect(mapped.quality == .excellent, "quality is best-link (10 dB), not the 9 dB average")
  }

  @Test
  func `Round-trip times average across days`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)

    let snapshot = builder.build(
      rows: [
        row(cell: plaza, day: "2025-07-20", ack: 1, rttMs: 200),
        row(cell: plaza, day: "2025-07-21", ack: 1, rttMs: 600)
      ],
      now: now
    )

    #expect(snapshot.cells.first?.averageRttMs == 400)
  }

  // MARK: - Geometry

  @Test
  func `Every cell carries a closable boundary and its centre`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)

    let snapshot = builder.build(rows: [row(cell: plaza, day: "2025-07-20", rx: 1)], now: now)

    let mapped = try #require(snapshot.cells.first)
    #expect(mapped.boundary.count >= 5, "a res-9 hexagon has six vertices, a pentagon five")
    #expect(mapped.boundary == SurveyGrid.boundary(of: plaza))
    #expect(mapped.center == SurveyGrid.center(of: plaza))
    #expect(abs(mapped.center.latitude - MapperFixtureLocation.plaza.latitude) < 0.01)
  }

  // MARK: - Weighting and ordering

  @Test
  func `Weight is observations relative to the busiest cell, and orders the snapshot`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let distant = try cell(MapperFixtureLocation.acrossTown)

    let snapshot = builder.build(
      rows: [
        row(cell: plaza, day: "2025-07-20", rx: 1),
        row(cell: distant, day: "2025-07-20", rx: 4)
      ],
      now: now
    )

    #expect(snapshot.cells.map(\.cell) == [distant, plaza], "busiest first")
    #expect(snapshot.cells.first?.normalizedWeight == 1)
    #expect(snapshot.cells.last?.normalizedWeight == 0.25)
  }

  @Test
  func `A cell proved only by acknowledgements still carries weight`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let distant = try cell(MapperFixtureLocation.acrossTown)

    let snapshot = builder.build(
      rows: [
        row(cell: plaza, day: "2025-07-20", ack: 4),
        row(cell: distant, day: "2025-07-20", rx: 2)
      ],
      now: now
    )

    #expect(snapshot.cells.map(\.cell) == [plaza, distant])
    let ackOnly = try #require(snapshot.cells.first)
    #expect(ackOnly.packetCount == 0)
    #expect(ackOnly.observationCount == 4)
    #expect(ackOnly.normalizedWeight == 1)
    #expect(ackOnly.quality == .unknown, "no packet means no SNR to grade")
  }

  @Test
  func `Rebuilding unchanged rows gives an identical snapshot`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let distant = try cell(MapperFixtureLocation.acrossTown)
    let rows = [
      row(cell: plaza, day: "2025-07-20", rx: 2),
      row(cell: distant, day: "2025-07-20", rx: 2)
    ]

    #expect(builder.build(rows: rows, now: now) == builder.build(rows: rows.reversed(), now: now))
  }

  // MARK: - Repeaters

  @Test
  func `Repeaters are listed busiest first, with resolver-supplied names`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let heard = Date(timeIntervalSince1970: 1_753_000_000)

    let snapshot = builder.build(
      rows: [row(
        cell: plaza,
        day: "2025-07-20",
        rx: 5,
        repeaters: [
          "0C": MapperRepeaterStats(
            id: "0C", rxPacketCount: 1, rxSnrSum: 4, rxSnrCount: 1,
            firstHeard: heard, lastHeard: heard
          ),
          "42": MapperRepeaterStats(
            id: "42", rxPacketCount: 4, rxSnrSum: 24, rxSnrCount: 3,
            firstHeard: heard, lastHeard: heard.addingTimeInterval(60)
          )
        ]
      )],
      candidates: [
        TrafficFixture.node([0x42], name: "North Ridge"),
        TrafficFixture.node([0x0C], name: "Harbour")
      ],
      now: now
    )

    let repeaters = try #require(snapshot.cells.first?.repeaters)
    #expect(repeaters.map(\.hexID) == ["42", "0C"])
    #expect(repeaters.first?.name == "North Ridge")
    #expect(repeaters.first?.packetCount == 4)
    #expect(repeaters.first?.averageSnr == 8)
    #expect(repeaters.first?.isAmbiguous == false)
    #expect(repeaters.last?.name == "Harbour")
  }

  @Test
  func `A hash no known node answers to stays a hash`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let heard = Date(timeIntervalSince1970: 1_753_000_000)

    let snapshot = builder.build(
      rows: [row(
        cell: plaza,
        day: "2025-07-20",
        rx: 1,
        repeaters: ["AB": MapperRepeaterStats(
          id: "AB", rxPacketCount: 1, firstHeard: heard, lastHeard: heard
        )]
      )],
      candidates: [TrafficFixture.node([0x42], name: "North Ridge")],
      now: now
    )

    let repeater = try #require(snapshot.cells.first?.repeaters.first)
    #expect(repeater.hexID == "AB")
    #expect(repeater.name == nil, "no candidate matches, and nothing here guesses from a string")
    #expect(repeater.averageSnr == nil, "an upstream-only hop has no reading of ours")
  }

  @Test
  func `Two nodes answering to one hash are reported as ambiguous`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let heard = Date(timeIntervalSince1970: 1_753_000_000)

    let snapshot = builder.build(
      rows: [row(
        cell: plaza,
        day: "2025-07-20",
        rx: 1,
        repeaters: ["42": MapperRepeaterStats(
          id: "42", rxPacketCount: 1, firstHeard: heard, lastHeard: heard
        )]
      )],
      candidates: [
        TrafficFixture.node([0x42, 0x01], fill: 0x11, name: "North Ridge"),
        TrafficFixture.node([0x42, 0x02], fill: 0x22, name: "South Ridge")
      ],
      now: now
    )

    #expect(snapshot.cells.first?.repeaters.first?.isAmbiguous == true)
  }

  @Test
  func `Repeater sightings merge across the days of one cell`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let monday = Date(timeIntervalSince1970: 1_753_000_000)
    let tuesday = monday.addingTimeInterval(86400)

    let snapshot = builder.build(
      rows: [
        row(cell: plaza, day: "2025-07-20", rx: 1, repeaters: [
          "42": MapperRepeaterStats(
            id: "42", rxPacketCount: 1, rxSnrSum: 4, rxSnrCount: 1,
            firstHeard: monday, lastHeard: monday
          )
        ]),
        row(cell: plaza, day: "2025-07-21", rx: 1, repeaters: [
          "42": MapperRepeaterStats(
            id: "42", rxPacketCount: 2, rxSnrSum: 8, rxSnrCount: 1,
            firstHeard: tuesday, lastHeard: tuesday
          )
        ])
      ],
      now: now
    )

    let repeater = try #require(snapshot.cells.first?.repeaters.first)
    #expect(repeater.packetCount == 3)
    #expect(repeater.averageSnr == 6)
    #expect(repeater.firstHeard == monday)
    #expect(repeater.lastHeard == tuesday)
  }

  /// The per-repeater spread and RSSI the cell card's "via <repeater>" view runs on.
  /// Widening extremes across days is the part a sum-and-count fold gets wrong if the
  /// columns are merged like counters.
  @Test
  func `A repeater's best and worst readings widen across the days of one cell`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let monday = Date(timeIntervalSince1970: 1_753_000_000)
    let tuesday = monday.addingTimeInterval(86400)

    let snapshot = builder.build(
      rows: [
        row(cell: plaza, day: "2025-07-20", rx: 1, repeaters: [
          "42": MapperRepeaterStats(
            id: "42", rxPacketCount: 1, txPacketCount: 1,
            rxSnrSum: 4, rxSnrCount: 1, txSnrSum: 2, txSnrCount: 1,
            rssiSum: -80, rssiCount: 1,
            minRxSnr: 4, maxRxSnr: 4, minTxSnr: 2, maxTxSnr: 2,
            firstHeard: monday, lastHeard: monday
          )
        ]),
        row(cell: plaza, day: "2025-07-21", rx: 1, repeaters: [
          "42": MapperRepeaterStats(
            id: "42", rxPacketCount: 1, txPacketCount: 1,
            rxSnrSum: 12, rxSnrCount: 1, txSnrSum: 10, txSnrCount: 1,
            rssiSum: -60, rssiCount: 1,
            minRxSnr: 12, maxRxSnr: 12, minTxSnr: 10, maxTxSnr: 10,
            firstHeard: tuesday, lastHeard: tuesday
          )
        ])
      ],
      now: now
    )

    let repeater = try #require(snapshot.cells.first?.repeaters.first)
    #expect(repeater.worstSnr == 4)
    #expect(repeater.bestSnr == 12)
    #expect(repeater.worstTxSnr == 2)
    #expect(repeater.bestTxSnr == 10)
    #expect(repeater.averageSnr == 8)
    #expect(repeater.averageRssi == -70)
  }

  // MARK: - Degenerate input

  @Test
  func `No rows is an empty snapshot, not a crash`() {
    let snapshot = builder.build(rows: [], now: now)

    #expect(snapshot.isEmpty)
    #expect(snapshot == .empty)
  }

  @Test
  func `A row whose stored cell index is corrupt is counted, not drawn`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)

    let snapshot = builder.build(
      rows: [
        MapperCellObservationDTO(cellRaw: 0, day: "2025-07-20", packetCount: 3, rxCount: 3),
        row(cell: plaza, day: "2025-07-20", rx: 1)
      ],
      now: now
    )

    #expect(snapshot.cells.count == 1)
    #expect(snapshot.unreadableRowCount == 1)
  }
}
