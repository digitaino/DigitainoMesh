import Foundation
import MapperRawLog
@testable import MC1
import MC1Services
import SurveyKit
import Testing

/// What the card's rows draw their bars and their leading rail from (docs/SIGNAL_MAPPER_V3.md
/// §10, Rafael 2026-09-04: "a better way to visualize the different signal levels").
///
/// Two rules are worth pinning because breaking either makes the card lie: a row is graded on
/// the same six-step scale, and the same number (`best`), as the hexagon it sits inside; and
/// the uplink never borrows the downlink's reading when nothing has reported one.
@Suite("Signal mapper row strength")
struct SignalMapperRowStrengthTests {
  private let cellRaw: UInt64 = 0x0892_8308_280F_FFFF
  private let start = Date(timeIntervalSince1970: 1_753_000_000)

  private func at(_ offset: TimeInterval) -> Date {
    start.addingTimeInterval(offset)
  }

  private func item(rxBest: Double?, uplinkBest: Double?) -> SignalMapperRepeaterListRow {
    SignalMapperRepeaterListRow(
      row: MapperRepeaterRow(
        hexID: "0C13",
        lastEvidenceAt: at(10),
        lastHeardAt: rxBest == nil ? nil : at(10),
        rxLatest: rxBest,
        rxBest: rxBest,
        rxAverage: rxBest,
        rxCount: rxBest == nil ? 0 : 1
      ),
      name: nil,
      isAmbiguous: false,
      uplink: uplinkBest.map {
        SignalMapperUplinkStats(latest: $0, best: $0, average: $0, count: 1, latestAt: at(10))
      }
    )
  }

  // MARK: - The six-step bridge

  /// A mint hexagon must not be able to draw the same bars as a green one: the four-step
  /// scale folds `excellent` and `good` into one colour and one bar level, and the card
  /// grades on the six-step scale precisely to keep them apart.
  @Test
  func `Every quality step draws a distinct bar level`() {
    let levels = SignalQuality.allCases.map(\.barLevel)
    #expect(Set(levels).count == SignalQuality.allCases.count)
    #expect(SignalQuality.unknown.barLevel == 0, "no reading is not a weak reading")
    #expect(SignalQuality.excellent.barLevel == 1)
    for quality in SignalQuality.allCases where quality != .unknown {
      #expect(quality.barLevel > 0)
      #expect(quality.barLevel <= 1)
    }
  }

  @Test
  func `Better quality means fuller bars`() {
    let ordered = SignalQuality.allCases.sorted { $0.rank < $1.rank }
    let levels = ordered.map(\.barLevel)
    #expect(levels == levels.sorted(), "bar level and rank must agree, or a weaker row draws more bars")
  }

  // MARK: - Which leg a row is graded on

  @Test
  func `The Hear layer grades a row on the best signal we heard it at`() {
    let row = item(rxBest: 7, uplinkBest: 13)
    #expect(SignalMapperCellCard.railQuality(for: row, layer: .heard) == .good)
    #expect(SignalMapperCellCard.downlinkQuality(for: row) == .good)
  }

  @Test
  func `The Reach layer grades a row on the best signal reported for us`() {
    let row = item(rxBest: 7, uplinkBest: 13)
    #expect(SignalMapperCellCard.railQuality(for: row, layer: .reach) == .excellent)
    #expect(SignalMapperCellCard.uplinkQuality(for: row) == .excellent)
  }

  /// The never-substitute rule. A repeater we hear perfectly and that has never said a word
  /// about us is unknown on the uplink — the row draws the "not measured" mark, not five
  /// bars borrowed from the other leg.
  @Test
  func `An unreported uplink is unknown rather than the downlink's value`() {
    let row = item(rxBest: 13, uplinkBest: nil)
    #expect(SignalMapperCellCard.uplinkQuality(for: row) == nil)
    #expect(SignalMapperCellCard.railQuality(for: row, layer: .reach) == .unknown)
    #expect(SignalMapperCellCard.railQuality(for: row, layer: .heard) == .excellent)
  }

  /// The inverse, which the Reach layer exists to show: heard nowhere, reported clearly.
  @Test
  func `A repeater we have never measured still grades its reach`() {
    let row = item(rxBest: nil, uplinkBest: 6)
    #expect(SignalMapperCellCard.downlinkQuality(for: row) == .unknown)
    #expect(SignalMapperCellCard.railQuality(for: row, layer: .heard) == .unknown)
    #expect(SignalMapperCellCard.railQuality(for: row, layer: .reach) == .good)
  }

  /// The rail and the hexagon are painted from one scale and one number, so a row can never
  /// contradict the colour under it.
  @Test
  func `A row's rail agrees with the hexagon its own reading would paint`() throws {
    let index = try #require(H3Cell(rawValue: cellRaw))
    let summary = MapperCellSummaryDTO(
      cellRaw: cellRaw,
      rxBestSnr: -3.5,
      rxSnrSum: -3.5,
      rxSnrCount: 1,
      rxLastAt: at(10),
      heardCount: 1,
      firstAt: at(10),
      lastAt: at(10)
    )
    let cell = try #require(SignalMapperSnapshotBuilder.build(summaries: [summary]).cells.first)
    #expect(cell.cell == index)
    #expect(SignalMapperCellCard.railQuality(for: item(rxBest: -3.5, uplinkBest: nil), layer: .heard)
      == cell.hearQuality)
  }

  // MARK: - The header's best link

  /// The per-cell version of the nav-bar pill (Rafael, 2026-09-05). Which row it speaks for
  /// is the whole question: the pill answers "what is the radio on right now", so the header
  /// leads on `rxLatest` and prefers a row still inside §1's ten minutes.
  private func linkItem(
    hexID: String,
    rxLatest: Double?,
    lastEvidenceAt: Date,
    hearsYou: Double? = nil
  ) -> SignalMapperRepeaterListRow {
    SignalMapperRepeaterListRow(
      row: MapperRepeaterRow(
        hexID: hexID,
        lastEvidenceAt: lastEvidenceAt,
        lastHeardAt: rxLatest == nil ? nil : lastEvidenceAt,
        rxLatest: rxLatest,
        rxBest: rxLatest,
        rxAverage: rxLatest,
        rxCount: rxLatest == nil ? 0 : 1,
        hearsYouSnr: hearsYou,
        hearsYouAt: hearsYou == nil ? nil : lastEvidenceAt
      ),
      name: nil,
      isAmbiguous: false,
      uplink: nil
    )
  }

  @Test
  func `The header speaks for the strongest thing we hear here now`() throws {
    let best = try #require(SignalMapperCellCard.bestLink(in: [
      linkItem(hexID: "AAAA", rxLatest: 3, lastEvidenceAt: at(0)),
      linkItem(hexID: "BBBB", rxLatest: 11, lastEvidenceAt: at(-30)),
      linkItem(hexID: "CCCC", rxLatest: 8, lastEvidenceAt: at(-5))
    ], now: at(10)))
    #expect(best.hexID == "BBBB")
  }

  /// Staleness bounds the choice without emptying the header: a hexagon whose evidence is
  /// all older than ten minutes is a place, not an error, so the strongest stale row speaks
  /// rather than nothing at all.
  @Test
  func `A stale row is passed over while anything fresh has a reading, and used when none does`() throws {
    let stale = linkItem(hexID: "AAAA", rxLatest: 13, lastEvidenceAt: at(-4000))
    let fresh = linkItem(hexID: "BBBB", rxLatest: 2, lastEvidenceAt: at(-30))

    #expect(try #require(SignalMapperCellCard.bestLink(in: [stale, fresh], now: at(10))).hexID == "BBBB")
    #expect(try #require(SignalMapperCellCard.bestLink(in: [stale], now: at(10))).hexID == "AAAA")
  }

  /// Every row here is a reply or an echo — nothing was ever measured — and the header still
  /// has something true to say about the uplink, so it takes the newest row rather than
  /// disappearing.
  @Test
  func `With nothing ever heard the header falls back to the newest row`() throws {
    let best = try #require(SignalMapperCellCard.bestLink(in: [
      linkItem(hexID: "AAAA", rxLatest: nil, lastEvidenceAt: at(-20), hearsYou: 9),
      linkItem(hexID: "BBBB", rxLatest: nil, lastEvidenceAt: at(-40), hearsYou: 4)
    ], now: at(10)))
    #expect(best.hexID == "AAAA")
    #expect(best.row.link(at: at(10)) == .hearsYou(snr: 9, at: at(-20)))
  }

  @Test
  func `An empty hexagon has no best link`() {
    #expect(SignalMapperCellCard.bestLink(in: [], now: at(10)) == nil)
  }

  /// A probe reply keeps a repeater's evidence fresh for as long as it keeps answering,
  /// so a row can be "fresh" while its last downlink *measurement* is hours old. The
  /// header prints that measurement, so the first pass must be gated on its age — not on
  /// the row's — or a two-hour-old 8 dB beats a thirty-second-old 1 dB and the header
  /// grades a link the radio is not on (review, 2026-09-05).
  @Test
  func `The best link is chosen by the age of the reading it prints, not by any evidence`() throws {
    let twoHoursAgo = at(10 - 2 * 60 * 60)
    let oldReadingStillReplying = SignalMapperRepeaterListRow(
      row: MapperRepeaterRow(
        hexID: "AAAA",
        lastEvidenceAt: at(10 - 60),
        lastHeardAt: twoHoursAgo,
        rxLatest: 8,
        rxBest: 8,
        rxAverage: 8,
        rxCount: 1,
        hearsYouSnr: 12,
        hearsYouAt: at(10 - 60)
      ),
      name: nil,
      isAmbiguous: false,
      uplink: nil
    )
    let heardJustNow = linkItem(hexID: "BBBB", rxLatest: 1, lastEvidenceAt: at(10 - 30))

    let best = try #require(SignalMapperCellCard.bestLink(in: [oldReadingStillReplying, heardJustNow], now: at(10)))
    #expect(best.hexID == "BBBB")

    // With nothing heard recently at all, the old reading is still the best there is.
    let onlyOld = try #require(SignalMapperCellCard.bestLink(in: [oldReadingStillReplying], now: at(10)))
    #expect(onlyOld.hexID == "AAAA")
  }
}
