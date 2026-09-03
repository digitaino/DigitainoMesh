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

  // MARK: - Per-repeater freshness

  /// "Strongest now" is a pair, and merging days must move both halves together: taking
  /// each field's own maximum would report Monday's strong reading as Tuesday's.
  @Test
  func `The later direct reading wins as a pair when days merge`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let monday = Date(timeIntervalSince1970: 1_753_000_000)
    let tuesday = monday.addingTimeInterval(86400)

    let snapshot = builder.build(
      rows: [
        row(cell: plaza, day: "2025-07-20", rx: 1, repeaters: [
          "42": MapperRepeaterStats(
            id: "42", rxPacketCount: 1, rxSnrSum: 12, rxSnrCount: 1,
            minRxSnr: 12, maxRxSnr: 12,
            lastDirectHeard: monday, lastRxSnr: 12,
            firstHeard: monday, lastHeard: monday
          )
        ]),
        row(cell: plaza, day: "2025-07-21", rx: 1, repeaters: [
          "42": MapperRepeaterStats(
            id: "42", rxPacketCount: 1, rxSnrSum: 1, rxSnrCount: 1,
            minRxSnr: 1, maxRxSnr: 1,
            lastDirectHeard: tuesday, lastRxSnr: 1,
            firstHeard: tuesday, lastHeard: tuesday
          )
        ])
      ],
      now: now
    )

    let repeater = try #require(snapshot.cells.first?.repeaters.first)
    #expect(repeater.lastDirectHeard == tuesday)
    #expect(repeater.lastRxSnr == 1, "the current reading is the latest one, not the best one")
    #expect(repeater.bestSnr == 12, "the best is still reported, as the best")
    #expect(repeater.directReadingCount == 2)
  }

  /// Rows written before the freshness columns existed still imply the two facts they hold:
  /// a repeater with direct readings was heard directly by `lastHeard`, and one that
  /// reported a reading had proved the uplink by then too.
  @Test
  func `A row written before the freshness columns falls back to what it does carry`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let heard = Date(timeIntervalSince1970: 1_753_000_000)

    let snapshot = builder.build(
      rows: [row(cell: plaza, day: "2025-07-20", rx: 2, repeaters: [
        "42": MapperRepeaterStats(
          id: "42", rxPacketCount: 1, txPacketCount: 1,
          rxSnrSum: 14, rxSnrCount: 2, txSnrSum: 3, txSnrCount: 1,
          minRxSnr: 5, maxRxSnr: 9,
          firstHeard: heard, lastHeard: heard.addingTimeInterval(300)
        ),
        // Relay-only: nothing to fall back to, and nothing may be invented.
        "0C": MapperRepeaterStats(
          id: "0C", relayCount: 3, firstHeard: heard, lastHeard: heard
        )
      ])],
      now: now
    )

    let repeaters = try #require(snapshot.cells.first?.repeaters)
    let measured = try #require(repeaters.first { $0.hexID == "42" })
    #expect(measured.lastDirectHeard == heard.addingTimeInterval(300))
    #expect(measured.lastRxSnr == 9, "the best reading is the only one such a row kept")
    #expect(measured.lastUplinkAt == heard.addingTimeInterval(300))
    #expect(measured.link(at: heard.addingTimeInterval(400)) == .twoWay)

    let relay = try #require(repeaters.first { $0.hexID == "0C" })
    #expect(relay.lastDirectHeard == nil)
    #expect(relay.lastRxSnr == nil)
    #expect(relay.lastUplinkAt == nil)
    #expect(relay.relayCount == 3)
    #expect(relay.isRelayOnly)
  }

  // MARK: - One chip per node

  /// Firmware advertises the same repeater at 1, 2 or 3 bytes depending on the path, so one
  /// node arrives as several hashes and used to be listed several times.
  @Test
  func `Hashes of differing width that resolve to one node become one repeater`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let heard = Date(timeIntervalSince1970: 1_753_000_000)

    let snapshot = builder.build(
      rows: [row(
        cell: plaza,
        day: "2025-07-20",
        rx: 5,
        repeaters: [
          "ABBA": MapperRepeaterStats(
            id: "ABBA", rxPacketCount: 2, rxSnrSum: 8, rxSnrCount: 2,
            minRxSnr: 4, maxRxSnr: 4, relayCount: 1,
            lastDirectHeard: heard, lastRxSnr: 4,
            firstHeard: heard, lastHeard: heard
          ),
          "ABBA4A": MapperRepeaterStats(
            id: "ABBA4A", rxPacketCount: 1, rxSnrSum: 10, rxSnrCount: 1,
            minRxSnr: 10, maxRxSnr: 10, relayCount: 2, echoCount: 1,
            lastDirectHeard: heard.addingTimeInterval(60), lastRxSnr: 10,
            lastUplinkAt: heard.addingTimeInterval(60),
            firstHeard: heard.addingTimeInterval(60), lastHeard: heard.addingTimeInterval(60)
          ),
          // One byte, two nodes answering to it: merging this into anyone would invent a
          // fact, so it stays its own row and says it is a guess.
          "0C": MapperRepeaterStats(
            id: "0C", rxPacketCount: 1, firstHeard: heard, lastHeard: heard
          )
        ]
      )],
      candidates: [
        TrafficFixture.node([0xAB, 0xBA, 0x4A], name: "North Ridge"),
        TrafficFixture.node([0x0C, 0x01], fill: 0x11, name: "Harbour"),
        TrafficFixture.node([0x0C, 0x02], fill: 0x22, name: "Harbour Annex")
      ],
      now: now
    )

    let repeaters = try #require(snapshot.cells.first?.repeaters)
    #expect(repeaters.count == 2, "two hashes of one node are one chip; the ambiguous one stands alone")

    let ridge = try #require(repeaters.first { $0.name == "North Ridge" })
    #expect(ridge.hexID == "ABBA4A", "the widest hash the mesh ever gave for this node")
    #expect(ridge.rxPacketCount == 3)
    #expect(ridge.packetCount == 3)
    #expect(ridge.relayCount == 3)
    #expect(ridge.echoCount == 1)
    #expect(ridge.directReadingCount == 3)
    #expect(ridge.bestSnr == 10)
    #expect(ridge.worstSnr == 4)
    #expect(ridge.lastDirectHeard == heard.addingTimeInterval(60))
    #expect(ridge.lastRxSnr == 10)
    #expect(ridge.lastUplinkAt == heard.addingTimeInterval(60))
    #expect(ridge.isAmbiguous == false)

    let ambiguous = try #require(repeaters.first { $0.hexID == "0C" })
    #expect(ambiguous.isAmbiguous, "two nodes answer to it, so it is a best guess")
    #expect(ambiguous.rxPacketCount == 1, "and it was not folded into either of them")
  }

  @Test
  func `Collapsing repeaters leaves a rebuild of unchanged rows identical`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let heard = Date(timeIntervalSince1970: 1_753_000_000)
    let rows = [row(cell: plaza, day: "2025-07-20", rx: 3, repeaters: [
      "ABBA": MapperRepeaterStats(id: "ABBA", rxPacketCount: 1, firstHeard: heard, lastHeard: heard),
      "ABBA4A": MapperRepeaterStats(
        id: "ABBA4A", rxPacketCount: 1, firstHeard: heard, lastHeard: heard
      ),
      "AB": MapperRepeaterStats(id: "AB", rxPacketCount: 1, firstHeard: heard, lastHeard: heard)
    ])]
    let candidates = [TrafficFixture.node([0xAB, 0xBA, 0x4A], name: "North Ridge")]

    let first = builder.build(rows: rows, candidates: candidates, now: now)
    let second = builder.build(rows: rows, candidates: candidates, now: now)

    #expect(first == second)
    #expect(first.cells.first?.repeaters.count == 1, "all three widths name the one node")
    #expect(first.cells.first?.repeaters.first?.hexID == "ABBA4A")
  }

  // MARK: - Link classification

  /// The three cases a chip can be in, on fixed clocks: nothing here may consult `Date()`.
  @Test
  func `A link is two-way only while both legs are current`() {
    let now = Date(timeIntervalSince1970: 1_753_000_000)
    let recent = now.addingTimeInterval(-60)
    let old = now.addingTimeInterval(-3600)

    let twoWay = repeater(lastDirectHeard: recent, lastUplinkAt: recent)
    #expect(twoWay.link(at: now) == .twoWay)
    #expect(!twoWay.isStale(at: now))
    #expect(twoWay.freshestEvidence(at: now) == recent)

    let heardOnly = repeater(lastDirectHeard: recent, lastUplinkAt: nil)
    #expect(heardOnly.link(at: now) == .oneWay)
    #expect(heardOnly.wasHeardDirectly)
    #expect(!heardOnly.wasUplinkProven)

    let uplinkOnly = repeater(lastDirectHeard: nil, lastUplinkAt: recent)
    #expect(uplinkOnly.link(at: now) == .oneWay)

    // One leg current, one leg stale: still only half a *current* link.
    let halfStale = repeater(lastDirectHeard: recent, lastUplinkAt: old)
    #expect(halfStale.link(at: now) == .oneWay)

    // Both legs proved, neither current: a link that was, not one that is — and never
    // `relayOnly`, which is a claim about evidence, not about age.
    let bothStale = repeater(lastDirectHeard: old, lastUplinkAt: old)
    #expect(bothStale.link(at: now) == .oneWay)
    #expect(bothStale.isStale(at: now))
    #expect(!bothStale.isRelayOnly)

    let relay = repeater(lastDirectHeard: nil, lastUplinkAt: nil)
    #expect(relay.link(at: now) == .relayOnly)
    #expect(relay.isRelayOnly)
    #expect(relay.isStale(at: now), "no evidence at all is not fresh evidence")
    #expect(relay.freshestEvidence(at: now) == nil)
  }

  @Test
  func `Freshness ends exactly at the ten-minute window`() {
    let now = Date(timeIntervalSince1970: 1_753_000_000)
    #expect(SignalMapperFreshness.window == 600)

    let onTheEdge = repeater(
      lastDirectHeard: now.addingTimeInterval(-600),
      lastUplinkAt: now.addingTimeInterval(-600)
    )
    #expect(onTheEdge.isDirectCurrent(at: now))
    #expect(onTheEdge.isUplinkCurrent(at: now))
    #expect(onTheEdge.link(at: now) == .twoWay)
    #expect(!onTheEdge.isStale(at: now))

    let justPast = repeater(
      lastDirectHeard: now.addingTimeInterval(-601),
      lastUplinkAt: now.addingTimeInterval(-601)
    )
    #expect(!justPast.isDirectCurrent(at: now))
    #expect(!justPast.isUplinkCurrent(at: now))
    #expect(justPast.link(at: now) == .oneWay)
    #expect(justPast.isStale(at: now))
  }

  private func repeater(
    lastDirectHeard: Date?,
    lastUplinkAt: Date?
  ) -> SignalMapperCoverageRepeater {
    let heard = Date(timeIntervalSince1970: 1_753_000_000)
    return SignalMapperCoverageRepeater(
      hexID: "42",
      packetCount: 1,
      averageSnr: lastDirectHeard == nil ? nil : 6,
      lastDirectHeard: lastDirectHeard,
      lastRxSnr: lastDirectHeard == nil ? nil : 6,
      lastUplinkAt: lastUplinkAt,
      firstHeard: heard,
      lastHeard: heard
    )
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

// MARK: - This ride vs all time

/// The residual arithmetic and the ride's own map (docs/SIGNAL_MAPPER_V2.md §2.6): a run's
/// contribution is the stored row now minus the row as it stood when the run started.
///
/// Every instant here is a fixed offset from one epoch, so "before the run" and "during the
/// run" are facts of the fixture rather than of when the suite happens to run.
@Suite("SignalMapperCoverageBuilder session")
struct SignalMapperCoverageSessionTests {
  private let builder = SignalMapperCoverageBuilder()
  private let epoch = Date(timeIntervalSince1970: 1_753_000_000)
  /// The run starts 1000 s into the fixture's timeline; anything earlier is history.
  private var startedAt: Date { epoch.addingTimeInterval(1000) }
  private var now: Date { epoch.addingTimeInterval(3000) }

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
    txSnr: Double? = nil,
    probesSent: Int = 0,
    latest: Date? = nil,
    repeaters: [String: MapperRepeaterStats] = [:]
  ) -> MapperCellObservationDTO {
    let packets = rx + txHeard
    return MapperCellObservationDTO(
      cellRaw: cell.rawValue,
      day: day,
      packetCount: packets,
      passivePacketCount: packets,
      probesSent: probesSent,
      rxCount: rx,
      txHeardCount: txHeard,
      ackCount: ack,
      snrSum: (snr ?? 0) * Double(packets),
      snrCount: snr == nil ? 0 : packets,
      minSnr: snr,
      maxSnr: snr,
      txSnrSum: txSnr ?? 0,
      txSnrCount: txSnr == nil ? 0 : 1,
      maxTxSnr: txSnr,
      earliest: latest,
      latest: latest,
      repeaters: repeaters
    )
  }

  private func stats(
    id: String,
    rx: Int = 0,
    tx: Int = 0,
    rxSnrSum: Double = 0,
    rxSnrCount: Int = 0,
    relay: Int = 0,
    echo: Int = 0,
    maxRxSnr: Double? = nil,
    lastDirectHeard: Date? = nil,
    lastRxSnr: Double? = nil,
    lastUplinkAt: Date? = nil,
    firstHeard: Date,
    lastHeard: Date
  ) -> MapperRepeaterStats {
    MapperRepeaterStats(
      id: id,
      rxPacketCount: rx,
      txPacketCount: tx,
      rxSnrSum: rxSnrSum,
      rxSnrCount: rxSnrCount,
      maxRxSnr: maxRxSnr,
      relayCount: relay,
      echoCount: echo,
      lastDirectHeard: lastDirectHeard,
      lastRxSnr: lastRxSnr,
      lastUplinkAt: lastUplinkAt,
      firstHeard: firstHeard,
      lastHeard: lastHeard
    )
  }

  private func baseline(_ rows: [MapperCellObservationDTO]) -> SignalMapperSessionBaseline {
    SignalMapperSessionBaseline(startedAt: startedAt, rows: rows)
  }

  // MARK: - The residual is the inverse of the fold

  @Test
  func `A residual against the row it was folded into reproduces what was folded`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let history = MapperCellObservationDTO(
      cellRaw: plaza.rawValue,
      day: "2025-07-20",
      packetCount: 7,
      activePacketCount: 2,
      passivePacketCount: 5,
      probesSent: 3,
      probesAnswered: 1,
      rxCount: 5,
      txHeardCount: 2,
      ackCount: 1,
      stationaryObservationCount: 4,
      rttMsSum: 800,
      rttSampleCount: 2,
      probeRttMsSum: 120,
      probeRttSampleCount: 3,
      snrSum: 35,
      snrCount: 5,
      minSnr: -2,
      maxSnr: 11,
      txSnrSum: 6,
      txSnrCount: 2,
      maxTxSnr: 4,
      rssiSum: -450,
      rssiCount: 5,
      floodCount: 3,
      directCount: 4,
      earliest: epoch,
      latest: epoch.addingTimeInterval(500),
      hopHistogram: [0: 4, 2: 3],
      repeaters: [
        "0C13": stats(
          id: "0C13",
          rx: 4,
          tx: 1,
          rxSnrSum: 20,
          rxSnrCount: 4,
          relay: 2,
          echo: 1,
          maxRxSnr: 9,
          lastDirectHeard: epoch.addingTimeInterval(400),
          lastRxSnr: 9,
          lastUplinkAt: epoch.addingTimeInterval(300),
          firstHeard: epoch,
          lastHeard: epoch.addingTimeInterval(400)
        )
      ]
    )
    let ride = MapperCellObservationDTO(
      cellRaw: plaza.rawValue,
      day: "2025-07-20",
      packetCount: 9,
      activePacketCount: 4,
      passivePacketCount: 5,
      probesSent: 5,
      probesAnswered: 4,
      rxCount: 6,
      txHeardCount: 3,
      ackCount: 2,
      stationaryObservationCount: 1,
      rttMsSum: 300,
      rttSampleCount: 1,
      probeRttMsSum: 240,
      probeRttSampleCount: 4,
      snrSum: 54,
      snrCount: 9,
      minSnr: 1,
      maxSnr: 8,
      txSnrSum: 9,
      txSnrCount: 3,
      maxTxSnr: 3,
      rssiSum: -720,
      rssiCount: 9,
      floodCount: 2,
      directCount: 7,
      earliest: startedAt.addingTimeInterval(100),
      latest: startedAt.addingTimeInterval(600),
      hopHistogram: [0: 5, 3: 4],
      repeaters: [
        "0C13": stats(
          id: "0C13",
          rx: 5,
          tx: 2,
          rxSnrSum: 30,
          rxSnrCount: 5,
          relay: 1,
          echo: 3,
          maxRxSnr: 7,
          lastDirectHeard: startedAt.addingTimeInterval(600),
          lastRxSnr: 7,
          lastUplinkAt: startedAt.addingTimeInterval(500),
          firstHeard: startedAt.addingTimeInterval(100),
          lastHeard: startedAt.addingTimeInterval(600)
        )
      ]
    )

    let stored = history.merged(with: ride)
    let residual = try #require(stored.residual(since: history, startedAt: startedAt))

    #expect(residual.packetCount == ride.packetCount)
    #expect(residual.activePacketCount == ride.activePacketCount)
    #expect(residual.passivePacketCount == ride.passivePacketCount)
    #expect(residual.probesSent == ride.probesSent)
    #expect(residual.probesAnswered == ride.probesAnswered)
    #expect(residual.rxCount == ride.rxCount)
    #expect(residual.txHeardCount == ride.txHeardCount)
    #expect(residual.ackCount == ride.ackCount)
    #expect(residual.stationaryObservationCount == ride.stationaryObservationCount)
    #expect(residual.rttMsSum == ride.rttMsSum)
    #expect(residual.rttSampleCount == ride.rttSampleCount)
    #expect(residual.probeRttMsSum == ride.probeRttMsSum)
    #expect(residual.probeRttSampleCount == ride.probeRttSampleCount)
    #expect(residual.snrSum == ride.snrSum)
    #expect(residual.snrCount == ride.snrCount)
    #expect(residual.txSnrSum == ride.txSnrSum)
    #expect(residual.txSnrCount == ride.txSnrCount)
    #expect(residual.rssiSum == ride.rssiSum)
    #expect(residual.rssiCount == ride.rssiCount)
    #expect(residual.floodCount == ride.floodCount)
    #expect(residual.directCount == ride.directCount)
    #expect(residual.hopHistogram == ride.hopHistogram)
    #expect(residual.observationCount == ride.observationCount)
    #expect(residual.avgSnr == ride.avgSnr, "means survive because sum and count both subtract")
    #expect(residual.avgRttMs == ride.avgRttMs)
    #expect(residual.latest == ride.latest)
    #expect(residual.earliest == startedAt, "the ride's window opens at the run, not before it")

    let repeater = try #require(residual.repeaters["0C13"])
    #expect(repeater.rxPacketCount == 5)
    #expect(repeater.txPacketCount == 2)
    #expect(repeater.rxSnrCount == 5)
    #expect(repeater.rxSnrSum == 30)
    #expect(repeater.relayCount == 1)
    #expect(repeater.echoCount == 3)
    #expect(repeater.lastDirectHeard == startedAt.addingTimeInterval(600))
    #expect(repeater.lastRxSnr == 7)
    #expect(repeater.lastUplinkAt == startedAt.addingTimeInterval(500))
    #expect(repeater.firstHeard == startedAt)
  }

  @Test
  func `Maxima are dropped rather than differenced`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    // The history holds the better link; a subtraction would hand the ride *that* number.
    let history = row(cell: plaza, day: "2025-07-20", rx: 4, snr: 12, txSnr: 6, latest: epoch)
    let stored = history.merged(
      with: row(cell: plaza, day: "2025-07-20", rx: 2, snr: 1, txSnr: 2, latest: startedAt)
    )
    let residual = try #require(stored.residual(since: history, startedAt: startedAt))

    #expect(residual.minSnr == nil)
    #expect(residual.maxSnr == nil)
    #expect(residual.maxTxSnr == nil)

    let session = builder.buildSession(
      rows: [stored],
      baseline: baseline([history]),
      now: now
    )
    let mapped = try #require(session.snapshot.cells.first)
    #expect(mapped.bestSnr == nil, "a ride never shows a best link it cannot prove is its own")
    #expect(mapped.worstSnr == nil)
    #expect(mapped.bestTxSnr == nil)
    #expect(mapped.averageSnr == 1, "the ride's mean is its own two packets")
  }

  @Test
  func `A row that shrank below its baseline clamps to nothing`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    // The anchor purge deleted this cell's history; the baseline still remembers it large.
    let history = row(cell: plaza, day: "2025-07-20", rx: 20, ack: 4, snr: 5, latest: epoch)
    let shrunken = row(cell: plaza, day: "2025-07-20", rx: 3, snr: 5, latest: epoch)

    #expect(shrunken.residual(since: history, startedAt: startedAt) == nil)

    let session = builder.buildSession(
      rows: [shrunken],
      baseline: baseline([history]),
      now: now
    )
    #expect(session.snapshot.isEmpty)
    #expect(session.scope.isEmpty)
  }

  @Test
  func `An unchanged row contributes nothing to the ride`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let unchanged = row(cell: plaza, day: "2025-07-20", rx: 6, snr: 4, latest: epoch)

    #expect(unchanged.residual(since: unchanged, startedAt: startedAt) == nil)
  }

  // MARK: - Repeater residuals

  @Test
  func `A repeater seen before and during the run keeps only the difference`() throws {
    let before = stats(
      id: "0C13",
      rx: 4,
      rxSnrSum: 20,
      rxSnrCount: 4,
      relay: 3,
      maxRxSnr: 11,
      lastDirectHeard: epoch,
      lastRxSnr: 11,
      firstHeard: epoch,
      lastHeard: epoch
    )
    let after = stats(
      id: "0C13",
      rx: 10,
      rxSnrSum: 50,
      rxSnrCount: 10,
      relay: 4,
      maxRxSnr: 11,
      lastDirectHeard: startedAt.addingTimeInterval(60),
      lastRxSnr: 3,
      firstHeard: epoch,
      lastHeard: startedAt.addingTimeInterval(60)
    )

    let residual = try #require(after.residual(since: before, startedAt: startedAt))
    #expect(residual.rxPacketCount == 6)
    #expect(residual.rxSnrCount == 6)
    #expect(residual.rxSnrSum == 30)
    #expect(residual.avgRxSnr == 5)
    #expect(residual.relayCount == 1)
    #expect(residual.maxRxSnr == nil)
    #expect(residual.firstHeard == epoch.addingTimeInterval(1000), "no earlier than the run")
  }

  @Test
  func `A repeater first met during the run passes through whole`() throws {
    let met = stats(
      id: "AB",
      rx: 3,
      rxSnrSum: 9,
      rxSnrCount: 3,
      echo: 2,
      maxRxSnr: 4,
      lastDirectHeard: startedAt.addingTimeInterval(30),
      lastRxSnr: 4,
      lastUplinkAt: startedAt.addingTimeInterval(20),
      firstHeard: startedAt.addingTimeInterval(10),
      lastHeard: startedAt.addingTimeInterval(30)
    )

    let residual = try #require(met.residual(since: nil, startedAt: startedAt))
    #expect(residual.rxPacketCount == 3)
    #expect(residual.echoCount == 2)
    #expect(residual.lastDirectHeard == startedAt.addingTimeInterval(30))
    #expect(residual.lastRxSnr == 4)
    #expect(residual.lastUplinkAt == startedAt.addingTimeInterval(20))
  }

  @Test
  func `A repeater not heard again during the run drops out entirely`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let old = stats(
      id: "CD",
      rx: 2,
      rxSnrCount: 2,
      lastDirectHeard: epoch,
      lastRxSnr: 5,
      firstHeard: epoch,
      lastHeard: epoch
    )
    let history = row(cell: plaza, day: "2025-07-20", rx: 2, latest: epoch, repeaters: ["CD": old])
    let stored = row(
      cell: plaza,
      day: "2025-07-20",
      rx: 5,
      latest: startedAt.addingTimeInterval(90),
      repeaters: ["CD": old]
    )

    let residual = try #require(stored.residual(since: history, startedAt: startedAt))
    #expect(residual.rxCount == 3)
    #expect(residual.repeaters.isEmpty, "no new sighting is no chip on the ride's card")
  }

  @Test
  func `Evidence older than the run is not the ride's freshness`() throws {
    // Its counts moved, so the repeater *was* heard during the run — but the stored
    // freshness pair is from before it, and reattributing it would date a stale reading now.
    let before = stats(id: "0C13", rx: 1, relay: 1, firstHeard: epoch, lastHeard: epoch)
    let after = stats(
      id: "0C13",
      rx: 1,
      relay: 4,
      lastDirectHeard: epoch.addingTimeInterval(100),
      lastRxSnr: 9,
      lastUplinkAt: epoch.addingTimeInterval(200),
      firstHeard: epoch,
      lastHeard: startedAt.addingTimeInterval(10)
    )

    let residual = try #require(after.residual(since: before, startedAt: startedAt))
    #expect(residual.relayCount == 3)
    #expect(residual.lastDirectHeard == nil)
    #expect(residual.lastRxSnr == nil, "the instant and the reading move as one pair or not at all")
    #expect(residual.lastUplinkAt == nil)
  }

  // MARK: - Scope

  @Test
  func `Touched is what the ride folded and fresh is what it mapped first`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let acrossTown = try cell(MapperFixtureLocation.acrossTown)
    let untouched = try cell(MapperFixtureLocation.plazaNudged)
    #expect(untouched == plaza, "the nudged fixture shares the plaza's cell")

    // The plaza was mapped before and re-covered; across town is new ground.
    let history = row(cell: plaza, day: "2025-07-19", rx: 8, snr: 6, latest: epoch)
    let recovered = row(
      cell: plaza,
      day: "2025-07-19",
      rx: 11,
      snr: 6,
      latest: startedAt.addingTimeInterval(120)
    )
    let virgin = row(
      cell: acrossTown,
      day: "2025-07-19",
      rx: 4,
      snr: 2,
      latest: startedAt.addingTimeInterval(200)
    )

    let session = builder.buildSession(
      rows: [recovered, virgin],
      baseline: baseline([history]),
      now: now
    )

    #expect(session.scope.touched == [plaza.rawValue, acrossTown.rawValue])
    #expect(session.scope.fresh == [acrossTown.rawValue])
    #expect(session.scope.contains(plaza.rawValue))
    #expect(!session.scope.isFresh(plaza.rawValue))
    #expect(session.snapshot.cells.count == 2)
    let ridePlaza = try #require(session.snapshot.cells.first { $0.cell == plaza })
    #expect(ridePlaza.rxCount == 3, "only the three packets the ride added")
  }

  @Test
  func `A cell the ride never entered is absent from the ride's map`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let acrossTown = try cell(MapperFixtureLocation.acrossTown)
    let stale = row(cell: acrossTown, day: "2025-07-19", rx: 9, snr: 3, latest: epoch)
    let history = row(cell: plaza, day: "2025-07-19", rx: 8, snr: 6, latest: epoch)
    let ridden = row(
      cell: plaza,
      day: "2025-07-19",
      rx: 9,
      snr: 6,
      latest: startedAt.addingTimeInterval(60)
    )

    let session = builder.buildSession(
      rows: [stale, ridden],
      baseline: baseline([history, stale]),
      now: now
    )

    #expect(session.scope.touched == [plaza.rawValue])
    #expect(!session.scope.contains(acrossTown.rawValue))
    #expect(session.snapshot.cells.map(\.cell) == [plaza])
  }

  @Test
  func `A ride across midnight folds its new day into the same hexagon`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let history = row(cell: plaza, day: "2025-07-20", rx: 4, snr: 5, latest: epoch)
    let tail = row(
      cell: plaza,
      day: "2025-07-20",
      rx: 6,
      snr: 5,
      latest: startedAt.addingTimeInterval(30)
    )
    // Past UTC midnight the store opens a second row, which the baseline knows nothing of.
    let tomorrow = row(
      cell: plaza,
      day: "2025-07-21",
      rx: 3,
      snr: 5,
      latest: startedAt.addingTimeInterval(90)
    )

    let session = builder.buildSession(
      rows: [tail, tomorrow],
      baseline: baseline([history]),
      now: now
    )

    let mapped = try #require(session.snapshot.cells.first)
    #expect(session.snapshot.cells.count == 1)
    #expect(mapped.observationCount == 5, "two residual packets plus the new day's three")
    #expect(mapped.dayCount == 2)
    #expect(session.scope.touched == [plaza.rawValue])
    #expect(
      session.scope.fresh.isEmpty,
      "a new day of a cell mapped last week is not newly mapped ground"
    )
  }

  // MARK: - Determinism and independence

  @Test
  func `The ride's map is identical however the rows arrive`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let acrossTown = try cell(MapperFixtureLocation.acrossTown)
    let history = [
      row(cell: plaza, day: "2025-07-19", rx: 5, snr: 4, latest: epoch),
      row(cell: acrossTown, day: "2025-07-19", rx: 2, snr: 1, latest: epoch)
    ]
    let rows = [
      row(cell: plaza, day: "2025-07-19", rx: 9, snr: 4, latest: startedAt.addingTimeInterval(10)),
      row(cell: plaza, day: "2025-07-20", rx: 4, snr: 4, latest: startedAt.addingTimeInterval(20)),
      row(
        cell: acrossTown,
        day: "2025-07-20",
        rx: 7,
        snr: 1,
        latest: startedAt.addingTimeInterval(30)
      ),
      row(
        cell: acrossTown,
        day: "2025-07-19",
        rx: 6,
        snr: 1,
        latest: startedAt.addingTimeInterval(40)
      )
    ]

    let first = builder.buildSession(rows: rows, baseline: baseline(history), now: now)
    for _ in 0..<12 {
      let shuffled = builder.buildSession(
        rows: rows.shuffled(),
        baseline: baseline(history.shuffled()),
        now: now
      )
      #expect(shuffled.snapshot == first.snapshot)
      #expect(shuffled.scope == first.scope)
    }
  }

  @Test
  func `Building the ride's map leaves the all-time map exactly as it was`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let history = row(cell: plaza, day: "2025-07-19", rx: 5, snr: 4, latest: epoch)
    let stored = row(
      cell: plaza,
      day: "2025-07-19",
      rx: 12,
      snr: 4,
      latest: startedAt.addingTimeInterval(10)
    )

    let idle = builder.build(rows: [stored], now: now)
    let session = builder.buildSession(rows: [stored], baseline: baseline([history]), now: now)
    let afterwards = builder.build(rows: [stored], now: now)

    #expect(idle == afterwards)
    #expect(idle.totalObservations == 12, "all time is still all time")
    #expect(session.snapshot.totalObservations == 7)
  }

  @Test
  func `The ride's weights ramp on the ride's own busiest hexagon`() throws {
    let plaza = try cell(MapperFixtureLocation.plaza)
    let acrossTown = try cell(MapperFixtureLocation.acrossTown)
    // A season of history at the plaza, one packet of it from this ride; across town is
    // quiet all time but is where the ride actually worked.
    let history = [
      row(cell: plaza, day: "2025-07-19", rx: 200, snr: 6, latest: epoch),
      row(cell: acrossTown, day: "2025-07-19", rx: 1, snr: 2, latest: epoch)
    ]
    let rows = [
      row(
        cell: plaza,
        day: "2025-07-19",
        rx: 201,
        snr: 6,
        latest: startedAt.addingTimeInterval(10)
      ),
      row(
        cell: acrossTown,
        day: "2025-07-19",
        rx: 21,
        snr: 2,
        latest: startedAt.addingTimeInterval(20)
      )
    ]

    let idle = builder.build(rows: rows, now: now)
    let session = builder.buildSession(rows: rows, baseline: baseline(history), now: now)

    let idlePlaza = try #require(idle.cells.first { $0.cell == plaza })
    #expect(idlePlaza.normalizedWeight == 1, "all time still ramps on the plaza")

    let ridePlaza = try #require(session.snapshot.cells.first { $0.cell == plaza })
    let rideAcrossTown = try #require(session.snapshot.cells.first { $0.cell == acrossTown })
    #expect(rideAcrossTown.normalizedWeight == 1)
    #expect(ridePlaza.normalizedWeight == 1.0 / 20.0)
  }
}
