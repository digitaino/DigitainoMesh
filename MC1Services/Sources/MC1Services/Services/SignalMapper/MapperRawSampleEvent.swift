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
    gateOutcome: MapperGateOutcome = .noFix
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
