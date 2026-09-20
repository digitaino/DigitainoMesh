import Foundation
import MC1Services
import MeshCore
import MeshWX
import Testing

@testable import MC1

/// The words a channel traffic bubble is made of (docs/MESHWX_UI.md §12, revision 10).
///
/// The owner's sixth ask: *a way to see all the GRP_DATA traffic on a channel like we do a chat.*
/// `WeatherTrafficSummary` is values and no strings; this is where they become the sentence, and
/// the sentence is the whole screen — a bubble is a title, some facts and a tap.
@Suite("Weather channel traffic copy")
struct WeatherTrafficCopyTests {
  typealias F = WeatherFormattingTests

  static let now = F.now
  static let tables = MeshWXTables.shared
  /// SV.W from NWS Austin/San Antonio, the fixture identity the rest of the suite uses.
  static let identity = MeshWXWarningIdentity(event: 3, office: 40, etn: 42)

  static func entry(
    direction: WeatherTrafficEntry.Direction = .received,
    length: Int = 159,
    seq: UInt8? = 212,
    snr: Double? = 12,
    pathLength: UInt8? = encodePathLen(hashSize: 1, hopCount: 2),
    at: Date = WeatherTrafficCopyTests.now,
    isBacklog: Bool = false,
    isDuplicate: Bool = false,
    hex: String = ""
  ) -> WeatherTrafficEntry {
    WeatherTrafficEntry(
      at: at, direction: direction, isBacklog: isBacklog, channelIndex: 31, botID: 0x0A1B,
      seq: seq, length: length, snr: snr, pathLength: pathLength, hex: hex,
      isDuplicate: isDuplicate)
  }

  static func title(_ title: WeatherTrafficTitle, isSent: Bool = false) -> String {
    WeatherTrafficCopy.title(title, isSent: isSent, tables: tables)
  }

  static func details(_ summary: WeatherTrafficSummary) -> String {
    WeatherTrafficCopy.details(summary, tables: tables).joined(separator: " · ")
  }

  // MARK: - Titles

  /// One line per kind of thing the weather slot carries. A request this phone sent is named for
  /// what it is, not for who sent it: "Request from 0A1B2C" pointing at the reader says nothing.
  @Test
  func `every kind of datagram has a name`() {
    #expect(Self.title(.warning(Self.identity)) == "Alert")
    #expect(Self.title(.cancel(Self.identity)) == "Alert ended")
    #expect(Self.title(.alertList) == "Alert list")
    #expect(Self.title(.observations) == "Observations")
    #expect(Self.title(.forecast) == "Forecast")
    #expect(Self.title(.text(subject: .stormReports)) == "Text report")
    #expect(Self.title(.notAvailable(letter: "f")) == "Not available")
    #expect(Self.title(.coverage) == "What it covers")
    #expect(Self.title(.alertMap) == "Alert map")
    #expect(Self.title(.undecodable) == "Unreadable")
    #expect(Self.title(.unknownType(rawType: 13)) == "Other data")

    let sender = Data([0x0A, 0x1B, 0x2C, 0x3D, 0x4E, 0x5F])
    #expect(Self.title(.request(sender: sender)) == "Request from 0A1B2C")
    #expect(Self.title(.request(sender: sender), isSent: true) == "Request sent")
  }

  /// The event an alert names is not in the summary's own detail list — it is on the title case —
  /// and a bubble reading "Alert" with nothing after it says less than the bytes do.
  @Test
  func `an alert bubble names its event, and a cancelled one its reason`() {
    let event = WeatherFormatting.eventName(Self.identity.event, tables: Self.tables)
    #expect(Self.details(WeatherTrafficSummary(title: .warning(Self.identity))) == event)
    #expect(Self.details(WeatherTrafficSummary(
      title: .cancel(Self.identity), detail: [.cancelReason(.upgraded)]))
      == "\(event) · upgraded")
    #expect(Self.details(WeatherTrafficSummary(
      title: .cancel(Self.identity), detail: [.cancelReason(.cancelled)]))
      == "\(event) · cancelled")
    #expect(Self.details(WeatherTrafficSummary(
      title: .cancel(Self.identity), detail: [.cancelReason(.expiredEarly)]))
      == "\(event) · expired early")
    // A reason nibble this build does not know is left to the bytes rather than made into a claim.
    #expect(Self.details(WeatherTrafficSummary(
      title: .cancel(Self.identity), detail: [.cancelReason(.other(9))])) == event)
  }

  /// "Not available · f · unknown location": the request letter the refusal echoes back is what
  /// says which of this phone's asks it answers (spec §8.3).
  @Test
  func `a refusal names the letter it answers and the reason it gives`() {
    func line(_ reason: MeshWXNotAvailableReason) -> String {
      Self.details(WeatherTrafficSummary(title: .notAvailable(letter: "f"), detail: [.reason(reason)]))
    }
    #expect(line(.unknownLocation) == "f · unknown location")
    #expect(line(.noData) == "f · no data")
    #expect(line(.unsupported) == "f · not supported")
    #expect(line(.botError) == "f · bot error")
    #expect(line(.rateLimited) == "f · asked too recently")
    #expect(line(.other(9)) == "f · no reason given")
  }

  // MARK: - Details

  @Test
  func `counts read one way for one and another for many`() {
    func detail(_ value: WeatherTrafficDetail) -> String? {
      WeatherTrafficCopy.detail(value, tables: Self.tables)
    }
    #expect(detail(.stations(13)) == "13 stations")
    #expect(detail(.stations(1)) == "1 station")
    #expect(detail(.entries(4)) == "4 alerts")
    #expect(detail(.entries(1)) == "1 alert")
    #expect(detail(.areas(38)) == "38 areas")
    #expect(detail(.areas(1)) == "1 area")
    #expect(detail(.offices(4)) == "4 offices")
    #expect(detail(.offices(1)) == "1 office")
  }

  /// Packet numbers are zero-based on the wire (spec §7C, §8.1) and one-based for a reader:
  /// nobody counting packets on a screen starts at nought.
  @Test
  func `a part or a chunk counts from one`() {
    func detail(_ value: WeatherTrafficDetail) -> String? {
      WeatherTrafficCopy.detail(value, tables: Self.tables)
    }
    #expect(detail(.part(index: 2, of: 7)) == "part 3 of 7")
    #expect(detail(.part(index: 0, of: 1)) == "part 1 of 1")
    // A text chunk is a part too: one word for one idea, whichever answer it belongs to.
    #expect(detail(.chunk(index: 1, of: 2)) == "part 2 of 2")
  }

  /// A sweep packet says what its sweep covers. A scoped packet that is not the one the scope
  /// rides on cannot, and "no states" must not read as "nothing".
  @Test
  func `a sweep packet says whether it is the country, some states, or cannot tell`() {
    func detail(_ value: WeatherTrafficDetail) -> String? {
      WeatherTrafficCopy.detail(value, tables: Self.tables)
    }
    #expect(detail(.national) == "the whole country")
    // In the packet's own order: this row is a reading of the bytes, not of a selection.
    #expect(detail(.scoped(states: ["TX", "OK"])) == "Texas and Oklahoma")
    #expect(detail(.scoped(states: [])) == "scoped, states not in this packet")
    #expect(detail(.cut) == "cut to fit")
    #expect(detail(.includesAdvisories) == "with advisories")
  }

  /// A forecast the bot picked the point for is the whole reason revision 10's `>f <lat>,<lon>`
  /// exists, so the row says so rather than reading as a bare "Forecast".
  @Test
  func `a forecast names its point, or says the bot chose one`() {
    func detail(_ value: WeatherTrafficDetail) -> String? {
      WeatherTrafficCopy.detail(value, tables: Self.tables)
    }
    #expect(detail(.botPoint) == "point chosen by the bot")
    #expect(detail(.point(102)) == WeatherCopy.pointName(102, tables: Self.tables))
    // A point this bundle has no name for is still the number the radio sent.
    #expect(detail(.point(65_000)) == "65000")
    #expect(detail(.requestText(">o KAUS")) == ">o KAUS")
  }

  // MARK: - The facts line

  /// "159 B · seq 212 · SNR 12 dB · 2 hops · 11:20 PM" — what is known, and nothing that is not.
  @Test
  func `the facts line says what the packet actually carried`() {
    #expect(F.plain(WeatherTrafficCopy.facts(
      Self.entry(), now: Self.now, calendar: F.calendar, locale: F.locale))
      == "159 B · seq 212 · SNR 12 dB · 2 hops · 11:20 PM")
    // A request this phone sent has no signal and no path: a shorter line, not a row of dashes.
    #expect(F.plain(WeatherTrafficCopy.facts(
      Self.entry(direction: .sent, length: 12, seq: 3, snr: nil, pathLength: nil),
      now: Self.now, calendar: F.calendar, locale: F.locale))
      == "12 B · seq 3 · 11:20 PM")
    // Backlog and duplicate are the two things no other screen in the app records.
    #expect(F.plain(WeatherTrafficCopy.facts(
      Self.entry(isBacklog: true, isDuplicate: true),
      now: Self.now, calendar: F.calendar, locale: F.locale))
      == "159 B · seq 212 · SNR 12 dB · 2 hops · 11:20 PM · from the radio's queue · duplicate")
    // A header that could not be read far enough says neither a sequence nor a signal.
    #expect(F.plain(WeatherTrafficCopy.facts(
      Self.entry(length: 5, seq: nil, snr: nil, pathLength: nil),
      now: Self.now, calendar: F.calendar, locale: F.locale))
      == "5 B · 11:20 PM")
  }

  @Test
  func `hops read from the path byte, and the no-path marker reads as flooded`() {
    #expect(WeatherTrafficCopy.hops(nil) == nil)
    #expect(WeatherTrafficCopy.hops(PacketBuilder.floodPathSentinel) == "flooded")
    #expect(WeatherTrafficCopy.hops(encodePathLen(hashSize: 1, hopCount: 1)) == "1 hop")
    #expect(WeatherTrafficCopy.hops(encodePathLen(hashSize: 2, hopCount: 4)) == "4 hops")
    // Straight from the radio: an absent line reads as no repeater, which is what it is.
    #expect(WeatherTrafficCopy.hops(encodePathLen(hashSize: 1, hopCount: 0)) == nil)
  }

  @Test
  func `decibels lose a trailing nought and keep a half`() {
    #expect(WeatherTrafficCopy.decibels(12, locale: F.locale) == "12")
    #expect(WeatherTrafficCopy.decibels(-2.5, locale: F.locale) == "-2.5")
    #expect(WeatherTrafficCopy.decibels(6.44, locale: F.locale) == "6.4")
    #expect(WeatherTrafficCopy.decibels(-0.75, locale: F.locale) == "-0.8")
  }

  /// As much as anyone on the channel knows about who asked (spec §7B): the first three bytes of
  /// their public key.
  @Test
  func `a sender is the first three bytes of their key`() {
    #expect(WeatherTrafficCopy.senderPrefix(Data([0x0A, 0x1B, 0x2C, 0x3D, 0x4E, 0x5F])) == "0A1B2C")
    #expect(WeatherTrafficCopy.senderPrefix(Data([0xFF])) == "FF")
    #expect(WeatherTrafficCopy.senderPrefix(Data()) == "")
  }

  /// The bytes are the row. Pairing them gives every line somewhere to break and leaves the
  /// selection one thing to copy.
  @Test
  func `the hex block is byte pairs`() {
    #expect(WeatherTrafficCopy.hexBlock("117a4ca000") == "11 7a 4c a0 00")
    #expect(WeatherTrafficCopy.hexBlock("") == "")
  }

  // MARK: - The whole line, off the bytes

  /// The design's own example, built out of a real packet: "Alert map · part 3 of 7 · 38 areas".
  /// The summary decodes the stored payload again rather than trusting the entry's header fields,
  /// so a row can only ever say what is in the packet.
  @Test
  func `a sweep packet's bubble reads off its own bytes`() throws {
    let texas = UInt8(Self.tables.states.firstIndex(of: "TX") ?? 0)
    let entries = (0..<38).map { offset in
      MeshWXAreaSweep.Entry(
        event: 3, stateIndex: texas, isCounty: false, start: UInt16(100 + offset), run: 1)
    }
    let message = MeshWXMessage(
      header: MeshWXHeader(seq: 212, bot: 0x0A1B, type: .areaSweep),
      payload: .areaSweep(MeshWXAreaSweep(
        builtMinutes: 29_824_100, group: 212, index: 2, total: 7, entries: entries)))
    let payload = try MeshWXEncoder.encode(message)
    let row = WeatherTrafficEntry.received(
      payload, channelIndex: 31, dataType: MeshWXWire.dataType, snr: 12,
      pathLength: encodePathLen(hashSize: 1, hopCount: 2), at: Self.now, isBacklog: false,
      isDuplicate: false)
    #expect(WeatherTrafficCopy.line(row, tables: Self.tables)
      == "Alert map · part 3 of 7 · 38 areas · the whole country")
    // Bytes the codec cannot read are still a row, and it claims nothing else.
    let unreadable = WeatherTrafficEntry(
      at: Self.now, direction: .received, channelIndex: 31, length: 5, hex: "117a4ca000")
    #expect(WeatherTrafficCopy.line(unreadable, tables: Self.tables) == "Unreadable")
  }
}
