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
  /// The issue time a revision 5 warning appends after the polygon and the areas (spec §3).
  static let warningIssuedSize = 2
  static let cancelSize = 8
  static let digestFixedSize = 10
  static let digestEntrySize = 6
  static let observationsFixedSize = 9
  static let observationStationSize = 11
  static let forecastFixedSize = 12
  static let forecastPeriodSize = 5
  static let textFixedSize = 8
  static let notAvailableSize = 6
  /// Header, centre, radius, station cap and the office count, before the offices themselves
  /// and the counted run list (spec §7A).
  static let coverageFixedSize = 14
  /// Header, the sender's key prefix and the request's own time, before the text (spec §7B).
  static let requestFixedSize = 14
  /// Header, the build time, and the three assembly bytes, before the entries (spec §7C).
  static let areaSweepFixedSize = 11
  static let areaSweepEntrySize = 4

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
  /// Stations one batch may carry when it also carries the per-station ages (spec §6.1). A full
  /// batch is already 163 bytes and the nibbles cost `ceil(n / 2)` more, so 14 with ages is 170
  /// and does not fit: the bot drops the farthest station — the list is nearest first — and never
  /// the ages, because a batch honest about some stations and silent about the rest is worse than
  /// one that says nothing. Not enforced separately; the packet budget is what refuses the 14th.
  public static let maxStationsWithAges = 13
  public static let maxPeriods = 14
  /// Offices one Coverage message may list (spec §7A). 24 offices and 30 runs together are 159
  /// bytes, so a full list of either never costs the other one; past it the bot cuts and says so.
  public static let maxCoverageOffices = 24
  /// Bytes of the sender's public key a Request carries: the same six-byte prefix a DM
  /// identifies the phone by, so one phone's DM and its datagram are one sender (spec §7B).
  public static let requestSenderPrefixSize = 6
  /// UTF-8 bytes a Request's text may take (spec §7B). Well under the packet budget: the whole
  /// §8.2 grammar fits, and a request is not the place to spend airtime.
  public static let maxRequestTextBytes = 40
  /// Entries one Area sweep packet carries (spec §7C): `(165 − 11) / 4` is 38, and the packet
  /// budget is what the cap is made of.
  public static let maxAreaSweepEntries = 38
  /// Packets one sweep may be split into (spec §7C), the same ceiling a Text reply has. Eight
  /// packets is the whole country's worth of airtime, which is why the screen never asks by itself.
  public static let maxAreaSweepPackets = 8
  /// States one `>wmap` may name (spec revision 10, §7C). Fifteen two-letter codes run together
  /// are 30 characters, which is what makes the compact form fit ``maxRequestTextBytes`` beside
  /// `>wmap all `. Past it the screen asks for the whole country and says so before the tap.
  public static let maxSweepScopeStates = 15
  /// How long the bot keeps the transmitted bytes of a multi-packet answer, so `>part` can send
  /// the named packets again (spec revision 10, §7C/§8.1). Ten minutes, eight answers. The app
  /// offers the ask only inside this window: past it the ordinary request is the only honest
  /// offer, because the bot no longer holds the bytes.
  public static let partsCacheSeconds = 600
  /// Consecutive UGC numbers one sweep entry may cover: the run field is six bits, carried less
  /// one, so 1 to 64.
  public static let maxAreaSweepRun: UInt8 = 64
  /// The largest UGC number a sweep entry may start at: the start field is ten bits.
  public static let maxAreaSweepStart: UInt16 = 0x03FF

  // MARK: Sentinels (spec §6, §7)
  //
  // Every optional field on the wire spends its whole range except one value; there is
  // no separate presence bitmap. Decoders must map the sentinel back to nil or a
  // reading of "−128 °F in Austin" ships to the user.

  /// Observation temperature/dewpoint: unknown.
  public static let temperatureUnknown: Int8 = -128
  /// Forecast high/low: not given for this entry — half of a whole day missing at the edge of the
  /// forecast window (spec §7, revision 3), not a night; a revision 1 day/night period carried one.
  public static let forecastTemperatureNotGiven: Int8 = 127
  /// Wind speed, visibility, pressure, humidity: unknown.
  public static let unsignedUnknown: UInt8 = 255
  /// Forecast point index: the bot resolved a place that has no bundled point.
  public static let unbundledPoint: UInt16 = 0xFFFF

  // MARK: Revision 5 times (spec §3, §6.1)
  //
  // Both are trailing blocks announced by a flags-nibble bit, so a decoder written before
  // revision 5 stops after the field it knows and reads the same message it always did.

  /// One age nibble step, in minutes.
  public static let observationAgeStepMinutes: UInt16 = 10
  /// The largest age a nibble carries: 15 steps. It is a saturation, not a reading — 150 means
  /// "150 minutes or more" — so a station at this value is reported as at least that old.
  public static let observationAgeSaturatedMinutes: UInt16 = 150
  /// The largest issue-to-expiry gap the u16 carries (45.5 days). Saturated rather than wrapped:
  /// at this value the product was issued *at or before* `expires − 65535`.
  public static let issuedBeforeSaturatedMinutes: UInt16 = .max

  // MARK: Warning tag byte (spec §3)

  static let tagPolygon: UInt8 = 0x02
  static let tagAreas: UInt8 = 0x01

  /// Warning flags nibble, bit 0: this identity was already sent.
  static let flagWarningUpdate: UInt8 = 0x1
  /// Warning flags nibble, bit 1: the issue time follows the polygon and the area list (spec §3,
  /// revision 5). In the flags nibble rather than in the tag byte because that byte has no spare
  /// bit: 7-6 tornado, 5-4 flood source, 3-2 flood damage, 1 polygon, 0 areas.
  static let flagWarningIssued: UInt8 = 0x2

  // MARK: Observations flags nibble (spec §6.1)

  /// Bit 0: the per-station ages follow the station records.
  static let flagObservationAges: UInt8 = 0x1

  // MARK: Coverage flags nibble (spec §7A)
  //
  // Both mean "this list is incomplete", never "this place is not covered". They are the reason
  // the message can be read as a denial at all: with them clear the lists are the whole area.

  /// Bit 0: the zone runs were cut.
  static let flagCoverageZonesCut: UInt8 = 0x1
  /// Bit 1: the office list was cut.
  static let flagCoverageOfficesCut: UInt8 = 0x2

  // MARK: Text flags nibble (spec §8.1)

  /// Bit 0: the product was longer than ``maxTextChunks`` chunks of ``maxTextBytes`` and the bot
  /// dropped the tail (spec §8.1, revision 7). The bot sets it on *every* chunk of a cut reply,
  /// not only the last: a phone missing the last chunk would otherwise be the one phone that
  /// cannot tell a reply with a hole in it from one that ends early on purpose.
  static let flagTextCut: UInt8 = 0x1

  // MARK: Data source (spec §2.2, revision 7)
  //
  // Bits 3-2 of the flags nibble, on every type that carries weather. The one exception is a
  // Cancel, whose *whole* nibble is a reason code (``MeshWXCancelReason``): bits 3-2 there are
  // part of the reason and say nothing about where anything came from.

  /// Flags bits 3-2: where the weather in the message came from (``MeshWXDataSource``).
  static let flagDataSourceMask: UInt8 = 0x0C
  /// How far down in the nibble ``flagDataSourceMask`` sits.
  static let flagDataSourceShift: UInt8 = 2

  /// Area run state byte, bit 7: the run numbers counties, not forecast zones.
  static let areaCountyBit: UInt8 = 0x80

  // MARK: Area sweep entry (spec §7C)
  //
  // A sweep entry is a Warning's area run squeezed from four bytes of state-plus-u16-plus-run
  // into four bytes that also carry the event, which is what lets one packet name 38 runs
  // instead of a warning's 30. The state and kind therefore sit the *other* way round from a
  // Warning's run byte: `state << 1 | kind`, not `kind << 7 | state`. Two layouts for the same
  // two fields is a trap worth naming rather than a constant worth sharing.

  /// Sweep entry byte 1, bit 0: the numbers are counties (`C`), not forecast zones (`Z`).
  static let sweepCountyBit: UInt8 = 0x1
  /// How far up byte 1 the state index sits.
  static let sweepStateShift: UInt8 = 1
  /// Bits 0-9 of a sweep entry's u16: the first UGC number in the run.
  static let sweepStartMask: UInt16 = 0x03FF
  /// Bits 10-15 of a sweep entry's u16: the run length, less one.
  static let sweepRunShift: UInt16 = 10

  // MARK: Area sweep flags nibble (spec §7C)

  /// Bit 0: entries were dropped to fit, so an area absent from the sweep may still be under
  /// an alert. Never read a gap in a cut sweep as clear weather.
  static let flagSweepCut: UInt8 = 0x1
  /// Bit 1: advisories are in this sweep, not only warnings and watches. Clear means the wider
  /// scope was not asked for, **not** that no advisory is active anywhere.
  static let flagSweepAdvisories: UInt8 = 0x2

  // MARK: Area sweep scope (spec revision 10, §7C)
  //
  // Revision 10 splits the `total` byte, which never used more than four of its bits, so a scoped
  // sweep says *on every packet* that it is not the country. The owner's reason for the whole
  // feature: "have a way for the user to select which areas they want to request the warnings
  // for. One, a few, or all. That way we don't default to sending everything."

  /// `total` byte, bit 7: this sweep covers only the states its scope entries name.
  ///
  /// Set on **every** packet of a scoped sweep, not only on packet 0, so a phone that lost the
  /// packet carrying the scope still knows it is not looking at the whole country — which is the
  /// difference between "no alert there" and "nobody asked about there".
  public static let sweepScopedBit: UInt8 = 0x80
  /// `total` byte, bits 0-3: the packet count, 1 to ``maxAreaSweepPackets``.
  public static let sweepTotalMask: UInt8 = 0x0F
  /// The event code of a scope entry (spec revision 10, §7C): no real event has code 0, which is
  /// what lets the scope ride in the entry list instead of costing a field of its own.
  ///
  /// A scope entry is `event 0`, kind zone, `start 0`, `run 1` — `XXZ000`, the Weather Service's
  /// own way of writing "all of state XX". The decoder lifts them out of ``MeshWXAreaSweep/entries``
  /// and into ``MeshWXAreaSweep/scope``; the encoder puts them back, first.
  public static let sweepScopeEvent: UInt8 = 0
}

/// The ten structured message types (spec §2.2, high nibble of the type byte).
///
/// Type 11 is reserved and 12-15 are free for third-party experiments, so this is
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
  /// Spec revision 4, §7A: what the bot carries, stated by the bot.
  case coverage = 8
  /// Spec revision 6, §7B: an app's `>` request, flooded on `#meshwx` as a datagram. The one
  /// type this app *sends*; another phone's, heard on the channel, is not ours to act on.
  case request = 9
  /// Spec revision 8, §7C: every area in the country under an alert, in one sweep of at most
  /// eight packets.
  case areaSweep = 10
}

/// Where the weather in a message came from (spec §2.2, revision 7: flags bits 3-2).
///
/// A bot with a dish reads its products off the GOES satellite broadcast; a bot on a wire fetches
/// them from NOAA; a bot with both fills the gaps in a satellite product from the internet and
/// says so. The difference is worth a line on screen because the two paths fail differently: a
/// dish loses products to rain fade in exactly the weather this app is for, and an internet feed
/// is only ever as current as the bot's last successful poll.
///
/// ``unstated`` is not a fourth kind of source. It is every bot older than revision 7, and every
/// message with no weather product behind it, so nothing on screen may read it as a claim.
public enum MeshWXDataSource: UInt8, Sendable, Hashable, Codable, CaseIterable {
  /// Not stated: a bot older than revision 7, or a message not built from a weather product.
  case unstated = 0
  /// Received off the GOES satellite by the bot's own dish.
  case goesSatellite = 1
  /// Fetched from NOAA over the internet.
  case internet = 2
  /// Built from products of both kinds.
  case mixed = 3

  /// Never fails: the field is two bits wide and all four values are defined.
  public init(bits: UInt8) {
    self = MeshWXDataSource(rawValue: bits & 0x3) ?? .unstated
  }

  /// This source's place in a flags nibble, ready to be ORed into one.
  var flagBits: UInt8 { rawValue << MeshWXWire.flagDataSourceShift }
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

  /// Where the weather in this message came from (spec §2.2, revision 7), read off flags bits
  /// 3-2. ``MeshWXDataSource/unstated`` for a bot older than revision 7 and for the types that
  /// carry no weather product — Not available, Coverage and Request always send 0.
  ///
  /// A Cancel never carries it: its whole nibble is a ``MeshWXCancelReason``, so reason 12 would
  /// otherwise read as "mixed". Unstated is the only honest answer for one.
  public var dataSource: MeshWXDataSource {
    guard type != .cancel else { return .unstated }
    return MeshWXDataSource(bits: (flags & MeshWXWire.flagDataSourceMask) >> MeshWXWire.flagDataSourceShift)
  }

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
