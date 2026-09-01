import Foundation
@testable import MeshCore
import Testing

/// Fixtures are real packets captured from the CoreScope observer network
/// (scope.digitaino.com, 2026-08-31), whose server-side hash both mirrors the
/// firmware and groups observations. Each case pins raw on-air bytes to the hash
/// the observers computed for them, so a drift in our implementation — or a
/// firmware-side change upstream — fails loudly against ground truth.
@Suite("Firmware content hash")
struct ContentHashTests {
  /// (raw on-air packet, expected content hash)
  private static let fixtures: [(rawHex: String, expected: String)] = [
    // REQ, direct route, empty path
    ("0240A24CC54D6F879566CAFE6B576162B9CF612BC0FE", "7b1313c6f661449a"),
    // RESPONSE, flood via ABBA
    ("0541ABBA4CA2B63CFF458621FB325BC6B2073010B6C14ECB", "286dcbdeab84b458"),
    // The SAME packet heard via a different repeater — the hash must not move
    ("054128634CA2B63CFF458621FB325BC6B2073010B6C14ECB", "286dcbdeab84b458"),
    // RESPONSE, direct, long encrypted payload
    (
      "06000E708C6182CB61FD1CDBB4CB95108F0C6B13400CEEE33AFF9BF62643E56A9318A35FC5"
        + "BA85C32ACA7E69B5B79C98222EA9E295D2BFE387C2EA4A7128018779DDCC1A0306",
      "b120e42c91ae7ca9"
    ),
    // TRACE — the raw path-length byte folds into the hash as LE16
    ("2600EB35966A000000000078CF9AC8DF92", "5ff4770f84006897"),
  ]

  @Test
  func `content hash matches observer ground truth for live packet fixtures`() throws {
    for fixture in Self.fixtures {
      let raw = try #require(Data(hexString: fixture.rawHex))
      let parsed = RxLogParser.parse(snr: nil, rssi: nil, payload: raw)
      #expect(parsed != nil, "fixture failed to parse: \(fixture.rawHex.prefix(16))")
      #expect(parsed?.contentHash == fixture.expected)
    }
  }

  @Test
  func `same packet through different paths yields one content hash but distinct packet hashes stay local`() throws {
    let rawViaABBA = try #require(Data(hexString: "0541ABBA4CA2B63CFF458621FB325BC6B2073010B6C14ECB"))
    let rawVia2863 = try #require(Data(hexString: "054128634CA2B63CFF458621FB325BC6B2073010B6C14ECB"))
    let viaABBA = try #require(RxLogParser.parse(snr: nil, rssi: nil, payload: rawViaABBA))
    let via2863 = try #require(RxLogParser.parse(snr: nil, rssi: nil, payload: rawVia2863))
    #expect(viaABBA.contentHash == via2863.contentHash)
    // The local correlation hash agrees here too (payloads match once the path is
    // stripped) — but the two hashes must never be conflated: contentHash prepends
    // the payload-type nibble and packetHash does not.
    #expect(viaABBA.contentHash != viaABBA.packetHash)
  }

  @Test
  func `payload type nibble separates otherwise identical payloads`() {
    let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let asRequest = ParsedRxLogData.computeContentHash(
      payloadTypeBits: 0, rawPathLengthByte: 0, packetPayload: payload
    )
    let asResponse = ParsedRxLogData.computeContentHash(
      payloadTypeBits: 1, rawPathLengthByte: 0, packetPayload: payload
    )
    #expect(asRequest != asResponse)
  }

  @Test
  func `non-trace packets ignore the raw path length byte`() {
    let payload = Data([0x01, 0x02, 0x03])
    let a = ParsedRxLogData.computeContentHash(
      payloadTypeBits: 5, rawPathLengthByte: 0x00, packetPayload: payload
    )
    let b = ParsedRxLogData.computeContentHash(
      payloadTypeBits: 5, rawPathLengthByte: 0x41, packetPayload: payload
    )
    #expect(a == b)
  }
}
