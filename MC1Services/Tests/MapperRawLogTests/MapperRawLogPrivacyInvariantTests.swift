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

  @Test
  func `The raw log schema is disjoint from the chat store's`() {
    // §2.4: the raw entities live in this container only. Registering them in
    // `PersistenceStore.schema` would put a movement log in the backed-up chat database
    // and hand every existing query a JOIN surface into it.
    let rawNames = Set(MapperRawLogStore.schema.entities.map(\.name))
    let mainNames = Set(PersistenceStore.schema.entities.map(\.name))

    #expect(rawNames == ["MapperSurveyRun", "MapperRawSample"])
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
