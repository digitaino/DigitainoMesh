import Foundation
@testable import MC1Services
import Testing

/// Spec source: legacy `SignalBarsService.handleDiscoverResponse`, `applyBlob`,
/// `handleTraceResponse`, `sortRepeaters`, `pruneStaleRepeaters`, `displayRepeaters`,
/// `dismissRepeater(hexID:)` and `clearStaleRepeaters`.
@Suite("SignalBarsTable")
struct SignalBarsTableTests {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)

  private func sighting(
    _ hex: String,
    rxSnr: Double = 4,
    txSnr: Double? = nil,
    rssi: Int? = nil,
    key: [UInt8]? = nil
  ) throws -> RepeaterSighting {
    try RepeaterSighting(
      id: #require(NodeHexID(hex)),
      rxSnr: rxSnr,
      txSnr: txSnr,
      rssi: rssi,
      publicKey: key.map { SignalBarsFixtures.publicKey($0) }
    )
  }

  // MARK: - Merging

  @Test
  func `A first sighting takes the raw SNR and a second is smoothed 75 to 25`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("0C", rxSnr: 8), now: start)
    #expect(table.repeaters.first?.rxSnr == 8)

    try table.ingest(sighting("0C", rxSnr: 4), now: start)
    // (8*3 + 4) / 4 — the firmware's EMA, so the app's bars are as steady as the OLED's.
    #expect(table.repeaters.first?.rxSnr == 7)
  }

  @Test
  func `Hashes of different widths merge into one repeater and keep the widest ID`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("0C", rxSnr: 6), now: start)
    try table.ingest(sighting("0C13", rxSnr: 6, key: [0x0C, 0x13]), now: start)
    #expect(table.repeaters.count == 1)
    #expect(table.repeaters[0].id.hex == "0C13")
    #expect(table.repeaters[0].publicKey != nil)

    // A narrower sighting of the same node must not shrink the ID back down.
    try table.ingest(sighting("0C", rxSnr: 6), now: start)
    #expect(table.repeaters.count == 1)
    #expect(table.repeaters[0].id.hex == "0C13")
  }

  @Test
  func `Widening a row's hash drops the resolved name for re-resolution`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("0C"), now: start)
    table.setName("Ridge Relay", for: nodeID("0C"))

    try table.ingest(sighting("0C13"), now: start)
    #expect(table.repeaters[0].id.hex == "0C13")
    #expect(table.repeaters[0].name == nil, "a name resolved at 1 byte cannot label a 2-byte identity")
  }

  @Test
  func `A changed public key drops the resolved name and an unchanged one keeps it`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("0C", key: [0x0C, 0x99]), now: start)
    table.setName("Ridge Relay", for: nodeID("0C"))

    try table.ingest(sighting("0C", key: [0x0C, 0x99]), now: start)
    #expect(table.repeaters[0].name == "Ridge Relay", "same identity, name stays")

    try table.ingest(sighting("0C", key: [0x0C, 0x13]), now: start)
    #expect(table.repeaters[0].name == nil, "the row turned out to be a different node")
  }

  @Test
  func `Applying a device blob at a different hash width carries neither name nor key`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("0C", key: [0x0C, 0x99]), now: start)
    table.setName("Ridge Relay", for: nodeID("0C"))

    table.apply(SignalBarsBlob(version: 2, entries: [
      SignalBarsFixtures.entry(hash: [0x0C, 0x13], rxSnrX4: 8)
    ]), now: start)

    let row = try #require(table[nodeID("0C13")])
    #expect(row.name == nil)
    #expect(row.publicKey == nil)
  }

  @Test
  func `clearNames drops every resolved name`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("0C"), now: start)
    try table.ingest(sighting("AA"), now: start)
    table.setName("One", for: nodeID("0C"))
    table.setName("Two", for: nodeID("AA"))

    table.clearNames()
    #expect(table.repeaters.allSatisfy { $0.name == nil })
  }

  @Test
  func `Nil fields never erase what is already known`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("0C", txSnr: 3, rssi: -60, key: [0x0C]), now: start)
    try table.ingest(sighting("0C"), now: start)

    let entry = try #require(table.repeaters.first)
    #expect(entry.rssi == -60)
    #expect(entry.publicKey != nil)
    #expect(entry.txSnr == 3)
    #expect(entry.txState == .measured(SNRQuality(snr: 3)))
  }

  @Test
  func `A sighting that reports how they hear us measures the TX leg`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("0C"), now: start)
    #expect(table.repeaters[0].txState == .unknown)

    try table.ingest(sighting("0C", txSnr: 7), now: start)
    #expect(table.repeaters[0].txState == .measured(.excellent))
    #expect(table.repeaters[0].txQuality == .excellent)
  }

  @Test
  func `At capacity the least recently heard entry is evicted`() throws {
    var table = SignalBarsTable()
    for index in 0..<8 {
      let hex = String(format: "%02X", index + 1)
      try table.ingest(sighting(hex), now: start.addingTimeInterval(Double(index)))
    }
    #expect(table.repeaters.count == 8)

    try table.ingest(sighting("FF"), now: start.addingTimeInterval(100))
    #expect(table.repeaters.count == 8)
    #expect(table.index(of: nodeID("01")) == nil, "oldest entry evicted")
    #expect(table.index(of: nodeID("FF")) != nil)
  }

  // MARK: - Ordering

  @Test
  func `A bidirectional link sorts above one whose TX leg is unmeasured`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("01", rxSnr: 10), now: start) // RX only → unknown TX
    try table.ingest(sighting("02", rxSnr: 2, txSnr: 2), now: start) // both legs measured

    #expect(table.repeaters.map(\.hexID) == ["02", "01"])
  }

  @Test
  func `In-flight measurements sit between measured and unmeasured links`() {
    let entries = [
      RepeaterSignal(id: nodeID("03"), rxSnr: 20, txState: .unknown, lastHeard: start),
      RepeaterSignal(id: nodeID("04"), rxSnr: 30, txState: .failed, lastHeard: start),
      RepeaterSignal(id: nodeID("02"), rxSnr: 20, txState: .measuring, lastHeard: start),
      RepeaterSignal(
        id: nodeID("01"),
        rxSnr: 1,
        txSnr: 1,
        txState: .measured(.good),
        lastHeard: start
      )
    ]

    let ordered = entries.sorted(by: RepeaterSignal.isOrderedBefore)

    #expect(ordered.map(\.hexID) == ["01", "02", "04", "03"])
  }

  @Test
  func `Sending a probe does not re-order the list while it is in flight`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("01", rxSnr: 10, txSnr: 8), now: start)
    try table.ingest(sighting("02", rxSnr: 9, txSnr: 7), now: start)

    table.markProbeSent(nodeID("01"), now: start)

    #expect(
      table.repeaters.map(\.hexID) == ["01", "02"],
      "a row must not jump while the user is watching it being measured"
    )
  }

  @Test
  func `Within a tier the better link score wins`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("01", rxSnr: 2, txSnr: 8), now: start)
    try table.ingest(sighting("02", rxSnr: 8, txSnr: 2), now: start)
    // 0.6·TX + 0.4·RX ranks the stronger TX leg first.
    #expect(table.repeaters.map(\.hexID) == ["01", "02"])
  }

  @Test
  func `A promoted best link is reported so the engine can re-prioritize it`() throws {
    var table = SignalBarsTable()
    let first = try table.ingest(sighting("01", rxSnr: 2), now: start)
    let weaker = try table.ingest(sighting("02", rxSnr: 1), now: start)
    let promoted = try table.ingest(sighting("02", rxSnr: 20, txSnr: 9), now: start)

    #expect(first.bestChanged)
    #expect(!weaker.bestChanged)
    #expect(promoted.bestChanged)
  }

  // MARK: - Probe replies

  @Test
  func `A reply carrying the remote SNR measures TX, records RTT and clears failures`() throws {
    var table = SignalBarsTable()
    let id = nodeID("0C")
    try table.ingest(sighting("0C", rxSnr: 8, key: [0x0C]), now: start)
    table.markProbeFailed(id, sentAt: start)
    #expect(table[id]?.failCount == 1)

    table.markProbeSent(id, now: start)
    table.applyProbeReply(
      RepeaterProbeReply(tag: 1, localSnr: 4, remoteSnr: 3),
      to: id,
      rttMs: 420,
      now: start.addingTimeInterval(1)
    )

    let entry = try #require(table[id])
    #expect(entry.txSnr == 3)
    #expect(entry.txState == .measured(SNRQuality(snr: 3)))
    #expect(entry.failCount == 0)
    #expect(entry.rttMs == 420)
    #expect(entry.rxSnr == 7, "local SNR is smoothed like any other RX reading")
    #expect(entry.lastHeard == start.addingTimeInterval(1))
  }

  @Test
  func `A reply without a remote SNR counts as a failure rather than faking TX from RX`() throws {
    var table = SignalBarsTable()
    let id = nodeID("0C")
    try table.ingest(sighting("0C", rxSnr: 8, key: [0x0C]), now: start)
    table.applyProbeReply(
      RepeaterProbeReply(tag: 1, localSnr: 4, remoteSnr: nil),
      to: id,
      rttMs: 100,
      now: start
    )

    let entry = try #require(table[id])
    #expect(entry.txState == .failed)
    #expect(entry.txSnr == nil)
    #expect(entry.failCount == 1)
  }

  @Test
  func `A timeout leaves a TX measurement that landed after the probe was sent alone`() throws {
    var table = SignalBarsTable()
    let id = nodeID("0C")
    try table.ingest(sighting("0C", rxSnr: 8, key: [0x0C]), now: start)
    table.markProbeSent(id, now: start)
    // A discover response can answer the TX leg while the trace is still outstanding.
    try table.ingest(sighting("0C", rxSnr: 8, txSnr: 5), now: start.addingTimeInterval(1))

    table.markProbeFailed(id, sentAt: start)

    let entry = try #require(table[id])
    #expect(entry.txState == .measured(SNRQuality(snr: 5)))
    #expect(entry.txSnr == 5)
    #expect(entry.failCount == 0, "the link answered; the timeout is stale news about it")
  }

  @Test
  func `A full refresh resets failures and writes off whatever never answered`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("01", key: [0x01]), now: start)
    try table.ingest(sighting("02", txSnr: 5, key: [0x02]), now: start)
    table.markProbeFailed(nodeID("01"), sentAt: start)

    table.beginFullRefresh()
    #expect(table.repeaters.allSatisfy { $0.failCount == 0 })
    let allMeasuring = table.repeaters.allSatisfy { $0.isMeasuring == true }
    #expect(allMeasuring)

    table.failOutstandingMeasurements()
    #expect(table.repeaters.allSatisfy { $0.txState == .failed })
    #expect(table.repeaters.allSatisfy { $0.failCount == 1 })
  }

  // MARK: - Device table

  @Test
  func `Applying a device blob keeps its order and preserves locally known facts`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("0C13", rxSnr: 5, rssi: -70, key: [0x0C, 0x13]), now: start)
    table.setName("Hilltop", for: nodeID("0C13"))
    table.markProbeSent(nodeID("0C13"), now: start)

    let blob = SignalBarsBlob(version: 2, entries: [
      SignalBarsFixtures.entry(hash: [0xAA], rxSnrX4: 8, isBest: true),
      SignalBarsFixtures.entry(
        hash: [0x0C, 0x13],
        rxSnrX4: 24,
        txSnrX4: 12,
        hasTx: true,
        ageSeconds: 30,
        rttMs: 900
      )
    ])
    table.apply(blob, now: start)

    #expect(table.repeaters.map(\.hexID) == ["AA", "0C13"], "device order is rendered verbatim")
    let mirrored = try #require(table[nodeID("0C13")])
    #expect(mirrored.name == "Hilltop")
    #expect(mirrored.rssi == -70)
    #expect(mirrored.publicKey != nil)
    #expect(mirrored.lastProbeAt == start)
    #expect(mirrored.rxSnr == 6)
    #expect(mirrored.txSnr == 3)
    #expect(mirrored.txState == .measured(SNRQuality(snr: 3)))
    #expect(mirrored.rttMs == 900)
    #expect(mirrored.lastHeard == start.addingTimeInterval(-30))
    #expect(table.repeaters[0].isDeviceBest)
  }

  @Test
  func `A blob reports the entries the radio heard since the last one, not the bytes that changed`() {
    var table = SignalBarsTable()

    let first = table.apply(SignalBarsBlob(version: 2, entries: [
      SignalBarsFixtures.entry(hash: [0x01], ageSeconds: 100),
      SignalBarsFixtures.entry(hash: [0x02], ageSeconds: 0)
    ]), now: start)
    #expect(first.map(\.hex) == ["01", "02"], "a row we did not have is news either way")

    // Five seconds later: 01 has only aged, 02 reports the same age because it keeps being
    // heard — so the poll where nothing changed in 02's bytes is the one that heard it.
    let second = table.apply(SignalBarsBlob(version: 2, entries: [
      SignalBarsFixtures.entry(hash: [0x01], ageSeconds: 105),
      SignalBarsFixtures.entry(hash: [0x02], ageSeconds: 0)
    ]), now: start.addingTimeInterval(5))
    #expect(second.map(\.hex) == ["02"])

    let third = table.apply(SignalBarsBlob(version: 2, entries: [
      SignalBarsFixtures.entry(hash: [0x01], ageSeconds: 2),
      SignalBarsFixtures.entry(hash: [0x02], ageSeconds: 15)
    ]), now: start.addingTimeInterval(10))
    #expect(third.map(\.hex) == ["01"], "01's age dropped; 02 has gone quiet")
  }

  @Test
  func `Device TX states map to measured, failed and unknown`() {
    var table = SignalBarsTable()
    table.apply(SignalBarsBlob(version: 2, entries: [
      SignalBarsFixtures.entry(hash: [0x01], txSnrX4: 8, hasTx: true),
      SignalBarsFixtures.entry(hash: [0x02], txFailed: true),
      SignalBarsFixtures.entry(hash: [0x03])
    ]), now: start)

    #expect(table.repeaters[0].txState == .measured(SNRQuality(snr: 2)))
    #expect(table.repeaters[1].txState == .failed)
    #expect(table.repeaters[2].txState == .unknown)
    #expect(table.repeaters[0].rttMs == nil, "a zero RTT means unknown, not instant")
  }

  // MARK: - Staleness, dismissal

  @Test
  func `Entries not heard within the prune window leave the table`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("01"), now: start)
    try table.ingest(sighting("02"), now: start.addingTimeInterval(290))

    let removed = table.pruneStale(now: start.addingTimeInterval(301))
    #expect(removed.map(\.hex) == ["01"])
    #expect(table.repeaters.map(\.hexID) == ["02"])
  }

  @Test
  func `Stale rows drop out of the display list without leaving the table`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("01"), now: start)
    let later = start.addingTimeInterval(901)

    #expect(table.repeaters.count == 1)
    #expect(table.displayed(now: later).isEmpty)
    #expect(table.hasStale(now: later))
  }

  @Test
  func `A nil hide threshold shows everything`() throws {
    var policy = SignalBarsPolicy()
    policy.staleHideThreshold = nil
    var table = SignalBarsTable(policy: policy)
    try table.ingest(sighting("01"), now: start)
    #expect(table.displayed(now: start.addingTimeInterval(100_000)).count == 1)
  }

  @Test
  func `A dismissed repeater is hidden until the radio hears it again`() throws {
    var table = SignalBarsTable()
    let id = nodeID("0C")
    try table.ingest(sighting("0C"), now: start)

    table.dismiss(id, now: start.addingTimeInterval(1))
    #expect(table.displayed(now: start.addingTimeInterval(2)).isEmpty)
    #expect(table.repeaters.count == 1, "a dismissal hides the row, it does not delete it")

    try table.ingest(sighting("0C"), now: start.addingTimeInterval(10))
    #expect(table.displayed(now: start.addingTimeInterval(11)).map(\.hexID) == ["0C"])
  }

  @Test
  func `A dismissal follows the node across hash widths`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("0C13"), now: start)
    table.dismiss(nodeID("0C"), now: start.addingTimeInterval(1))
    #expect(table.displayed(now: start.addingTimeInterval(2)).isEmpty)
  }

  @Test
  func `Clearing stale rows dismisses every entry past the hide window at once`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("01"), now: start)
    try table.ingest(sighting("02"), now: start.addingTimeInterval(1000))
    let now = start.addingTimeInterval(1000)

    table.clearStale(now: now)
    #expect(table.displayed(now: now).map(\.hexID) == ["02"])
    #expect(!table.hasStale(now: now))
  }

  @Test
  func `With auto-hide off, clearing stale falls back to the manual window`() throws {
    var policy = SignalBarsPolicy()
    policy.staleHideThreshold = nil
    var table = SignalBarsTable(policy: policy)
    try table.ingest(sighting("01"), now: start)
    let now = start.addingTimeInterval(61)

    #expect(table.hasStale(now: now))
    table.clearStale(now: now)
    #expect(table.displayed(now: now).isEmpty)
  }

  // MARK: - Lookup

  @Test
  func `Lookup uses the bidirectional prefix rule, never string equality`() throws {
    var table = SignalBarsTable()
    try table.ingest(sighting("0C13"), now: start)

    #expect(table[nodeID("0C")] != nil)
    #expect(table[nodeID("0C13")] != nil)
    #expect(table[nodeID("0C13AB")] != nil)
    #expect(table[nodeID("0D")] == nil)
  }
}
