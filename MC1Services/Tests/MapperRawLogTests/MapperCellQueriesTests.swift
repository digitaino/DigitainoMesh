import Foundation
@testable import MapperRawLog
import MC1Services
import Testing

/// The card's queries (docs/SIGNAL_MAPPER_V3.md §3): one row per repeater heard directly,
/// the headline, and the reach line — computed from a cell's rows and nothing else.
///
/// Every fixture goes through the store, so what is under test is the same DTO shape the
/// card will hold, including the store's own scrubbing on the way in.
@Suite("Mapper cell queries")
struct MapperCellQueriesTests {
  private let start = Date(timeIntervalSince1970: 1_753_000_000)

  private func at(_ offset: TimeInterval) -> Date {
    start.addingTimeInterval(offset)
  }

  /// Round-trips events through an in-memory store and hands back the cell's rows in the
  /// order the card will get them (newest first).
  private func rows(_ events: [MapperRawSampleEvent]) async throws -> [MapperRawSampleDTO] {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples(events, runID: nil, startingSeq: 0)
    return try await store.fetchSamples(
      cellRaw: summaryCellA,
      since: start.addingTimeInterval(-86400),
      until: start.addingTimeInterval(86400),
      limit: 1000
    )
  }

  // MARK: - Repeater rows

  @Test
  func `One row per repeater heard directly, newest first`() async throws {
    let rows = try await rows([
      cellEvent(at: at(10), kind: .passiveRx, hexID: "0C13", rxSnr: 6, rssi: -91),
      cellEvent(at: at(20), kind: .passiveRx, hexID: "0C13", rxSnr: 12.5, rssi: -70),
      cellEvent(at: at(30), kind: .passiveRx, hexID: "42AA", rxSnr: 4.5, rssi: -100),
      // Direct-routed: credits nobody (§1), so it mints no row and feeds no average.
      cellEvent(at: at(40), kind: .passiveRx, hexID: nil, rxSnr: 20, rssi: -50)
    ])

    let repeaters = MapperCellQueries.repeaterRows(in: rows, now: at(60))
    #expect(repeaters.map(\.hexID) == ["42AA", "0C13"], "sorted by last heard, newest first")

    let central = try #require(repeaters.first { $0.hexID == "0C13" })
    #expect(central.rxLatest == 12.5)
    #expect(central.rxBest == 12.5)
    #expect(central.rxAverage == 9.25)
    #expect(central.rxCount == 2)
    #expect(central.rssiLatest == -70)
    #expect(central.lastHeardAt == at(20))
    #expect(central.link(at: at(60)) == .none)
  }

  @Test
  func `The latest reading is the latest by time, not by fetch order`() async throws {
    // The store hands rows back newest first, so a naive "last one wins" would report the
    // *oldest* reading as current. Insert them out of order too, so neither order helps.
    let rows = try await rows([
      cellEvent(at: at(50), kind: .passiveRx, hexID: "0C13", rxSnr: 1, rssi: -110),
      cellEvent(at: at(10), kind: .passiveRx, hexID: "0C13", rxSnr: 9, rssi: -60)
    ])

    let row = try #require(MapperCellQueries.repeaterRows(in: rows, now: at(60)).first)
    #expect(row.rxLatest == 1)
    #expect(row.rssiLatest == -110)
    #expect(row.rxBest == 9)
    #expect(row.lastHeardAt == at(50))
  }

  @Test
  func `Two repeaters heard at the same instant tie-break on hex ID`() async throws {
    let rows = try await rows([
      cellEvent(at: at(10), kind: .passiveRx, hexID: "FF01", rxSnr: 3),
      cellEvent(at: at(10), kind: .passiveRx, hexID: "0A02", rxSnr: 3)
    ])
    #expect(MapperCellQueries.repeaterRows(in: rows, now: at(20)).map(\.hexID) == ["0A02", "FF01"])
  }

  @Test
  func `A probe reply is hears-you, at the latest reported SNR`() async throws {
    let rows = try await rows([
      cellEvent(at: at(10), kind: .probeTraceReply, hexID: "0C13", rxSnr: 5, txSnr: 13),
      // A later, worse report is still the current one: this is a reading, not a record.
      cellEvent(at: at(20), kind: .probeTraceReply, hexID: "0C13", rxSnr: 5, txSnr: 2),
      cellEvent(at: at(30), kind: .probeDiscoverResponse, hexID: "42AA", rxSnr: 1, txSnr: -6)
    ])

    let repeaters = MapperCellQueries.repeaterRows(in: rows, now: at(60))
    let central = try #require(repeaters.first { $0.hexID == "0C13" })
    #expect(central.hearsYouSnr == 2)
    #expect(central.hearsYouAt == at(20))
    #expect(central.link(at: at(60)) == .hearsYou(snr: 2, at: at(20)))

    let other = try #require(repeaters.first { $0.hexID == "42AA" })
    #expect(other.link(at: at(60)) == .hearsYou(snr: -6, at: at(30)))
  }

  @Test
  func `The first hop of an echo is the node that heard us`() async throws {
    // §1's three-hops case: we send, A hears us, B hears A, C hears B, C's rebroadcast
    // reaches us. C is RX evidence; A is TX evidence; B is neither, as far as we know.
    let rows = try await rows([
      cellEvent(at: at(10), kind: .txHeard, hexID: "CCCC", rxSnr: 7, pathHashes: ["AAAA", "BBBB", "CCCC"]),
      // A is also heard directly here, so this fixture pins both legs of its row at once.
      cellEvent(at: at(5), kind: .passiveRx, hexID: "AAAA", rxSnr: 2)
    ])

    let repeaters = MapperCellQueries.repeaterRows(in: rows, now: at(60))
    let heardUs = try #require(repeaters.first { $0.hexID == "AAAA" })
    #expect(heardUs.heardYouAt == at(10))
    #expect(heardUs.hearsYouSnr == nil)
    #expect(heardUs.link(at: at(60)) == .heardYou(at: at(10)))

    let weHeard = try #require(repeaters.first { $0.hexID == "CCCC" })
    #expect(weHeard.rxLatest == 7)
    #expect(weHeard.heardYouAt == nil, "the last hop of an echo never heard us")
    #expect(weHeard.link(at: at(60)) == .none)

    #expect(!repeaters.contains { $0.hexID == "BBBB" }, "a middle hop is somebody else's measurement")
  }

  /// §1's (b) with only one leg: the repeater told us how well it heard us, and our radio
  /// took no reading of its reply. That row used to be discarded outright, which deleted
  /// exactly the case the card exists for — a repeater that hears us and that we cannot hear
  /// (Rafael, 2026-09-04).
  @Test
  func `A reply with no reading of our own still mints a row, with no downlink figures`() async throws {
    let rows = try await rows([
      cellEvent(at: at(10), kind: .probeTraceReply, hexID: "AAAA", txSnr: 11)
    ])

    let row = try #require(MapperCellQueries.repeaterRows(in: rows, now: at(60)).first)
    #expect(row.hexID == "AAAA")
    #expect(row.rxLatest == nil, "we never measured it; 0 dB would be an invented reading")
    #expect(row.rxBest == nil)
    #expect(row.rxAverage == nil)
    #expect(row.rxCount == 0)
    #expect(row.lastHeardAt == nil, "nil is `never`, and that is a fact worth keeping")
    #expect(row.lastEvidenceAt == at(10))
    #expect(row.link(at: at(60)) == .hearsYou(snr: 11, at: at(10)))
  }

  /// §1's (a) with only one leg: an echo proves its first hop heard our radio, and that hop
  /// was never heard directly here. The inverse of the case above.
  @Test
  func `An echo mints a row for a first hop we have never heard`() async throws {
    let rows = try await rows([
      cellEvent(at: at(10), kind: .txHeard, hexID: "CCCC", rxSnr: 7, pathHashes: ["AAAA", "BBBB", "CCCC"])
    ])

    let repeaters = MapperCellQueries.repeaterRows(in: rows, now: at(60))
    let heardUs = try #require(repeaters.first { $0.hexID == "AAAA" })
    #expect(heardUs.rxLatest == nil)
    #expect(heardUs.rxCount == 0)
    #expect(heardUs.lastHeardAt == nil)
    #expect(heardUs.lastEvidenceAt == at(10))
    #expect(heardUs.link(at: at(60)) == .heardYou(at: at(10)))

    #expect(!repeaters.contains { $0.hexID == "BBBB" }, "a middle hop is still somebody else's measurement")
  }

  // MARK: - One repeater, two hash widths

  /// The 2026-09-05 ride's "how come I see two entries for the same repeater?": the card
  /// listed "Digitaino Central ABBA" and "Digitaino Central AB", which is one repeater
  /// arriving under a 2-byte path hash on some packets and its 1-byte prefix on others.
  /// All three passes have to fold through the same canonical id, or the row would carry
  /// one leg from each hash and read as a link nothing measured.
  @Test
  func `A repeater seen under two hash widths is one row, with the narrow hash as an alias`() async throws {
    let rows = try await rows([
      cellEvent(at: at(10), kind: .passiveRx, hexID: "ABBA", rxSnr: 10, rssi: -80),
      cellEvent(at: at(20), kind: .passiveRx, hexID: "AB", rxSnr: 4, rssi: -100),
      cellEvent(at: at(30), kind: .probeTraceReply, hexID: "AB", txSnr: 7),
      cellEvent(at: at(40), kind: .txHeard, hexID: "ABBA", rxSnr: 6, pathHashes: ["AB"])
    ])

    let repeaters = MapperCellQueries.repeaterRows(in: rows, now: at(60))
    #expect(repeaters.map(\.hexID) == ["ABBA"], "the wider hash is the one that can be resolved")

    let merged = try #require(repeaters.first)
    #expect(merged.aliasHexIDs == ["AB"])
    #expect(merged.rxCount == 3, "every reading, whichever width credited it")
    #expect(merged.rxBest == 10)
    #expect(merged.rxLatest == 6)
    #expect(merged.hearsYouSnr == 7, "pass 2 folds through the same id as pass 1")
    #expect(merged.heardYouAt == at(40), "and so does the echo's first hop")
  }

  /// The half of the rule that refuses to guess: a 1-byte hash that fits two of the cell's
  /// wider hashes names one of them and we cannot say which, so it stays its own row rather
  /// than being merged into whichever happened to be listed first.
  @Test
  func `A one-byte hash that fits two repeaters stays its own row`() async throws {
    let rows = try await rows([
      cellEvent(at: at(10), kind: .passiveRx, hexID: "ABBA", rxSnr: 10),
      cellEvent(at: at(20), kind: .passiveRx, hexID: "ABCD", rxSnr: 8),
      cellEvent(at: at(30), kind: .passiveRx, hexID: "AB", rxSnr: 4)
    ])

    let repeaters = MapperCellQueries.repeaterRows(in: rows, now: at(60))
    #expect(repeaters.map(\.hexID) == ["AB", "ABCD", "ABBA"])
    #expect(repeaters.flatMap(\.aliasHexIDs).isEmpty, "nothing may be folded when the byte cannot say which")
    #expect(MapperCellQueries.canonicalHexIDs(in: rows, now: at(60))["AB"] == "AB")
  }

  @Test
  func `Sorting and ageing read the newest evidence, not the newest reading`() async throws {
    let rows = try await rows([
      // Measured long ago, and it answered a probe a moment ago: it is a fresh row that
      // happens to have an old downlink reading.
      cellEvent(at: at(-3000), kind: .passiveRx, hexID: "AAAA", rxSnr: 5),
      cellEvent(at: at(0), kind: .probeTraceReply, hexID: "AAAA", txSnr: 9),
      cellEvent(at: at(-100), kind: .passiveRx, hexID: "BBBB", rxSnr: 5)
    ])

    let repeaters = MapperCellQueries.repeaterRows(in: rows, now: at(60))
    #expect(repeaters.map(\.hexID) == ["AAAA", "BBBB"], "AAAA's reply is the newest evidence in the cell")
    let recent = try #require(repeaters.first)
    #expect(recent.lastEvidenceAt == at(0))
    #expect(recent.lastHeardAt == at(-3000))
    #expect(!recent.isStale(at: at(60)), "a reply a minute old is not a stale row")
  }

  @Test
  func `A reported number outranks an echo even when the echo is newer`() async throws {
    let rows = try await rows([
      cellEvent(at: at(10), kind: .probeTraceReply, hexID: "AAAA", rxSnr: 5, txSnr: 13),
      cellEvent(at: at(50), kind: .txHeard, hexID: "AAAA", rxSnr: 7, pathHashes: ["AAAA"])
    ])

    let row = try #require(MapperCellQueries.repeaterRows(in: rows, now: at(60)).first)
    #expect(row.heardYouAt == at(50))
    #expect(row.link(at: at(60)) == .hearsYou(snr: 13, at: at(10)), "printing `heard you` here would say less than we know")
  }

  @Test
  func `Evidence stamped after the moment asked about is not evidence yet`() async throws {
    let rows = try await rows([
      cellEvent(at: at(10), kind: .passiveRx, hexID: "AAAA", rxSnr: 5),
      cellEvent(at: at(90), kind: .probeTraceReply, hexID: "AAAA", rxSnr: 5, txSnr: 13)
    ])

    let asOfEarly = try #require(MapperCellQueries.repeaterRows(in: rows, now: at(60)).first)
    #expect(asOfEarly.link(at: at(60)) == .none)
    #expect(asOfEarly.rxCount == 1)

    let asOfLate = try #require(MapperCellQueries.repeaterRows(in: rows, now: at(120)).first)
    #expect(asOfLate.link(at: at(120)) == .hearsYou(snr: 13, at: at(90)))
    #expect(asOfLate.rxCount == 2)
  }

  @Test
  func `Freshness is ten minutes, and the boundary itself is fresh`() async throws {
    let rows = try await rows([cellEvent(at: at(0), kind: .passiveRx, hexID: "0C13", rxSnr: 5)])
    let row = try #require(MapperCellQueries.repeaterRows(in: rows, now: at(0)).first)

    #expect(MapperCellQueries.freshnessWindow == 600)
    #expect(!row.isStale(at: at(600)))
    #expect(row.isStale(at: at(601)))
    // Stale is a hint, never a filter: §1 prints the age and hides nothing.
    #expect(MapperCellQueries.repeaterRows(in: rows, now: at(86400)).count == 1)
  }

  // MARK: - Headline

  @Test
  func `The headline counts what the card prints`() async throws {
    let rows = try await rows([
      cellEvent(at: at(0), kind: .passiveRx, hexID: "0C13", rxSnr: 6),
      cellEvent(at: at(10), kind: .passiveRx, hexID: nil, rxSnr: 20),
      cellEvent(at: at(20), kind: .passiveRx, hexID: "42AA", rxSnr: 12.5),
      cellEvent(at: at(30), kind: .probeAttempt, hexID: "0C13"),
      cellEvent(at: at(40), kind: .probeTraceReply, hexID: "0C13", rxSnr: 3, txSnr: 8),
      cellEvent(at: at(50), kind: .probeLost, hexID: "42AA"),
      cellEvent(at: at(60), kind: .txHeard, hexID: "0C13", rxSnr: 1, pathHashes: ["0C13"])
    ])

    let headline = MapperCellQueries.cellHeadline(in: rows, now: at(100))
    #expect(headline.rxBest == 12.5, "the direct-routed 20 dB credits nobody")
    #expect(headline.rxLatestAt == at(60))
    #expect(headline.heardCount == 3)
    #expect(headline.txBest == 8)
    #expect(headline.txReadings == 1)
    #expect(headline.hasHeardYou)
    #expect(!headline.isUnreachedProbed)
    #expect(headline.probesSent == 1)
    #expect(headline.probesAnswered == 1)
  }

  @Test
  func `Probed and unheard is a different fact from never probed`() async throws {
    let probed = try await rows([
      cellEvent(at: at(0), kind: .probeAttempt, hexID: "0C13"),
      cellEvent(at: at(10), kind: .probeLost, hexID: "0C13"),
      cellEvent(at: at(20), kind: .passiveRx, hexID: "0C13", rxSnr: 5)
    ])
    let probedHeadline = MapperCellQueries.cellHeadline(in: probed, now: at(60))
    #expect(probedHeadline.isUnreachedProbed)
    #expect(!probedHeadline.hasHeardYou)
    #expect(probedHeadline.probesAnswered == 0)

    let quiet = try await rows([cellEvent(at: at(0), kind: .passiveRx, hexID: "0C13", rxSnr: 5)])
    let quietHeadline = MapperCellQueries.cellHeadline(in: quiet, now: at(60))
    #expect(!quietHeadline.isUnreachedProbed, "we never asked here")
    #expect(quietHeadline.probesSent == 0)
  }

  @Test
  func `An echo alone is heard-you without a number`() async throws {
    let rows = try await rows([
      cellEvent(at: at(0), kind: .probeAttempt, hexID: "AAAA"),
      cellEvent(at: at(10), kind: .txHeard, hexID: "AAAA", rxSnr: 3, pathHashes: ["AAAA"])
    ])
    let headline = MapperCellQueries.cellHeadline(in: rows, now: at(60))
    #expect(headline.hasHeardYou)
    #expect(headline.txBest == nil, "the TX layer's neutral fill, not a colour")
    #expect(headline.txReadings == 0)
    #expect(!headline.isUnreachedProbed)
  }

  @Test
  func `The headline and the summary agree about the same rows`() async throws {
    // Two independent readers of the same evidence — the card's live query and the map's
    // cache — must not disagree about a hexagon.
    let store = try MapperRawLogStore.inMemory()
    let events = [
      cellEvent(at: at(0), kind: .passiveRx, hexID: "0C13", rxSnr: 6),
      cellEvent(at: at(10), kind: .passiveRx, hexID: nil, rxSnr: 20),
      cellEvent(at: at(20), kind: .probeTraceReply, hexID: "0C13", rxSnr: 3, txSnr: 8),
      cellEvent(at: at(30), kind: .probeAttempt, hexID: "0C13"),
      cellEvent(at: at(40), kind: .txHeard, hexID: "0C13", rxSnr: 1, pathHashes: ["0C13"]),
      cellEvent(at: at(50), kind: .sent)
    ]
    try await store.insertSamples(events, runID: nil, startingSeq: 0)

    let cellRows = try await store.fetchSamples(
      cellRaw: summaryCellA,
      since: at(-1),
      until: at(1000),
      limit: 1000
    )
    let headline = MapperCellQueries.cellHeadline(in: cellRows, now: at(100))
    let summary = try #require(try await store.fetchCellSummary(cellRaw: summaryCellA))

    #expect(headline.rxBest == summary.rxBestSnr)
    #expect(headline.rxLatestAt == summary.rxLastAt)
    #expect(headline.heardCount == summary.heardCount)
    #expect(headline.txBest == summary.txBestSnr)
    #expect(headline.txReadings == summary.txSnrCount)
    #expect(headline.hasHeardYou == summary.hasHeardYou)
    #expect(headline.isUnreachedProbed == summary.isUnreachedProbed)
    #expect(headline.probesSent == summary.probesSent)
  }

  // MARK: - Reach

  @Test
  func `Reach counts observers once, however they spell themselves`() async throws {
    let store = try MapperRawLogStore.inMemory()
    try await store.insertSamples([
      cellEvent(at: at(0), kind: .sent, contentHash: "aaaa111122223333"),
      cellEvent(at: at(10), kind: .sent, contentHash: "bbbb444455556666"),
      // Sent, but the echo has not revealed its hash yet: countable, not askable.
      cellEvent(at: at(20), kind: .sent),
      // One observer, two spellings, and it heard both packets — plus a repeat sighting of
      // the first, which scope can return when the same packet reaches it twice.
      cellEvent(at: at(30), kind: .observerSighting, cell: nil, hexID: "AA01", contentHash: "aaaa111122223333"),
      cellEvent(at: at(31), kind: .observerSighting, cell: nil, hexID: "aa01", contentHash: "aaaa111122223333"),
      cellEvent(at: at(32), kind: .observerSighting, cell: nil, hexID: "AA01", contentHash: "bbbb444455556666"),
      cellEvent(at: at(33), kind: .observerSighting, cell: nil, hexID: "BB02", contentHash: "aaaa111122223333")
    ], runID: nil, startingSeq: 0)

    let cellRows = try await store.fetchSamples(cellRaw: summaryCellA, since: at(-1), until: at(1000), limit: 100)
    let hashes = Set(cellRows.compactMap(\.contentHash))
    let sightings = try await store.fetchObserverSightings(contentHashes: hashes)

    let reach = MapperCellQueries.reach(in: cellRows, sightings: sightings)
    #expect(reach.observerCount == 2, "AA01 and aa01 are one observer")
    #expect(reach.sightingCount == 4)
    #expect(reach.packetCount == 2, "the hash-less send cannot be looked up, so it is not `heard`")
    #expect(reach.sentCount == 3)
  }

  @Test
  func `Reach with nothing heard still reports what we sent`() async throws {
    let rows = try await rows([
      cellEvent(at: at(0), kind: .sent, contentHash: "aaaa111122223333"),
      cellEvent(at: at(10), kind: .passiveRx, hexID: "0C13", rxSnr: 5)
    ])
    let reach = MapperCellQueries.reach(in: rows, sightings: [])
    #expect(reach == MapperCellReach(observerCount: 0, sightingCount: 0, packetCount: 0, sentCount: 1))
  }

  // MARK: - Doubtful placements

  /// The other half of the 2026-09-04 fix, from the reader's side: a row placed on a fix the
  /// aggregate gate refused is a row like any other here. The card reads rows, and the only
  /// thing that ever made a probe reply unreachable was a nil `cellRaw` — the store's cell
  /// fetch is an equality match, and nil matches nothing for ever.
  @Test
  func `A row placed on a doubtful fix is read back like any other`() async throws {
    let rows = try await rows([
      cellEvent(at: at(0), kind: .probeAttempt, hexID: "0C13", gateOutcome: .inaccurateFix),
      cellEvent(at: at(10), kind: .probeTraceReply, hexID: "0C13", rxSnr: 5, txSnr: 12, gateOutcome: .inaccurateFix)
    ])

    #expect(rows.count == 2, "the cell fetch finds them; a nil cell would have found neither")
    let row = try #require(MapperCellQueries.repeaterRows(in: rows, now: at(60)).first)
    #expect(row.rxLatest == 5)
    #expect(row.link(at: at(60)) == .hearsYou(snr: 12, at: at(10)))

    let headline = MapperCellQueries.cellHeadline(in: rows, now: at(60))
    #expect(headline.probesSent == 1)
    #expect(headline.probesAnswered == 1)
    #expect(headline.txBest == 12)
  }

  @Test
  func `Empty rows produce empty answers rather than nils to unwrap`() {
    #expect(MapperCellQueries.repeaterRows(in: [], now: start).isEmpty)
    let headline = MapperCellQueries.cellHeadline(in: [], now: start)
    #expect(headline == MapperCellHeadline())
    #expect(MapperCellQueries.reach(in: [], sightings: []) == MapperCellReach())
  }
}
