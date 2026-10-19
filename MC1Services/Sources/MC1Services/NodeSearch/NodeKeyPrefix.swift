import Foundation

/// A fragment of a node's public key, held at nibble (half-byte) granularity.
///
/// This is deliberately **not** ``NodeHexID``. A hash ID is a whole number of bytes,
/// capped at ``NodeHexID/maxByteWidth``, and names a node the way the firmware
/// advertises it. What a user types into a search field is neither: `"0"`, `"0C1"` and a
/// full 64-character key are all legitimate things to search for, and only the first
/// bytes of a 32-byte key are ever hash-shaped. Forcing search input through `NodeHexID`
/// would reject every odd-length query and everything past three bytes.
///
/// Matching is done against `Data` — the raw public key — rather than against a hex
/// string, so no call site has to agree on a casing convention to get the right answer.
/// The nibble sequence is compared to the key's own nibble sequence, which is what makes
/// odd-length queries meaningful: `"0C1"` pins down one and a half bytes.
///
/// Parsing is strict, and strictness is the point. Legacy matched a search term against
/// key hex with `localizedCaseInsensitiveContains`, so the query `"0c"` matched a key
/// containing `"CC"`; only a query made entirely of hex digits reaches key matching here,
/// and comparison is over raw values, never over locale-folded text.
public struct NodeKeyPrefix: Sendable, Hashable, CustomStringConvertible {
  /// The widest public key the protocol carries; a prefix may pin down all of it.
  public static let maxByteWidth = 32

  /// The widest prefix that can be expressed, in nibbles.
  public static let maxNibbleWidth = maxByteWidth * 2

  /// The prefix nibbles, most significant first, each in `0...15`.
  /// Always 1...``maxNibbleWidth`` of them.
  public let nibbles: [UInt8]

  private init(unchecked nibbles: [UInt8]) {
    self.nibbles = nibbles
  }

  /// Parses a run of hex digits such as `"0"`, `"0c"`, `"0C1"` or a full 64-digit key.
  ///
  /// Surrounding whitespace is trimmed. Returns `nil` for an empty value, for anything
  /// containing a non-hex character, or for more than ``maxNibbleWidth`` digits — a
  /// query wider than a public key can never match one, and silently truncating it would
  /// turn a typo into a confident wrong answer.
  public init?(hex text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= Self.maxNibbleWidth else { return nil }

    var parsed: [UInt8] = []
    parsed.reserveCapacity(trimmed.count)
    for character in trimmed {
      guard let value = character.hexDigitValue, value >= 0, value <= 15 else { return nil }
      parsed.append(UInt8(value))
    }
    self.init(unchecked: parsed)
  }

  /// Wraps a whole number of bytes, for callers that already hold key data
  /// (a ``NodeHexID``'s bytes, a `senderKeyPrefix`).
  /// Returns `nil` for empty data or more than ``maxByteWidth`` bytes.
  public init?(bytes: Data) {
    guard !bytes.isEmpty, bytes.count <= Self.maxByteWidth else { return nil }
    var parsed: [UInt8] = []
    parsed.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      parsed.append(byte >> 4)
      parsed.append(byte & 0x0F)
    }
    self.init(unchecked: parsed)
  }

  /// How many nibbles this prefix pins down.
  public var nibbleWidth: Int {
    nibbles.count
  }

  /// Whether the prefix covers a whole number of bytes.
  public var isByteAligned: Bool {
    nibbleWidth.isMultiple(of: 2)
  }

  /// Canonical uppercase hex, matching `Data.uppercaseHexString()` for byte-aligned
  /// prefixes and extending it by a single digit for odd widths.
  public var hex: String {
    String(nibbles.map { Self.hexDigits[Int($0)] })
  }

  public var description: String {
    hex
  }

  private static let hexDigits: [Character] = Array("0123456789ABCDEF")

  // MARK: - Matching

  /// Whether `key` begins with this prefix.
  ///
  /// This is the strongest match a search can make: the user typed the start of the key
  /// exactly as it is displayed. A key shorter than the prefix never matches — unlike
  /// ``NodeHexID/matchedByteCount(againstPublicKey:)``, which tolerates truncated
  /// records because it is resolving a hash rather than answering a user's query.
  public func isPrefix(of key: Data) -> Bool {
    guard key.count * 2 >= nibbleWidth else { return false }
    for (offset, nibble) in nibbles.enumerated() where Self.nibble(of: key, at: offset) != nibble {
      return false
    }
    return true
  }

  /// Whether this prefix appears anywhere in `key`, at any nibble offset.
  ///
  /// The weaker of the two matches, and the reason it exists is that legacy offered it:
  /// searching a key's interior finds a node when the user remembers a distinctive run of
  /// digits but not where it sits. It ranks below ``isPrefix(of:)`` rather than beside it.
  public func isContained(in key: Data) -> Bool {
    let total = key.count * 2
    guard total >= nibbleWidth else { return false }
    for start in 0...(total - nibbleWidth) {
      var matched = true
      for (offset, nibble) in nibbles.enumerated() where Self.nibble(of: key, at: start + offset) != nibble {
        matched = false
        break
      }
      if matched { return true }
    }
    return false
  }

  /// The nibble at `index` counting from the most significant nibble of the first byte.
  private static func nibble(of key: Data, at index: Int) -> UInt8 {
    let byte = key[key.startIndex + index / 2]
    return index.isMultiple(of: 2) ? byte >> 4 : byte & 0x0F
  }
}
