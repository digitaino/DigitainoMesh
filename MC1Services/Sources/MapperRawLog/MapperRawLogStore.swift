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
  static let schema = Schema([
    MapperSurveyRun.self,
    MapperRawSample.self
  ])

  /// How many rows one `save()` deletes at a time.
  ///
  /// A ride can hold `rawSampleCapPerSession` (50 000) rows and the purge runs at
  /// launch. Deleting them in one transaction would build a 50 000-object undo/change
  /// set in memory and hold the store through the whole thing; chunking keeps the peak
  /// bounded and lets a killed launch resume where it stopped (review M12).
  static let deleteChunkSize = 500

  private static let logger = Logger(subsystem: "MapperRawLog", category: "Store")

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
  public func insertSamples(_ events: [MapperRawSampleEvent], runID: UUID, startingSeq: Int64) throws {
    guard !events.isEmpty else { return }
    for (offset, event) in events.enumerated() {
      modelContext.insert(
        MapperRawSample(event: event, runID: runID, seq: startingSeq + Int64(offset))
      )
    }
    if let run = try run(runID) {
      run.sampleCount += events.count
    } else {
      Self.logger.warning("raw batch for an unknown run; rows kept, counter skipped")
    }
    try modelContext.save()
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
  /// - Returns: how many runs were purged.
  @discardableResult
  public func purgeExpired(retentionDays: Int, now: Date) throws -> Int {
    guard retentionDays > 0 else { return 0 }
    let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)

    let runs = try modelContext.fetch(FetchDescriptor<MapperSurveyRun>())
    let expired = runs.filter { ($0.endedAt ?? $0.startedAt) < cutoff }
    guard !expired.isEmpty else { return 0 }

    for run in expired {
      try deleteSamples(runID: run.id)
      modelContext.delete(run)
      try modelContext.save()
    }
    return expired.count
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
    while true {
      var descriptor = FetchDescriptor<MapperRawSample>(
        predicate: #Predicate<MapperRawSample> { $0.runID == target }
      )
      descriptor.fetchLimit = Self.deleteChunkSize
      let batch = try modelContext.fetch(descriptor)
      if batch.isEmpty { break }
      for row in batch {
        modelContext.delete(row)
      }
      try modelContext.save()
      deleted += batch.count
    }
    return deleted
  }
}
