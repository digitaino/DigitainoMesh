import Foundation
@testable import MC1Services
import SQLite3
import SwiftData
import Testing

/// Migration trial for the Build 40 → v2 store upgrade.
///
/// These tests open a store seeded with **Build 40's actual schema** (via the legacy
/// branch's own model code) under v2's schema — the exact transition a fielded user's
/// database goes through on first launch after updating. They are gated on environment
/// variables pointing at seeded store files and skip silently when unset, so the suite
/// stays green in CI without fixtures:
///
/// - `TRIAL_STORE_URL` — a populated store covering every renamed (`deviceID`→`radioID`)
///   entity, the fork-only columns, and the survey tables.
/// - `TRIAL_DUPE_STORE_URL` — a store with two `TracePathRun` rows sharing one `id`,
///   exercising the unique constraint v2 adds (upstream v4→v5).
/// - `REAL_STORE_URL` — any real Build 40 store (e.g. pulled from a device); verified
///   generically by row-count preservation instead of fixture values.
///
/// Each test copies the fixture aside and migrates the copy, so seeded originals
/// survive reruns.
@Suite("Build 40 Migration Trial")
struct Build40MigrationTrialTests {
  private static let radioID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
  private static let contactID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
  private static let channelMsgID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!
  private static let sentMsgID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000004")!
  private static let sessionID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000005")!
  private static let notedRunID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000006")!

  /// Copies a seeded store (plus `-wal`/`-shm` and the external-binary `_SUPPORT`
  /// sidecar) into a fresh temp directory and returns the copy's URL.
  private func stageCopy(of original: URL) throws -> URL {
    let fm = FileManager.default
    let stage = fm.temporaryDirectory
      .appendingPathComponent("b40-trial-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)

    let name = original.lastPathComponent
    let sourceDir = original.deletingLastPathComponent()
    for suffix in ["", "-wal", "-shm"] {
      let source = sourceDir.appendingPathComponent(name + suffix)
      if fm.fileExists(atPath: source.path) {
        try fm.copyItem(at: source, to: stage.appendingPathComponent(name + suffix))
      }
    }
    let support = "." + (name as NSString).deletingPathExtension + "_SUPPORT"
    let supportURL = sourceDir.appendingPathComponent(support)
    if fm.fileExists(atPath: supportURL.path) {
      try fm.copyItem(at: supportURL, to: stage.appendingPathComponent(support))
    }
    return stage.appendingPathComponent(name)
  }

  private func openUnderV2Schema(_ url: URL) throws -> ModelContainer {
    let configuration = ModelConfiguration(
      schema: PersistenceStore.schema,
      url: url,
      allowsSave: true
    )
    return try ModelContainer(for: PersistenceStore.schema, configurations: [configuration])
  }

  @Test
  func `Build 40 store opens under the v2 schema with every seeded row intact`() throws {
    guard let path = ProcessInfo.processInfo.environment["TRIAL_STORE_URL"] else { return }

    let staged = try stageCopy(of: URL(fileURLWithPath: path))
    let container = try openUnderV2Schema(staged) // the migration moment
    let context = ModelContext(container)

    // Device — `radioID` here is a NEW v2 column (default UUID), backfilled later by
    // performRadioIDMigration; only the row itself must survive.
    let devices = try context.fetch(FetchDescriptor<Device>())
    #expect(devices.count == 1)
    #expect(devices.first?.id == Self.radioID)

    // Renamed column: Contact.deviceID → radioID must carry the Build 40 value.
    let contacts = try context.fetch(FetchDescriptor<Contact>())
    #expect(contacts.count == 1)
    #expect(contacts.first?.radioID == Self.radioID)
    #expect(contacts.first?.nickname == "Alpha")
    #expect(contacts.first?.isFavorite == true)

    // Fork-only Message columns re-added in v2 must read back Build 40's values.
    let messages = try context.fetch(FetchDescriptor<Message>())
    #expect(messages.count == 2)
    let channelMsg = try #require(messages.first { $0.id == Self.channelMsgID })
    #expect(channelMsg.radioID == Self.radioID)
    #expect(channelMsg.text == "see you at the meetup")
    #expect(channelMsg.senderNodeName == "AlphaNode")
    #expect(channelMsg.reactionSummary == "👍:2")
    #expect(channelMsg.userLatitude == 37.7749)
    #expect(channelMsg.userLongitude == -122.4194)
    #expect(channelMsg.txPowerDbm == 17)

    let reactions = try context.fetch(FetchDescriptor<Reaction>())
    #expect(reactions.count == 1)
    #expect(reactions.first?.radioID == Self.radioID)
    #expect(reactions.first?.sentMessageID == Self.sentMsgID)

    let traces = try context.fetch(FetchDescriptor<SavedTracePath>())
    #expect(traces.count == 1)
    #expect(traces.first?.radioID == Self.radioID)
    let runs = try context.fetch(FetchDescriptor<TracePathRun>())
    #expect(runs.count == 2)
    #expect(runs.first { $0.id == Self.notedRunID }?.note == "5 dBi antenna on the roof")

    // Dormant survey entities must keep their tables and rows.
    let sessions = try context.fetch(FetchDescriptor<SurveySession>())
    #expect(sessions.count == 1)
    #expect(sessions.first?.id == Self.sessionID)
    #expect(sessions.first?.radioID == Self.radioID)
    #expect(sessions.first?.name == "Sunday drive")
    let points = try context.fetch(FetchDescriptor<SignalSurveyPoint>())
    #expect(points.count == 25)
    #expect(points.allSatisfy { $0.radioID == Self.radioID })
    #expect(points.allSatisfy { $0.surveySessionID == Self.sessionID })
    #expect(points.count(where: \.isActiveProbe) == 13)

    // The remaining renamed entities, one row each.
    #expect(try context.fetch(FetchDescriptor<Channel>()).first?.radioID == Self.radioID)
    #expect(try context.fetch(FetchDescriptor<RxLogEntry>()).first?.radioID == Self.radioID)
    #expect(try context.fetch(FetchDescriptor<DiscoveredNode>()).first?.radioID == Self.radioID)
    #expect(try context.fetch(FetchDescriptor<RemoteNodeSession>()).first?.radioID == Self.radioID)
    #expect(try context.fetch(FetchDescriptor<BlockedChannelSender>()).first?.radioID == Self.radioID)
  }

  /// Row counts per Core Data table, read straight from the SQLite file before
  /// SwiftData ever touches it — the pre-migration ground truth.
  private func rawRowCounts(at url: URL, tables: [String]) throws -> [String: Int] {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
      throw StoreTrialError.cannotOpenRaw(url)
    }
    defer { sqlite3_close(db) }

    var counts: [String: Int] = [:]
    for table in tables {
      var statement: OpaquePointer?
      // A table absent from the source store (e.g. survey tables in a store that already
      // passed through the early-v2 schema) is created empty by the migration: expect 0.
      guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else {
        counts[table] = 0
        continue
      }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw StoreTrialError.unreadableTable(table)
      }
      counts[table] = Int(sqlite3_column_int64(statement, 0))
    }
    guard counts["ZMESSAGE", default: 0] > 0 || counts["ZDEVICE", default: 0] > 0 else {
      throw StoreTrialError.notAMeshCoreStore(url)
    }
    return counts
  }

  private enum StoreTrialError: Error {
    case cannotOpenRaw(URL)
    case unreadableTable(String)
    case notAMeshCoreStore(URL)
  }

  /// Runs a single-value COUNT-style query against the raw SQLite file.
  /// Reads the staged copy BEFORE `openUnderV2Schema` migrates it — call order matters.
  private func rawScalar(at url: URL, query: String) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
      throw StoreTrialError.cannotOpenRaw(url)
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
      throw StoreTrialError.unreadableTable(query)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw StoreTrialError.unreadableTable(query)
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  @Test
  func `A real Build 40 store opens under the v2 schema with all row counts preserved`() throws {
    guard let path = ProcessInfo.processInfo.environment["REAL_STORE_URL"] else { return }

    // Every Build 40 table, paired with the v2 fetch that must see the same rows.
    let staged = try stageCopy(of: URL(fileURLWithPath: path))
    let tables = [
      "ZDEVICE", "ZCONTACT", "ZMESSAGE", "ZMESSAGEREPEAT", "ZREACTION", "ZCHANNEL",
      "ZREMOTENODESESSION", "ZROOMMESSAGE", "ZSAVEDTRACEPATH", "ZTRACEPATHRUN",
      "ZRXLOGENTRY", "ZDEBUGLOGENTRY", "ZLINKPREVIEWDATA", "ZDISCOVEREDNODE",
      "ZNODESTATUSSNAPSHOT", "ZBLOCKEDCHANNELSENDER", "ZSURVEYSESSION", "ZSIGNALSURVEYPOINT"
    ]
    let before = try rawRowCounts(at: staged, tables: tables)
    let emptyNamesBefore = try rawScalar(
      at: staged,
      query: "SELECT COUNT(*) FROM ZCONTACT WHERE ZNAME IS NULL OR ZNAME = ''"
    )

    let migrationStart = ContinuousClock.now
    let container = try openUnderV2Schema(staged) // the migration moment
    let migrationDuration = ContinuousClock.now - migrationStart
    let context = ModelContext(container)

    func check<T: PersistentModel>(_ type: T.Type, _ table: String) throws {
      let after = try context.fetchCount(FetchDescriptor<T>())
      #expect(after == before[table], "\(table): \(before[table] ?? -1) rows before, \(after) after")
    }
    try check(Device.self, "ZDEVICE")
    try check(Contact.self, "ZCONTACT")
    try check(Message.self, "ZMESSAGE")
    try check(MessageRepeat.self, "ZMESSAGEREPEAT")
    try check(Reaction.self, "ZREACTION")
    try check(Channel.self, "ZCHANNEL")
    try check(RemoteNodeSession.self, "ZREMOTENODESESSION")
    try check(RoomMessage.self, "ZROOMMESSAGE")
    try check(SavedTracePath.self, "ZSAVEDTRACEPATH")
    try check(TracePathRun.self, "ZTRACEPATHRUN")
    try check(RxLogEntry.self, "ZRXLOGENTRY")
    try check(DebugLogEntry.self, "ZDEBUGLOGENTRY")
    try check(LinkPreviewData.self, "ZLINKPREVIEWDATA")
    try check(DiscoveredNode.self, "ZDISCOVEREDNODE")
    try check(NodeStatusSnapshot.self, "ZNODESTATUSSNAPSHOT")
    try check(BlockedChannelSender.self, "ZBLOCKEDCHANNELSENDER")
    try check(SurveySession.self, "ZSURVEYSESSION")
    try check(SignalSurveyPoint.self, "ZSIGNALSURVEYPOINT")

    // The rename must carry values, not just columns. Real stores legitimately hold
    // oddities (contacts with empty names from partial syncs), so assert preservation
    // of the oddity count (read pre-migration above) rather than cleanliness.
    let contacts = try context.fetch(FetchDescriptor<Contact>())
    #expect(contacts.count(where: { $0.name.isEmpty }) == emptyNamesBefore)
    let radioIDs = Set(try context.fetch(FetchDescriptor<Device>()).map(\.id))
    if !radioIDs.isEmpty {
      #expect(contacts.allSatisfy { radioIDs.contains($0.radioID) })
    }

    let total = before.values.reduce(0, +)
    print("[real-store trial] migrated \(total) rows across \(tables.count) tables in \(migrationDuration): \(before)")
  }

  @Test
  func `Duplicate TracePathRun ids surface as a throwing container open, not silent loss`() throws {
    guard let path = ProcessInfo.processInfo.environment["TRIAL_DUPE_STORE_URL"] else { return }

    let staged = try stageCopy(of: URL(fileURLWithPath: path))
    // v2 adds `.unique` to TracePathRun.id (upstream v4→v5); a Build 40 store with
    // duplicates cannot satisfy it. The open must throw — which the app now catches
    // with the store-recovery screen — rather than dropping rows silently.
    #expect(throws: (any Error).self) {
      _ = try openUnderV2Schema(staged)
    }
  }
}
