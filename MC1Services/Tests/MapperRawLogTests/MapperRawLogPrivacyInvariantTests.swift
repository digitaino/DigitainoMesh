import Foundation
@testable import MapperRawLog
import MC1Services
import SwiftData
import Testing

/// The raw ride log's privacy rules (docs/ACTIVE_SURVEY_M3_5.md §3, review findings F1/F2/
/// F3/F4), written as assertions rather than as prose somebody has to remember.
///
/// These are structural tests in the same spirit as `MapperPrivacyInvariantTests` on the
/// aggregate side, and they point the *opposite* way in one respect: the aggregate store
/// must not contain coordinates, and this one must. That divergence was decided once, with
/// a defence attached, and both directions are pinned so neither can drift into the other
/// by accident.
@Suite("Raw ride log privacy invariants")
struct MapperRawLogPrivacyInvariantTests {
  // MARK: - The tripwire

  /// Which MC1Services files are allowed to know that raw samples exist.
  ///
  /// `MapperRawSampleEvent.swift` declares the boundary; the capture and probe engines are
  /// the two emitters §2.4 names. Anything else mentioning `MapperRawSample` in MC1Services
  /// is, by the shape of this module, either an upload path reaching for raw rows or a
  /// step toward one.
  private static let allowedEmitters: Set<String> = [
    "MapperRawSampleEvent.swift",
    "SignalMapperCaptureEngine.swift",
    "SignalMapperProbeEngine.swift"
  ]

  @Test
  func `Only the named emitters in MC1Services mention raw samples`() throws {
    // This is the tripwire the whole module arrangement rests on, and it is worth being
    // explicit about what it does and does not catch.
    //
    // The dependency edge in Package.swift already makes it impossible for MC1Services to
    // *call into* MapperRawLog — that is a compile error, not a test. What it cannot stop
    // is MC1Services growing its own parallel notion of a raw sample: a DTO, a queue, an
    // "upload buffer" that quietly reconstructs the shape on the wrong side of the line.
    // Every such attempt has to spell the name somewhere, and this test fails the build
    // when it appears outside the three files that are supposed to have it.
    //
    // A future emitter is a deliberate edit to `allowedEmitters` with a reviewer looking
    // at it, which is exactly the friction wanted.
    let sourcesRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // MapperRawLogTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // MC1Services (package root)
      .appendingPathComponent("Sources/MC1Services", isDirectory: true)

    #expect(
      FileManager.default.fileExists(atPath: sourcesRoot.path),
      "MC1Services sources not found at \(sourcesRoot.path); this test would pass vacuously"
    )

    let enumerator = try #require(
      FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
    )

    var mentions: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
      if contents.contains("MapperRawSample") {
        mentions.append(url.lastPathComponent)
      }
    }

    // Non-vacuity: the walk has to be finding the declaring file, or a broken path would
    // make an empty offender list look like a pass.
    #expect(
      mentions.contains("MapperRawSampleEvent.swift"),
      "the source walk found no reference at all, so this assertion proves nothing"
    )

    let offenders = mentions.filter { !Self.allowedEmitters.contains($0) }.sorted()
    #expect(
      offenders.isEmpty,
      """
      MC1Services files outside the allow-list reference MapperRawSample: \(offenders).
      Raw ride-log rows carry precise coordinates and full repeater keys and must stay \
      unreachable from the module M2 uploads out of (ACTIVE_SURVEY_M3_5.md §2.4, §6 F2).
      """
    )
  }

  // MARK: - The gate enum cannot express disc membership

  @Test
  func `The gate outcome enum has no anchor case`() {
    // §6 F4: a per-row "inside an anchor disc" label is a solvable oracle for the discs'
    // geometry — a handful of labelled points around a boundary recovers the centre and
    // the radius, which is the one thing about anchors that must never be recoverable.
    // The recorder is fed before anchor policy runs, and the enum it writes into has no
    // case to put the answer in even if somebody wired it the other way round.
    #expect(MapperGateOutcome.allCases.count == 5)

    let names = MapperGateOutcome.allCases.map { String(describing: $0).lowercased() }
    let offenders = names.filter { $0.contains("anchor") }
    #expect(offenders.isEmpty, "anchor-shaped gate outcomes: \(offenders)")

    // And the same names are the ones the design enumerates, so a rename cannot quietly
    // repurpose a case into a disc label.
    #expect(Set(names) == ["accepted", "nofix", "stalefix", "inaccuratefix", "movedsincecapture"])
  }

  // MARK: - The coordinate divergence, pinned in this direction

  @Test
  func `A raw sample row does have coordinate columns`() throws {
    // The mirror image of MC1ServicesTests' assertion that `MapperCellObservation` has
    // none. Both are deliberate. The aggregate store is what M2 uploads from and buckets
    // everything to a 174 m cell; the raw log is a session-scoped recording of the rider's
    // own ride, where the precision *is* the value (§3.1) and the containment is the
    // container, the retention and the module edge instead.
    //
    // Asserting it positively matters: someone hardening the app could "fix" this table by
    // dropping the coordinates, and would silently destroy the feature rather than fail a
    // test.
    let entity = try #require(
      MapperRawLogStore.schema.entities.first { $0.name == "MapperRawSample" }
    )
    let columns = Set(entity.properties.map(\.name))

    #expect(columns.contains("latitude"))
    #expect(columns.contains("longitude"))
    #expect(columns.contains("horizontalAccuracyMeters"))
    #expect(columns.contains("speedMetersPerSecond"))
    #expect(columns.contains("courseDegrees"))

    // The two columns §6 F1/F9 removed, asserted absent by name so re-adding one fails
    // here rather than in a review nobody schedules.
    #expect(!columns.contains("packetHash"))
    #expect(!columns.contains("repeaterName"))
    #expect(
      columns.filter { $0.lowercased().contains("name") }.isEmpty,
      "a name-shaped column appeared on the raw sample row"
    )
  }

  // MARK: - The hash columns, and where they are allowed to be non-nil

  /// **Superseded invariant, 2026-09-03.** This suite used to assert that no
  /// `contentHash` column existed at all — the strongest reading of ACTIVE_SURVEY_M3_5
  /// §6 F1, which refused any mesh-wide packet identity on a raw row because it is a
  /// cross-mesh join key: an exported ride could be matched against a third party's RX
  /// log and de-anonymised.
  ///
  /// docs/SIGNAL_MAPPER_V3.md §2 and §9 narrow that refusal rather than dropping it. Two
  /// kinds now carry a hash, and only two:
  ///
  /// - `sent` — *our own* transmission. The hash identifies a packet we chose to put on
  ///   the air, under our own key, and it is what a `traces/{hash}` lookup needs. Joining
  ///   it against a stranger's log reveals that we transmitted, which the transmission
  ///   already did.
  /// - `observerSighting` — an observer's sighting of that same packet, fetched from
  ///   CoreScope. The hash *is* the join that produced the row; refusing to store it would
  ///   mean re-fetching to learn what we already know.
  ///
  /// On every other kind the hash would be F1's cross-mesh key over somebody else's
  /// traffic, so the column stays nil there, and that is what this test pins. The raw
  /// packet bytes (§9) are pinned the same way: they exist for scope's ingest and for
  /// re-decoding, on the kinds that *are* a received packet, and nowhere else — a `sent`
  /// row in particular never has them, because the firmware built the packet and never
  /// showed it to the app.
  @Test
  func `contentHash and rawHex survive only on the kinds allowed to carry them`() async throws {
    let at = Date(timeIntervalSince1970: 1_753_000_000)
    let (store, runID) = try await makeStoreWithRun(startedAt: at)

    // Every kind this build knows, each fed a hash *and* a packet body — an event shape no
    // real producer emits, precisely so the store's own scrubbing is what is measured
    // rather than the producers' good behaviour.
    let kinds = MapperRawSampleKind.allCases
    let events = kinds.map { kind in
      MapperRawSampleEvent(
        timestamp: at,
        kind: kind,
        pathHashes: ["0C", "42"],
        rawHex: Data([0x15, 0x00, 0xAB]),
        contentHash: "a1b2c3d4e5f60718",
        messageID: UUID(),
        gateOutcome: .accepted
      )
    }
    try await store.insertSamples(events, runID: runID, startingSeq: 0)

    let rows = try await store.fetchSamples(runID: runID, offset: 0, limit: kinds.count)
    #expect(rows.count == kinds.count, "the fixture must cover every kind, or this proves nothing")

    let hashAllowed: Set<MapperRawSampleKind> = [.sent, .observerSighting]
    // The list §2 spells out, restated here so widening `packetBearingKinds` fails on a
    // named case rather than on an abstract set comparison.
    let bytesRefused: Set<MapperRawSampleKind> = [
      .sent, .ackResolved, .breadcrumb, .radioLinkUp, .radioLinkDown,
      .probeAttempt, .observerSighting
    ]

    for row in rows {
      let kind = try #require(row.kind)
      if hashAllowed.contains(kind) {
        #expect(row.contentHash == "a1b2c3d4e5f60718", "\(kind) is one of the two kinds a hash belongs on")
      } else {
        #expect(row.contentHash == nil, "\(kind) kept a mesh-wide packet hash (§6 F1)")
      }

      if bytesRefused.contains(kind) {
        #expect(row.rawHex == nil, "\(kind) kept packet bytes it never had")
      }
      // The path hashes are not privileged: they are what the packet itself advertised to
      // every node it passed, and every kind may record them.
      #expect(row.pathHashes == ["0C", "42"])
    }

    // A `sent` row is the one place both halves meet: hash yes, bytes no.
    let sent = try #require(rows.first { $0.kind == .sent })
    #expect(sent.contentHash != nil)
    #expect(sent.rawHex == nil, "the firmware builds our packets; the app never sees their bytes")
  }

  // MARK: - The derived cache keeps none of what the rows keep

  @Test
  func `A cell summary is cells only — no coordinate, no identity, no hash`() throws {
    // SIGNAL_MAPPER_V3 §7 step 3 adds a *derived* table so the map does not scan hundreds
    // of thousands of rows. Derived is not a licence to widen: the raw row's coordinate is
    // defended by the container, the retention and the module edge (above), and a second
    // table repeating it would be a second thing to defend. A summary that answered "which
    // repeater" or "which packet" per cell would also be a per-hexagon association graph —
    // exactly the shape §6 F1/F9 refused on the row.
    let entity = try #require(
      MapperRawLogStore.schema.entities.first { $0.name == "MapperCellSummary" }
    )
    let columns = Set(entity.properties.map(\.name))

    #expect(columns.contains("cellRaw"))
    for forbidden in ["latitude", "longitude", "horizontalAccuracyMeters", "speedMetersPerSecond", "courseDegrees"] {
      #expect(!columns.contains(forbidden), "the summary grew a coordinate column: \(forbidden)")
    }
    #expect(!columns.contains("repeaterHexID"))
    #expect(!columns.contains("repeaterPublicKey"))
    #expect(!columns.contains("contentHash"))
    #expect(!columns.contains("rawHex"))
    #expect(
      columns.filter { $0.lowercased().contains("name") || $0.lowercased().contains("hash") }.isEmpty,
      "a name- or hash-shaped column appeared on the cell summary"
    )

    // And it cannot be serialised by accident either: a table of these is still "every
    // hexagon this phone has been in, and when" (§2.8).
    let summary: Any = MapperCellSummaryDTO(cellRaw: 0x0892_8308_280F_FFFF)
    #expect(!(summary is any Encodable))
    #expect(!(summary is any Decodable))
    #expect(((MapperCellSummaryDTO.self as Any) is any Encodable.Type) == false)
  }

  @Test
  func `The cache never disagrees with the rows`() async throws {
    // The property that makes a derived table safe to keep at all. Inserts fold
    // incrementally and deletes rebuild, which are two different code paths; a purge that
    // takes the row holding a maximum is where a decrement-based cache would quietly start
    // lying. Checked against a fold written from the spec (`independentSummary`), not
    // against the production folder, so this is a comparison and not a tautology.
    let now = Date(timeIntervalSince1970: 1_753_000_000)
    let old = now.addingTimeInterval(-120 * 86400)
    let store = try MapperRawLogStore.inMemory()

    // A first batch, half of it already outside retention, in two cells.
    try await store.insertSamples([
      cellEvent(at: old, kind: .passiveRx, cell: summaryCellA, hexID: "0C13", rxSnr: 14),
      cellEvent(at: old.addingTimeInterval(1), kind: .probeTraceReply, cell: summaryCellA, hexID: "0C13", rxSnr: 2, txSnr: 11),
      cellEvent(at: old.addingTimeInterval(2), kind: .passiveRx, cell: summaryCellB, hexID: "42AA", rxSnr: 5),
      cellEvent(at: now.addingTimeInterval(-3600), kind: .passiveRx, cell: summaryCellA, hexID: "0C13", rxSnr: 3)
    ], runID: nil, startingSeq: 0)

    // A second batch, so the incremental path runs over an existing summary.
    try await store.insertSamples([
      cellEvent(at: now.addingTimeInterval(-1800), kind: .txHeard, cell: summaryCellA, hexID: "0C13", rxSnr: 1, pathHashes: ["0C13"]),
      cellEvent(at: now.addingTimeInterval(-1700), kind: .probeAttempt, cell: summaryCellA, hexID: "0C13"),
      cellEvent(at: now.addingTimeInterval(-1600), kind: .sent, cell: summaryCellA),
      cellEvent(at: now.addingTimeInterval(-1500), kind: .passiveRx, cell: summaryCellA, hexID: nil, rxSnr: 18)
    ], runID: nil, startingSeq: 4)

    _ = try await store.purgeExpired(retentionDays: 90, now: now)

    let rows = try await allRows(store, from: old.addingTimeInterval(-1), to: now.addingTimeInterval(1))
    for cell in [summaryCellA, summaryCellB] {
      let stored = try await store.fetchCellSummary(cellRaw: cell)
      #expect(stored == independentSummary(of: rows, cellRaw: cell), "cell \(String(cell, radix: 16))")
    }
    // Cell B lost its only row to the purge and must be gone rather than zeroed.
    #expect(try await store.fetchCellSummaries().map(\.cellRaw) == [summaryCellA])

    // And a full rebuild from the rows lands on the same table.
    let beforeRebuild = try await store.fetchCellSummaries()
    _ = try await store.rebuildAllSummaries()
    #expect(try await store.fetchCellSummaries() == beforeRebuild)
  }

  @Test
  func `The raw log schema is disjoint from the chat store's`() {
    // §2.4: the raw entities live in this container only. Registering them in
    // `PersistenceStore.schema` would put a movement log in the backed-up chat database
    // and hand every existing query a JOIN surface into it.
    let rawNames = Set(MapperRawLogStore.schema.entities.map(\.name))
    let mainNames = Set(PersistenceStore.schema.entities.map(\.name))

    #expect(rawNames == ["MapperSurveyRun", "MapperRawSample", "MapperCellSummary"])
    #expect(rawNames.isDisjoint(with: mainNames))
  }

  // MARK: - The wire is not reachable by accident

  @Test
  func `The raw log DTOs expose no serialization of their own`() {
    // §2.8/§6 F2: the only encoder that may exist for these rows is the explicit one in
    // the app target, whose default tier rounds coordinates, trims the ride's endpoints
    // and truncates keys. A synthesised `Codable` would make `JSONEncoder().encode(rows)`
    // — a full-fidelity movement log, home address included — a one-liner.
    //
    // Compile-time absence cannot be asserted directly, so this checks it two ways: the
    // instance conformance (the mechanism `MapperPrivacyInvariantTests` uses) and the
    // metatype, which also catches a conditional conformance added elsewhere.
    let sample: Any = MapperRawSampleDTO(
      runID: UUID(),
      seq: 0,
      timestamp: Date(timeIntervalSince1970: 1_753_000_000),
      kindRaw: MapperRawSampleKind.breadcrumb.rawValue,
      latitude: 37.7749,
      longitude: -122.4194,
      gateOutcomeRaw: MapperGateOutcome.accepted.rawValue
    )
    #expect(!(sample is any Encodable))
    #expect(!(sample is any Decodable))

    let run: Any = MapperSurveyRunDTO(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_753_000_000))
    #expect(!(run is any Encodable))
    #expect(!(run is any Decodable))

    #expect(((MapperRawSampleDTO.self as Any) is any Encodable.Type) == false)
    #expect(((MapperSurveyRunDTO.self as Any) is any Encodable.Type) == false)
  }

  // MARK: - Backup exclusion

  @Test
  func `The on-disk store directory is excluded from backup`() throws {
    // §6 F3: raw GPS is only acceptable because the container it lands in does not ride
    // iCloud Backup. `live(directory:)` takes the path as a parameter precisely so this
    // can be checked against a real directory rather than asserted in a comment.
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("MapperRawLogTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try MapperRawLogStore.live(directory: directory)

    let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)

    // And the store really was created there — an exclusion flag on an empty directory
    // would prove nothing about where the rows went.
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("store.sqlite").path))
  }
}
