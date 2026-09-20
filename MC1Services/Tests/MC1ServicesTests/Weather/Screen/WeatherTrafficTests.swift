import Foundation
@testable import MC1Services
import MeshCore
import MeshWX
import Testing

/// The channel traffic timeline (docs/MESHWX_UI.md §12, revision 10). The owner's sixth ask:
/// *a way to see all the GRP_DATA traffic on a channel like we do a chat.*
@Suite("Weather channel traffic")
struct WeatherTrafficTests {
  private typealias F = WeatherFixture
  private let tables = MeshWXTables.shared

  private func entry(_ message: MeshWXMessage) throws -> WeatherTrafficEntry {
    WeatherTrafficEntry.received(
      try MeshWXEncoder.encode(message), channelIndex: 3, dataType: MeshWXWire.dataType,
      snr: 6.5, pathLength: 0xFF, at: F.t0, isBacklog: false, isDuplicate: false)
  }

  /// The bytes are the row, and everything above them is a reading of the bytes: the entry keeps
  /// the payload as hex and hands it back unchanged.
  @Test
  func `an entry keeps the payload it was built from`() throws {
    let payload = try MeshWXEncoder.encode(F.digest(seq: 7, entries: []))
    let row = WeatherTrafficEntry.received(
      payload, channelIndex: 31, dataType: MeshWXWire.dataType, snr: -2.25, pathLength: 0x41,
      at: F.t0, isBacklog: true, isDuplicate: true)
    #expect(row.bytes == payload)
    #expect(row.hex == payload.map { String(format: "%02x", $0) }.joined())
    #expect(row.length == payload.count)
    #expect(row.channelIndex == 31)
    #expect(row.seq == 7)
    #expect(row.type == MeshWXMessageType.digest.rawValue)
    #expect(row.botID == F.botID)
    #expect(row.direction == .received)
    #expect(row.isBacklog)
    #expect(row.isDuplicate)
    #expect(row.snr == -2.25)
    #expect(row.pathLength == 0x41)
    // It persists beside the weather state, so it has to survive a file.
    let coded = try JSONDecoder().decode(
      WeatherTrafficEntry.self, from: try JSONEncoder().encode(row))
    #expect(coded == row)
    // Hex that is not hex is nil rather than a summary built out of garbage.
    #expect(WeatherTrafficEntry(at: F.t0, direction: .sent, channelIndex: 3, length: 0, hex: "zz")
      .bytes == nil)
  }

  /// "Observations · 13 stations", and one station named when the batch carries only one — which
  /// is somebody's `>o KAUS`, not the bot's hourly broadcast.
  @Test
  func `an observations batch names its size, or its one station`() throws {
    let batch = try entry(F.observations(
      seq: 1, stations: (0..<13).map { (UInt16($0), Int8(70)) }))
    let summary = WeatherTrafficSummary.make(entry: batch, tables: tables)
    #expect(summary.title == .observations)
    #expect(summary.detail == [.stations(13)])

    let one = try entry(F.observations(seq: 2, stations: [(202, 84)]))
    #expect(WeatherTrafficSummary.make(entry: one, tables: tables).detail == [.station(202)])
  }

  /// "Alert map · part 3 of 7 · 38 areas", plus what the sweep covers — the one thing a reader
  /// of this screen cannot work out for themselves.
  @Test
  func `a sweep packet names its part, its areas and its scope`() throws {
    let national = try entry(F.areaSweep(
      seq: 1, group: 7, index: 2, total: 7, entries: [F.texasSweepEntry, F.oklahomaSweepEntry]))
    let summary = WeatherTrafficSummary.make(entry: national, tables: tables)
    #expect(summary.title == .alertMap)
    // Six Texas zones and four Oklahoma counties: ten areas in two runs.
    #expect(summary.detail == [.part(index: 2, of: 7), .areas(10), .national])

    let scoped = try entry(F.areaSweep(
      seq: 2, group: 8, index: 0, total: 2, entries: [F.texasSweepEntry], wasCut: true,
      includesAdvisories: true, scope: [F.texasState, F.oklahomaState]))
    #expect(WeatherTrafficSummary.make(entry: scoped, tables: tables).detail
      == [.part(index: 0, of: 2), .areas(6), .scoped(states: ["TX", "OK"]), .cut, .includesAdvisories])
    // A packet that is not the one carrying the scope says it is scoped and no more.
    let later = try entry(F.areaSweep(
      seq: 3, group: 8, index: 1, total: 2, entries: [F.oklahomaSweepEntry], isScoped: true))
    #expect(WeatherTrafficSummary.make(entry: later, tables: tables).detail
      == [.part(index: 1, of: 2), .areas(4), .scoped(states: [])])
  }

  /// "Request from 0A1B2C · `>o KAUS`". The sender prefix is as much as anyone on the channel
  /// knows about who asked, and the text is verbatim.
  @Test
  func `a request names its sender prefix and its text`() throws {
    let row = try entry(F.request(seq: 4, text: ">o KAUS"))
    let summary = WeatherTrafficSummary.make(entry: row, tables: tables)
    #expect(summary.title == .request(sender: Data([0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F])))
    #expect(summary.detail == [.requestText(">o KAUS")])
  }

  /// "Not available · f · unknown location": the letter the bot echoed back and the reason.
  @Test
  func `a refusal names the letter and the reason`() throws {
    let row = try entry(F.notAvailable(seq: 5, letter: "f", reason: .unknownLocation))
    let summary = WeatherTrafficSummary.make(entry: row, tables: tables)
    #expect(summary.title == .notAvailable(letter: "f"))
    #expect(summary.detail == [.reason(.unknownLocation)])
  }

  @Test
  func `the rest of the types read off their own fields`() throws {
    #expect(WeatherTrafficSummary.make(entry: try entry(F.warning(seq: 1)), tables: tables).title
      == .warning(F.svw42))
    #expect(WeatherTrafficSummary.make(
      entry: try entry(F.cancel(seq: 2, reason: .upgraded)), tables: tables)
      == WeatherTrafficSummary(title: .cancel(F.svw42), detail: [.cancelReason(.upgraded)]))
    #expect(WeatherTrafficSummary.make(
      entry: try entry(F.digest(seq: 3, entries: [(F.svw42, 30), (F.wsw7, 60)])), tables: tables)
      == WeatherTrafficSummary(title: .alertList, detail: [.entries(2)]))
    #expect(WeatherTrafficSummary.make(
      entry: try entry(F.forecast(seq: 4, point: 102)), tables: tables)
      == WeatherTrafficSummary(title: .forecast, detail: [.point(102)]))
    // `0xFFFF` is not a point, it is "the bot picked one this bundle cannot name" (spec revision
    // 10, §1.3). The row says that rather than naming the sentinel or saying nothing at all —
    // a bare "Forecast" is the one thing the revision 10 answer is not.
    #expect(WeatherTrafficSummary.make(
      entry: try entry(F.forecast(seq: 5, point: 0xFFFF)), tables: tables)
      == WeatherTrafficSummary(title: .forecast, detail: [.botPoint]))
    #expect(WeatherTrafficSummary.make(
      entry: try entry(F.text(seq: 6, subject: .stormReports, group: 3, index: 1, total: 2,
                              text: "hail", wasCut: true)), tables: tables)
      == WeatherTrafficSummary(
        title: .text(subject: .stormReports), detail: [.chunk(index: 1, of: 2), .cut]))
    // A coverage statement's one number on this screen is how many offices it named; the circle,
    // the zone runs and the station cap belong to the radio page (§12).
    #expect(WeatherTrafficSummary.make(entry: try entry(F.coverage(seq: 7)), tables: tables)
      == WeatherTrafficSummary(title: .coverage, detail: [.offices(4)]))
    var noOffices = F.austinCoverage
    noOffices.officeIndices = []
    #expect(WeatherTrafficSummary.make(entry: try entry(F.coverage(seq: 8, noOffices)), tables: tables)
      == WeatherTrafficSummary(title: .coverage, detail: []))
  }

  /// Bytes the codec cannot read are still a row: the length and the hex are what the screen has,
  /// and claiming anything more would be inventing it.
  @Test
  func `unreadable bytes make a row that claims nothing`() {
    let row = WeatherTrafficEntry(
      at: F.t0, direction: .received, channelIndex: 3, length: 5, hex: "117a4ca000")
    #expect(WeatherTrafficSummary.make(entry: row, tables: tables).title == .undecodable)
    #expect(WeatherTrafficSummary.make(entry: row, tables: tables).detail.isEmpty)
  }

  /// A reserved or third-party nibble (spec §2.2) shows as itself rather than as nothing.
  @Test
  func `an unknown type shows its own nibble`() {
    // Type 12, flags 0, four bytes: a header and nothing this build knows behind it.
    let row = WeatherTrafficEntry(
      at: F.t0, direction: .received, channelIndex: 3, length: 4, hex: "017a4cc0")
    #expect(WeatherTrafficSummary.make(entry: row, tables: tables).title == .unknownType(rawType: 12))
  }
}
