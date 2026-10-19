import Foundation
import MapperRawLog
import MC1Services

/// The two shapes §5 offers: one row per observation, in the format the consumer's tooling
/// already reads.
///
/// CSV and JSONL rather than JSON because docs/SIGNAL_MAPPER_V3.md §0 records the consumer
/// as *undetermined*: both are line-oriented, so a 40 000-row file can be streamed out here
/// and streamed in there without either end holding the table, and neither commits the
/// project to a schema a later consumer would have to be talked out of.
enum MapperObservationExportFormat: String, CaseIterable, Identifiable, Sendable {
  case csv
  case jsonl

  var id: String {
    rawValue
  }

  var fileExtension: String {
    rawValue
  }

  /// Uppercased format names, deliberately not localized: "CSV" and "JSONL" are the file
  /// formats' own names and are the same in every locale the app ships.
  var displayName: String {
    rawValue.uppercased()
  }
}

/// The observation table's encoder: one row per observation, every column of
/// docs/SIGNAL_MAPPER_V3.md §2 (SIGNAL_MAPPER_V3 §5, §7 step 5).
///
/// **Not a second privacy tier.** ``MapperRideExport`` has two — a scrubbed one for sharing
/// a ride and a `RAW-PRIVATE` one for the debug panel — because "show my ride" is a gesture
/// aimed at other people. This file is not that gesture: it is the answer to "let me look at
/// my own data", reached from Settings, filtered by hand, and written at full precision on
/// purpose. It carries exact coordinates, full repeater keys and the packet bytes, which is
/// what makes it re-analysable, and it is the user's to hand to nobody or to a laptop. The
/// share sheet is how it leaves the phone and ``MapperRideExport/deleteExports()`` is what
/// takes it off disk afterwards.
///
/// Streams page by page through ``MapperRideExport/FileWriter``: 40 000 rows at ~400 bytes
/// is a file, not an array, and the store's own reads are paginated for the same reason
/// (review M12).
enum MapperObservationExport {
  /// Rows fetched — and encoded, and written — per page.
  ///
  /// One store round trip and one `write(2)` per page: at 5 000 rows a page peaks around a
  /// megabyte of buffer while making a 40 000-row export eight round trips rather than
  /// 40 000.
  static let pageSize = 5000

  /// The CSV column order, and the JSONL key set — one list so the two formats cannot drift.
  ///
  /// Order is identity first (`seq`, `timestamp`, `kind`, `runID`), then where we were, then
  /// what the packet was, then who the row is *about*, then the two measurement legs, then
  /// the payload-shaped extras. §2's table, read top to bottom, with `seq` and the resolved
  /// name added: `seq` because it is the correlation key the export must be able to reproduce
  /// its own order from, and `repeaterName` because a hash-width ID is unreadable and the
  /// name is not on the row (§6 F9 — names are resolved at export time, never persisted).
  static let columns: [String] = [
    "seq",
    "timestamp",
    "kind",
    "runID",
    "cell",
    "latitude",
    "longitude",
    "horizontalAccuracyMeters",
    "fixAgeSeconds",
    "payloadType",
    "routeType",
    "hopCount",
    "pathHashes",
    "repeaterHexID",
    "repeaterName",
    "repeaterPublicKey",
    "rxSnr",
    "rssi",
    "txSnr",
    "perHopSnrs",
    "contentHash",
    "txPowerDbm",
    "rttMs",
    "rawHex"
  ]

  /// RFC 4180's own line terminator. A reader that wants LF strips the CR; a reader that
  /// wants CRLF cannot invent it, so the strict spelling is the one that works everywhere.
  static let lineTerminator = "\r\n"

  /// Separates the entries of a list column in CSV, where a comma would need quoting and a
  /// semicolon collides with the European CSV dialect's field separator.
  static let listSeparator = "|"

  // MARK: - Export

  /// Writes the filtered table to a file and hands back its URL for the share sheet.
  ///
  /// - Parameters:
  ///   - repeaterNames: hash ID → resolved name, built once per export by
  ///     ``repeaterNames(for:candidates:resolver:now:)``. A hash with no entry exports an
  ///     empty name rather than a guess.
  ///   - day: the calendar day the filename carries. A parameter so the test suite can pin it.
  /// - Returns: a file URL in the backup-excluded export directory, named
  ///   `mapper-observations-<yyyy-MM-dd>.csv` / `.jsonl`. Call
  ///   ``MapperRideExport/deleteExports()`` once the share sheet has closed.
  static func export(
    matching filter: MapperSampleFilter,
    format: MapperObservationExportFormat,
    repeaterNames: [String: String],
    store: MapperRawLogStore,
    day: Date = Date()
  ) async throws -> URL {
    let url = try exportURL(format: format, day: day)
    let writer = try MapperRideExport.FileWriter(url: url)
    do {
      if format == .csv {
        try writer.write(headerLine + lineTerminator)
      }

      var cursor: Int64?
      while true {
        let page = try await store.fetchSamples(matching: filter, after: cursor, limit: pageSize)
        if page.isEmpty { break }
        var buffer = Data()
        for sample in page {
          switch format {
          case .csv:
            buffer.append(Data((csvLine(for: sample, repeaterNames: repeaterNames) + lineTerminator).utf8))
          case .jsonl:
            try buffer.append(writer.encodedJSON(jsonObject(for: sample, repeaterNames: repeaterNames)))
            buffer.append(0x0A)
          }
        }
        try writer.write(buffer)
        // A short page is the last page: `fetchSamples(matching:after:limit:)` returns rows in
        // `seq` order and the cursor has already passed everything before it.
        if page.count < pageSize { break }
        cursor = page.last?.seq
      }

      try writer.close()
    } catch {
      // Never leave a truncated export behind — half a table in a share-able directory is a
      // file somebody can still pick up and send, and its last row would be silently missing.
      writer.closeIgnoringErrors()
      try? FileManager.default.removeItem(at: url)
      throw error
    }
    return url
  }

  /// Resolves each hash ID once, through the same ``NodeIdentityResolving`` path the cell
  /// card uses, so a repeater is named identically on screen and in the file.
  ///
  /// Unresolved hashes are simply absent: §2's rule is that names are personal data resolved
  /// from the contact list at export time, and a hash nothing in the contact list answers to
  /// has no name to print. Ambiguity is not marked either — the card shows it because a user
  /// can act on it, while a file column reading `Digitaino Central?` would be a value nobody
  /// can parse.
  static func repeaterNames(
    for hexIDs: [String],
    candidates: [AnyResolvableNode],
    resolver: any NodeIdentityResolving = NodeIdentityResolver(),
    now: Date
  ) -> [String: String] {
    var names: [String: String] = [:]
    for hexID in hexIDs {
      guard let id = NodeHexID(hexID),
            let resolution = resolver.resolve(id, among: candidates, now: now) else { continue }
      names[hexID] = resolution.best.resolvableName
    }
    return names
  }

  // MARK: - CSV

  static var headerLine: String {
    columns.map(csvField).joined(separator: ",")
  }

  /// One CSV record, without its terminator.
  static func csvLine(for sample: MapperRawSampleDTO, repeaterNames: [String: String]) -> String {
    values(for: sample, repeaterNames: repeaterNames).map(csvField).joined(separator: ",")
  }

  /// RFC 4180 §2.6/2.7: a field containing a comma, a quote or a line break is enclosed in
  /// double quotes, and each embedded quote is doubled. Everything else is written bare —
  /// quoting every field would be legal too, and would make the file half again as large for
  /// a table whose columns are overwhelmingly numbers.
  static func csvField(_ value: String) -> String {
    guard value.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" || $0 == "\r" }) else {
      return value
    }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  /// The row's values in ``columns`` order. Nil is the empty field, everywhere, for every
  /// type — a CSV has no null, and a sentinel like `-1` in an SNR column would read as a
  /// measurement.
  static func values(for sample: MapperRawSampleDTO, repeaterNames: [String: String]) -> [String] {
    [
      String(sample.seq),
      MapperRideExport.fullTimestamp(sample.timestamp),
      MapperRideExport.kindName(sample),
      sample.runID?.uuidString ?? "",
      sample.cellRaw.map(MapperRideExport.h3String) ?? "",
      decimal(sample.latitude),
      decimal(sample.longitude),
      decimal(sample.horizontalAccuracyMeters),
      decimal(sample.fixAgeSeconds),
      integer(sample.payloadTypeRaw),
      integer(sample.routeTypeRaw),
      integer(sample.hopCount),
      // Nil and empty both render as an empty field: CSV cannot tell "no path field" from "a
      // path field with no hops", which JSONL can and does.
      sample.pathHashes.map { $0.joined(separator: listSeparator) } ?? "",
      sample.repeaterHexID ?? "",
      sample.repeaterHexID.flatMap { repeaterNames[$0] } ?? "",
      sample.repeaterPublicKey.map(MapperRideExport.hexString) ?? "",
      decimal(sample.rxSnr),
      integer(sample.rssi),
      decimal(sample.txSnr),
      MapperRideExport.finite(sample.perHopSnrs)
        .map { $0.map { String($0) }.joined(separator: listSeparator) } ?? "",
      sample.contentHash ?? "",
      integer(sample.txPowerDbm),
      integer(sample.rttMs),
      sample.rawHex.map(MapperRideExport.hexString) ?? ""
    ]
  }

  // MARK: - JSONL

  /// One JSONL object. Absent columns are **omitted keys**, not nulls — the same rule
  /// ``MapperRideExport``'s tiers follow, and the one that keeps "no path field" and "an
  /// empty path field" distinguishable, which the CSV cannot.
  static func jsonObject(
    for sample: MapperRawSampleDTO,
    repeaterNames: [String: String]
  ) -> [String: MapperRideExport.JSONValue] {
    var object: [String: MapperRideExport.JSONValue] = [
      "seq": .int64(sample.seq),
      "timestamp": .string(MapperRideExport.fullTimestamp(sample.timestamp)),
      "kind": .string(MapperRideExport.kindName(sample))
    ]

    if let runID = sample.runID { object["runID"] = .string(runID.uuidString) }
    if let cell = sample.cellRaw { object["cell"] = .string(MapperRideExport.h3String(cell)) }
    if let latitude = MapperRideExport.finite(sample.latitude) { object["latitude"] = .double(latitude) }
    if let longitude = MapperRideExport.finite(sample.longitude) { object["longitude"] = .double(longitude) }
    if let accuracy = MapperRideExport.finite(sample.horizontalAccuracyMeters) {
      object["horizontalAccuracyMeters"] = .double(accuracy)
    }
    if let fixAge = MapperRideExport.finite(sample.fixAgeSeconds) { object["fixAgeSeconds"] = .double(fixAge) }
    if let payloadType = sample.payloadTypeRaw { object["payloadType"] = .int(payloadType) }
    if let routeType = sample.routeTypeRaw { object["routeType"] = .int(routeType) }
    if let hopCount = sample.hopCount { object["hopCount"] = .int(hopCount) }
    if let pathHashes = sample.pathHashes { object["pathHashes"] = .strings(pathHashes) }
    if let hexID = sample.repeaterHexID {
      object["repeaterHexID"] = .string(hexID)
      if let name = repeaterNames[hexID] { object["repeaterName"] = .string(name) }
    }
    if let key = sample.repeaterPublicKey {
      object["repeaterPublicKey"] = .string(MapperRideExport.hexString(key))
    }
    if let rxSnr = MapperRideExport.finite(sample.rxSnr) { object["rxSnr"] = .double(rxSnr) }
    if let rssi = sample.rssi { object["rssi"] = .int(rssi) }
    if let txSnr = MapperRideExport.finite(sample.txSnr) { object["txSnr"] = .double(txSnr) }
    if let perHopSnrs = MapperRideExport.finite(sample.perHopSnrs) { object["perHopSnrs"] = .doubles(perHopSnrs) }
    if let contentHash = sample.contentHash { object["contentHash"] = .string(contentHash) }
    if let txPower = sample.txPowerDbm { object["txPowerDbm"] = .int(txPower) }
    if let rttMs = sample.rttMs { object["rttMs"] = .int(rttMs) }
    if let rawHex = sample.rawHex { object["rawHex"] = .string(MapperRideExport.hexString(rawHex)) }

    return object
  }

  // MARK: - Formatting

  /// Swift's shortest round-tripping decimal (`-97.7431`), never exponent-padded and never
  /// rounded: this file is the full-precision one, and a coordinate that changes when it is
  /// read back is not the observation that was recorded.
  private static func decimal(_ value: Double?) -> String {
    guard let value = MapperRideExport.finite(value) else { return "" }
    return String(value)
  }

  private static func integer(_ value: Int?) -> String {
    value.map(String.init) ?? ""
  }

  // MARK: - Files

  /// `mapper-observations-<yyyy-MM-dd>.<ext>`, replacing any file already there.
  ///
  /// Two exports on the same day collide by design, exactly as ``MapperRideExport`` intends:
  /// these files live for the duration of one share sheet, and a directory accumulating
  /// movement logs under near-identical names is worse than one that keeps the newest. The
  /// date is the rider's own calendar day, a human label; every timestamp inside is UTC.
  private static func exportURL(format: MapperObservationExportFormat, day: Date) throws -> URL {
    let directory = try MapperRideExport.prepareDirectory()
    let url = directory.appendingPathComponent(
      "mapper-observations-\(MapperRideExport.filenameDate(day)).\(format.fileExtension)",
      isDirectory: false
    )
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    return url
  }
}
