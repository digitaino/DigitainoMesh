import Foundation
import MapperRawLog
@testable import MC1
@testable import MC1Services
import Testing

/// The observation table's file (docs/SIGNAL_MAPPER_V3.md §5).
///
/// Three things are worth pinning here and nothing else is: the **column order**, because a
/// consumer reading position 7 as `fixAgeSeconds` breaks silently when a column moves; the
/// **escaping**, because a repeater called `K5TDC, "Solar"` is the single input that turns a
/// CSV into a corrupt one; and the **paging**, because the export walks a table larger than
/// one page and a cursor bug loses or repeats rows without failing anything.
///
/// Dates are fixed. A timestamp column asserted against `Date()` would be a test that passes
/// only in the second it was written.
///
/// **Serialized**, because the tests that actually write a file share one directory — the
/// backup-excluded `MapperRideExport` scratch directory the production code uses — and
/// `deleteExports()` removes that directory whole. Run in parallel, one test's cleanup would
/// delete another's file mid-write, and the failure would look like a paging bug.
@Suite("Mapper observation export", .serialized)
struct MapperObservationExportTests {
  /// 2025-09-02T06:40:00Z, chosen so the ISO 8601 string in the assertions is readable.
  private let at = Date(timeIntervalSince1970: 1_756_795_200)
  private let cell: UInt64 = 0x0892_8308_280F_FFFF

  // MARK: - Fixtures

  /// A row of a given kind with every column the kind can carry filled in, so a column-order
  /// assertion is about the order rather than about which fields happened to be nil.
  private func sample(
    kind: MapperRawSampleKind,
    seq: Int64 = 7,
    repeaterHexID: String? = "0C13",
    runID: UUID? = UUID(uuidString: "9F3C0D51-1E3B-4C55-9A22-6F5D0C1E2A34")
  ) -> MapperRawSampleDTO {
    MapperRawSampleDTO(
      runID: runID,
      seq: seq,
      timestamp: at,
      kindRaw: kind.rawValue,
      rxSnr: 6.25,
      txSnr: -3.5,
      rssi: -91,
      hopCount: 2,
      rttMs: 840,
      routeTypeRaw: 1,
      payloadTypeRaw: 4,
      perHopSnrs: [6.25, -3.5],
      pathHashes: ["0C", "42"],
      rawHex: Data([0x01, 0xAB, 0xFF]),
      contentHash: "0123456789ABCDEF",
      messageID: nil,
      repeaterHexID: repeaterHexID,
      repeaterPublicKey: Data([0xAB, 0xCD]),
      wasFocused: true,
      latitude: 30.2672,
      longitude: -97.7431,
      horizontalAccuracyMeters: 8,
      speedMetersPerSecond: 6.4,
      courseDegrees: 271.5,
      txPowerDbm: 22,
      fixAgeSeconds: 1.25,
      cellRaw: cell,
      gateOutcomeRaw: MapperGateOutcome.accepted.rawValue
    )
  }

  private var names: [String: String] {
    ["0C13": "Digitaino Central"]
  }

  // MARK: - Columns

  @Test
  func `The header names every §2 column, in one fixed order`() {
    #expect(MapperObservationExport.headerLine == """
    seq,timestamp,kind,runID,cell,latitude,longitude,horizontalAccuracyMeters,fixAgeSeconds,\
    payloadType,routeType,hopCount,pathHashes,repeaterHexID,repeaterName,repeaterPublicKey,\
    rxSnr,rssi,txSnr,perHopSnrs,contentHash,txPowerDbm,rttMs,rawHex
    """)
    #expect(MapperObservationExport.columns.count == 24)
  }

  @Test
  func `A row's values line up with the header, field for field`() {
    let values = MapperObservationExport.values(for: sample(kind: .passiveRx), repeaterNames: names)
    #expect(values.count == MapperObservationExport.columns.count)

    let row = Dictionary(uniqueKeysWithValues: zip(MapperObservationExport.columns, values))
    #expect(row["seq"] == "7")
    #expect(row["timestamp"] == "2025-09-02T06:40:00.000Z")
    #expect(row["kind"] == "passiveRx")
    #expect(row["runID"] == "9F3C0D51-1E3B-4C55-9A22-6F5D0C1E2A34")
    #expect(row["cell"] == "8928308280fffff")
    #expect(row["latitude"] == "30.2672")
    #expect(row["longitude"] == "-97.7431")
    #expect(row["horizontalAccuracyMeters"] == "8.0")
    #expect(row["fixAgeSeconds"] == "1.25")
    #expect(row["payloadType"] == "4")
    #expect(row["routeType"] == "1")
    #expect(row["hopCount"] == "2")
    #expect(row["pathHashes"] == "0C|42")
    #expect(row["repeaterHexID"] == "0C13")
    #expect(row["repeaterName"] == "Digitaino Central")
    #expect(row["repeaterPublicKey"] == "abcd")
    #expect(row["rxSnr"] == "6.25")
    #expect(row["rssi"] == "-91")
    #expect(row["txSnr"] == "-3.5")
    #expect(row["perHopSnrs"] == "6.25|-3.5")
    #expect(row["contentHash"] == "0123456789ABCDEF")
    #expect(row["txPowerDbm"] == "22")
    #expect(row["rttMs"] == "840")
    #expect(row["rawHex"] == "01abff")
  }

  @Test(arguments: MapperRawSampleKind.allCases)
  func `Every kind writes a row, named as the kind and never blank`(kind: MapperRawSampleKind) {
    let line = MapperObservationExport.csvLine(for: sample(kind: kind), repeaterNames: names)
    let fields = line.split(separator: ",", omittingEmptySubsequences: false)
    #expect(fields.count == MapperObservationExport.columns.count)
    // Third column is `kind`, and the name is the enum case — not a raw integer, which a file
    // read six months from now could not interpret without this build's source.
    #expect(fields[2] == MapperRideExport.kindName(sample(kind: kind)))
    #expect(!fields[2].isEmpty)
  }

  @Test
  func `A nil column is an empty field, not a sentinel`() {
    let bare = MapperRawSampleDTO(
      runID: nil,
      seq: 0,
      timestamp: at,
      kindRaw: MapperRawSampleKind.breadcrumb.rawValue,
      gateOutcomeRaw: MapperGateOutcome.noFix.rawValue
    )
    let values = MapperObservationExport.values(for: bare, repeaterNames: names)
    let row = Dictionary(uniqueKeysWithValues: zip(MapperObservationExport.columns, values))
    #expect(row["runID"] == "")
    #expect(row["cell"] == "")
    #expect(row["latitude"] == "")
    #expect(row["rxSnr"] == "")
    #expect(row["rssi"] == "")
    #expect(row["pathHashes"] == "")
    #expect(row["repeaterHexID"] == "")
    #expect(row["repeaterName"] == "")
    #expect(row["rawHex"] == "")
    #expect(row["seq"] == "0")
    #expect(row["kind"] == "breadcrumb")
  }

  @Test
  func `An unresolved hash exports an empty name rather than a guess`() {
    let values = MapperObservationExport.values(
      for: sample(kind: .passiveRx, repeaterHexID: "9999"),
      repeaterNames: names
    )
    let row = Dictionary(uniqueKeysWithValues: zip(MapperObservationExport.columns, values))
    #expect(row["repeaterHexID"] == "9999")
    #expect(row["repeaterName"] == "")
  }

  // MARK: - Escaping

  @Test
  func `RFC 4180: only a comma, a quote or a line break forces quoting`() {
    #expect(MapperObservationExport.csvField("Digitaino Central") == "Digitaino Central")
    #expect(MapperObservationExport.csvField("") == "")
    #expect(MapperObservationExport.csvField("-97.7431") == "-97.7431")
    #expect(MapperObservationExport.csvField("K5TDC, Solar") == "\"K5TDC, Solar\"")
    #expect(MapperObservationExport.csvField("K5TDC \"Solar\"") == "\"K5TDC \"\"Solar\"\"\"")
    #expect(MapperObservationExport.csvField("two\nlines") == "\"two\nlines\"")
    #expect(MapperObservationExport.csvField("carriage\rreturn") == "\"carriage\rreturn\"")
  }

  @Test
  func `A repeater name full of separators still leaves a parseable row`() {
    let line = MapperObservationExport.csvLine(
      for: sample(kind: .passiveRx),
      repeaterNames: ["0C13": "K5TDC, \"Solar\"\nRepeater"]
    )
    #expect(line.contains("\"K5TDC, \"\"Solar\"\"\nRepeater\""))
    // The name is one quoted field, so the row still has 23 unquoted commas.
    let outsideQuotes = line.split(separator: "\"", omittingEmptySubsequences: false)
      .enumerated()
      .filter { $0.offset.isMultiple(of: 2) }
      .map(\.element)
      .joined()
    #expect(outsideQuotes.filter { $0 == "," }.count == MapperObservationExport.columns.count - 1)
  }

  // MARK: - JSONL

  @Test
  func `A JSONL line is one object whose keys are the columns that had a value`() throws {
    let object = MapperObservationExport.jsonObject(for: sample(kind: .passiveRx), repeaterNames: names)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decoded = try JSONSerialization.jsonObject(with: encoder.encode(object)) as? [String: Any]
    let line = try #require(decoded)

    #expect(line["seq"] as? Int == 7)
    #expect(line["timestamp"] as? String == "2025-09-02T06:40:00.000Z")
    #expect(line["kind"] as? String == "passiveRx")
    #expect(line["cell"] as? String == "8928308280fffff")
    #expect(line["latitude"] as? Double == 30.2672)
    #expect(line["repeaterName"] as? String == "Digitaino Central")
    #expect(line["repeaterPublicKey"] as? String == "abcd")
    #expect(line["rawHex"] as? String == "01abff")
    // Lists stay lists in JSONL, where the CSV has to join them.
    #expect(line["pathHashes"] as? [String] == ["0C", "42"])
    #expect(line["perHopSnrs"] as? [Double] == [6.25, -3.5])
    // Every key the CSV has a column for, and no others: `wasFocused` and `gateOutcome` are
    // on the DTO but are not §2 columns, and must not appear.
    #expect(Set(line.keys).isSubset(of: Set(MapperObservationExport.columns)))
    #expect(line["wasFocused"] == nil)
    #expect(line["gateOutcome"] == nil)
    #expect(line["messageID"] == nil)
  }

  @Test
  func `An absent column is an omitted key, not a null`() {
    let bare = MapperRawSampleDTO(
      runID: nil,
      seq: 3,
      timestamp: at,
      kindRaw: MapperRawSampleKind.breadcrumb.rawValue,
      pathHashes: [],
      gateOutcomeRaw: MapperGateOutcome.noFix.rawValue
    )
    let object = MapperObservationExport.jsonObject(for: bare, repeaterNames: names)
    #expect(object["runID"] == nil)
    #expect(object["latitude"] == nil)
    #expect(object["repeaterHexID"] == nil)
    #expect(object["repeaterName"] == nil)
    // Nil and empty are different claims about a path field, and JSONL keeps them apart —
    // this row *had* a path field that decoded to no hops.
    #expect(object["pathHashes"] != nil)
  }

  // MARK: - Paging

  @Test
  func `A table larger than a page exports every row, once`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let rowCount = 12000
    // Written in batches so the fixture does not build one 12 000-object transaction, which
    // is the same reason the store's own writes are batched.
    var seq: Int64 = 0
    for batch in stride(from: 0, to: rowCount, by: 1000) {
      let events = (0..<1000).map { offset in
        MapperRawSampleEvent(
          timestamp: at.addingTimeInterval(Double(batch + offset)),
          kind: .passiveRx,
          rxSnr: 6.25,
          repeaterHexID: "0C13",
          latitude: 30.2672,
          longitude: -97.7431,
          cellRaw: cell,
          gateOutcome: .accepted
        )
      }
      try await store.insertSamples(events, runID: nil, startingSeq: seq)
      seq += Int64(events.count)
    }
    #expect(try await store.countSamples(matching: MapperSampleFilter()) == rowCount)
    #expect(rowCount > MapperObservationExport.pageSize)

    defer { MapperRideExport.deleteExports() }

    let csv = try await MapperObservationExport.export(
      matching: MapperSampleFilter(),
      format: .csv,
      repeaterNames: names,
      store: store,
      day: at
    )
    #expect(csv.lastPathComponent == "mapper-observations-\(MapperRideExport.filenameDate(at)).csv")
    let csvText = try String(contentsOf: csv, encoding: .utf8)
    let csvLines = csvText.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    #expect(csvLines.count == rowCount + 1)
    #expect(csvLines.first == MapperObservationExport.headerLine)
    // Every `seq` exactly once, in order: a cursor that repeated a page or skipped one would
    // still produce a plausible-looking file.
    let seqs = csvLines.dropFirst().map { String($0.split(separator: ",")[0]) }
    #expect(seqs == (0..<rowCount).map(String.init))

    let jsonl = try await MapperObservationExport.export(
      matching: MapperSampleFilter(),
      format: .jsonl,
      repeaterNames: names,
      store: store,
      day: at
    )
    #expect(jsonl.pathExtension == "jsonl")
    let jsonlText = try String(contentsOf: jsonl, encoding: .utf8)
    let jsonlLines = jsonlText.components(separatedBy: "\n").filter { !$0.isEmpty }
    #expect(jsonlLines.count == rowCount)
    // Every line parses on its own — the property that makes JSONL streamable.
    let first = try JSONSerialization.jsonObject(with: Data(jsonlLines[0].utf8)) as? [String: Any]
    #expect(first?["seq"] as? Int == 0)
    let last = try JSONSerialization.jsonObject(with: Data(jsonlLines[rowCount - 1].utf8)) as? [String: Any]
    #expect(last?["seq"] as? Int == Int(rowCount - 1))
  }

  @Test
  func `A filtered export writes exactly the rows the count promised`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let events: [MapperRawSampleEvent] = (0..<50).map { offset in
      MapperRawSampleEvent(
        timestamp: at.addingTimeInterval(Double(offset)),
        kind: offset.isMultiple(of: 5) ? .breadcrumb : .passiveRx,
        rxSnr: 6.25,
        repeaterHexID: offset.isMultiple(of: 5) ? nil : "0C13",
        cellRaw: cell,
        gateOutcome: .accepted
      )
    }
    try await store.insertSamples(events, runID: nil, startingSeq: 0)

    defer { MapperRideExport.deleteExports() }

    let filter = MapperSampleFilter(kinds: [.breadcrumb])
    let expected = try await store.countSamples(matching: filter)
    #expect(expected == 10)

    let url = try await MapperObservationExport.export(
      matching: filter,
      format: .csv,
      repeaterNames: names,
      store: store,
      day: at
    )
    let lines = try String(contentsOf: url, encoding: .utf8)
      .components(separatedBy: "\r\n")
      .filter { !$0.isEmpty }
    #expect(lines.count == expected + 1)
    #expect(lines.dropFirst().allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false)[2] == "breadcrumb" })
  }

  @Test
  func `An empty selection still writes a header, and JSONL writes an empty file`() async throws {
    let store = try MapperRawLogStore.inMemory()
    defer { MapperRideExport.deleteExports() }

    let csv = try await MapperObservationExport.export(
      matching: MapperSampleFilter(),
      format: .csv,
      repeaterNames: [:],
      store: store,
      day: at
    )
    #expect(try String(contentsOf: csv, encoding: .utf8) == MapperObservationExport.headerLine + "\r\n")

    let jsonl = try await MapperObservationExport.export(
      matching: MapperSampleFilter(),
      format: .jsonl,
      repeaterNames: [:],
      store: store,
      day: at
    )
    #expect(try String(contentsOf: jsonl, encoding: .utf8).isEmpty)
  }

  // MARK: - Names

  @Test
  func `Names resolve through the same path the card uses, once per hash`() {
    let key = Data([0x0C, 0x13, 0x99, 0x42] + Array(repeating: UInt8(0), count: 28))
    let candidate = AnyResolvableNode(
      TestResolvableNode(
        publicKey: key,
        lastAdvertTimestamp: UInt32(at.timeIntervalSince1970),
        recencyDate: at,
        resolvableName: "Digitaino Central"
      )
    )
    let resolved = MapperObservationExport.repeaterNames(
      for: ["0C13", "FFFF"],
      candidates: [candidate],
      now: at
    )
    #expect(resolved["0C13"] == "Digitaino Central")
    #expect(resolved["FFFF"] == nil)
  }
}

/// The minimum a resolver candidate has to be, so the name test does not need a contact row.
private struct TestResolvableNode: RepeaterResolvable {
  let publicKey: Data
  var latitude: Double = 0
  var longitude: Double = 0
  var hasLocation = false
  let lastAdvertTimestamp: UInt32
  let recencyDate: Date
  let resolvableName: String
  var expiresWhenStale = false
}
