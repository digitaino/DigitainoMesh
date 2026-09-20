import Foundation
import Testing

@testable import MeshWX

/// The official wire vectors.
///
/// The fixture is the publisher's own file, byte for byte: `docs/meshwx_v5_vectors.json` from
/// the bot's repository (thirteen at revision 5, which added the two vectors carrying the new
/// times beside the revision 4 form of the same two messages).
/// A codec checked only against itself passes forever while being wrong, so nothing in this
/// file is derived from the Swift implementation.
enum MeshWXVectors {
  /// Every vector, or an empty array if the fixture did not copy or any vector failed to read
  /// (which ``MeshWXVectorTests/fixtureIsPresent()`` turns into a failure rather than a silent
  /// pass over nothing).
  static let all: [Vector] = load()

  /// How many vectors the file holds, counted without the fixture type; nil when it did not load.
  static let fileCount: Int? = fixtureData().flatMap { data in
    (try? JSONSerialization.jsonObject(with: data) as? [Any])?.count
  }

  /// `request_digest`, the revision 6 Request vector (spec §7B): `>d` to bot `0x041D` from the
  /// sender `01 02 03 04 05 06` at `ts` 1789660000 with `seq` 1 — sixteen bytes.
  ///
  /// Quoted from the spec, and since revision 10 also in the publisher's file. It is kept here
  /// because the spec printed these bytes before any vector carried them, and
  /// ``MeshWXVectorTests/theRequestVectorsAreTheBytesTheSpecPrints()`` checks the two against each
  /// other: a vector file that silently disagreed with the printed spec is the one failure this
  /// constant can still catch.
  static let requestDigestHex = "011d0490010203040506600bac6a3e64"

  private static func fixtureData() -> Data? {
    guard
      let url = Bundle.module.url(
        forResource: "meshwx_v5_vectors", withExtension: "json", subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: "meshwx_v5_vectors", withExtension: "json")
    else { return nil }
    return try? Data(contentsOf: url)
  }

  private static func load() -> [Vector] {
    guard let data = fixtureData() else { return [] }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return (try? decoder.decode([Vector].self, from: data)) ?? []
  }

  struct Vector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let hex: String
    let decoded: Decoded

    var testDescription: String { name }
  }

  /// Every field any vector's `decoded` object can carry, all optional so one type can
  /// stand in for all seven message shapes. The tests read only the fields that belong
  /// to the message under test, so a typo in a key surfaces as a nil, not as a pass.
  struct Decoded: Decodable, Sendable {
    // Header
    let seq: UInt8
    let bot: UInt16
    let type: UInt8
    let name: String
    let flags: UInt8

    // Warning / cancel / digest identity
    let event: UInt8?
    let office: UInt8?
    let etn: UInt16?
    let expiresMin: UInt32?
    let tornado: UInt8?
    let floodSource: UInt8?
    let floodDamage: UInt8?
    let hailQin: UInt8?
    let windMph: UInt8?
    let update: Bool?
    /// `[[lat, lon], …]`.
    let polygon: [[Double]]?
    let areas: [Area]?

    // Cancel
    let reason: UInt8?

    // Digest, and — since revision 8 — the Area sweep, whose entries arrive under the same key
    // in a shape of their own.
    let nowMin: UInt32?
    let feedHealth: UInt8?
    let entries: EntriesField?

    // Area sweep (spec §7C). `group`, `idx` and `total` are shared with Text above; the build
    // time is read under either spelling, because the wire field is `built` and every other time
    // in this file carries the `_min` suffix the bot's decoder adds.
    let built: UInt32?
    let builtMin: UInt32?
    let cut: Bool?
    let advisories: Bool?
    /// Revision 10, §1.2: the reference JSON adds both to **every** decoded Area sweep, so a
    /// national one reads `scoped: false, scope: []`. Optional here because the file this is a
    /// copy of held only revision 9 vectors when the fields were written; a revision 9 vector
    /// therefore reads as national, which is what it was.
    let scoped: Bool?
    let scope: [UInt8]?

    /// The build time of an Area sweep, whichever key the vector carries it under.
    var sweepBuiltMinutes: UInt32? { builtMin ?? built }

    // Observations
    let tsMin: UInt32?
    /// The station list of an Observations vector, or the hourly cap of a Coverage one: the wire
    /// key is the same word for both, so one flat fixture type has to read either shape.
    let stations: StationsField?

    // Forecast, and — since revision 5 — the warning's own issue time, which the bot's
    // decoder resolves to the same absolute minutes under the same key.
    let point: UInt16?
    let issuedMin: UInt32?
    let firstPeriod: UInt8?
    let periods: [Period]?

    // Text
    let subject: UInt8?
    let group: UInt8?
    let idx: UInt8?
    let total: UInt8?
    let text: String?

    // Not available
    let request: String?
    let requestCode: UInt8?

    // Request (spec §7B). `text` is shared with Text above; `sender` is the six-byte key prefix
    // as lower-case hex and `ts` is Unix **seconds**, not the minutes every other time here is.
    let sender: String?
    let ts: UInt32?

    // Coverage (the zone runs arrive in `areas`, the warning's own shape)
    let lat: Double?
    let lon: Double?
    let radiusKm: UInt16?
    let offices: [UInt8]?
    let zonesCut: Bool?
    let officesCut: Bool?

    /// `stations` in two shapes, told apart by what the JSON holds rather than by the vector's
    /// name, so a mis-typed field surfaces as a decode failure rather than a silent nil.
    enum StationsField: Decodable, Sendable {
      case list([Station])
      case cap(UInt8)

      init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let cap = try? container.decode(UInt8.self) {
          self = .cap(cap)
        } else {
          self = .list(try container.decode([Station].self))
        }
      }

      var list: [Station]? {
        guard case let .list(stations) = self else { return nil }
        return stations
      }

      var cap: UInt8? {
        guard case let .cap(cap) = self else { return nil }
        return cap
      }
    }

    /// `entries` in two shapes — a Digest's identities and an Area sweep's runs — told apart by
    /// what the JSON holds rather than by the vector's name, the way ``StationsField`` is. A
    /// mis-typed field surfaces as a decode failure (which `fixtureIsPresent` reports) rather
    /// than as a silent nil the tests would pass over.
    enum EntriesField: Decodable, Sendable {
      case digest([DigestEntry])
      case sweep([SweepEntry])

      init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let digest = try? container.decode([DigestEntry].self) {
          self = .digest(digest)
        } else {
          self = .sweep(try container.decode([SweepEntry].self))
        }
      }

      var digest: [DigestEntry]? {
        guard case let .digest(entries) = self else { return nil }
        return entries
      }

      var sweep: [SweepEntry]? {
        guard case let .sweep(entries) = self else { return nil }
        return entries
      }
    }

    struct Area: Decodable, Sendable {
      let state: UInt8
      let county: Bool
      let start: UInt16
      let run: UInt8
    }

    /// One Area sweep entry: a Warning's area run with the event code in front of it (spec §7C).
    struct SweepEntry: Decodable, Sendable {
      let event: UInt8
      let state: UInt8
      let county: Bool
      let start: UInt16
      let run: UInt8
      /// The codes the entry expands to, where the vector prints them.
      let ugcs: [String]?
    }

    struct DigestEntry: Decodable, Sendable {
      let event: UInt8
      let office: UInt8
      let etn: UInt16
      let expiresRel: UInt16
      let expiresMin: UInt32
    }

    struct Station: Decodable, Sendable {
      let station: UInt16
      let tempF: Int8?
      let dewpointF: Int8?
      let windDirDeg: Double
      let windDir: String
      let sky: UInt8
      let windMph: UInt8?
      let gustMph: UInt8
      let visibilityMi: UInt8?
      let pressureInhg: Double?
      let humidityPct: UInt8?
      let feelsDeltaF: Int8
      /// Revision 5: minutes this station's own report is older than the batch `ts`. Null in
      /// the revision 4 vectors, which carry no ages at all.
      let ageMin: UInt16?
    }

    struct Period: Decodable, Sendable {
      let highF: Int8?
      let lowF: Int8?
      let popPct: UInt8?
      let sky: UInt8
      let thunder: Bool
      let wintry: Bool
      let windy: Bool
      let fog: Bool
      let windDirDeg: Double
      let windDir: String
      let windMph: UInt8
    }
  }
}

// MARK: - Hex

extension Data {
  /// Parse a lower- or upper-case hex string. Returns nil on an odd length or a
  /// non-hex digit, so a malformed fixture fails the test instead of decoding garbage.
  init?(meshWXHex hex: String) {
    let digits = Array(hex.utf8)
    guard digits.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(digits.count / 2)
    var index = 0
    while index < digits.count {
      guard let high = Data.nibble(digits[index]), let low = Data.nibble(digits[index + 1])
      else { return nil }
      bytes.append(high << 4 | low)
      index += 2
    }
    self.init(bytes)
  }

  private static func nibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: byte - 0x30
    case 0x61...0x66: byte - 0x61 + 10
    case 0x41...0x46: byte - 0x41 + 10
    default: nil
    }
  }

  /// Lower-case hex, the form the vectors use.
  var meshWXHex: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
