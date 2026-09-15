import Foundation

/// Transport constants and limits of the MeshWX v5 wire format (spec §2).
///
/// Every v5 message is the `data` field of one MeshCore `GRP_DATA` packet on the
/// `#meshwx` channel. The app never sees the encrypted frame around it: the companion
/// radio hands up `(data_type, data)` and anything whose `data_type` is not
/// ``dataType`` is not ours.
///
/// The numbers here are not style preferences — they are the reason a message fits in
/// one LoRa packet. A 165-byte datagram is already ~600 ms of airtime at SF7, and the
/// bot repeats a packet it did not hear echoed, so an encoder that quietly overruns a
/// limit costs the whole channel, not just the sender.
public enum MeshWXWire {
  /// MeshCore `data_type` carrying a v5 message (development range, spec §2.1).
  public static let dataType: UInt16 = 0xFF10

  /// Largest `data` payload the transport accepts, in bytes.
  public static let maxData = 165

  /// Size of the common header (spec §2.2).
  public static let headerSize = 4

  // MARK: Per-message fixed sizes
  //
  // The decoder needs these before it knows how long the variable part is, so they are
  // named rather than inlined as magic offsets.

  static let warningFixedSize = 15
  static let cancelSize = 8
  static let digestFixedSize = 10
  static let digestEntrySize = 6
  static let observationsFixedSize = 9
  static let observationStationSize = 11
  static let forecastFixedSize = 12
  static let forecastPeriodSize = 5
  static let textFixedSize = 8
  static let notAvailableSize = 6

  // MARK: Counts and limits (spec §3, §5, §6, §7, §8.1)

  /// Text bytes one chunk can carry: the packet budget minus the 8-byte text header.
  public static let maxTextBytes = maxData - textFixedSize  // 157
  /// Chunks one reply may be split into.
  public static let maxTextChunks = 8
  public static let minPolygonVertices = 3
  public static let maxPolygonVertices = 30
  public static let maxAreaRuns = 30
  public static let maxDigestEntries = 25
  public static let maxStations = 14
  public static let maxPeriods = 14

  // MARK: Sentinels (spec §6, §7)
  //
  // Every optional field on the wire spends its whole range except one value; there is
  // no separate presence bitmap. Decoders must map the sentinel back to nil or a
  // reading of "−128 °F in Austin" ships to the user.

  /// Observation temperature/dewpoint: unknown.
  public static let temperatureUnknown: Int8 = -128
  /// Forecast high/low: not given for this period (nights have no high, days no low).
  public static let forecastTemperatureNotGiven: Int8 = 127
  /// Wind speed, visibility, pressure, humidity: unknown.
  public static let unsignedUnknown: UInt8 = 255
  /// Forecast point index: the bot resolved a place that has no bundled point.
  public static let unbundledPoint: UInt16 = 0xFFFF

  // MARK: Warning tag byte (spec §3)

  static let tagPolygon: UInt8 = 0x02
  static let tagAreas: UInt8 = 0x01

  /// Warning flags nibble, bit 0: this identity was already sent.
  static let flagWarningUpdate: UInt8 = 0x1

  /// Area run state byte, bit 7: the run numbers counties, not forecast zones.
  static let areaCountyBit: UInt8 = 0x80
}

/// The seven structured message types (spec §2.2, high nibble of the type byte).
///
/// Types 8-11 are reserved and 12-15 are free for third-party experiments, so this is
/// deliberately not exhaustive over the nibble: ``MeshWXHeader/rawType`` keeps the byte
/// and receivers ignore what they do not know.
public enum MeshWXMessageType: UInt8, Sendable, Hashable, Codable, CaseIterable {
  case warning = 1
  case cancel = 2
  case digest = 3
  case observations = 4
  case forecast = 5
  case text = 6
  case notAvailable = 7
}

/// The decoded 4-byte common header (spec §2.2).
///
/// `bot` is the first two bytes of the bot's public key, which is how an app keeps
/// state per bot when two of them cover the same place (spec §12). `seq` is per-bot and
/// wraps; a gap in it is the cue to ask for a digest, and a repeat of `(bot, seq)` is
/// the bot's own "nobody repeated me" retransmission and must be dropped (spec §2.3).
public struct MeshWXHeader: Sendable, Hashable, Codable {
  public var seq: UInt8
  public var bot: UInt16
  /// The raw high nibble, kept verbatim so an unknown future type survives a
  /// decode/re-encode round trip instead of being flattened to zero.
  public var rawType: UInt8
  /// The low nibble. Type-specific: bit 0 is "update" on a warning, the whole nibble is
  /// the reason on a cancel, unused elsewhere.
  public var flags: UInt8

  /// The known type, or nil for a reserved or experimental nibble.
  public var type: MeshWXMessageType? { MeshWXMessageType(rawValue: rawType) }

  public init(seq: UInt8, bot: UInt16, rawType: UInt8, flags: UInt8) {
    self.seq = seq
    self.bot = bot
    self.rawType = rawType & 0x0F
    self.flags = flags & 0x0F
  }

  public init(seq: UInt8, bot: UInt16, type: MeshWXMessageType, flags: UInt8 = 0) {
    self.init(seq: seq, bot: bot, rawType: type.rawValue, flags: flags)
  }
}
