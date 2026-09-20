import Foundation
import MeshWX

// MARK: - One datagram

/// One `GRP_DATA` datagram on the `#meshwx` slot, as the channel traffic screen lists it
/// (docs/MESHWX_UI.md §12, revision 10).
///
/// The owner's sixth ask: *a way to see all the GRP_DATA traffic on a channel like we do a chat.*
/// So this is the wire, not the model. Every datagram that reached the weather slot is here —
/// **decodable or not, duplicate or not, live or drained from the radio's queue** — and so is
/// every Request datagram this phone put on the air. It is the one place in the weather feature
/// that records something the reducer threw away, which is the whole reason it exists: "nothing
/// arrived" and "eight packets arrived and every one of them was a copy" look identical
/// everywhere else in the app.
///
/// ``hex`` is the message, and everything above it is a reading of the message: the summary
/// (``WeatherTrafficSummary``) is made by decoding the bytes again, so a row can never claim
/// something the bytes do not say.
public struct WeatherTrafficEntry: Sendable, Hashable, Codable, Identifiable {
  /// Which way the datagram went. There is no third case: the phone either heard it on the
  /// channel or sent it, and a request served from the five-minute rule is neither — nothing
  /// went out, so nothing is logged.
  public enum Direction: String, Sendable, Hashable, Codable {
    case received
    case sent
  }

  public var id: UUID
  /// Phone clock: when this phone received or sent it. Not the content's own time, which belongs
  /// to the decoded message and never to the packet.
  public var at: Date
  public var direction: Direction
  /// Drained from the radio's queue rather than heard live. It can be hours old and says nothing
  /// about whether the bot is in range now, which is why the row says so.
  public var isBacklog: Bool
  /// The channel slot it arrived on, or the slot the request went out on. Always the slot
  /// carrying `#meshwx` on this radio, which is not a fixed number — the owner's keeps it at 31.
  public var channelIndex: UInt8
  /// The MeshCore `data_type`. Always ``MeshWXWire/dataType`` here: a datagram of any other type
  /// is not ours and never reaches the log. Kept all the same, because a row that cannot show
  /// what it is a row of is not evidence of anything.
  public var dataType: UInt16
  /// The header's `bot`, or the bot a sent request names. Nil when the bytes could not be read
  /// far enough to know.
  public var botID: UInt16?
  /// The header's `seq` — the bot's own counter for a received message, this phone's request
  /// counter for a sent one. Nil when the header could not be read.
  public var seq: UInt8?
  /// The header's raw type nibble (``MeshWXMessageType``), kept as the byte so a type this build
  /// does not know still shows as itself.
  public var type: UInt8?
  /// The header's flags nibble, kept raw: what it means depends on the type.
  public var flags: UInt8?
  /// Payload length in bytes — the airtime, which is the whole point of watching the channel.
  public var length: Int
  /// Signal-to-noise of the received packet, in dB. Nil for one this phone sent.
  public var snr: Double?
  /// The encoded path-length byte (`0xFF` for a direct route, otherwise hash size and hop count
  /// packed together). Nil for a sent request: it has no path yet.
  public var pathLength: UInt8?
  /// The payload, lower-case hex. The row's detail view shows it, and
  /// ``WeatherTrafficSummary/make(entry:tables:)`` decodes it again rather than trusting the
  /// fields above.
  public var hex: String
  /// The reducer took this for a copy of a message already applied — the bot's own resend of an
  /// unechoed packet, or a late delivery. Always false for a sent request and for bytes that
  /// never decoded.
  public var isDuplicate: Bool

  public init(
    id: UUID = UUID(),
    at: Date,
    direction: Direction,
    isBacklog: Bool = false,
    channelIndex: UInt8,
    dataType: UInt16 = MeshWXWire.dataType,
    botID: UInt16? = nil,
    seq: UInt8? = nil,
    type: UInt8? = nil,
    flags: UInt8? = nil,
    length: Int,
    snr: Double? = nil,
    pathLength: UInt8? = nil,
    hex: String,
    isDuplicate: Bool = false
  ) {
    self.id = id
    self.at = at
    self.direction = direction
    self.isBacklog = isBacklog
    self.channelIndex = channelIndex
    self.dataType = dataType
    self.botID = botID
    self.seq = seq
    self.type = type
    self.flags = flags
    self.length = length
    self.snr = snr
    self.pathLength = pathLength
    self.hex = hex
    self.isDuplicate = isDuplicate
  }

  /// A datagram heard on the weather slot. The header fields are filled from the bytes where the
  /// bytes carry a readable one, and left nil where they do not: an undecodable datagram is a
  /// row that says its length and its hex and claims nothing else.
  public static func received(
    _ payload: Data,
    channelIndex: UInt8,
    dataType: UInt16,
    snr: Double?,
    pathLength: UInt8?,
    at: Date,
    isBacklog: Bool,
    isDuplicate: Bool,
    id: UUID = UUID()
  ) -> WeatherTrafficEntry {
    let header = try? MeshWXDecoder.decodeHeader(payload)
    return WeatherTrafficEntry(
      id: id,
      at: at,
      direction: .received,
      isBacklog: isBacklog,
      channelIndex: channelIndex,
      dataType: dataType,
      botID: header?.bot,
      seq: header?.seq,
      type: header?.rawType,
      flags: header?.flags,
      length: payload.count,
      snr: snr,
      pathLength: pathLength,
      hex: WeatherTrafficEntry.hex(of: payload),
      isDuplicate: isDuplicate)
  }

  /// A Request datagram this phone flooded on the channel (spec §7B). The bytes are the ones the
  /// radio actually took, handed back by the transport, so the row shows what went out rather
  /// than a reconstruction of it.
  public static func sent(
    _ payload: Data,
    channelIndex: UInt8,
    botID: UInt16,
    at: Date,
    id: UUID = UUID()
  ) -> WeatherTrafficEntry {
    let header = try? MeshWXDecoder.decodeHeader(payload)
    return WeatherTrafficEntry(
      id: id,
      at: at,
      direction: .sent,
      channelIndex: channelIndex,
      botID: botID,
      seq: header?.seq,
      type: header?.rawType,
      flags: header?.flags,
      length: payload.count,
      hex: WeatherTrafficEntry.hex(of: payload))
  }

  /// The payload again, or nil when the stored hex is not hex — which a file edited by hand can
  /// be, and a summary built from garbage would be worse than no summary.
  public var bytes: Data? {
    Self.data(fromHex: hex)
  }

  static func hex(of data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  static func data(fromHex hex: String) -> Data? {
    let digits = Array(hex.utf8)
    guard digits.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(digits.count / 2)
    var index = 0
    while index < digits.count {
      guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
      bytes.append(high << 4 | low)
      index += 2
    }
    return Data(bytes)
  }

  private static func nibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: byte - 0x30
    case 0x61...0x66: byte - 0x61 + 10
    case 0x41...0x46: byte - 0x41 + 10
    default: nil
    }
  }
}

// MARK: - The ring

/// The log's rules: a ring of ``limit``, oldest first, and a way to empty it.
///
/// Oldest first because the screen is a chat timeline and reads downwards (docs/MESHWX_UI.md
/// §12). Three hundred rows is a busy afternoon on a shared channel and about 60 KB of hex beside
/// the weather state — a window on what the radio is doing, deliberately not a record of it.
public enum WeatherTrafficLog {
  public static let limit = 300

  /// The log with one datagram appended, trimmed to ``limit`` from the front.
  public static func appending(
    _ entry: WeatherTrafficEntry, to log: [WeatherTrafficEntry], limit: Int = limit
  ) -> [WeatherTrafficEntry] {
    var appended = log
    appended.append(entry)
    if appended.count > limit {
      appended.removeFirst(appended.count - limit)
    }
    return appended
  }
}

// MARK: - What one row says

/// What a datagram *is*, in the wire's own terms: the bubble's first line
/// (docs/MESHWX_UI.md §12).
///
/// Values, not words. The screen turns each case into the sentence for the reader's locale; this
/// file has no strings in it for the same reason ``WeatherChannelSubject`` has none.
public enum WeatherTrafficTitle: Sendable, Hashable {
  case warning(MeshWXWarningIdentity)
  case cancel(MeshWXWarningIdentity)
  case alertList
  case observations
  case forecast
  case text(subject: MeshWXTextSubject)
  /// The bot cannot serve a request (spec §8.3). The letter is the request's, echoed back.
  case notAvailable(letter: Character)
  case coverage
  /// Somebody's `>` request, heard on the channel (spec §7B) or sent by this phone. `sender` is
  /// the six-byte key prefix the datagram carries, which is as much as anyone on the channel
  /// knows about who asked.
  case request(sender: Data)
  case alertMap
  /// Bytes on the weather slot the codec could not read at all.
  case undecodable
  /// A reserved or third-party type nibble (spec §2.2, nibbles 11-15).
  case unknownType(rawType: UInt8)
}

/// What qualifies the title, in the order the bubble reads them.
public enum WeatherTrafficDetail: Sendable, Hashable {
  case stations(Int)
  /// Identities in an alert list.
  case entries(Int)
  /// Alert runs in one sweep packet — scope entries excluded, because they are not areas under
  /// an alert.
  case areas(Int)
  /// "part 3 of 7", zero-based on the wire and left that way here.
  case part(index: UInt8, of: UInt8)
  case chunk(index: UInt8, of: UInt8)
  case point(UInt16)
  /// A forecast whose point is `0xFFFF` — the bot chose it, and no bundle index names it (spec
  /// revision 10, §1.3). Without this the row for the very answer revision 10 exists for read as
  /// a bare "Forecast", which is the one thing it is not.
  case botPoint
  case station(UInt16)
  /// How many Weather Service offices a coverage statement names (spec §7A). The row's only
  /// number: the circle and the zone runs are what the radio page is for.
  case offices(Int)
  /// The `>` text a Request datagram carries, verbatim.
  case requestText(String)
  case reason(MeshWXNotAvailableReason)
  case cancelReason(MeshWXCancelReason)
  /// A scoped sweep, and the state codes its scope entries name. Empty when this packet is not
  /// the one the scope rides on: the sweep is scoped and what it covers is not in these bytes.
  case scoped(states: [String])
  /// A sweep of the whole country.
  case national
  /// Entries were dropped to fit (sweep) or the tail was dropped (text).
  case cut
  case includesAdvisories
}

/// One row of the channel traffic timeline, read out of the bytes the entry carries
/// (docs/MESHWX_UI.md §12).
///
/// Built by decoding ``WeatherTrafficEntry/hex`` again rather than from the entry's header
/// fields, so a summary can only ever say what is in the packet. The screen renders
/// "Observations · 13 stations", "Alert map · part 3 of 7 · 38 areas", "Request from 0A1B2C ·
/// `>o KAUS`" and "Not available · f · unknown location" out of these values.
public struct WeatherTrafficSummary: Sendable, Hashable {
  public var title: WeatherTrafficTitle
  /// In reading order, `·` between them on screen. Empty for a message with nothing to add.
  public var detail: [WeatherTrafficDetail]

  public init(title: WeatherTrafficTitle, detail: [WeatherTrafficDetail] = []) {
    self.title = title
    self.detail = detail
  }

  public static func make(entry: WeatherTrafficEntry, tables: MeshWXTables) -> WeatherTrafficSummary {
    guard let bytes = entry.bytes, let message = try? MeshWXDecoder.decode(bytes) else {
      return WeatherTrafficSummary(title: .undecodable)
    }
    switch message.payload {
    case let .warning(warning):
      // How many zones or counties it names, as the web client's bubble says it: the size of an
      // alert is the one thing its name does not tell you. Nothing for a polygon-only warning.
      let areas = (warning.areas ?? []).reduce(0) { $0 + Int($1.run) }
      return WeatherTrafficSummary(
        title: .warning(warning.identity), detail: areas > 0 ? [.areas(areas)] : [])
    case let .cancel(cancel):
      return WeatherTrafficSummary(title: .cancel(cancel.identity), detail: [.cancelReason(cancel.reason)])
    case let .digest(digest):
      return WeatherTrafficSummary(title: .alertList, detail: [.entries(digest.entries.count)])
    case let .observations(batch):
      return WeatherTrafficSummary(
        title: .observations,
        detail: batch.stations.count == 1
          ? [.station(batch.stations[0].stationIndex)]
          : [.stations(batch.stations.count)])
    case let .forecast(forecast):
      return WeatherTrafficSummary(
        title: .forecast,
        // `0xFFFF` is not a point, it is "the bot picked one this bundle cannot name" (spec §7,
        // revision 10 §1.3), so the row says *that* rather than naming a sentinel.
        detail: forecast.isUnbundledPoint ? [.botPoint] : [.point(forecast.pointIndex)])
    case let .text(chunk):
      var detail: [WeatherTrafficDetail] = [.chunk(index: chunk.index, of: chunk.total)]
      if chunk.wasCut { detail.append(.cut) }
      return WeatherTrafficSummary(title: .text(subject: chunk.subject), detail: detail)
    case let .notAvailable(notAvailable):
      return WeatherTrafficSummary(
        title: .notAvailable(letter: notAvailable.requestLetter),
        detail: [.reason(notAvailable.reason)])
    case let .coverage(coverage):
      // The office count and nothing else. A statement's circle, its zone runs and its station
      // cap are the radio page's subject (§12); this row only has to say what went past.
      return WeatherTrafficSummary(
        title: .coverage,
        detail: coverage.officeIndices.isEmpty ? [] : [.offices(coverage.officeIndices.count)])
    case let .request(request):
      return WeatherTrafficSummary(
        title: .request(sender: request.senderPrefix), detail: [.requestText(request.text)])
    case let .areaSweep(sweep):
      // Areas, not runs: an entry is a run of up to 64 neighbouring zones or counties, and the
      // map's own status line counts what is shaded ("309 areas under an alert"). A packet's
      // bubble counts the same thing, so the numbers on the two screens add up.
      var detail: [WeatherTrafficDetail] = [
        .part(index: sweep.index, of: sweep.total),
        .areas(sweep.entries.reduce(0) { $0 + Int($1.run) })
      ]
      detail.append(sweep.isScoped
        ? .scoped(states: sweep.scope.map { tables.stateCode($0) ?? String($0) })
        : .national)
      if sweep.wasCut { detail.append(.cut) }
      if sweep.includesAdvisories { detail.append(.includesAdvisories) }
      return WeatherTrafficSummary(title: .alertMap, detail: detail)
    case .unknown:
      return WeatherTrafficSummary(title: .unknownType(rawType: message.header.rawType))
    }
  }
}
