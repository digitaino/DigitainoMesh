import Foundation
import MC1Services
import os
import SwiftData

// MARK: - Errors

public enum MapperRawLogStoreError: Error, Sendable, Equatable {
  /// The store directory could not be marked as excluded from backup.
  ///
  /// Fatal on purpose. Backup exclusion is not a nicety here: it is the specific
  /// defence docs/ACTIVE_SURVEY_M3_5.md §6 F3 accepted in exchange for persisting raw
  /// coordinates at all. A raw ride log riding iCloud Backup is a movement diary
  /// leaving the device, so a store that cannot promise otherwise refuses to open —
  /// the failure direction is "no ride log", never "an unprotected one".
  case backupExclusionFailed(String)
  /// A run-scoped write named a run this store has never seen.
  case runNotFound
}

extension MapperRawLogStoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .backupExclusionFailed(reason): "Could not exclude the ride log from backup: \(reason)"
    case .runNotFound: "Survey run not found."
    }
  }
}

// MARK: - Store

/// The raw ride log's own SwiftData store: its own container, its own schema, its own
/// actor.
///
/// **Why a separate everything** (docs/ACTIVE_SURVEY_M3_5.md §2.4):
///
/// - *Own schema.* ``MapperSurveyRun`` and ``MapperRawSample`` are never registered in
///   `PersistenceStore.schema`. Nothing in the chat store can join against a ride, and
///   the aggregate mapper pipeline keeps its own coordinate-free shape (§3).
/// - *Own container, backup-excluded.* §6 F3 — the raw log must not land in iCloud
///   Backup beside the chat database.
/// - *Own actor.* §6 M12 — a 50 000-row export streaming through the shared
///   `PersistenceStore` would stall chat writes for seconds. This actor serialises
///   ride traffic and nothing else.
/// - *Own module.* The privacy guarantee that outranks all of the above lives in
///   `Package.swift`: MapperRawLog depends on MC1Services, so MC1Services importing it
///   back is a dependency cycle and does not compile. No upload code in MC1Services can
///   ever reach a raw row, by construction rather than by review.
///
/// Reads are paginated by design (``fetchSamples(runID:offset:limit:)``): the export
/// path in the app target streams to a file rather than materialising a whole ride.
@ModelActor
public actor MapperRawLogStore {
  /// The raw log's schema, and the whole of it.
  ///
  /// Deliberately disjoint from `PersistenceStore.schema` — see the type's note. If a
  /// raw entity ever appears in both, the module edge still holds but the "no
  /// cross-table JOIN surface" property does not, so keep them apart.
  /// ``MapperCellSummary`` joins them as a *derived* entity: rebuildable from the samples
  /// at any moment (SIGNAL_MAPPER_V3 §7 step 3), and in this schema rather than a second
  /// container because it must be written in the same transaction as the rows it folds.
  static let schema = Schema([
    MapperSurveyRun.self,
    MapperRawSample.self,
    MapperCellSummary.self
  ])

  /// How many rows one `save()` deletes at a time.
  ///
  /// A ride can hold `rawSampleCapPerSession` (50 000) rows and the purge runs at
  /// launch. Deleting them in one transaction would build a 50 000-object undo/change
  /// set in memory and hold the store through the whole thing; chunking keeps the peak
  /// bounded and lets a killed launch resume where it stopped (review M12).
  static let deleteChunkSize = 500

  /// Keys per `contains` predicate, well under SQLite's variable limit — the rule
  /// `PersistenceStore+BackupHelpers.fetchInChunks` states, restated here because that
  /// helper lives on the other side of the module edge.
  static let maxKeysPerFetch = 900

  private static let logger = Logger(subsystem: "MapperRawLog", category: "Store")

  /// Live subscribers to ``rowArrivals()``, one continuation each.
  ///
  /// A dictionary rather than a single continuation because the screen and a test can both
  /// be listening, and a shared `AsyncStream` would deliver each signal to exactly one of
  /// them. Entries remove themselves on termination, so a cancelled `.task` leaves nothing
  /// behind.
  private var arrivalContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

  /// Ends every subscription when the store goes away, so a `for await` over a stream from
  /// a dead store finishes instead of parking for the life of the process.
  deinit {
    for continuation in arrivalContinuations.values {
      continuation.finish()
    }
  }

  // MARK: - Construction

  /// Where the on-disk store lives: `Application Support/MapperRawLog/`.
  ///
  /// Application Support rather than Caches — the system may evict Caches mid-ride, and
  /// a ride log that vanishes under thermal pressure is worse than one that has to be
  /// purged on a schedule.
  public static var defaultDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("MapperRawLog", isDirectory: true)
  }

  /// Opens (creating if needed) the on-disk ride log.
  ///
  /// `directory` is a parameter rather than a constant so the backup-exclusion
  /// invariant is *testable*: the privacy test points it at a temporary directory and
  /// reads the resource value back. Production callers pass nothing.
  public static func live(directory: URL = MapperRawLogStore.defaultDirectory) throws -> MapperRawLogStore {
    try prepareDirectory(directory)
    let configuration = ModelConfiguration(
      schema: schema,
      url: directory.appendingPathComponent("store.sqlite"),
      allowsSave: true
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return MapperRawLogStore(modelContainer: container)
  }

  /// An ephemeral store for tests and previews. Same schema, same code paths, nothing
  /// on disk to exclude from anything.
  public static func inMemory() throws -> MapperRawLogStore {
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return MapperRawLogStore(modelContainer: container)
  }

  /// Creates the container directory and stamps the two file-system properties the
  /// design asks for.
  ///
  /// Order matters: both attributes are set on the **directory before** SwiftData
  /// creates anything inside it, because the sqlite file and its `-wal`/`-shm`
  /// companions inherit their data-protection class at creation time. Setting it
  /// afterwards would leave the write-ahead log — which is where the most recent
  /// minutes of a ride actually are — at the default class.
  private static func prepareDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    #if os(iOS)
      // §2.4 asks for `FileProtectionType.complete` "where SwiftData permits", and
      // `ModelConfiguration` permits nothing of the sort — the class has to come from
      // the enclosing directory. `.completeUnlessOpen` rather than `.complete` because
      // `.complete` makes every write fail the moment the screen locks, and the
      // recorder is forbidden from crashing a ride over a failed write: it would drop
      // the rows silently and the rider would find out at export time. Unless-open
      // gives the same at-rest protection while an open run keeps writing.
      // A failure here is logged, not fatal: the store still gets the platform default
      // (`.completeUntilFirstUserAuthentication`), which is not nothing.
      do {
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUnlessOpen],
          ofItemAtPath: directory.path
        )
      } catch {
        logger.warning("raw log data protection not applied: \(String(describing: type(of: error)), privacy: .public)")
      }
    #endif

    // OfflineMapService.excludeDatabaseFromBackup precedent, with the opposite failure
    // policy — see `MapperRawLogStoreError.backupExclusionFailed`.
    var url = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    do {
      try url.setResourceValues(values)
    } catch {
      throw MapperRawLogStoreError.backupExclusionFailed(error.localizedDescription)
    }
  }

  // MARK: - Runs

  /// Opens a run and returns its id. The id is the by-value foreign key every raw row
  /// carries, and the app's session object holds it for the ride's duration — across
  /// BLE rewires and engine generations (§2.6).
  public func createRun(
    radioID: UUID?,
    frequency: UInt32?,
    bandwidth: UInt32?,
    spreadingFactor: UInt8?,
    codingRate: UInt8?,
    txPower: Int8?,
    focusTargetHexIDs: [String],
    startedAt: Date
  ) throws -> UUID {
    let run = MapperSurveyRun(
      startedAt: startedAt,
      radioID: radioID,
      frequency: frequency,
      bandwidth: bandwidth,
      spreadingFactor: spreadingFactor,
      codingRate: codingRate,
      txPower: txPower,
      focusTargetHexIDsData: MapperSurveyRunDTO.encode(focusTargetHexIDs: focusTargetHexIDs)
    )
    modelContext.insert(run)
    try modelContext.save()
    return run.id
  }

  /// Stamps the end of a ride. Idempotent in effect — a second call overwrites with the
  /// later stamp, which is what an auto-end followed by a manual stop should produce.
  public func endRun(_ id: UUID, at endedAt: Date) throws {
    guard let run = try run(id) else { throw MapperRawLogStoreError.runNotFound }
    run.endedAt = endedAt
    try modelContext.save()
  }

  /// Adds counter **deltas** to a run.
  ///
  /// Additive rather than assigning, because the callers are engines that die: a BLE
  /// rewire tears down the probe engine, hands over what it counted, and a fresh engine
  /// starts counting from zero. Assignment would reset the ride to the newest engine's
  /// tally every time the radio blinked (§2.6).
  public func accumulateCounters(
    runID: UUID,
    probesSent: Int = 0,
    tracesSent: Int = 0,
    discoversSent: Int = 0,
    repliesHeard: Int = 0,
    probesLost: Int = 0,
    cellsProbed: Int = 0
  ) throws {
    guard let run = try run(runID) else { throw MapperRawLogStoreError.runNotFound }
    run.probesSent += probesSent
    run.tracesSent += tracesSent
    run.discoversSent += discoversSent
    run.repliesHeard += repliesHeard
    run.probesLost += probesLost
    run.cellsProbed += cellsProbed
    try modelContext.save()
  }

  /// Replaces the run's lock-on set. Wholesale rather than additive: the focus set is a
  /// *current* choice (≤3 targets), not a tally, and the rider changing their mind
  /// mid-ride must not leave the old target listed.
  public func updateFocusTargets(runID: UUID, hexIDs: [String]) throws {
    guard let run = try run(runID) else { throw MapperRawLogStoreError.runNotFound }
    run.focusTargetHexIDsData = MapperSurveyRunDTO.encode(focusTargetHexIDs: hexIDs)
    try modelContext.save()
  }

  /// Every run, newest first — the order a history list or an export picker wants.
  public func fetchRuns() throws -> [MapperSurveyRunDTO] {
    let descriptor = FetchDescriptor<MapperSurveyRun>(
      sortBy: [SortDescriptor(\MapperSurveyRun.startedAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor).map(MapperSurveyRunDTO.init(from:))
  }

  public func fetchRun(_ id: UUID) throws -> MapperSurveyRunDTO? {
    try run(id).map(MapperSurveyRunDTO.init(from:))
  }

  // MARK: - Samples

  /// Appends a batch of events as rows `startingSeq ..< startingSeq + events.count`, and
  /// bumps the run's `sampleCount` by the same amount.
  ///
  /// Sequence numbers are assigned here, from the base the recorder passes in, so one
  /// batch is one transaction and the numbering cannot interleave with another batch's.
  ///
  /// A batch naming an unknown run still writes its rows — the samples are the evidence
  /// and a missing header is no reason to throw them away — it just has no counter to
  /// bump. Losing rows is the one failure mode this module has no recovery for.
  /// `runID` is nil for the ordinary case since v3: the log is always on, and a ride is
  /// a label some of its rows happen to carry.
  public func insertSamples(_ events: [MapperRawSampleEvent], runID: UUID?, startingSeq: Int64) throws {
    guard !events.isEmpty else { return }
    for (offset, event) in events.enumerated() {
      modelContext.insert(
        MapperRawSample(event: event, runID: runID, seq: startingSeq + Int64(offset))
      )
    }
    if let runID {
      if let run = try run(runID) {
        run.sampleCount += events.count
      } else {
        Self.logger.warning("raw batch for an unknown run; rows kept, counter skipped")
      }
    }
    // The derived per-cell cache is folded here, inside the same transaction as the rows:
    // a summary that survived a save its rows did not would be the one kind of drift a
    // rebuild cannot notice, because both sides would look internally consistent.
    try foldIntoSummaries(events)
    try modelContext.save()
    // After the save, never inside it: a screen woken by this signal turns straight round
    // and reads, and it must not read a transaction that has not landed. One signal per
    // batch — the recorder already batches, and the card only needs to know *that*
    // something arrived (field report with screenshot, 2026-09-04: a ride wrote rows for
    // twenty-eight minutes while the card underneath said "Nothing heard here this ride",
    // because nothing but a 20 s timer ever asked again).
    notifyRowArrival()
  }

  /// A signal per batch of rows written, for a screen that has to repaint when the log
  /// grows under it.
  ///
  /// `Void` elements and `.bufferingNewest(1)`: the consumer's only question is "has
  /// anything landed since I last looked", and a burst of ten batches while it is busy
  /// must wake it once, not queue ten wake-ups. Consumers still coalesce on their own
  /// clock — this stream says *that* the log changed, never how much.
  public func rowArrivals() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    arrivalContinuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeArrivalContinuation(id) }
    }
    return stream
  }

  private func removeArrivalContinuation(_ id: UUID) {
    arrivalContinuations[id] = nil
  }

  private func notifyRowArrival() {
    for continuation in arrivalContinuations.values {
      continuation.yield()
    }
  }

  /// The sequence number a freshly built recorder must continue from.
  ///
  /// `seq` used to be run-local and every ride started at zero. Since v3 the table
  /// outlives every session, so a recorder built at launch has to pick up where the last
  /// one stopped — otherwise two app launches write overlapping numbers into one table and
  /// the ordering key stops ordering anything.
  ///
  /// One descending fetch of one row, once per launch, off the main actor. There is no
  /// index on `seq` alone and adding one would cost every insert for a query that runs
  /// once; the scan is the cheaper trade.
  public func nextSeq() throws -> Int64 {
    var descriptor = FetchDescriptor<MapperRawSample>(
      sortBy: [SortDescriptor(\MapperRawSample.seq, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    guard let highest = try modelContext.fetch(descriptor).first?.seq else { return 0 }
    return highest + 1
  }

  public func sampleCount(runID: UUID) throws -> Int {
    // Repo-wide #Predicate idiom: hoist the UUID to a local `let` first
    // (PersistenceStore+Messages.swift:47-50). A captured property or a member access
    // inside the macro body is what makes SwiftData fall back to loading rows.
    let target = runID
    let descriptor = FetchDescriptor<MapperRawSample>(
      predicate: #Predicate<MapperRawSample> { $0.runID == target }
    )
    return try modelContext.fetchCount(descriptor)
  }

  /// One page of a run's rows, in `seq` order.
  ///
  /// Paginated with no whole-run alternative on purpose (§2.8, review M12): a ride holds
  /// up to 50 000 rows, and a single fetch of those would hold this actor — and the
  /// export's caller — for seconds while building the array. The app target's encoder
  /// walks pages straight into the output file.
  public func fetchSamples(runID: UUID, offset: Int, limit: Int) throws -> [MapperRawSampleDTO] {
    guard limit > 0 else { return [] }
    let target = runID
    var descriptor = FetchDescriptor<MapperRawSample>(
      predicate: #Predicate<MapperRawSample> { $0.runID == target },
      sortBy: [SortDescriptor(\MapperRawSample.seq, order: .forward)]
    )
    descriptor.fetchOffset = max(0, offset)
    descriptor.fetchLimit = limit
    return try modelContext.fetch(descriptor).map(MapperRawSampleDTO.init(from:))
  }

  // MARK: - Cell and repeater queries (v3)

  /// Every row recorded in one hexagon within a half-open time window, newest first.
  ///
  /// The card's whole data source (SIGNAL_MAPPER_V3 §3): with aggregates gone, "what did
  /// this cell see" is this query and the `(cellRaw, timestamp)` index is what makes it
  /// affordable across 90 days. Newest-first because every consumer wants the recent end
  /// and stops early; `limit` bounds a dense cell to something a caller can hold.
  ///
  /// `until` is exclusive so consecutive windows tile without double-counting the instant
  /// they share.
  public func fetchSamples(
    cellRaw: UInt64,
    since: Date,
    until: Date,
    limit: Int
  ) throws -> [MapperRawSampleDTO] {
    guard limit > 0 else { return [] }
    let cell = Int64(bitPattern: cellRaw)
    let from = since
    let to = until
    var descriptor = FetchDescriptor<MapperRawSample>(
      predicate: #Predicate<MapperRawSample> {
        $0.cellRaw == cell && $0.timestamp >= from && $0.timestamp < to
      },
      sortBy: [SortDescriptor(\MapperRawSample.timestamp, order: .reverse)]
    )
    descriptor.fetchLimit = limit
    return try modelContext.fetch(descriptor).map(MapperRawSampleDTO.init(from:))
  }

  /// Every row *about* one repeater, newest first — optionally narrowed to one hexagon.
  ///
  /// The repeater-detail chart (§8): its RX and heard-us readings over time, in this cell
  /// or everywhere. `repeaterHexID` matches exactly rather than by
  /// `NodeHexID.identifiesSameNode`, because a predicate cannot express the bidirectional
  /// prefix rule; a caller that needs cross-width matching asks for each width it knows
  /// and merges, which is a decision about identity and belongs above the store.
  public func fetchSamples(
    repeaterHexID: String,
    cellRaw: UInt64?,
    since: Date,
    until: Date,
    limit: Int
  ) throws -> [MapperRawSampleDTO] {
    guard limit > 0 else { return [] }
    let hexID = repeaterHexID
    let from = since
    let to = until
    var descriptor: FetchDescriptor<MapperRawSample>
    if let cellRaw {
      let cell = Int64(bitPattern: cellRaw)
      descriptor = FetchDescriptor<MapperRawSample>(
        predicate: #Predicate<MapperRawSample> {
          $0.repeaterHexID == hexID && $0.cellRaw == cell && $0.timestamp >= from && $0.timestamp < to
        },
        sortBy: [SortDescriptor(\MapperRawSample.timestamp, order: .reverse)]
      )
    } else {
      descriptor = FetchDescriptor<MapperRawSample>(
        predicate: #Predicate<MapperRawSample> {
          $0.repeaterHexID == hexID && $0.timestamp >= from && $0.timestamp < to
        },
        sortBy: [SortDescriptor(\MapperRawSample.timestamp, order: .reverse)]
      )
    }
    descriptor.fetchLimit = limit
    return try modelContext.fetch(descriptor).map(MapperRawSampleDTO.init(from:))
  }

  /// Our own transmissions in a window, oldest first — optionally only those sent from
  /// one hexagon.
  ///
  /// The input to reach (§4): CoreScope lists a node's transmissions by public key and
  /// time, so the query it needs is "when did we transmit from here", and these rows are
  /// the answer. Oldest first because the caller turns them into one `since`/`until`
  /// request per cluster and reads them forward. Unbounded: a phone sends tens of packets
  /// an hour, not thousands, and a truncated list would silently under-report reach.
  public func fetchSentSamples(
    since: Date,
    until: Date,
    cellRaw: UInt64?
  ) throws -> [MapperRawSampleDTO] {
    let sentKind = MapperRawSampleKind.sent.rawValue
    let from = since
    let to = until
    let descriptor: FetchDescriptor<MapperRawSample>
    if let cellRaw {
      let cell = Int64(bitPattern: cellRaw)
      descriptor = FetchDescriptor<MapperRawSample>(
        predicate: #Predicate<MapperRawSample> {
          $0.kindRaw == sentKind && $0.cellRaw == cell && $0.timestamp >= from && $0.timestamp < to
        },
        sortBy: [SortDescriptor(\MapperRawSample.timestamp, order: .forward)]
      )
    } else {
      descriptor = FetchDescriptor<MapperRawSample>(
        predicate: #Predicate<MapperRawSample> {
          $0.kindRaw == sentKind && $0.timestamp >= from && $0.timestamp < to
        },
        sortBy: [SortDescriptor(\MapperRawSample.timestamp, order: .forward)]
      )
    }
    return try modelContext.fetch(descriptor).map(MapperRawSampleDTO.init(from:))
  }

  /// Every stored observer sighting of the named packets, oldest first.
  ///
  /// The second half of reach (§4): the caller takes the `contentHash`es off a cell's
  /// `sent` rows and asks who heard them. Rows are written once, when CoreScope is asked,
  /// so a second look at the same hexagon costs this query and no network at all — which
  /// is the whole reason the sightings are rows rather than a response object.
  ///
  /// Matching is exact, and deliberately so: the hash is what both sides computed over the
  /// same bytes, and a fuzzy match on a packet identity would be a way to attribute
  /// somebody else's traffic to us. Case is normalised by the caller's own set — the
  /// producers write what CoreScope returned.
  public func fetchObserverSightings(contentHashes: Set<String>) throws -> [MapperRawSampleDTO] {
    guard !contentHashes.isEmpty else { return [] }
    let sightingKind = MapperRawSampleKind.observerSighting.rawValue
    // `[String?]` rather than `[String]` because the column is optional and the predicate
    // has to compare like with like. Chunked on the shared helper's rule: a `contains`
    // predicate becomes one SQL parameter per key, and a heavy reach session can hold more
    // hashes than a caller would guess.
    let hashes: [String?] = contentHashes.sorted()
    var rows: [MapperRawSample] = []
    var index = 0
    while index < hashes.count {
      let end = Swift.min(index + Self.maxKeysPerFetch, hashes.count)
      let chunk = Array(hashes[index..<end])
      let descriptor = FetchDescriptor<MapperRawSample>(
        predicate: #Predicate<MapperRawSample> {
          $0.kindRaw == sightingKind && chunk.contains($0.contentHash)
        },
        sortBy: [SortDescriptor(\MapperRawSample.timestamp, order: .forward)]
      )
      try rows.append(contentsOf: modelContext.fetch(descriptor))
      index = end
    }
    return rows.map(MapperRawSampleDTO.init(from:))
  }

  /// Back-fills the mesh-wide packet identity onto the `sent` rows for one message.
  ///
  /// §2: the firmware builds the packet, so the app learns the hash only when the echo
  /// comes back. Every `sent` row carrying that `messageID` and no hash yet is stamped —
  /// plural because a resend transmits the same content again and each transmission is
  /// its own row.
  ///
  /// Rows that already carry a hash are left alone: the first echo is the authority, and
  /// a later one arriving with a different value would mean the correlation is wrong, not
  /// that the row should change.
  ///
  /// - Returns: how many rows were stamped.
  @discardableResult
  public func setContentHash(messageID: UUID, contentHash: String) throws -> Int {
    let target = messageID
    let sentKind = MapperRawSampleKind.sent.rawValue
    let descriptor = FetchDescriptor<MapperRawSample>(
      predicate: #Predicate<MapperRawSample> {
        $0.messageID == target && $0.kindRaw == sentKind && $0.contentHash == nil
      }
    )
    let rows = try modelContext.fetch(descriptor)
    guard !rows.isEmpty else { return 0 }
    for row in rows {
      row.contentHash = contentHash
    }
    try modelContext.save()
    return rows.count
  }

  // MARK: - Size

  /// Bytes one row costs on disk, including its share of the indexes.
  ///
  /// Measured, not guessed: "The per-row size estimate matches what a real store costs"
  /// in `MapperRawLogAlwaysOnTests` writes 5 000 rows of the widest production shape — a
  /// passive-RX row with a fix, a two-hop path, a 32-byte repeater key and 100 bytes of
  /// packet — into a real on-disk store and divides `store.sqlite` plus its `-wal` by the
  /// row count. That measured **403 bytes/row** on 2026-09-03 (macOS, SwiftData/sqlite as
  /// shipped); 400 is that figure rounded, and the test fails if reality drifts outside a
  /// generous band around it.
  ///
  /// Slightly pessimistic on purpose: breadcrumbs, ACKs and probe rows carry no packet
  /// bytes and cost well under half of this, so the readout over-states rather than
  /// under-states what the table is using.
  ///
  /// An estimate rather than a `SELECT` over row sizes because the honest question the
  /// Settings readout answers is "is this table costing me a gigabyte", and a per-row
  /// walk of 400 000 rows to answer it would cost more than the answer is worth.
  public static let approximateBytesPerRow = 400

  /// What the Settings size readout and the delete-older-than control read (§5).
  ///
  /// `oldest` is the retention story made concrete — "your data starts here" — and nil
  /// only when the table is empty.
  public func storageSummary() throws -> (rowCount: Int, oldest: Date?, approximateBytes: Int) {
    let rowCount = try modelContext.fetchCount(FetchDescriptor<MapperRawSample>())
    var oldestDescriptor = FetchDescriptor<MapperRawSample>(
      sortBy: [SortDescriptor(\MapperRawSample.timestamp, order: .forward)]
    )
    oldestDescriptor.fetchLimit = 1
    let oldest = try modelContext.fetch(oldestDescriptor).first?.timestamp
    return (rowCount, oldest, rowCount * Self.approximateBytesPerRow)
  }

  // MARK: - Maintenance

  /// Closes runs that were never stopped, stamping `endedAt` from the run's own last
  /// sample (or its start, for a run that recorded nothing).
  ///
  /// Jetsam and crashes are the normal case, not the exception: iOS kills a foreground
  /// app holding a live location stream and a BLE link whenever it feels like it, and
  /// `stopRun` never gets to run (§2.6). An open run is otherwise indistinguishable from
  /// an active one — retention would never expire it, and the recording indicator would
  /// claim a ride is in progress days later. Call this at launch, before starting a new
  /// run.
  ///
  /// `now` bounds the stamp: a sample carrying a skewed clock must not produce a run that
  /// ends in the future, which would then outlive every retention window.
  ///
  /// - Returns: how many runs were closed.
  @discardableResult
  public func reconcileOrphanRuns(now: Date) throws -> Int {
    let descriptor = FetchDescriptor<MapperSurveyRun>(
      predicate: #Predicate<MapperSurveyRun> { $0.endedAt == nil }
    )
    let orphans = try modelContext.fetch(descriptor)
    guard !orphans.isEmpty else { return 0 }

    for run in orphans {
      let last = try lastSampleTimestamp(runID: run.id) ?? run.startedAt
      run.endedAt = Swift.min(Swift.max(last, run.startedAt), now)
    }
    try modelContext.save()
    return orphans.count
  }

  /// Deletes runs whose end (or start, for a run with no end) is older than
  /// `retentionDays`, along with every row they own.
  ///
  /// `retentionDays == 0` is a **no-op**, not "expire everything": zero means keep
  /// forever, and §2.9 makes that an explicit user choice rather than the default
  /// precisely because a precise movement diary's analytic value decays in weeks while
  /// its exposure accrues indefinitely.
  ///
  /// Expiry is decided in Swift rather than in a `#Predicate` because the rule is
  /// `endedAt ?? startedAt` and there are a handful of runs — one per ride — so the
  /// fetch is cheap. The 50 000-row side is what gets chunked.
  ///
  /// - Returns: how many runs were purged. Rows are purged whether or not they belonged
  ///   to one — see below.
  @discardableResult
  public func purgeExpired(retentionDays: Int, now: Date) throws -> Int {
    guard retentionDays > 0 else { return 0 }
    let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)

    // A purge that starts with no cache must not end with a partial one. Every delete below
    // funnels through ``rebuildSummaries(cellsRaw:)``, which *inserts* a summary for a cell
    // that straddles the cutoff and still folds non-empty — and one such row is enough to
    // make the launch's ``rebuildAllSummariesIfEmpty()`` see a populated table and skip the
    // migration fold entirely, stranding every untouched hexagon's history off the map for
    // good. Restoring the emptiness the purge found is cheaper and safer than teaching four
    // delete paths to distinguish a rebuild from a first fold.
    let summariesWereEmpty = try modelContext.fetchCount(FetchDescriptor<MapperCellSummary>()) == 0

    // Rows first, by their own timestamp, whatever run they name (SIGNAL_MAPPER_V3 §2:
    // "90 days on the phone, oldest rows go"). Since v3 most rows have no `runID` at all,
    // and a purge that only walked run headers would have kept the always-on log forever
    // — the exact failure the retention promise exists to prevent. A run's own rows are
    // covered by the same sweep: they cannot be newer than the run that ended.
    try deleteSamples(olderThan: cutoff)

    let runs = try modelContext.fetch(FetchDescriptor<MapperSurveyRun>())
    let expired = runs.filter { ($0.endedAt ?? $0.startedAt) < cutoff }
    for run in expired {
      try deleteSamples(runID: run.id)
      modelContext.delete(run)
      try modelContext.save()
    }

    if summariesWereEmpty {
      try deleteAllSummaries()
    }
    return expired.count
  }

  /// Deletes every row older than `cutoff`, chunked like every other bulk delete here.
  ///
  /// Both the retention sweep's engine and §5's "delete rows older than" control, which
  /// is the user's own hand on the same lever. Run *headers* are untouched: a ride whose
  /// rows have aged out still happened, and its counters are the only record left of it.
  ///
  /// - Returns: how many rows were deleted.
  @discardableResult
  public func deleteSamples(olderThan cutoff: Date) throws -> Int {
    let limit = cutoff
    var deleted = 0
    var touched: Set<Int64> = []
    while true {
      var descriptor = FetchDescriptor<MapperRawSample>(
        predicate: #Predicate<MapperRawSample> { $0.timestamp < limit }
      )
      descriptor.fetchLimit = Self.deleteChunkSize
      let batch = try modelContext.fetch(descriptor)
      if batch.isEmpty { break }
      for row in batch {
        if let cellRaw = row.cellRaw { touched.insert(cellRaw) }
        modelContext.delete(row)
      }
      try modelContext.save()
      deleted += batch.count
    }
    // Every cell that lost a row is recomputed from what is left, rather than decremented:
    // see ``rebuildSummaries(cells:)`` for why a maximum cannot be subtracted.
    try rebuildSummaries(cellsRaw: touched)
    return deleted
  }

  /// Deletes one run and its rows. The per-ride half of the delete affordance §3.1
  /// promises next to delete-all.
  public func deleteRun(_ id: UUID) throws {
    try deleteSamples(runID: id)
    if let run = try run(id) {
      modelContext.delete(run)
    }
    try modelContext.save()
  }

  /// Deletes everything. Chunked for the same reason the purge is.
  public func deleteAll() throws {
    while true {
      var descriptor = FetchDescriptor<MapperRawSample>()
      descriptor.fetchLimit = Self.deleteChunkSize
      let batch = try modelContext.fetch(descriptor)
      if batch.isEmpty { break }
      for row in batch {
        modelContext.delete(row)
      }
      try modelContext.save()
    }

    let runs = try modelContext.fetch(FetchDescriptor<MapperSurveyRun>())
    for run in runs {
      modelContext.delete(run)
    }
    // Nothing is left to fold, so the derived table goes with the rows rather than being
    // rebuilt into a table of empty cells.
    try deleteAllSummaries()
    try modelContext.save()
  }

  // MARK: - Internals

  private func run(_ id: UUID) throws -> MapperSurveyRun? {
    let target = id
    var descriptor = FetchDescriptor<MapperSurveyRun>(
      predicate: #Predicate<MapperSurveyRun> { $0.id == target }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func lastSampleTimestamp(runID: UUID) throws -> Date? {
    let target = runID
    var descriptor = FetchDescriptor<MapperRawSample>(
      predicate: #Predicate<MapperRawSample> { $0.runID == target },
      sortBy: [SortDescriptor(\MapperRawSample.seq, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first?.timestamp
  }

  /// Deletes a run's rows ``deleteChunkSize`` at a time, saving between chunks.
  @discardableResult
  private func deleteSamples(runID: UUID) throws -> Int {
    let target = runID
    var deleted = 0
    var touched: Set<Int64> = []
    while true {
      var descriptor = FetchDescriptor<MapperRawSample>(
        predicate: #Predicate<MapperRawSample> { $0.runID == target }
      )
      descriptor.fetchLimit = Self.deleteChunkSize
      let batch = try modelContext.fetch(descriptor)
      if batch.isEmpty { break }
      for row in batch {
        if let cellRaw = row.cellRaw { touched.insert(cellRaw) }
        modelContext.delete(row)
      }
      try modelContext.save()
      deleted += batch.count
    }
    try rebuildSummaries(cellsRaw: touched)
    return deleted
  }
}
