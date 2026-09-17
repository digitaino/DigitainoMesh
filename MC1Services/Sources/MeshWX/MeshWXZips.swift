import Foundation
import OSLog
import Synchronization

// MARK: - ZIP codes (spec §9 `zips.json`, §11)

/// A US ZIP code from `zips.json`: the Census ZCTA's internal point, and the bundled place
/// nearest it, which names it.
///
/// ZCTAs approximate delivery ZIPs, so PO-box-only and some business ZIPs (the White House's
/// 20500) have no row. Those are unknown ZIPs, not errors.
public struct MeshWXZip: Sendable, Hashable {
  /// Five digits, leading zeros kept: `"00901"`.
  public let code: String
  public let lat: Double
  public let lon: Double
  /// Index into `places.json` `places`, and so into ``MeshWXTables/places``.
  public let placeIndex: Int
  public let place: MeshWXPlace

  /// `"San Juan, PR 00901"`: the place's label with the ZIP after it (spec §9.1), the same
  /// characters as the weather bot's reply and as the app's row for the town.
  public var label: String {
    MeshWXPlaceNames.label(name: place.name, state: place.state, zip: code)
  }
}

/// One `zips.json` row after the ZIP itself.
struct MeshWXZipRow: Sendable {
  let lat: Double
  let lon: Double
  let placeIndex: Int
}

extension MeshWXTables {
  private static let zipLog = Logger(subsystem: "com.mc1", category: "MeshWX")

  /// The five digits a query names as a ZIP: `"78701"`, or ZIP+4 `"78701-1234"`, → `"78701"`,
  /// surrounding whitespace allowed. Anything else is nil: four or six digits are not a ZIP.
  ///
  /// The bot's rule (`geodata.zip_code`, a full match of `(\d{5})(?:-\d{4})?`). Python's `\d`
  /// is any Unicode decimal digit, so the same is accepted here; the table only has ASCII ones.
  public static func zipCode(in query: String) -> String? {
    let scalars = Array(query.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
    guard scalars.count == 5 || (scalars.count == 10 && scalars[5] == "-") else { return nil }
    for (offset, scalar) in scalars.enumerated() where offset != 5 {
      guard scalar.properties.generalCategory == .decimalNumber else { return nil }
    }
    var code = String.UnicodeScalarView()
    code.append(contentsOf: scalars.prefix(5))
    return String(code)
  }

  /// The ZIP a query names, looked up exactly and never by prefix (spec §9, §11). Nil for a
  /// query that is not a ZIP, and for a ZIP the table does not have.
  ///
  /// The first query that is a ZIP reads `zips.json` (1.1 MB, 33,144 rows); nothing pays for
  /// it at launch. Call it off the main thread.
  public func zip(_ query: String) -> MeshWXZip? {
    guard let code = Self.zipCode(in: query), let row = zipRows()[code],
          places.indices.contains(row.placeIndex)
    else { return nil }
    return MeshWXZip(
      code: code, lat: row.lat, lon: row.lon, placeIndex: row.placeIndex, place: places[row.placeIndex])
  }

  /// How many ZIPs the table holds, reading it if not read yet; 0 when the file is missing or bad.
  public var zipCount: Int { zipRows().count }

  /// Every ZIP in the table, ascending: the file's own order.
  func zipCodes() -> [String] { zipRows().keys.sorted() }

  /// Whether `zips.json` has been read (or tried and failed).
  var isZipTableLoaded: Bool { zipTable.withLock { $0 != nil } }

  /// Read-check under the lock, parse outside it, then publish, as ``MeshWXGeometry`` does: two
  /// cold callers at once may both parse, the first published wins, and a failed read is not retried.
  func zipRows() -> [String: MeshWXZipRow] {
    if let loaded = zipTable.withLock({ $0 }) { return loaded }
    let parsed = Self.parseZips(in: resourceDirectory)
    return zipTable.withLock { table in
      if let existing = table { return existing }
      table = parsed
      return parsed
    }
  }

  private static func parseZips(in directory: URL?) -> [String: MeshWXZipRow] {
    let started = ContinuousClock.now
    guard let file: ZipsFile = load("zips", from: directory, JSONDecoder()) else { return [:] }
    var rows: [String: MeshWXZipRow] = [:]
    rows.reserveCapacity(file.zips.count)
    // Assigned, not `uniqueKeysWithValues`: a duplicate must not trap, and the last one wins as
    // in the bot's dict comprehension.
    for record in file.zips {
      rows[record.code] = MeshWXZipRow(lat: record.lat, lon: record.lon, placeIndex: record.placeIndex)
    }
    let elapsed = started.duration(to: .now).components
    let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
    zipLog.info("MeshWX zips.json loaded: \(rows.count) ZIPs in \(milliseconds) ms")
    return rows
  }

  private struct ZipsFile: Decodable {
    let zips: [ZipRecord]
  }

  /// `["78701", 30.2706, -97.7426, 29645]`: ZIP, lat, lon, place index.
  private struct ZipRecord: Decodable {
    let code: String
    let lat: Double
    let lon: Double
    let placeIndex: Int

    init(from decoder: any Decoder) throws {
      var row = try decoder.unkeyedContainer()
      code = try row.decode(String.self)
      lat = try row.decode(Double.self)
      lon = try row.decode(Double.self)
      placeIndex = try row.decode(Int.self)
    }
  }
}
