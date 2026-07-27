import Foundation

/// A repeater/node hash ID: the leading 1-3 bytes of a node's public key, as advertised
/// in path hops, drawn on the firmware's OLED and shown in the signal-bars UI.
///
/// This is the app's single representation of a node hash. Nothing else should compare
/// hex ID strings: firmware advertises the *same* node at different hash widths depending
/// on the path it took, so `"0C" == "0C13"` is false as an identifier but true as a node
/// — a distinction only ``identifiesSameNode(as:)`` gets right.
///
/// Parsing is strict. Whitespace around the value is trimmed, case is normalized to
/// uppercase, and anything else — an odd number of digits, non-hex characters, an empty
/// value, or more than ``maxByteWidth`` bytes — is rejected rather than coerced.
/// Equality and hashing are over the raw bytes, so case never affects them.
public struct NodeHexID: Sendable, Hashable, CustomStringConvertible {
  /// The widest hash the firmware advertises. Path hop hashes are 1, 2 or 3 bytes wide.
  public static let maxByteWidth = 3

  /// The raw hash bytes, always 1...``maxByteWidth`` of them.
  public let bytes: [UInt8]

  private init(unchecked bytes: [UInt8]) {
    self.bytes = bytes
  }

  /// Parses a hex string such as `"0C"`, `"0c13"` or `"0C13AB"`.
  /// Returns `nil` for anything that is not a whole number of hex bytes within the width limit.
  public init?(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count.isMultiple(of: 2) else { return nil }
    guard trimmed.count <= Self.maxByteWidth * 2 else { return nil }

    var parsed: [UInt8] = []
    parsed.reserveCapacity(trimmed.count / 2)
    var index = trimmed.startIndex
    while index < trimmed.endIndex {
      let next = trimmed.index(index, offsetBy: 2)
      guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
      parsed.append(byte)
      index = next
    }
    self.init(unchecked: parsed)
  }

  /// Wraps raw hash bytes. Returns `nil` unless there are 1...``maxByteWidth`` of them.
  public init?(bytes: [UInt8]) {
    guard (1...Self.maxByteWidth).contains(bytes.count) else { return nil }
    self.init(unchecked: bytes)
  }

  /// Wraps raw hash bytes. Returns `nil` unless there are 1...``maxByteWidth`` of them.
  public init?(data: Data) {
    self.init(bytes: [UInt8](data))
  }

  /// The hash bytes as `Data`, for comparison against public keys and path hop slices.
  public var data: Data {
    Data(bytes)
  }

  /// How many bytes of hash this ID pins down (1...``maxByteWidth``).
  public var byteWidth: Int {
    bytes.count
  }

  /// Canonical uppercase hex, matching the hop hex produced by `Data.uppercaseHexString()`
  /// and by ``SignalBarsBlob/Entry/hexID``.
  public var hex: String {
    data.uppercaseHexString()
  }

  public var description: String {
    hex
  }

  /// Truncates to a narrower hash. Returns `nil` for a width outside `1...byteWidth`,
  /// because widening would mean inventing bytes this ID never carried.
  public func narrowed(toByteWidth width: Int) -> NodeHexID? {
    guard (1...byteWidth).contains(width) else { return nil }
    return NodeHexID(unchecked: Array(bytes.prefix(width)))
  }

  // MARK: - Comparison

  /// Whether both IDs name the same node, allowing for differing hash widths.
  ///
  /// This is the bidirectional prefix rule the legacy views open-coded as
  /// `a.hasPrefix(b) || b.hasPrefix(a)`: a 1-byte hash heard on one path and a 2-byte
  /// hash heard on another are the same repeater as long as they agree on every byte
  /// they both carry. Use this — never `==` — when comparing a stored/watched ID with
  /// one that arrived over the air.
  public func identifiesSameNode(as other: NodeHexID) -> Bool {
    let shared = Swift.min(byteWidth, other.byteWidth)
    return bytes.prefix(shared).elementsEqual(other.bytes.prefix(shared))
  }

  /// Whether this ID is a leading prefix of `other` (or equal to it). One-directional,
  /// unlike ``identifiesSameNode(as:)``.
  public func isPrefix(of other: NodeHexID) -> Bool {
    byteWidth <= other.byteWidth && other.bytes.starts(with: bytes)
  }

  // MARK: - Public-key matching

  /// How many leading bytes this ID and `key` agree on, or `nil` if they disagree.
  ///
  /// Normally the answer is ``byteWidth`` — public keys are far wider than any hash.
  /// A key shorter than the ID (a truncated record) matches on the bytes both sides
  /// carry, and the shorter agreement is what ranks it below a full-width match in
  /// ``NodeIdentityResolver``.
  public func matchedByteCount(againstPublicKey key: Data) -> Int? {
    let shared = Swift.min(byteWidth, key.count)
    guard shared > 0, key.prefix(shared).elementsEqual(bytes.prefix(shared)) else { return nil }
    return shared
  }

  /// Whether `key` could belong to the node this ID names.
  public func matchesPublicKey(_ key: Data) -> Bool {
    matchedByteCount(againstPublicKey: key) != nil
  }

  // MARK: - Consolidation

  /// Collapses IDs that are prefixes of each other, keeping the longest (most specific)
  /// form of each node.
  ///
  /// A repeater seen as `"0C"` on one path and `"0C13"` on another is one node, and the
  /// wider hash is the better identifier. Order follows first appearance, except that a
  /// node promoted to a wider hash moves to the position of that wider sighting.
  public static func consolidate(_ ids: [NodeHexID]) -> [NodeHexID] {
    var result: [NodeHexID] = []
    for id in ids {
      // Already covered by a wider form of the same node.
      if result.contains(where: { id.isPrefix(of: $0) && $0.byteWidth > id.byteWidth }) { continue }
      // This is the wider form — drop the narrower ones it supersedes.
      result.removeAll { $0.isPrefix(of: id) && id.byteWidth > $0.byteWidth }
      if !result.contains(id) { result.append(id) }
    }
    return result
  }

  /// String-facing ``consolidate(_:)`` for call sites holding hop hex (for example
  /// `DiscoveredNodeDTO.pathNodesHex`). Input is normalized to uppercase and anything
  /// unparseable is dropped.
  public static func consolidate(hexStrings: [String]) -> [String] {
    consolidate(hexStrings.compactMap(NodeHexID.init)).map(\.hex)
  }
}
