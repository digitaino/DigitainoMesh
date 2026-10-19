import Foundation
@testable import MC1Services
import Testing

/// Spec source: legacy `MC1/Views/Contacts/ContactsViewModel.swift` — the `looksLikeHex`
/// gate and `hexMatchTier` from commits `a3057d81` (strict hex matching) and `3cbfac71`
/// (pubkey prefix priority), restated over `Data` instead of over hex strings.
@Suite("NodeKeyPrefix")
struct NodeKeyPrefixTests {
  /// A 32-byte key beginning with `prefix`, padded with `fill`.
  private static func key(_ prefix: [UInt8], fill: UInt8 = 0x77) -> Data {
    Data(prefix) + Data(repeating: fill, count: 32 - prefix.count)
  }

  // MARK: - Parsing

  struct ParseCase: Sendable {
    let input: String
    let expectedHex: String?
    let comment: String
  }

  @Test(arguments: [
    ParseCase(input: "0", expectedHex: "0", comment: "a single nibble is a legitimate query"),
    ParseCase(input: "0c", expectedHex: "0C", comment: "case is normalized up"),
    ParseCase(input: "0C1", expectedHex: "0C1", comment: "odd widths survive — NodeHexID cannot express this"),
    ParseCase(input: "  0C13  ", expectedHex: "0C13", comment: "surrounding whitespace is trimmed"),
    ParseCase(input: String(repeating: "AB", count: 32), expectedHex: String(repeating: "AB", count: 32), comment: "a full 32-byte key is in range"),
    ParseCase(input: "", expectedHex: nil, comment: "empty is not a key fragment"),
    ParseCase(input: "   ", expectedHex: nil, comment: "whitespace only is not a key fragment"),
    ParseCase(input: "0G", expectedHex: nil, comment: "a non-hex digit disqualifies the whole query"),
    ParseCase(input: "Alice", expectedHex: nil, comment: "an ordinary name is not hex"),
    ParseCase(input: "0C 13", expectedHex: nil, comment: "interior whitespace is not trimmed away"),
    ParseCase(input: String(repeating: "A", count: 65), expectedHex: nil, comment: "wider than a public key can never match one")
  ])
  func `parsing accepts hex digit runs up to a full key and rejects everything else`(testCase: ParseCase) {
    let parsed = NodeKeyPrefix(hex: testCase.input)
    #expect(parsed?.hex == testCase.expectedHex, "\(testCase.comment) — input \(testCase.input)")
  }

  @Test
  func `a hex query that is all digits is not confused with a decimal number`() throws {
    let prefix = try #require(NodeKeyPrefix(hex: "0013"))
    #expect(prefix.nibbleWidth == 4)
    #expect(prefix.hex == "0013")
    #expect(prefix.isByteAligned)
  }

  @Test
  func `an odd width is reported as not byte aligned`() throws {
    #expect(try #require(NodeKeyPrefix(hex: "0C1")).isByteAligned == false)
  }

  @Test
  func `raw key bytes convert to a prefix`() throws {
    let prefix = try #require(NodeKeyPrefix(bytes: Data([0x0C, 0x13])))
    #expect(prefix.hex == "0C13")
    #expect(NodeKeyPrefix(bytes: Data()) == nil)
    #expect(NodeKeyPrefix(bytes: Data(repeating: 0xAA, count: 33)) == nil)
  }

  // MARK: - Prefix matching

  struct MatchCase: Sendable {
    let query: String
    let keyBytes: [UInt8]
    let isPrefix: Bool
    let isContained: Bool
    let comment: String
  }

  @Test(arguments: [
    MatchCase(query: "0C", keyBytes: [0x0C, 0x13], isPrefix: true, isContained: true, comment: "byte-aligned prefix"),
    MatchCase(query: "0c", keyBytes: [0x0C, 0x13], isPrefix: true, isContained: true, comment: "lowercase query, same answer"),
    MatchCase(query: "0", keyBytes: [0x0C, 0x13], isPrefix: true, isContained: true, comment: "single nibble prefix"),
    MatchCase(query: "0C1", keyBytes: [0x0C, 0x13], isPrefix: true, isContained: true, comment: "odd-width prefix pins one and a half bytes"),
    MatchCase(query: "0C2", keyBytes: [0x0C, 0x13], isPrefix: false, isContained: false, comment: "odd-width prefix that disagrees on the half byte"),
    MatchCase(query: "0C", keyBytes: [0xCC, 0x0C], isPrefix: false, isContained: true, comment: "legacy's `0c` vs `CC` bug: never a prefix here"),
    MatchCase(query: "CC", keyBytes: [0x0C, 0xC1], isPrefix: false, isContained: true, comment: "an interior match can straddle a byte boundary"),
    MatchCase(query: "13", keyBytes: [0x0C, 0x13], isPrefix: false, isContained: true, comment: "interior, byte aligned"),
    MatchCase(query: "AB", keyBytes: [0x0C, 0x13], isPrefix: false, isContained: false, comment: "absent entirely")
  ])
  func `key matching is over raw bytes at nibble granularity`(testCase: MatchCase) throws {
    let prefix = try #require(NodeKeyPrefix(hex: testCase.query))
    let key = Self.key(testCase.keyBytes, fill: 0x77)
    #expect(prefix.isPrefix(of: key) == testCase.isPrefix, "\(testCase.comment) — isPrefix")
    #expect(prefix.isContained(in: key) == testCase.isContained, "\(testCase.comment) — isContained")
  }

  @Test
  func `a prefix wider than the key never matches`() throws {
    let prefix = try #require(NodeKeyPrefix(hex: "0C13AB"))
    #expect(prefix.isPrefix(of: Data([0x0C, 0x13])) == false)
    #expect(prefix.isContained(in: Data([0x0C, 0x13])) == false)
  }

  @Test
  func `a full width key matches itself exactly`() throws {
    let key = Self.key([0x0C, 0x13], fill: 0x77)
    let prefix = try #require(NodeKeyPrefix(hex: key.uppercaseHexString()))
    #expect(prefix.isPrefix(of: key))
    #expect(prefix.isContained(in: key))
  }

  @Test
  func `nothing matches an empty key`() throws {
    let prefix = try #require(NodeKeyPrefix(hex: "0C"))
    #expect(prefix.isPrefix(of: Data()) == false)
    #expect(prefix.isContained(in: Data()) == false)
  }
}
