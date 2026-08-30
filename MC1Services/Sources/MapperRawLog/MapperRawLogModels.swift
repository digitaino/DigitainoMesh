import Foundation
import MC1Services
import SwiftData

// MARK: - Survey run

/// One ride: the container every raw row belongs to.
///
/// A run outlives the engines that feed it. BLE rewires destroy and rebuild
/// `SignalMapperProbeEngine`/`SignalMapperCaptureEngine`, and the app-level session
/// re-attaches a new engine generation to the *same* run row
/// (docs/ACTIVE_SURVEY_M3_5.md §2.6) — which is why the cumulative counters live here
/// and not on any engine's in-memory snapshot: they have to survive the thing that
/// produced them.
///
/// The radio configuration is snapshotted as five plain columns rather than a
/// relationship to a `Device` row. This store shares no schema with the chat store
/// (§2.4) and must be readable with the radio long since unpaired: a ride recorded at
/// SF11/BW250 is uninterpretable without the settings it was flown at, and a foreign
/// key into a database this module cannot see would answer nothing.
@Model
final class MapperSurveyRun {
  #Unique<MapperSurveyRun>([\.id])

  /// Stable run identity, minted by ``MapperRawLogStore/createRun(radioID:frequency:bandwidth:spreadingFactor:codingRate:txPower:focusTargetHexIDs:startedAt:)``
  /// and used as the (by-value) foreign key on every ``MapperRawSample``.
  var id: UUID

  var startedAt: Date

  /// When the ride stopped. Nil means *still open*, which after a jetsam or a crash is
  /// a lie the launch pass has to correct — see
  /// ``MapperRawLogStore/reconcileOrphanRuns(now:)`` and §2.6's auto-end rules.
  var endedAt: Date?

  /// Which paired radio flew the ride, when known. An identifier only: no name, no key.
  var radioID: UUID?

  // MARK: - Radio configuration snapshot

  /// LoRa parameters as they were at ride start. All optional because a run may be
  /// opened before the device row has settled, and a wrong number here would silently
  /// mis-scale every link-budget calculation done against the log later.
  var frequency: UInt32?
  var bandwidth: UInt32?
  var spreadingFactor: UInt8?
  var codingRate: UInt8?
  var txPower: Int8?

  // MARK: - Cumulative counters

  /// Session tallies accumulated across engine generations by
  /// ``MapperRawLogStore/accumulateCounters(runID:probesSent:tracesSent:discoversSent:repliesHeard:probesLost:cellsProbed:)``.
  /// Deltas are added rather than assigned: a rewire hands over whatever the dying
  /// engine had counted, and an assignment would reset the ride's totals to the new
  /// engine's zero.
  var probesSent: Int = 0
  var tracesSent: Int = 0
  var discoversSent: Int = 0
  var repliesHeard: Int = 0
  var probesLost: Int = 0
  var cellsProbed: Int = 0

  /// How many raw rows this run has written. Maintained by
  /// ``MapperRawLogStore/insertSamples(_:runID:startingSeq:)`` so the HUD and the
  /// export sheet can size a run without a `COUNT(*)` over 50 000 rows.
  var sampleCount: Int = 0

  /// Lock-on targets for this ride, JSON `["0C13", ...]` of hash-width hex IDs.
  ///
  /// JSON rather than a relationship or a joined string because it is read and written
  /// whole and never queried into — the same argument
  /// ``MapperCellObservation/hopHistogramData`` makes.
  var focusTargetHexIDsData: Data = Data()

  init(
    id: UUID = UUID(),
    startedAt: Date,
    endedAt: Date? = nil,
    radioID: UUID? = nil,
    frequency: UInt32? = nil,
    bandwidth: UInt32? = nil,
    spreadingFactor: UInt8? = nil,
    codingRate: UInt8? = nil,
    txPower: Int8? = nil,
    focusTargetHexIDsData: Data = Data()
  ) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.radioID = radioID
    self.frequency = frequency
    self.bandwidth = bandwidth
    self.spreadingFactor = spreadingFactor
    self.codingRate = codingRate
    self.txPower = txPower
    self.focusTargetHexIDsData = focusTargetHexIDsData
  }
}

// MARK: - Raw sample

/// One raw ride-log row: everything a survey session saw, at the fidelity it saw it.
///
/// This is the deliberate opposite of ``MapperCellObservation``, and the divergences are
/// each defended separately in docs/ACTIVE_SURVEY_M3_5.md §3:
///
/// - **Raw coordinates are stored here.** The aggregate store buckets to an H3 cell and
///   keeps nothing finer; this row keeps the fix, because "how far did my signal reach"
///   is a question a 174 m cell cannot answer. The containment is structural instead:
///   own container, backup-excluded, 30-day retention, scrubbed-by-default export, and
///   the module edge that makes these rows unreachable from MC1Services.
/// - **Full repeater public keys are stored here** (§3.3). Hash-width IDs collide, and a
///   ride whose repeaters cannot be told apart is not analysable. The scrubbed export
///   truncates them back to hash width.
///
/// Two columns that a reasonable person would add are deliberately absent:
///
/// - **No `packetHash`** (§6 F1). `SHA-256(payload)` is identical on every node that
///   heard the packet, so it is a cross-mesh join key: any exported ride could be
///   de-anonymised against a third party's RX log, and locally it joins straight to
///   `RxLogEntry`. The run-local ``seq`` is the correlation key instead — it means
///   nothing outside this run's own rows, which is exactly the property wanted.
/// - **No `repeaterName`** (§6 F9, §2.4). Names are personal data and would sit on every
///   row of a movement log. They resolve at export time from the contact list, where the
///   user can see them, and are never persisted here.
///
/// There is no SwiftData relationship to ``MapperSurveyRun`` either: ``runID`` is a
/// foreign key by value. §2.4 wants "no cross-table JOIN surface", and a cascade
/// relationship over 50 000 rows would also fight the chunked delete that
/// ``MapperRawLogStore/purgeExpired(retentionDays:now:)`` needs.
@Model
final class MapperRawSample {
  // `runID` alone serves the count/delete/purge paths; `runID + seq` serves the
  // paginated ordered read the export streams through. Both are the whole access
  // pattern of this table.
  #Index<MapperRawSample>([\.runID], [\.runID, \.seq])

  /// Which run wrote this row. By value — see the type's note on relationships.
  var runID: UUID

  /// Run-local monotonic sequence, assigned by ``MapperRawSampleRecorder``.
  ///
  /// The correlation key that replaces `packetHash` (§6 F1): it orders rows within one
  /// ride exactly and identifies nothing at all outside it. Timestamps cannot do this
  /// job — two events in the same millisecond are ordinary at 100 rows/batch, and the
  /// export must be able to reproduce the order it read.
  var seq: Int64

  var timestamp: Date

  /// ``MapperRawSampleKind`` raw value. Stored raw rather than as the enum so a row
  /// written by a newer build with a kind this one has not heard of still reads back
  /// instead of failing the whole fetch.
  var kindRaw: Int

  // MARK: - Radio measurements

  /// Our radio's reading of the far end (downlink).
  var rxSnr: Double?
  /// The far end's reading of us (uplink) — the whole point of active survey.
  var txSnr: Double?
  var rssi: Int?
  var hopCount: Int?
  var rttMs: Int?
  var routeTypeRaw: Int?
  var payloadTypeRaw: Int?

  /// The trace reply's per-hop uplink SNR array in path order, JSON `[6.5, -2.0]`.
  /// Nil when the event carried none; an empty array and "no array" are different
  /// facts and stay different.
  var perHopSnrsData: Data?

  // MARK: - Repeater identity

  var repeaterHexID: String?
  /// The responder's full public key when the probe layer knew it. Allowed *here* only
  /// (§3.3); nothing in MC1Services can reach this column, and the scrubbed export
  /// truncates it.
  var repeaterPublicKey: Data?
  /// Whether this event concerned a lock-on target, so a focus link can be separated
  /// from background traffic without re-deriving the focus set at analysis time.
  var wasFocused: Bool

  // MARK: - Position

  var latitude: Double?
  var longitude: Double?
  var horizontalAccuracyMeters: Double?
  var speedMetersPerSecond: Double?
  var courseDegrees: Double?
  /// How old the fix was when the event was placed against it. Stored rather than
  /// derived: the fix's own capture time is not kept, and `timestamp - fixAge` is the
  /// only honest way to say when the phone was actually *there*.
  var fixAgeSeconds: Double?

  /// The H3 cell the event was placed in, as the **bit pattern** of the 64-bit index.
  ///
  /// `Int64` rather than `UInt64` on purpose. SQLite's integer column is signed 64-bit,
  /// and SwiftData is value-preserving rather than bit-casting across that boundary —
  /// the same mechanic that makes a stored `-1` trap a `UInt8` fetch, recorded in
  /// `PersistenceStore.createContainer`'s v1→v2 note. Storing the bit pattern makes the
  /// column exactly what SQLite holds, so any index round-trips losslessly instead of
  /// depending on H3 never setting the high bit. Converted back with
  /// `UInt64(bitPattern:)` at the DTO boundary and nowhere else.
  var cellRaw: Int64?

  /// ``MapperGateOutcome`` raw value: why the aggregate pipeline would have accepted or
  /// rejected the fix behind this row.
  ///
  /// Data quality only. The recorder is fed *before* anchor policy runs (§2.4 gate
  /// split), and the enum has no anchor case to write even if it were — a per-row
  /// in/out label would be a solvable oracle for the anchor discs' geometry (§6 F4).
  var gateOutcomeRaw: Int

  init(
    runID: UUID,
    seq: Int64,
    timestamp: Date,
    kindRaw: Int,
    rxSnr: Double? = nil,
    txSnr: Double? = nil,
    rssi: Int? = nil,
    hopCount: Int? = nil,
    rttMs: Int? = nil,
    routeTypeRaw: Int? = nil,
    payloadTypeRaw: Int? = nil,
    perHopSnrsData: Data? = nil,
    repeaterHexID: String? = nil,
    repeaterPublicKey: Data? = nil,
    wasFocused: Bool = false,
    latitude: Double? = nil,
    longitude: Double? = nil,
    horizontalAccuracyMeters: Double? = nil,
    speedMetersPerSecond: Double? = nil,
    courseDegrees: Double? = nil,
    fixAgeSeconds: Double? = nil,
    cellRaw: Int64? = nil,
    gateOutcomeRaw: Int
  ) {
    self.runID = runID
    self.seq = seq
    self.timestamp = timestamp
    self.kindRaw = kindRaw
    self.rxSnr = rxSnr
    self.txSnr = txSnr
    self.rssi = rssi
    self.hopCount = hopCount
    self.rttMs = rttMs
    self.routeTypeRaw = routeTypeRaw
    self.payloadTypeRaw = payloadTypeRaw
    self.perHopSnrsData = perHopSnrsData
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
    self.gateOutcomeRaw = gateOutcomeRaw
  }

  /// Builds a row from a recorder event. `seq` comes from the recorder, not the event —
  /// the event has no idea where in the run it landed.
  convenience init(event: MapperRawSampleEvent, runID: UUID, seq: Int64) {
    self.init(
      runID: runID,
      seq: seq,
      timestamp: event.timestamp,
      kindRaw: event.kind.rawValue,
      rxSnr: event.rxSnr,
      txSnr: event.txSnr,
      rssi: event.rssi,
      hopCount: event.hopCount,
      rttMs: event.rttMs,
      routeTypeRaw: event.routeTypeRaw.map(Int.init),
      payloadTypeRaw: event.payloadTypeRaw.map(Int.init),
      perHopSnrsData: MapperRawSampleDTO.encode(perHopSnrs: event.perHopSnrs),
      repeaterHexID: event.repeaterHexID,
      repeaterPublicKey: event.repeaterPublicKey,
      wasFocused: event.wasFocused,
      latitude: event.latitude,
      longitude: event.longitude,
      horizontalAccuracyMeters: event.horizontalAccuracyMeters,
      speedMetersPerSecond: event.speedMetersPerSecond,
      courseDegrees: event.courseDegrees,
      fixAgeSeconds: event.fixAgeSeconds,
      cellRaw: event.cellRaw.map { Int64(bitPattern: $0) },
      gateOutcomeRaw: event.gateOutcome.rawValue
    )
  }
}

// MARK: - Run DTO

/// Sendable snapshot of a ``MapperSurveyRun`` row.
///
/// **Deliberately not `Codable`**, and for a sharper reason than the aggregate store's
/// DTOs have. This type is the header of a precise movement log: ride start and end
/// instants, the radio that flew it, the repeaters that were locked on. A synthesised
/// conformance would make `JSONEncoder().encode(runs)` compile anywhere this module is
/// linked, and §2.8 says the *only* encoder that may exist is the explicit, field-by-field
/// one in the app target — the one whose default tier scrubs coordinates, trims the
/// endpoints and drops the radio config, and whose full-raw tier sits behind a debug
/// confirmation. Making the easy path not compile is what keeps that promise mechanical
/// rather than remembered.
public struct MapperSurveyRunDTO: Sendable, Equatable {
  public let id: UUID
  public let startedAt: Date
  public let endedAt: Date?
  public let radioID: UUID?

  public let frequency: UInt32?
  public let bandwidth: UInt32?
  public let spreadingFactor: UInt8?
  public let codingRate: UInt8?
  public let txPower: Int8?

  public let probesSent: Int
  public let tracesSent: Int
  public let discoversSent: Int
  public let repliesHeard: Int
  public let probesLost: Int
  public let cellsProbed: Int
  public let sampleCount: Int

  public let focusTargetHexIDs: [String]

  public init(
    id: UUID,
    startedAt: Date,
    endedAt: Date? = nil,
    radioID: UUID? = nil,
    frequency: UInt32? = nil,
    bandwidth: UInt32? = nil,
    spreadingFactor: UInt8? = nil,
    codingRate: UInt8? = nil,
    txPower: Int8? = nil,
    probesSent: Int = 0,
    tracesSent: Int = 0,
    discoversSent: Int = 0,
    repliesHeard: Int = 0,
    probesLost: Int = 0,
    cellsProbed: Int = 0,
    sampleCount: Int = 0,
    focusTargetHexIDs: [String] = []
  ) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.radioID = radioID
    self.frequency = frequency
    self.bandwidth = bandwidth
    self.spreadingFactor = spreadingFactor
    self.codingRate = codingRate
    self.txPower = txPower
    self.probesSent = probesSent
    self.tracesSent = tracesSent
    self.discoversSent = discoversSent
    self.repliesHeard = repliesHeard
    self.probesLost = probesLost
    self.cellsProbed = cellsProbed
    self.sampleCount = sampleCount
    self.focusTargetHexIDs = focusTargetHexIDs
  }

  init(from model: MapperSurveyRun) {
    self.init(
      id: model.id,
      startedAt: model.startedAt,
      endedAt: model.endedAt,
      radioID: model.radioID,
      frequency: model.frequency,
      bandwidth: model.bandwidth,
      spreadingFactor: model.spreadingFactor,
      codingRate: model.codingRate,
      txPower: model.txPower,
      probesSent: model.probesSent,
      tracesSent: model.tracesSent,
      discoversSent: model.discoversSent,
      repliesHeard: model.repliesHeard,
      probesLost: model.probesLost,
      cellsProbed: model.cellsProbed,
      sampleCount: model.sampleCount,
      focusTargetHexIDs: Self.decode(focusTargetHexIDs: model.focusTargetHexIDsData)
    )
  }

  /// Duration of the ride, once it has one. Nil for a run still open — which after a
  /// crash means "not yet reconciled", not "still riding".
  public var duration: TimeInterval? {
    endedAt.map { $0.timeIntervalSince(startedAt) }
  }

  // MARK: - JSON column

  /// Sorted keys so an unchanged focus set encodes to identical bytes run to run, which
  /// keeps diffing a store dump meaningful — the idiom
  /// ``MapperCellObservationDTO`` uses for its own columns.
  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  /// The one serialization that exists for a focus set, and it is a *storage column*
  /// codec, not a wire one. A malformed column yields an empty set rather than losing
  /// the run: the counters and the samples are still good data.
  static func encode(focusTargetHexIDs: [String]) -> Data {
    (try? encoder.encode(focusTargetHexIDs)) ?? Data()
  }

  static func decode(focusTargetHexIDs data: Data) -> [String] {
    guard !data.isEmpty else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
  }
}

// MARK: - Sample DTO

/// Sendable snapshot of a ``MapperRawSample`` row: what leaves the store actor.
///
/// **Deliberately not `Codable`** — see ``MapperSurveyRunDTO``. This one carries the
/// coordinate, the speed, the course and the full repeater key of a single moment on a
/// ride; it is the most sensitive shape in the app, and the only egress it is allowed is
/// the app target's explicit export encoder (§2.8), which chooses each field it emits
/// and scrubs by default. `JSONEncoder().encode(samples)` must not be a thing anybody can
/// type by accident.
///
/// Enum-valued columns are exposed as their raw `Int`s with typed accessors alongside, so
/// a row written by a future build — a kind this build has never heard of — survives a
/// read/export round trip instead of being dropped or, worse, mislabelled.
public struct MapperRawSampleDTO: Sendable, Equatable {
  public let runID: UUID
  public let seq: Int64
  public let timestamp: Date
  public let kindRaw: Int

  public let rxSnr: Double?
  public let txSnr: Double?
  public let rssi: Int?
  public let hopCount: Int?
  public let rttMs: Int?
  public let routeTypeRaw: Int?
  public let payloadTypeRaw: Int?
  public let perHopSnrs: [Double]?

  public let repeaterHexID: String?
  public let repeaterPublicKey: Data?
  public let wasFocused: Bool

  public let latitude: Double?
  public let longitude: Double?
  public let horizontalAccuracyMeters: Double?
  public let speedMetersPerSecond: Double?
  public let courseDegrees: Double?
  public let fixAgeSeconds: Double?

  /// The H3 index, converted back from the row's stored bit pattern. See
  /// ``MapperRawSample/cellRaw`` for why storage and DTO disagree about signedness.
  public let cellRaw: UInt64?
  public let gateOutcomeRaw: Int

  public init(
    runID: UUID,
    seq: Int64,
    timestamp: Date,
    kindRaw: Int,
    rxSnr: Double? = nil,
    txSnr: Double? = nil,
    rssi: Int? = nil,
    hopCount: Int? = nil,
    rttMs: Int? = nil,
    routeTypeRaw: Int? = nil,
    payloadTypeRaw: Int? = nil,
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
    gateOutcomeRaw: Int
  ) {
    self.runID = runID
    self.seq = seq
    self.timestamp = timestamp
    self.kindRaw = kindRaw
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
    self.gateOutcomeRaw = gateOutcomeRaw
  }

  init(from model: MapperRawSample) {
    self.init(
      runID: model.runID,
      seq: model.seq,
      timestamp: model.timestamp,
      kindRaw: model.kindRaw,
      rxSnr: model.rxSnr,
      txSnr: model.txSnr,
      rssi: model.rssi,
      hopCount: model.hopCount,
      rttMs: model.rttMs,
      routeTypeRaw: model.routeTypeRaw,
      payloadTypeRaw: model.payloadTypeRaw,
      perHopSnrs: Self.decode(perHopSnrs: model.perHopSnrsData),
      repeaterHexID: model.repeaterHexID,
      repeaterPublicKey: model.repeaterPublicKey,
      wasFocused: model.wasFocused,
      latitude: model.latitude,
      longitude: model.longitude,
      horizontalAccuracyMeters: model.horizontalAccuracyMeters,
      speedMetersPerSecond: model.speedMetersPerSecond,
      courseDegrees: model.courseDegrees,
      fixAgeSeconds: model.fixAgeSeconds,
      cellRaw: model.cellRaw.map { UInt64(bitPattern: $0) },
      gateOutcomeRaw: model.gateOutcomeRaw
    )
  }

  // MARK: - Typed accessors

  /// Nil for a raw value this build has no case for — a forward-compatible row, not a
  /// corrupt one.
  public var kind: MapperRawSampleKind? {
    MapperRawSampleKind(rawValue: kindRaw)
  }

  public var gateOutcome: MapperGateOutcome? {
    MapperGateOutcome(rawValue: gateOutcomeRaw)
  }

  // MARK: - JSON column

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  /// Nil in, nil out: "no per-hop array" and "an empty per-hop array" are different
  /// claims about a trace reply and must not collapse into each other.
  static func encode(perHopSnrs: [Double]?) -> Data? {
    guard let perHopSnrs else { return nil }
    return (try? encoder.encode(perHopSnrs)) ?? Data()
  }

  static func decode(perHopSnrs data: Data?) -> [Double]? {
    guard let data else { return nil }
    guard !data.isEmpty else { return [] }
    return (try? JSONDecoder().decode([Double].self, from: data)) ?? []
  }
}
