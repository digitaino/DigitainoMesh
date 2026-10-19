import Foundation
import MapperRawLog
@testable import MC1
import MC1Services
import SurveyKit
import Testing

/// The card's own arithmetic (docs/SIGNAL_MAPPER_V3.md §3, mockup screen 2): the per-repeater
/// uplink fold the Reach layer leads with.
///
/// `MapperCellQueries` already owns the repeater rows and the headline, and its own suite
/// pins those. What is new here is the `now · best · avg` fold over the *uplink* leg, which
/// exists because a reply's SNR is the one number `MapperRepeaterRow` keeps only the latest
/// of — and it has to obey the same rule the query does: only a trace or discover reply
/// carries an uplink number (§1 (b)).
@Suite("Signal mapper card builder")
struct SignalMapperCardBuilderTests {
  private let cellRaw: UInt64 = 0x0892_8308_280F_FFFF
  private let start = Date(timeIntervalSince1970: 1_753_000_000)

  private func at(_ offset: TimeInterval) -> Date {
    start.addingTimeInterval(offset)
  }

  private func row(
    _ offset: TimeInterval,
    _ kind: MapperRawSampleKind,
    hexID: String?,
    rxSnr: Double? = nil,
    txSnr: Double? = nil,
    pathHashes: [String]? = nil
  ) -> MapperRawSampleDTO {
    MapperRawSampleDTO(
      runID: nil,
      seq: Int64(offset),
      timestamp: at(offset),
      kindRaw: kind.rawValue,
      rxSnr: rxSnr,
      txSnr: txSnr,
      pathHashes: pathHashes,
      repeaterHexID: hexID,
      cellRaw: cellRaw,
      gateOutcomeRaw: MapperGateOutcome.accepted.rawValue
    )
  }

  // MARK: - Uplink fold

  @Test
  func `Uplink now, best and average come from replies only`() throws {
    let stats = SignalMapperCardBuilder.uplinkStats(in: [
      row(10, .probeDiscoverResponse, hexID: "0C13", rxSnr: 12, txSnr: 6),
      row(30, .probeTraceReply, hexID: "0C13", rxSnr: 12, txSnr: 13),
      row(20, .probeTraceReply, hexID: "0C13", rxSnr: 12, txSnr: 11),
      // An echo's SNR is our reading of the rebroadcast, not their reading of us.
      row(40, .txHeard, hexID: "0C13", rxSnr: 20, pathHashes: ["0C13"]),
      // A passive reception carries no uplink at all.
      row(50, .passiveRx, hexID: "0C13", rxSnr: 9)
    ], now: at(100))

    let central = try #require(stats["0C13"])
    #expect(central.latest == 13)
    #expect(central.best == 13)
    #expect(central.average == 10)
    #expect(central.count == 3)
    #expect(central.latestAt == at(30))
  }

  @Test
  func `Latest is the latest by time, not by position`() throws {
    // Rows come back newest first and a reply settles after the packets heard while
    // waiting for it, so neither array order may decide which reading is "now".
    let stats = SignalMapperCardBuilder.uplinkStats(in: [
      row(30, .probeTraceReply, hexID: "0C13", txSnr: 4),
      row(90, .probeTraceReply, hexID: "0C13", txSnr: 9),
      row(60, .probeTraceReply, hexID: "0C13", txSnr: 2)
    ], now: at(200))
    #expect(try #require(stats["0C13"]).latest == 9)
  }

  @Test
  func `Rows stamped after now are not read`() {
    let stats = SignalMapperCardBuilder.uplinkStats(in: [
      row(10, .probeTraceReply, hexID: "0C13", txSnr: 5),
      row(500, .probeTraceReply, hexID: "0C13", txSnr: 12)
    ], now: at(100))
    #expect(stats["0C13"]?.best == 5)
  }

  @Test
  func `A repeater that never reported has no uplink stats at all`() {
    let stats = SignalMapperCardBuilder.uplinkStats(in: [
      row(10, .passiveRx, hexID: "9A21", rxSnr: 7),
      row(20, .txHeard, hexID: "9A21", rxSnr: 8, pathHashes: ["9A21"])
    ], now: at(100))
    #expect(stats["9A21"] == nil)
  }

  /// The uplink fold is joined to the repeater rows by hex id, so it has to key on the same
  /// *canonical* id the query does. A repeater whose replies came back under a 1-byte path
  /// hash and whose receptions came under the 2-byte one would otherwise have its uplink
  /// filed under a key no row carries, and the merged row would print an em dash for a
  /// number we hold (2026-09-05).
  @Test
  func `Uplink folds onto the hash the repeater row is listed under`() throws {
    let stats = SignalMapperCardBuilder.uplinkStats(in: [
      row(10, .passiveRx, hexID: "ABBA", rxSnr: 9),
      row(20, .probeTraceReply, hexID: "AB", txSnr: 7),
      row(40, .probeTraceReply, hexID: "ABBA", txSnr: 11)
    ], now: at(100))

    #expect(Array(stats.keys) == ["ABBA"])
    let merged = try #require(stats["ABBA"])
    #expect(merged.latest == 11)
    #expect(merged.best == 11)
    #expect(merged.average == 9)
    #expect(merged.count == 2)
  }

  // MARK: - Assembled card

  @Test
  func `The card lists one row per repeater heard directly, newest first, with its uplink`() throws {
    let builder = SignalMapperCardBuilder()
    let index = try #require(H3Cell(rawValue: cellRaw))
    let data = builder.build(
      cell: index,
      scope: .allTime,
      since: at(0),
      rows: [
        row(10, .passiveRx, hexID: "0C13", rxSnr: 6),
        row(20, .passiveRx, hexID: "0C13", rxSnr: 12.5),
        row(25, .probeTraceReply, hexID: "0C13", rxSnr: 12, txSnr: 13),
        row(30, .passiveRx, hexID: "9A21", rxSnr: 4.5),
        // Direct-routed: credits nobody (§1), so it mints no row.
        row(40, .passiveRx, hexID: nil, rxSnr: 20)
      ],
      now: at(100)
    )

    #expect(data.repeaters.map(\.hexID) == ["9A21", "0C13"])
    let central = try #require(data.repeaters.first { $0.hexID == "0C13" })
    #expect(central.row.rxLatest == 12)
    #expect(central.row.rxBest == 12.5)
    #expect(central.uplink?.latest == 13)
    #expect(central.row.link(at: at(100)) == .hearsYou(snr: 13, at: at(25)))
    // No candidate pool: a hash stays a hash rather than being guessed at.
    #expect(central.name == nil)
    #expect(central.isAmbiguous == false)

    let other = try #require(data.repeaters.first { $0.hexID == "9A21" })
    #expect(other.uplink == nil)
    #expect(other.row.link(at: at(100)) == .none)

    // The headline is the same fold the map's summary makes, over this window's rows.
    #expect(data.headline.heardCount == 4)
    // 20 dB came off a direct-routed packet that credits nobody, so it never grades the
    // hexagon — the headline and the rows agree about that, because they apply one rule.
    #expect(data.headline.rxBest == 12.5)
    #expect(data.headline.txBest == 13)
    #expect(data.rows.count == 5)
    #expect(data.since == at(0))
  }

  /// The asymmetry the card exists to show, from the side the card renders: a repeater that
  /// answered a probe and that our radio has never measured. It has an uplink and no
  /// downlink, and the Hear layer's lead line falls back to a phrase rather than printing a
  /// reading we never took (Rafael, 2026-09-04).
  @Test
  func `A repeater known only from its reply has an uplink and no downlink`() throws {
    let index = try #require(H3Cell(rawValue: cellRaw))
    let data = SignalMapperCardBuilder().build(
      cell: index,
      scope: .ride,
      since: at(0),
      rows: [
        // No `rxSnr`: we never heard the reply's carrier well enough to log a reading.
        row(10, .probeDiscoverResponse, hexID: "0C13", txSnr: 11),
        row(20, .passiveRx, hexID: "9A21", rxSnr: 4.5)
      ],
      now: at(100)
    )

    let replyOnly = try #require(data.repeaters.first { $0.hexID == "0C13" })
    #expect(replyOnly.row.rxLatest == nil)
    #expect(replyOnly.row.rxBest == nil)
    #expect(replyOnly.row.rxAverage == nil)
    #expect(replyOnly.row.rxCount == 0)
    #expect(replyOnly.row.lastHeardAt == nil)
    #expect(replyOnly.row.lastEvidenceAt == at(10))
    #expect(replyOnly.row.link(at: at(100)) == .hearsYou(snr: 11, at: at(10)))
    #expect(replyOnly.uplink?.latest == 11, "the Reach layer leads with the number it does have")

    // The uplink fold and the row query agree about which repeaters exist: a row with an
    // uplink and no RX is expected now rather than impossible.
    #expect(data.repeaters.map(\.hexID) == ["9A21", "0C13"])
    #expect(data.repeaters.first { $0.hexID == "9A21" }?.uplink == nil)
  }

  /// End to end, the complaint itself: one repeater arriving under two hash widths is one
  /// card row, carrying both legs and both hashes, so the card never has to disambiguate two
  /// rows that resolve to the same name by suffixing each with its hash.
  @Test
  func `Two hash widths of one repeater build a single row with both legs`() throws {
    let index = try #require(H3Cell(rawValue: cellRaw))
    let data = SignalMapperCardBuilder().build(
      cell: index,
      scope: .allTime,
      since: at(0),
      rows: [
        row(10, .passiveRx, hexID: "ABBA", rxSnr: 9),
        row(20, .passiveRx, hexID: "AB", rxSnr: 3),
        row(30, .probeTraceReply, hexID: "AB", txSnr: 7)
      ],
      now: at(100)
    )

    #expect(data.repeaters.map(\.hexID) == ["ABBA"])
    let merged = try #require(data.repeaters.first)
    #expect(merged.row.aliasHexIDs == ["AB"])
    #expect(merged.row.rxCount == 2)
    #expect(merged.uplink?.latest == 7, "the uplink follows the row it belongs to")
    #expect(merged.row.link(at: at(100)) == .hearsYou(snr: 7, at: at(30)))
  }

  @Test
  func `A hexagon whose window holds nothing builds an empty card rather than nil`() throws {
    let index = try #require(H3Cell(rawValue: cellRaw))
    let data = SignalMapperCardBuilder().build(
      cell: index,
      scope: .ride,
      since: at(0),
      rows: [],
      now: at(100)
    )
    #expect(data.repeaters.isEmpty)
    #expect(data.headline.heardCount == 0)
    #expect(data.scope == .ride)
  }
}
