import Foundation
@testable import MC1Services
import Testing

/// Spec source: legacy `MC1/Utilities/RepeaterHexID.swift`,
/// `SurveyExportService.consolidateHexIDs`, and the ad-hoc bidirectional `hasPrefix`
/// comparison that used to live inline in `RepeaterSignalListView`.
@Suite("NodeHexID")
struct NodeHexIDTests {
  // MARK: - Parsing and normalization

  @Test
  func `Parsing normalizes case and surrounding whitespace to canonical uppercase hex`() throws {
    let cases: [(input: String, hex: String, bytes: [UInt8])] = [
      ("0c", "0C", [0x0C]),
      ("0C", "0C", [0x0C]),
      ("0c13", "0C13", [0x0C, 0x13]),
      ("0C13ab", "0C13AB", [0x0C, 0x13, 0xAB]),
      ("  0c13  ", "0C13", [0x0C, 0x13]),
      ("\tab\n", "AB", [0xAB])
    ]
    for c in cases {
      let id = try #require(NodeHexID(c.input), "expected \(c.input) to parse")
      #expect(id.hex == c.hex)
      #expect(id.bytes == c.bytes)
      #expect(id.byteWidth == c.bytes.count)
      #expect(id.data == Data(c.bytes))
    }
  }

  @Test
  func `Case differences do not affect equality or hashing`() throws {
    let lower = try #require(NodeHexID("0c13"))
    let upper = try #require(NodeHexID("0C13"))
    #expect(lower == upper)
    #expect(Set([lower, upper]).count == 1)
  }

  @Test
  func `Invalid hex input is rejected rather than silently coerced`() {
    let invalid = [
      "", // empty
      "   ", // whitespace only
      "0", // half a byte
      "0C1", // odd digit count
      "ZZ", // non-hex characters
      "0Cg3", // one bad nibble
      "0C 13", // interior whitespace is not a separator
      "0x0C", // prefixed literal
      "0C13AB12" // 4 bytes — wider than any firmware hash
    ]
    for text in invalid {
      #expect(NodeHexID(text) == nil, "expected \(text.debugDescription) to be rejected")
    }
  }

  @Test
  func `Byte and Data initializers enforce the 1 to 3 byte width`() {
    #expect(NodeHexID(bytes: [])?.hex == nil)
    #expect(NodeHexID(bytes: [0x0C])?.hex == "0C")
    #expect(NodeHexID(bytes: [0x0C, 0x13, 0xAB])?.hex == "0C13AB")
    #expect(NodeHexID(bytes: [0x0C, 0x13, 0xAB, 0x01]) == nil)
    #expect(NodeHexID(data: Data())?.hex == nil)
    #expect(NodeHexID(data: Data([0xAB]))?.hex == "AB")
    #expect(NodeHexID.maxByteWidth == 3)
  }

  @Test
  func `Narrowing truncates to a shorter width and refuses to invent bytes`() throws {
    let id = try #require(NodeHexID("0C13AB"))
    #expect(id.narrowed(toByteWidth: 1)?.hex == "0C")
    #expect(id.narrowed(toByteWidth: 2)?.hex == "0C13")
    #expect(id.narrowed(toByteWidth: 3)?.hex == "0C13AB")
    #expect(id.narrowed(toByteWidth: 4) == nil)
    #expect(id.narrowed(toByteWidth: 0) == nil)
  }

  // MARK: - Same-node comparison across differing hash widths

  @Test
  func `identifiesSameNode applies the bidirectional prefix rule in both directions`() throws {
    let cases: [(lhs: String, rhs: String, same: Bool)] = [
      ("0C", "0C", true), // identical, same width
      ("0C", "0C13", true), // narrow query, wide row
      ("0C13", "0C", true), // wide query, narrow row
      ("0C", "0C13AB", true), // 1 byte vs 3 bytes
      ("0C13AB", "0C", true),
      ("0C13", "0C13AB", true),
      ("0C13", "0C14", false), // diverges in the second byte
      ("0C", "0D", false), // diverges immediately
      ("0C13AB", "0C13AC", false)
    ]
    for c in cases {
      let lhs = try #require(NodeHexID(c.lhs))
      let rhs = try #require(NodeHexID(c.rhs))
      #expect(lhs.identifiesSameNode(as: rhs) == c.same, "\(c.lhs) vs \(c.rhs)")
      #expect(rhs.identifiesSameNode(as: lhs) == c.same, "\(c.rhs) vs \(c.lhs) (symmetry)")
    }
  }

  @Test
  func `Equality is stricter than identifiesSameNode`() throws {
    let narrow = try #require(NodeHexID("0C"))
    let wide = try #require(NodeHexID("0C13"))
    #expect(narrow != wide)
    #expect(narrow.identifiesSameNode(as: wide))
  }

  @Test
  func `isPrefix is one-directional, unlike identifiesSameNode`() throws {
    let narrow = try #require(NodeHexID("0C"))
    let wide = try #require(NodeHexID("0C13"))
    #expect(narrow.isPrefix(of: wide))
    #expect(!wide.isPrefix(of: narrow))
    #expect(narrow.isPrefix(of: narrow))
  }

  // MARK: - Public-key matching

  @Test
  func `matchedByteCount reports the agreed prefix length against a public key`() throws {
    let key = Data([0x0C, 0x13, 0xAB] + [UInt8](repeating: 0x77, count: 29))
    #expect(try #require(NodeHexID("0C")).matchedByteCount(againstPublicKey: key) == 1)
    #expect(try #require(NodeHexID("0C13")).matchedByteCount(againstPublicKey: key) == 2)
    #expect(try #require(NodeHexID("0C13AB")).matchedByteCount(againstPublicKey: key) == 3)
    #expect(try #require(NodeHexID("0C14")).matchedByteCount(againstPublicKey: key) == nil)
    #expect(try #require(NodeHexID("0D")).matchedByteCount(againstPublicKey: key) == nil)
  }

  @Test
  func `A key shorter than the id still matches on the bytes both sides share`() throws {
    let truncated = Data([0x0C])
    #expect(try #require(NodeHexID("0C13")).matchedByteCount(againstPublicKey: truncated) == 1)
    #expect(try #require(NodeHexID("0C13")).matchesPublicKey(truncated))
    #expect(try #require(NodeHexID("0D13")).matchedByteCount(againstPublicKey: truncated) == nil)
    #expect(try #require(NodeHexID("0C")).matchedByteCount(againstPublicKey: Data()) == nil)
  }

  // MARK: - Consolidation (keep the longest known form)

  @Test
  func `consolidate keeps the longest form regardless of the order it was seen in`() throws {
    let cases: [(input: [String], expected: [String])] = [
      (["0C", "0C13"], ["0C13"]), // short then long
      (["0C13", "0C"], ["0C13"]), // long then short
      (["0C", "0C13", "0C13AB"], ["0C13AB"]), // three widths collapse to one
      (["0C13AB", "0C13", "0C"], ["0C13AB"]),
      (["0C", "0C"], ["0C"]), // duplicates collapse
      (["0C", "0D"], ["0C", "0D"]), // unrelated ids are both kept
      (["0C13", "0C14"], ["0C13", "0C14"]), // diverging second byte is a different node
      ([], []),
      (["0C", "AB", "0C13"], ["AB", "0C13"]) // the surviving long form takes the extended slot
    ]
    for c in cases {
      let ids = try c.input.map { try #require(NodeHexID($0)) }
      #expect(NodeHexID.consolidate(ids).map(\.hex) == c.expected, "input \(c.input)")
    }
  }

  @Test
  func `The string-facing consolidate normalizes case and drops unparseable ids`() {
    #expect(NodeHexID.consolidate(hexStrings: ["0c", "0C13"]) == ["0C13"])
    #expect(NodeHexID.consolidate(hexStrings: ["0C", "zz", "0C13"]) == ["0C13"])
    #expect(NodeHexID.consolidate(hexStrings: ["nonsense"]) == [])
  }
}
