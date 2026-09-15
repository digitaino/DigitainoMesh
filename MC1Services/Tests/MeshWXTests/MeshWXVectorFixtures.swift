import Foundation
import Testing

@testable import MeshWX

/// The nine official wire vectors from the v5 developer kit.
///
/// The fixture is the publisher's own file, byte for byte: `meshwx_v5_vectors.json` from
/// `MeshWX_iOS_Kit_2026-09-15`. A codec checked only against itself passes forever while
/// being wrong, so nothing in this file is derived from the Swift implementation.
enum MeshWXVectors {
  /// Every vector, or an empty array if the fixture did not copy (which
  /// ``MeshWXVectorTests/fixtureIsPresent()`` turns into a failure rather than a silent
  /// pass over nothing).
  static let all: [Vector] = load()

  private static func load() -> [Vector] {
    guard
      let url = Bundle.module.url(
        forResource: "meshwx_v5_vectors", withExtension: "json", subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: "meshwx_v5_vectors", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return [] }
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

    // Digest
    let nowMin: UInt32?
    let feedHealth: UInt8?
    let entries: [DigestEntry]?

    // Observations
    let tsMin: UInt32?
    let stations: [Station]?

    // Forecast
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

    struct Area: Decodable, Sendable {
      let state: UInt8
      let county: Bool
      let start: UInt16
      let run: UInt8
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
