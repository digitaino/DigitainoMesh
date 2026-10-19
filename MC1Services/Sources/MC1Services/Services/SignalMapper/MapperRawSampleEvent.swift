import Foundation

/// What kind of event a raw ride-log row records.
///
/// The raw log keeps *everything* a survey session sees, including events the
/// aggregate pipeline deliberately drops — that asymmetry is the log's purpose
/// (docs/ACTIVE_SURVEY_M3_5.md §2.4).
public enum MapperRawSampleKind: Int, Sendable, CaseIterable {
  /// A probe transmission (trace or discover) left the radio.
  case probeAttempt = 0
  /// A trace reply settled — carries both link legs and, when available, per-hop SNR.
  case probeTraceReply = 1
  /// A discover response — carries both legs and the responder's full public key.
  case probeDiscoverResponse = 2
  /// A probe timed out with the radio link healthy: genuine loss evidence.
  case probeLost = 3
  /// A probe written off because the session/radio went away (BLE teardown, stop).
  /// Never loss evidence — kept distinct so teardown can't paint phantom dead zones.
  case probeAbandoned = 4
  /// A passively received packet.
  case passiveRx = 5
  /// Our own transmission heard being rebroadcast (uplink *fact*, downlink numbers).
  case txHeard = 6
  /// A message send resolved as delivered (end-to-end ACK; RTT when firmware sent it).
  case ackResolved = 7
  /// A periodic position marker, independent of radio traffic. Distinguishes
  /// "no coverage here" from "radio was offline here" and draws the ride polyline.
  case breadcrumb = 8
  /// The BLE link to the radio dropped.
  case radioLinkDown = 9
  /// The BLE link to the radio came back.
  case radioLinkUp = 10
  /// One of *our own* transmissions left the radio: a message, an advert or a manual
  /// flood (docs/SIGNAL_MAPPER_V3.md §2, "Our own packets"). Probe transmissions keep
  /// their own ``probeAttempt`` kind rather than doubling as `sent` rows.
  ///
  /// The firmware builds the packet, so the app cannot compute a content hash at send
  /// time; ``MapperRawSampleEvent/contentHash`` is back-filled once the echo reveals it,
  /// keyed by ``MapperRawSampleEvent/messageID``.
  case sent = 11
  /// One observer's sighting of one of our packets, fetched from CoreScope after the
  /// fact (§4). `repeaterHexID` is the observer, `rxSnr`/`rssi` are *its* reading of us,
  /// `contentHash` is the packet, and there is no position: the row records what somebody
  /// else heard, not where we were.
  case observerSighting = 12

  /// The kinds allowed to carry a ``MapperRawSampleEvent/contentHash``.
  ///
  /// ACTIVE_SURVEY_M3_5 §6 F1 refused a mesh-wide packet identity on raw rows outright: it
  /// is a cross-mesh join key, and an exported ride carrying one could be matched against a
  /// third party's RX log. SIGNAL_MAPPER_V3 §2 narrows that to these two, where the packet
  /// being identified is *ours* — a transmission we chose to make under our own key, and
  /// an observer's sighting of that same transmission, which is the join reach is built
  /// from. On anything else the hash would still be F1's key over somebody else's traffic.
  ///
  /// Enforced on write, not merely documented: `MapperRawSample` drops a hash a kind is not
  /// entitled to, so a future producer cannot smuggle one in by filling the field.
  public static let hashBearingKinds: Set<MapperRawSampleKind> = [.sent, .observerSighting]

  /// The kinds allowed to carry ``MapperRawSampleEvent/rawHex`` — the ones that *are* a
  /// packet our radio received (§9). Our own `sent` rows are not among them: the firmware
  /// builds the packet and never hands the bytes back.
  public static let packetBearingKinds: Set<MapperRawSampleKind> = [
    .passiveRx, .txHeard, .probeTraceReply, .probeDiscoverResponse
  ]

  public var mayCarryContentHash: Bool {
    Self.hashBearingKinds.contains(self)
  }

  public var mayCarryPacketBytes: Bool {
    Self.packetBearingKinds.contains(self)
  }
}

/// Why the aggregate pipeline accepted or rejected the fix behind a sample.
///
/// Deliberately **has no anchor-exclusion case**: the raw recorder is fed before
/// anchor policy runs, so a raw row cannot express disc membership — a per-point
/// in/out label would be a solvable oracle for the disc geometry that §2.6 of
/// SIGNAL_MAPPER_V2.md says must never be recoverable. Only data-quality outcomes
/// exist here.
public enum MapperGateOutcome: Int, Sendable, CaseIterable {
  case accepted = 0
  case noFix = 1
  case staleFix = 2
  case inaccurateFix = 3
  case movedSinceCapture = 4
}

/// One raw ride-log event, as emitted by the capture/probe engines toward the
/// session recorder. Everything is optional except identity — the log's rule is
/// "record what was known, never guess".
public struct MapperRawSampleEvent: Sendable, Equatable {
  public var timestamp: Date
  public var kind: MapperRawSampleKind

  // Radio measurements. `rxSnr`/`rssi` are our radio's reading (downlink);
  // `txSnr` is the far end's reading of us (uplink); `perHopSnrs` is the trace
  // reply's per-hop uplink array in path order.
  public var rxSnr: Double?
  public var txSnr: Double?
  public var rssi: Int?
  public var hopCount: Int?
  public var rttMs: Int?
  public var routeTypeRaw: UInt8?
  public var payloadTypeRaw: UInt8?
  public var perHopSnrs: [Double]?

  /// The packet's hop hashes in path order (sender first), canonical uppercase hex —
  /// the same spelling ``NodeHexID/hex`` produces, so a row joins against the rest of
  /// the mapper without re-formatting. Nil when the event carried no path; an empty
  /// array means "a path field that decoded to no hops", which is a different fact.
  public var pathHashes: [String]?

  /// The packet bytes exactly as the radio handed them over (SIGNAL_MAPPER_V3 §9): what
  /// a later tool re-decodes and what CoreScope's client-reception payload carries. Set
  /// on rows that *are* a received packet — ``MapperRawSampleKind/passiveRx``,
  /// ``MapperRawSampleKind/txHeard`` — and nil everywhere else, including our own
  /// ``MapperRawSampleKind/sent`` rows, where the firmware built the packet and never
  /// showed it to us.
  public var rawHex: Data?

  /// The packet's mesh-wide identity: `SHA-256` over the payload-type nibble and the
  /// packet payload, 16 lowercase hex characters, identical on every node and observer
  /// that heard it (`ParsedRxLogData.computeContentHash`).
  ///
  /// Allowed on ``MapperRawSampleKind/sent`` and ``MapperRawSampleKind/observerSighting``
  /// rows only. §2/§9 of SIGNAL_MAPPER_V3 supersede ACTIVE_SURVEY_M3_5 §6 F1 for exactly
  /// these two kinds: a hash on *our own* transmission and on somebody else's sighting of
  /// it is the join key reach depends on, while a hash on a passively heard packet would
  /// still be the cross-mesh join into a third party's RX log that F1 refused.
  public var contentHash: String?

  /// Local correlation for a ``MapperRawSampleKind/sent`` row: which message row this
  /// transmission was, so the echo can back-fill ``contentHash`` later. Never leaves the
  /// phone — a UUID minted by this install names nothing on the mesh.
  public var messageID: UUID?

  // Repeater identity. The full public key is stored when the probe layer knows
  // it (targets, discover responses) — the raw log is the one store allowed to
  // keep it (docs/ACTIVE_SURVEY_M3_5.md §3.3). No name is ever recorded per-row.
  public var repeaterHexID: String?
  public var repeaterPublicKey: Data?
  public var wasFocused: Bool

  // Position, from the fix the event was placed against (send-time fix for
  // probe events). Nil when no usable fix existed — the row still records that.
  public var latitude: Double?
  public var longitude: Double?
  public var horizontalAccuracyMeters: Double?
  public var speedMetersPerSecond: Double?
  public var courseDegrees: Double?
  public var fixAgeSeconds: Double?
  public var cellRaw: UInt64?
  public var gateOutcome: MapperGateOutcome
  /// The radio's confirmed TX power at the moment of the event, dBm. Stamped by the
  /// app-side breadcrumb task (the engines never learn power): adaptive power keeps
  /// re-stepping mid-ride, and uplink SNRs measured at a varying, unrecorded power
  /// are not comparable to each other (M3.5 UI review S3). Nil when unknown.
  public var txPowerDbm: Int8?

  public init(
    timestamp: Date,
    kind: MapperRawSampleKind,
    rxSnr: Double? = nil,
    txSnr: Double? = nil,
    rssi: Int? = nil,
    hopCount: Int? = nil,
    rttMs: Int? = nil,
    routeTypeRaw: UInt8? = nil,
    payloadTypeRaw: UInt8? = nil,
    perHopSnrs: [Double]? = nil,
    pathHashes: [String]? = nil,
    rawHex: Data? = nil,
    contentHash: String? = nil,
    messageID: UUID? = nil,
    repeaterHexID: String? = nil,
    repeaterPublicKey: Data? = nil,
    wasFocused: Bool = false,
    latitude: Double? = nil,
    longitude: Double? = nil,
    horizontalAccuracyMeters: Double? = nil,
    speedMetersPerSecond: Double? = nil,
    courseDegrees: Double? = nil,
    fixAgeSeconds: Double? = nil,
    cellRaw: UInt64? = nil,
    gateOutcome: MapperGateOutcome = .noFix,
    txPowerDbm: Int8? = nil
  ) {
    self.timestamp = timestamp
    self.kind = kind
    self.rxSnr = rxSnr
    self.txSnr = txSnr
    self.rssi = rssi
    self.hopCount = hopCount
    self.rttMs = rttMs
    self.routeTypeRaw = routeTypeRaw
    self.payloadTypeRaw = payloadTypeRaw
    self.perHopSnrs = perHopSnrs
    self.pathHashes = pathHashes
    self.rawHex = rawHex
    self.contentHash = contentHash
    self.messageID = messageID
    self.repeaterHexID = repeaterHexID
    self.repeaterPublicKey = repeaterPublicKey
    self.wasFocused = wasFocused
    self.latitude = latitude
    self.longitude = longitude
    self.horizontalAccuracyMeters = horizontalAccuracyMeters
    self.speedMetersPerSecond = speedMetersPerSecond
    self.courseDegrees = courseDegrees
    self.fixAgeSeconds = fixAgeSeconds
    self.cellRaw = cellRaw
    self.gateOutcome = gateOutcome
    self.txPowerDbm = txPowerDbm
  }

  /// Populate the position block from a fix, computing the age against `at`.
  public mutating func setFix(_ fix: MapperFix, at: Date) {
    latitude = fix.latitude
    longitude = fix.longitude
    horizontalAccuracyMeters = fix.horizontalAccuracyMeters
    speedMetersPerSecond = fix.speedMetersPerSecond
    courseDegrees = fix.courseDegrees
    fixAgeSeconds = at.timeIntervalSince(fix.timestamp)
  }
}

/// Where survey sessions send raw events. Implemented by the MapperRawLog module
/// (which depends on MC1Services; MC1Services can never import it back — that
/// dependency edge is what keeps raw rows structurally unreachable from any
/// future upload code in this module). Nil recorder = no raw logging, which is
/// the ambient-capture configuration: only explicit sessions record raw.
public protocol MapperRawSampleRecording: Actor {
  func record(_ event: MapperRawSampleEvent) async
}
