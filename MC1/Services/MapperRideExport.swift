import Foundation
import MapperRawLog
import MC1Services

/// Errors the ride-log encoder can fail with.
///
/// Deliberately not `LocalizedError`: the scrubbed tier is reachable from the user-facing
/// share affordance, and a raw English string surfacing there would be an unlocalized
/// leak into a shipped screen. Callers decide how to present a failure.
enum MapperRideExportError: Error, Equatable {
  /// The export directory could not be marked as excluded from backup.
  ///
  /// Fatal for the same reason `MapperRawLogStoreError.backupExclusionFailed` is: the
  /// file about to be written is a precise movement log, and the failure direction has to
  /// be "no export" rather than "an export that rides iCloud Backup".
  case backupExclusionFailed(String)
  /// The output file could not be created.
  case fileCreationFailed(String)
}

/// The ride log's **only** encoder — the single place a ``MapperRawSampleDTO`` is allowed
/// to become bytes.
///
/// It lives in the app target on purpose (docs/ACTIVE_SURVEY_M3_5.md §2.8, review F2). The
/// raw DTOs are deliberately not `Codable`, so `JSONEncoder().encode(samples)` does not
/// compile anywhere in MC1Services or MapperRawLog; the field-by-field encoding below is
/// the only egress that exists, and every field it emits was chosen by hand.
///
/// **Why scrubbed is the default share path** (review F5). "Show my ride" typed into a
/// community chat is one gesture, and the raw log is the most sensitive shape in the app:
/// a full-precision export publishes, in that single gesture, the user's front door (the
/// ride starts and ends there), the full public keys of every repeater they touched, and a
/// radio-configuration fingerprint that ties the file to their hardware. None of that is
/// what the user meant to share — they meant to share where the signal went. So the
/// share-safe tier is not an option offered beside the raw one: it is what
/// ``scrubbedExport(run:store:)`` produces, coordinates rounded to ~110 m, the two
/// endpoints clipped away entirely, keys truncated to hash width, timestamps at minute
/// precision, no radio config, no gate outcomes, no identifiers. The full tier exists only
/// behind the debug panel and names itself `RAW-PRIVATE` so a file picked out of a share
/// sheet by mistake announces what it is.
///
/// Both tiers stream: reads are paginated at ``pageSize`` and each page is appended
/// straight to an open file handle, because a ride can hold `rawSampleCapPerSession`
/// (50 000) rows and materialising those as one array — or as one array of encoded
/// objects — is both a multi-second actor stall (review M12) and a memory spike on a phone
/// that is simultaneously holding a live location stream and a BLE link.
enum MapperRideExport {
  /// The wire-format marker written at the top of every file. Bumped only when the key
  /// set of either tier changes incompatibly.
  static let format = "pocketmesh-ride-v1"

  /// Rows fetched per page. Chosen to keep one page's peak well under a megabyte while
  /// making a 50 000-row ride 25 store round trips rather than 500.
  static let pageSize = 2000

  /// Radius around each endpoint whose samples the scrubbed tier deletes outright.
  ///
  /// The single highest-value privacy knob in the whole feature (§2.8): a ride log's first
  /// and last positioned samples are the user's front door, and rounding coordinates does
  /// nothing about them — a 110 m-quantised cluster at the start of every ride is still a
  /// home address. Clipping is not obfuscation; the rows are never written.
  static let endpointTrimMeters: Double = 500

  /// Decimal places kept on a scrubbed coordinate: ~110 m at the equator, and less in
  /// longitude the further from it — a street, not an address.
  static let scrubbedCoordinateDecimals = 3

  // MARK: - Export tiers

  /// The share-safe tier, and the default for every user-facing share (§2.8, review F5).
  ///
  /// Emits a closed key set: coordinates rounded to ``scrubbedCoordinateDecimals``, every
  /// sample within ``endpointTrimMeters`` of the run's first or last positioned sample
  /// dropped, minute-precision timestamps, `repeaterHexID` only (**never**
  /// `repeaterPublicKey`), and no radio configuration, gate outcomes, run id, `seq` or any
  /// other identifier. What survives is what the file is for: where the signal reached and
  /// how well.
  ///
  /// - Returns: a file URL in the backup-excluded export directory, named
  ///   `ride-<yyyy-MM-dd>-shared.json`. Call ``deleteExports()`` once the share sheet has
  ///   closed.
  static func scrubbedExport(run: MapperSurveyRunDTO, store: MapperRawLogStore) async throws -> URL {
    // The trim needs both endpoints before the first sample can be written, and the last
    // positioned sample is only known after the whole run has been read — so the scrubbed
    // tier pays for one extra streaming pass. Buffering the ride instead would defeat the
    // point of paginating at all.
    let anchors = try await endpointAnchors(runID: run.id, store: store)
    let url = try exportURL(for: run, suffix: "shared")
    try await write(run: run, store: store, anchors: anchors, to: url)
    return url
  }

  /// The full tier: every column at full precision, including raw coordinates, full
  /// repeater public keys, the radio-configuration snapshot, gate outcomes and the run
  /// UUID.
  ///
  /// Debug-panel only, behind a confirmation that enumerates the contents (§2.8). The
  /// `RAW-PRIVATE` in the filename is a deliberate warning label: this file is a precise
  /// movement diary and belongs on a laptop, not in a chat.
  static func fullExport(run: MapperSurveyRunDTO, store: MapperRawLogStore) async throws -> URL {
    let url = try exportURL(for: run, suffix: "RAW-PRIVATE")
    try await write(run: run, store: store, anchors: nil, to: url)
    return url
  }

  /// Removes the whole export directory.
  ///
  /// Callers invoke this after the share sheet closes: an export is a *copy* of the most
  /// sensitive store in the app sitting in a directory other processes can be handed URLs
  /// into, and it should exist for exactly as long as the share does. Silent by design —
  /// a failure to delete is not something to interrupt the user with, and the next export
  /// recreates the directory regardless.
  static func deleteExports() {
    try? FileManager.default.removeItem(at: directory)
  }

  // MARK: - Writing

  /// Streams one export to `url`. `anchors` non-nil selects the scrubbed tier — the trim
  /// anchors and the tier are the same decision, so they are the same parameter.
  private static func write(
    run: MapperSurveyRunDTO,
    store: MapperRawLogStore,
    anchors: EndpointAnchors?,
    to url: URL
  ) async throws {
    let scrubbed = anchors != nil
    let writer = try FileWriter(url: url)
    do {
      try writer.write(#"{"format":"\#(format)","scrubbed":\#(scrubbed),"run":"#)
      try writer.writeJSON(scrubbed ? scrubbedRunObject(run) : fullRunObject(run))
      try writer.write(#","samples":["#)

      var offset = 0
      var isFirstSample = true
      while true {
        let page = try await store.fetchSamples(runID: run.id, offset: offset, limit: pageSize)
        if page.isEmpty { break }
        for sample in page {
          let object: [String: JSONValue]? = if let anchors {
            scrubbedSampleObject(sample, anchors: anchors)
          } else {
            fullSampleObject(sample)
          }
          guard let object else { continue }
          if !isFirstSample { try writer.write(",") }
          isFirstSample = false
          try writer.writeJSON(object)
        }
        // A short page is the last page; `fetchSamples` returns rows in `seq` order and
        // the run is finished (or, mid-ride, growing only at the tail we just read).
        if page.count < pageSize { break }
        offset += page.count
      }

      try writer.write("]}")
      try writer.close()
    } catch {
      // Never leave a truncated export behind: half a JSON document in a share-able
      // directory is a file somebody can still pick up and send.
      writer.closeIgnoringErrors()
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  /// The value shapes the two tiers emit, and no others.
  ///
  /// A typed value rather than `[String: Any]`: `JSONSerialization` renders every double
  /// with 17 significant digits, so a coordinate deliberately rounded to three decimals
  /// would land in a *shared* file as `-3.7120000000000002` — numerically the rounded
  /// value, but a reader inspecting the file cannot tell that from unscrubbed precision,
  /// and a privacy promise nobody can verify by looking is worth much less.
  /// `JSONEncoder` writes the shortest round-tripping form (`-3.712`).
  private enum JSONValue: Encodable, Sendable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case strings([String])
    case doubles([Double])

    func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case let .string(value): try container.encode(value)
      case let .int(value): try container.encode(value)
      case let .int64(value): try container.encode(value)
      case let .double(value): try container.encode(value)
      case let .bool(value): try container.encode(value)
      case let .strings(value): try container.encode(value)
      case let .doubles(value): try container.encode(value)
      }
    }
  }

  /// Appends to an open file handle. A tiny type so the tier encoders can stay pure
  /// dictionary builders and the streaming lives in exactly one place.
  private struct FileWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder

    init(url: URL) throws {
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw MapperRideExportError.fileCreationFailed(url.lastPathComponent)
      }
      handle = try FileHandle(forWritingTo: url)
      encoder = JSONEncoder()
      // Sorted keys so two exports of the same ride are byte-identical — the property that
      // makes a key-set freeze test (§3) and a diff between two rides meaningful.
      encoder.outputFormatting = [.sortedKeys]
    }

    func write(_ text: String) throws {
      try handle.write(contentsOf: Data(text.utf8))
    }

    func writeJSON(_ object: [String: JSONValue]) throws {
      try handle.write(contentsOf: encoder.encode(object))
    }

    func close() throws {
      try handle.close()
    }

    func closeIgnoringErrors() {
      try? handle.close()
    }
  }

  // MARK: - Run encoding

  /// The scrubbed run header: durations and counts, no identity.
  ///
  /// No run UUID, no radio id and no radio configuration — the five LoRa parameters are a
  /// hardware fingerprint that would let two shared rides be tied to the same rig even
  /// after every coordinate has been rounded. The counters stay because they are the
  /// ride's summary and describe airtime, not the rider.
  private static func scrubbedRunObject(_ run: MapperSurveyRunDTO) -> [String: JSONValue] {
    var object: [String: JSONValue] = [
      "startedAt": .string(minuteTimestamp(run.startedAt)),
      "probesSent": .int(run.probesSent),
      "tracesSent": .int(run.tracesSent),
      "discoversSent": .int(run.discoversSent),
      "repliesHeard": .int(run.repliesHeard),
      "probesLost": .int(run.probesLost),
      "cellsProbed": .int(run.cellsProbed),
      // Deliberately *not* named `sampleCount`: it is how many rows the ride recorded, and
      // the `samples` array is shorter by however many the endpoint trim removed. A reader
      // comparing the two should see a discrepancy and know why.
      "recordedSampleCount": .int(run.sampleCount),
      "focusTargetHexIDs": .strings(run.focusTargetHexIDs),
      // Self-describing scrubbing: a recipient looking at a ride that starts half a
      // kilometre from anywhere needs to know that is deliberate, not a GPS failure.
      "coordinateDecimals": .int(scrubbedCoordinateDecimals),
      "endpointTrimMeters": .int(Int(endpointTrimMeters))
    ]
    if let endedAt = run.endedAt {
      object["endedAt"] = .string(minuteTimestamp(endedAt))
    }
    return object
  }

  /// The full run header: the DTO, whole.
  private static func fullRunObject(_ run: MapperSurveyRunDTO) -> [String: JSONValue] {
    var object: [String: JSONValue] = [
      "id": .string(run.id.uuidString),
      "startedAt": .string(fullTimestamp(run.startedAt)),
      "probesSent": .int(run.probesSent),
      "tracesSent": .int(run.tracesSent),
      "discoversSent": .int(run.discoversSent),
      "repliesHeard": .int(run.repliesHeard),
      "probesLost": .int(run.probesLost),
      "cellsProbed": .int(run.cellsProbed),
      "sampleCount": .int(run.sampleCount),
      "focusTargetHexIDs": .strings(run.focusTargetHexIDs)
    ]
    if let endedAt = run.endedAt { object["endedAt"] = .string(fullTimestamp(endedAt)) }
    if let radioID = run.radioID { object["radioID"] = .string(radioID.uuidString) }
    if let frequency = run.frequency { object["frequency"] = .int(Int(frequency)) }
    if let bandwidth = run.bandwidth { object["bandwidth"] = .int(Int(bandwidth)) }
    if let spreadingFactor = run.spreadingFactor { object["spreadingFactor"] = .int(Int(spreadingFactor)) }
    if let codingRate = run.codingRate { object["codingRate"] = .int(Int(codingRate)) }
    if let txPower = run.txPower { object["txPower"] = .int(Int(txPower)) }
    return object
  }

  // MARK: - Sample encoding

  /// One scrubbed sample, or nil if the endpoint trim swallowed it.
  ///
  /// The key set here is closed and deliberate. Absent, each for its own reason:
  /// `runID`/`seq` (identifiers; array order already carries the ordering),
  /// `repeaterPublicKey` (§3.3 — the raw store is the only place a full key may live),
  /// `horizontalAccuracyMeters`/`courseDegrees`/`fixAgeSeconds` (fix forensics that
  /// sharpen a rounded coordinate back up), `gateOutcome` (a per-row accept/reject label
  /// is fix-quality metadata the recipient cannot use and the rider did not offer), and
  /// `routeType`/`payloadType` (traffic metadata about the mesh, not about coverage).
  private static func scrubbedSampleObject(
    _ sample: MapperRawSampleDTO,
    anchors: EndpointAnchors
  ) -> [String: JSONValue]? {
    var object: [String: JSONValue] = [
      "kind": .string(kindName(sample)),
      "timestamp": .string(minuteTimestamp(sample.timestamp)),
      "wasFocused": .bool(sample.wasFocused)
    ]

    if let latitude = finite(sample.latitude), let longitude = finite(sample.longitude) {
      guard !anchors.trims(latitude: latitude, longitude: longitude) else { return nil }
      object["latitude"] = .double(rounded(latitude, decimals: scrubbedCoordinateDecimals))
      object["longitude"] = .double(rounded(longitude, decimals: scrubbedCoordinateDecimals))
      // The cell is emitted only alongside a coordinate that survived the trim. A row
      // carrying a cell but no coordinate cannot be trim-checked, and an H3 res-9 index is
      // a ~174 m location: shipping one unchecked would put the home cell back in the file
      // the trim just took it out of.
      if let cell = sample.cellRaw { object["cell"] = .string(h3String(cell)) }
    }

    if let speed = finite(sample.speedMetersPerSecond) {
      object["speedMetersPerSecond"] = .double(rounded(speed, decimals: 1))
    }
    if let rxSnr = finite(sample.rxSnr) { object["rxSnr"] = .double(rxSnr) }
    if let txSnr = finite(sample.txSnr) { object["txSnr"] = .double(txSnr) }
    if let rssi = sample.rssi { object["rssi"] = .int(rssi) }
    if let hopCount = sample.hopCount { object["hopCount"] = .int(hopCount) }
    if let rttMs = sample.rttMs { object["rttMs"] = .int(rttMs) }
    if let perHopSnrs = finite(sample.perHopSnrs) { object["perHopSnrs"] = .doubles(perHopSnrs) }
    if let hexID = sample.repeaterHexID { object["repeaterHexID"] = .string(hexID) }

    return object
  }

  /// One full-precision sample: every column the DTO carries, including the ones the
  /// scrubbed tier refuses.
  private static func fullSampleObject(_ sample: MapperRawSampleDTO) -> [String: JSONValue] {
    var object: [String: JSONValue] = [
      "runID": .string(sample.runID.uuidString),
      "seq": .int64(sample.seq),
      "timestamp": .string(fullTimestamp(sample.timestamp)),
      "kind": .string(kindName(sample)),
      "gateOutcome": .string(gateOutcomeName(sample)),
      "wasFocused": .bool(sample.wasFocused)
    ]

    if let rxSnr = finite(sample.rxSnr) { object["rxSnr"] = .double(rxSnr) }
    if let txSnr = finite(sample.txSnr) { object["txSnr"] = .double(txSnr) }
    if let rssi = sample.rssi { object["rssi"] = .int(rssi) }
    if let hopCount = sample.hopCount { object["hopCount"] = .int(hopCount) }
    if let rttMs = sample.rttMs { object["rttMs"] = .int(rttMs) }
    if let routeType = sample.routeTypeRaw { object["routeType"] = .int(routeType) }
    if let payloadType = sample.payloadTypeRaw { object["payloadType"] = .int(payloadType) }
    if let perHopSnrs = finite(sample.perHopSnrs) { object["perHopSnrs"] = .doubles(perHopSnrs) }

    if let hexID = sample.repeaterHexID { object["repeaterHexID"] = .string(hexID) }
    if let key = sample.repeaterPublicKey { object["repeaterPublicKey"] = .string(hexString(key)) }

    if let latitude = finite(sample.latitude) { object["latitude"] = .double(latitude) }
    if let longitude = finite(sample.longitude) { object["longitude"] = .double(longitude) }
    if let accuracy = finite(sample.horizontalAccuracyMeters) {
      object["horizontalAccuracyMeters"] = .double(accuracy)
    }
    if let speed = finite(sample.speedMetersPerSecond) { object["speedMetersPerSecond"] = .double(speed) }
    if let course = finite(sample.courseDegrees) { object["courseDegrees"] = .double(course) }
    if let fixAge = finite(sample.fixAgeSeconds) { object["fixAgeSeconds"] = .double(fixAge) }
    if let cell = sample.cellRaw { object["cell"] = .string(h3String(cell)) }

    return object
  }

  // MARK: - Enum names

  /// Case names rather than raw integers, so a file read six months from now does not need
  /// this build's source to be interpreted.
  ///
  /// Written as an exhaustive switch on purpose: `String(describing:)` would silently name
  /// a case added later, and a new raw-sample kind must be a deliberate decision to
  /// *publish* rather than something that appears in exports by itself. Unknown raw values
  /// — a row written by a newer build — degrade to `unknown-<raw>` instead of vanishing.
  private static func kindName(_ sample: MapperRawSampleDTO) -> String {
    guard let kind = sample.kind else { return "unknown-\(sample.kindRaw)" }
    switch kind {
    case .probeAttempt: return "probeAttempt"
    case .probeTraceReply: return "probeTraceReply"
    case .probeDiscoverResponse: return "probeDiscoverResponse"
    case .probeLost: return "probeLost"
    case .probeAbandoned: return "probeAbandoned"
    case .passiveRx: return "passiveRx"
    case .txHeard: return "txHeard"
    case .ackResolved: return "ackResolved"
    case .breadcrumb: return "breadcrumb"
    case .radioLinkDown: return "radioLinkDown"
    case .radioLinkUp: return "radioLinkUp"
    }
  }

  /// Full tier only — the scrubbed tier emits no gate outcomes at all.
  private static func gateOutcomeName(_ sample: MapperRawSampleDTO) -> String {
    guard let outcome = sample.gateOutcome else { return "unknown-\(sample.gateOutcomeRaw)" }
    switch outcome {
    case .accepted: return "accepted"
    case .noFix: return "noFix"
    case .staleFix: return "staleFix"
    case .inaccurateFix: return "inaccurateFix"
    case .movedSinceCapture: return "movedSinceCapture"
    }
  }

  // MARK: - Endpoint trim

  private struct Coordinate {
    let latitude: Double
    let longitude: Double
  }

  /// The run's first and last positioned samples — the two discs the scrubbed tier clips.
  private struct EndpointAnchors {
    var first: Coordinate?
    var last: Coordinate?

    /// True when the point falls inside **either** disc.
    ///
    /// Union, not intersection: on an out-and-back ride the two endpoints coincide and the
    /// distinction does not matter, but on a one-way ride an intersection test would keep
    /// both front doors in the file — which is the exact failure §2.8 exists to prevent.
    func trims(latitude: Double, longitude: Double) -> Bool {
      for anchor in [first, last] {
        guard let anchor else { continue }
        let distance = MapperRideExport.haversineMeters(
          latitude1: anchor.latitude,
          longitude1: anchor.longitude,
          latitude2: latitude,
          longitude2: longitude
        )
        if distance <= MapperRideExport.endpointTrimMeters { return true }
      }
      return false
    }
  }

  /// Streams the run once to find its first and last *positioned* samples.
  ///
  /// Positioned, not merely first and last: a ride that opens with a `noFix` breadcrumb or
  /// closes with a `radioLinkDown` marker must still be clipped at the real endpoints.
  private static func endpointAnchors(runID: UUID, store: MapperRawLogStore) async throws -> EndpointAnchors {
    var anchors = EndpointAnchors()
    var offset = 0
    while true {
      let page = try await store.fetchSamples(runID: runID, offset: offset, limit: pageSize)
      if page.isEmpty { break }
      for sample in page {
        guard let latitude = finite(sample.latitude), let longitude = finite(sample.longitude) else { continue }
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        if anchors.first == nil { anchors.first = coordinate }
        anchors.last = coordinate
      }
      if page.count < pageSize { break }
      offset += page.count
    }
    return anchors
  }

  /// Great-circle distance in meters on a sphere of the same mean radius `SurveyGrid` uses.
  ///
  /// A sphere is ample: the question asked of it is "inside 500 m or not", and the
  /// ellipsoidal correction is metres on that scale.
  private static func haversineMeters(
    latitude1: Double,
    longitude1: Double,
    latitude2: Double,
    longitude2: Double
  ) -> Double {
    let earthRadiusMeters = 6_371_007.2
    let radiansPerDegree = Double.pi / 180
    let deltaLatitude = (latitude2 - latitude1) * radiansPerDegree
    let deltaLongitude = (longitude2 - longitude1) * radiansPerDegree
    let a = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
      + cos(latitude1 * radiansPerDegree) * cos(latitude2 * radiansPerDegree)
      * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
    return 2 * earthRadiusMeters * atan2(sqrt(a), sqrt(max(0, 1 - a)))
  }

  // MARK: - Files

  /// Backup-excluded scratch directory the exports are written into.
  private static var directory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("MapperRideExport", isDirectory: true)
  }

  /// Creates the export directory and stamps the backup exclusion on it before anything is
  /// written inside, so no export file ever exists in a directory that is not yet excluded.
  private static func prepareDirectory() throws -> URL {
    var url = directory
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    do {
      try url.setResourceValues(values)
    } catch {
      throw MapperRideExportError.backupExclusionFailed(error.localizedDescription)
    }
    return url
  }

  /// `ride-<yyyy-MM-dd>-<suffix>.json`, replacing any file already there.
  ///
  /// Two rides on the same day collide by design: these files live only for the duration of
  /// one share sheet (``deleteExports()``), and a directory accumulating movement logs
  /// under near-identical names is worse than one that keeps the newest.
  private static func exportURL(for run: MapperSurveyRunDTO, suffix: String) throws -> URL {
    let directory = try prepareDirectory()
    let url = directory.appendingPathComponent(
      "ride-\(filenameDate(run.startedAt))-\(suffix).json",
      isDirectory: false
    )
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    return url
  }

  /// The ride's calendar day **in the rider's own time zone** — the filename is a human
  /// label ("my ride on the 29th"), while every timestamp inside the file is UTC. It leaks
  /// nothing the minute-precision timestamps do not already say.
  private static func filenameDate(_ date: Date) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }

  // MARK: - Formatting

  private static let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar
  }()

  /// Millisecond-precision ISO 8601 in UTC, for the full tier. Sub-second resolution is
  /// what makes RTT and per-hop ordering reconstructable, which is the tier's whole point.
  private static let fullTimestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  private static func fullTimestamp(_ date: Date) -> String {
    date.formatted(fullTimestampStyle)
  }

  /// `2026-08-29T21:14Z` — truncated to the minute, never rounded.
  ///
  /// Second-precision timestamps on a movement log are a fingerprint: they align a shared
  /// ride against any other timestamped record of the same afternoon. A minute is enough to
  /// tell a coverage story and coarse enough to make that alignment ambiguous.
  private static func minuteTimestamp(_ date: Date) -> String {
    let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(
      format: "%04d-%02d-%02dT%02d:%02dZ",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0,
      components.hour ?? 0,
      components.minute ?? 0
    )
  }

  /// Canonical H3 form: unpadded lowercase hex, the same string `h3ToString` produces.
  /// Emitted as text rather than a number because a 64-bit index is not safely
  /// representable in every JSON reader's number type.
  private static func h3String(_ cell: UInt64) -> String {
    String(cell, radix: 16)
  }

  private static func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private static func rounded(_ value: Double, decimals: Int) -> Double {
    let factor = pow(10.0, Double(decimals))
    return (value * factor).rounded() / factor
  }

  /// `JSONEncoder` throws on a non-finite double, and it throws *mid-file* — after the
  /// header and thousands of rows are already on disk. A NaN that reached the store from
  /// firmware must cost its own field, not the whole export.
  private static func finite(_ value: Double?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return value
  }

  /// All-or-nothing: dropping individual non-finite entries would silently renumber the
  /// hops, and a per-hop SNR array whose indices no longer match the path is worse than an
  /// absent one.
  private static func finite(_ values: [Double]?) -> [Double]? {
    guard let values, values.allSatisfy(\.isFinite) else { return nil }
    return values
  }
}
