import CryptoKit
import Foundation

// MARK: - Crockford Base32

/// Crockford Base32 alphabet (excludes I, L, O, U to avoid ambiguity)
private let crockfordAlphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

/// Crockford Base32 decode table (maps ASCII to 5-bit values, -1 for invalid)
private let crockfordDecodeTable: [Int8] = {
  var table = [Int8](repeating: -1, count: 128)
  for (index, char) in crockfordAlphabet.enumerated() {
    table[Int(char.asciiValue!)] = Int8(index)
    if let upper = Character(char.uppercased()).asciiValue {
      table[Int(upper)] = Int8(index)
    }
  }
  // Handle common substitutions (both cases)
  table[Int(Character("O").asciiValue!)] = 0 // O -> 0
  table[Int(Character("o").asciiValue!)] = 0
  table[Int(Character("I").asciiValue!)] = 1 // I -> 1
  table[Int(Character("i").asciiValue!)] = 1
  table[Int(Character("L").asciiValue!)] = 1 // L -> 1
  table[Int(Character("l").asciiValue!)] = 1
  return table
}()

/// Encodes 5 bytes (40 bits) to 8 Crockford Base32 characters
private func encodeCrockfordBase32(_ bytes: some Collection<UInt8>) -> String {
  precondition(bytes.count == 5)
  let byteArray = Array(bytes)

  // Pack 5 bytes into a 40-bit value
  var bits: UInt64 = 0
  for byte in byteArray {
    bits = (bits << 8) | UInt64(byte)
  }

  // Extract 8 groups of 5 bits, MSB first
  var result = ""
  result.reserveCapacity(8)
  for shift in stride(from: 35, through: 0, by: -5) {
    let index = Int((bits >> shift) & 0x1F)
    result.append(crockfordAlphabet[index])
  }
  return result
}

/// Validates a string contains only valid Crockford Base32 characters
private func isValidCrockfordBase32(_ string: String) -> Bool {
  for char in string {
    guard let ascii = char.asciiValue, ascii < 128, crockfordDecodeTable[Int(ascii)] >= 0 else {
      return false
    }
  }
  return true
}

/// Normalizes a Crockford Base32 string to lowercase canonical form
private func normalizeCrockfordBase32(_ string: String) -> String {
  var result = ""
  result.reserveCapacity(string.count)
  for char in string {
    guard let ascii = char.asciiValue, ascii < 128 else { continue }
    let value = crockfordDecodeTable[Int(ascii)]
    if value >= 0 {
      result.append(crockfordAlphabet[Int(value)])
    }
  }
  return result
}

/// Parsed reaction data extracted from wire format
public struct ParsedReaction: Sendable, Equatable {
  public let emoji: String
  public let targetSender: String
  public let messageHash: String // 8 Crockford Base32 chars (lowercase)
}

/// Parsed DM reaction data (shorter format without sender)
public struct ParsedDMReaction: Sendable, Equatable {
  public let emoji: String
  public let messageHash: String // 8 Crockford Base32 chars (lowercase)
}

/// Parses and builds the reaction wire format.
///
/// Three formats are on the wire; see `docs/Reactions.md` for the interoperability spec.
///
/// - v3 (piggyback, canonical — always emitted):
///   - channel: `{emoji} reacted to "{snippet}" @[{sender}]\n{hash}`
///   - DM: `{emoji} reacted to "{snippet}"\n{hash}`
///   Structurally a v1 reaction whose emoji field carries a readable phrase: stock
///   upstream MC1 parses it with its v1-only parser (exact `@[{sender}]`, trailing
///   hash line) and attaches it to the right message, while clients with no reactions
///   support display a sentence. The phrase must never contain `:` or `,` — it lands
///   verbatim in upstream's `{emoji}:{count}` summary cache — nor a second `@[`.
/// - v2 (human-readable — accepted on receive; emitted by fork Builds 19–40):
///   - channel: `{emoji} reacted to [{sender}]: "{snippet}" ({hash})`
///   - DM: `{emoji} reacted to: "{snippet}" ({hash})`
/// - v1 (legacy — accepted on receive; emitted by stock upstream MC1):
///   - channel: `{emoji}@[{sender}]\n{hash}`
///   - DM: `{emoji}\n{hash}`
///
/// Parsing tries v3, then v2, then v1. The `{snippet}` is a cosmetic echo of the
/// target text and is never parsed or compared — only `{hash}` carries identity.
public enum ReactionParser {
  /// Returns true if the text matches any known reaction format (PocketMesh or meshcore-open).
  static func isReactionText(_ text: String, isDM: Bool) -> Bool {
    if MeshCoreOpenReactionParser.parse(text) != nil { return true }
    // meshcore-open v1 carries a free-text emoji field, so it gets the same validation the
    // receive handlers apply — otherwise this would classify as a reaction a string those
    // handlers hand back to plain-message handling.
    if let v1 = MeshCoreOpenReactionParser.parseV1(text), isValidReactionEmoji(v1.emoji) {
      return true
    }
    return isDM ? parseDM(text) != nil : parse(text) != nil
  }

  /// Parses channel reaction text. Tries v3 piggyback, then human-readable v2, then legacy v1.
  public static func parse(_ text: String) -> ParsedReaction? {
    if let result = parsePiggyback(text) { return result }
    if let result = parseHumanReadable(text) { return result }
    return parseLegacy(text)
  }

  /// Parses DM reaction text. Tries v3 piggyback, then human-readable v2, then legacy v1.
  public static func parseDM(_ text: String) -> ParsedDMReaction? {
    if let result = parseDMPiggyback(text) { return result }
    if let result = parseDMHumanReadable(text) { return result }
    return parseDMLegacy(text)
  }

  // MARK: - Emoji Field Validation

  /// Validates the emoji field extracted from a received reaction.
  ///
  /// The field is unbounded on the wire but lands in the persisted summary cache, whose own
  /// grammar is `{emoji}:{count}` pairs joined by `,` — so accepting anything that merely
  /// *starts* with an emoji lets a peer with the channel key inject those delimiters and
  /// fabricate counts. Every legitimate producer (this app's picker, a Build-40 fork,
  /// meshcore-open's emoji table) sends exactly one emoji grapheme cluster, so that is what
  /// is accepted. Rejection is not an error path: the text falls through to plain-message
  /// handling, which is what a client with no reactions support displays anyway.
  static func isValidReactionEmoji(_ emoji: String) -> Bool {
    guard emoji.count == 1, let cluster = emoji.first, cluster.isEmoji else { return false }
    return cluster.unicodeScalars.allSatisfy(isEmojiComponentScalar)
  }

  /// Whether a scalar may appear inside a reaction's emoji cluster: an emoji scalar (which
  /// covers skin-tone modifiers and regional indicators), a joiner or variation selector,
  /// the keycap enclosing mark, or a tag character from a subdivision flag.
  private static func isEmojiComponentScalar(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.properties.isEmoji { return true }
    switch scalar.value {
    case 0x200D, 0xFE0E, 0xFE0F, 0x20E3: return true
    case 0xE0020...0xE007F: return true
    default: return false
    }
  }

  // MARK: - Piggyback Format (v3)

  /// Parses the piggyback channel reaction format.
  /// Format: `{emoji} reacted to "{snippet}" @[{sender}]\n{hash}`
  private static func parsePiggyback(_ text: String) -> ParsedReaction? {
    guard let newlineIndex = text.lastIndex(of: "\n") else { return nil }

    let rawHash = String(text[text.index(after: newlineIndex)...])
    guard rawHash.count == 8, isValidCrockfordBase32(rawHash) else { return nil }
    let messageHash = normalizeCrockfordBase32(rawHash)

    let withoutHash = String(text[..<newlineIndex])

    // The structural `@[` is the first occurrence — the snippet sanitizer guarantees
    // an echoed `@[` never survives into the phrase.
    guard let atBracket = withoutHash.range(of: "@[") else { return nil }
    let afterAtBracket = withoutHash[atBracket.upperBound...]
    guard afterAtBracket.hasSuffix("]") else { return nil }
    let sender = String(afterAtBracket.dropLast())
    guard !sender.isEmpty else { return nil }

    let phrase = withoutHash[..<atBracket.lowerBound]
    guard let emoji = piggybackEmoji(fromPhrase: phrase, phraseSuffix: "\" ") else { return nil }

    return ParsedReaction(emoji: emoji, targetSender: sender, messageHash: messageHash)
  }

  /// Parses the piggyback DM reaction format.
  /// Format: `{emoji} reacted to "{snippet}"\n{hash}`
  private static func parseDMPiggyback(_ text: String) -> ParsedDMReaction? {
    // Reject the channel form — its `@[{sender}]` would land inside the phrase here.
    // Mirrors upstream MC1's own DM/channel discrimination so both classify alike.
    if text.contains("@[") { return nil }

    guard let newlineIndex = text.lastIndex(of: "\n") else { return nil }

    let rawHash = String(text[text.index(after: newlineIndex)...])
    guard rawHash.count == 8, isValidCrockfordBase32(rawHash) else { return nil }
    let messageHash = normalizeCrockfordBase32(rawHash)

    let phrase = text[..<newlineIndex]
    guard let emoji = piggybackEmoji(fromPhrase: phrase, phraseSuffix: "\"") else { return nil }

    return ParsedDMReaction(emoji: emoji, messageHash: messageHash)
  }

  /// Extracts and validates the leading emoji of a piggyback phrase
  /// (`{emoji} reacted to "{snippet}"` + the given suffix). Returns nil when the
  /// phrase doesn't have that structure.
  private static func piggybackEmoji(fromPhrase phrase: Substring, phraseSuffix: String) -> String? {
    guard let cluster = phrase.first else { return nil }
    let emoji = String(cluster)
    guard isValidReactionEmoji(emoji) else { return nil }

    let rest = phrase.dropFirst()
    guard rest.hasPrefix(" reacted to \""), rest.hasSuffix(phraseSuffix) else { return nil }
    return emoji
  }

  // MARK: - Human-Readable Format (v2)

  /// Parses the human-readable channel reaction format.
  /// Format: `{emoji} reacted to [{sender}]: "{snippet}" ({hash})`
  private static func parseHumanReadable(_ text: String) -> ParsedReaction? {
    // Step 1: Extract hash from trailing " ({8-char-hash})"
    guard let hash = extractTrailingHash(text) else { return nil }
    let withoutHash = String(text[..<text.index(text.endIndex, offsetBy: -(hash.count + 3))])

    // Step 2: Find " reacted to [" to locate the sender. `range(of:)` finds the first
    // occurrence, which is the structural one — the snippet that follows can echo the
    // marker verbatim without stealing the match.
    guard let reactedRange = withoutHash.range(of: " reacted to [") else { return nil }

    let emoji = String(withoutHash[..<reactedRange.lowerBound])
    guard isValidReactionEmoji(emoji) else { return nil }

    // Step 3: Extract sender from "[sender]: " after "reacted to"
    let afterReacted = withoutHash[reactedRange.upperBound...]
    guard let closeBracket = afterReacted.range(of: "]: ") else { return nil }
    let sender = String(afterReacted[..<closeBracket.lowerBound])
    guard !sender.isEmpty else { return nil }

    return ParsedReaction(emoji: emoji, targetSender: sender, messageHash: hash)
  }

  /// Parses the human-readable DM reaction format.
  /// Format: `{emoji} reacted to: "{snippet}" ({hash})`
  private static func parseDMHumanReadable(_ text: String) -> ParsedDMReaction? {
    guard let hash = extractTrailingHash(text) else { return nil }
    let withoutHash = String(text[..<text.index(text.endIndex, offsetBy: -(hash.count + 3))])

    guard let reactedRange = withoutHash.range(of: " reacted to: ") else { return nil }

    // Structural, not whole-string: everything before the first marker must be the emoji
    // field. That rejects the channel format (its bracketed sender sits there) without
    // rejecting a DM whose snippet merely quotes a marker.
    let emoji = String(withoutHash[..<reactedRange.lowerBound])
    guard isValidReactionEmoji(emoji) else { return nil }

    return ParsedDMReaction(emoji: emoji, messageHash: hash)
  }

  /// Extracts an 8-char Crockford Base32 hash from a trailing `" ({hash})"` pattern.
  /// Returns the normalized (lowercase) hash, or nil if the shape doesn't match.
  private static func extractTrailingHash(_ text: String) -> String? {
    guard text.hasSuffix(")") else { return nil }

    let withoutParen = text.dropLast() // remove ")"
    guard withoutParen.count >= 10 else { return nil } // " (" + 8 chars minimum
    let hashStart = withoutParen.index(withoutParen.endIndex, offsetBy: -8)
    let rawHash = String(withoutParen[hashStart...])
    guard isValidCrockfordBase32(rawHash) else { return nil }

    // Verify " (" precedes the hash
    guard withoutParen[..<hashStart].hasSuffix(" (") else { return nil }

    return normalizeCrockfordBase32(rawHash)
  }

  // MARK: - Legacy Format (v1)

  /// Parses the legacy channel reaction format.
  /// Format: `{emoji}@[{sender}]\n{hash}`
  private static func parseLegacy(_ text: String) -> ParsedReaction? {
    // Step 1: Split on last newline to get hash
    guard let newlineIndex = text.lastIndex(of: "\n") else {
      return nil
    }

    let rawHash = String(text[text.index(after: newlineIndex)...])
    guard rawHash.count == 8, isValidCrockfordBase32(rawHash) else {
      return nil
    }
    let messageHash = normalizeCrockfordBase32(rawHash)

    // Remove hash suffix (everything before the newline)
    let withoutHash = String(text[..<newlineIndex])

    // Step 2: Find `@[` to locate sender start
    guard let atBracketIndex = withoutHash.range(of: "@[") else {
      return nil
    }

    let emoji = String(withoutHash[..<atBracketIndex.lowerBound])

    guard isValidReactionEmoji(emoji) else {
      return nil
    }

    let afterAtBracket = withoutHash[atBracketIndex.upperBound...]

    // Step 3: Extract sender (everything up to closing bracket)
    guard afterAtBracket.hasSuffix("]") else {
      return nil
    }

    let sender = String(afterAtBracket.dropLast())

    guard !sender.isEmpty else {
      return nil
    }

    return ParsedReaction(
      emoji: emoji,
      targetSender: sender,
      messageHash: messageHash
    )
  }

  /// Parses the legacy DM reaction format.
  /// Format: `{emoji}\n{hash}` (no sender field)
  private static func parseDMLegacy(_ text: String) -> ParsedDMReaction? {
    // Reject channel format (contains `@[`)
    if text.contains("@[") {
      return nil
    }

    // Split on newline to get hash
    guard let newlineIndex = text.lastIndex(of: "\n") else {
      return nil
    }

    let rawHash = String(text[text.index(after: newlineIndex)...])
    guard rawHash.count == 8, isValidCrockfordBase32(rawHash) else {
      return nil
    }
    let messageHash = normalizeCrockfordBase32(rawHash)

    // Extract emoji (everything before the newline)
    let emoji = String(text[..<newlineIndex])

    guard isValidReactionEmoji(emoji) else {
      return nil
    }

    return ParsedDMReaction(emoji: emoji, messageHash: messageHash)
  }

  // MARK: - Building

  /// Safety headroom (UTF-8 bytes) reserved below the firmware transmit ceiling
  /// when building reactions. The snippet is cosmetic, but the trailing hash is
  /// load-bearing: if the firmware truncates the tail (e.g. because the prepended
  /// node name is a byte longer than the app measured, or the true text ceiling
  /// is slightly under our constant), it clips the hash mid-string and the
  /// reaction fails to parse. Reserving headroom keeps the hash clear of that edge.
  static let reactionByteMargin = 8

  /// Prepares target text for embedding as a piggyback snippet.
  ///
  /// The piggyback phrase travels through upstream MC1's v1 parser as its *emoji field*
  /// and from there into its persisted `{emoji}:{count}` summary cache, so the snippet
  /// must never carry the cache delimiters — `:` and `,` become spaces (as do line
  /// breaks, which the trailing-hash split can't contain). An echoed `@[` would end the
  /// phrase early on any first-match parser, so a no-break space splits it — invisible
  /// in display, structurally inert. Space runs left by the replacements collapse.
  private static func sanitizePiggybackSnippet(_ text: String) -> String {
    let neutralized = text.replacingOccurrences(of: "@[", with: "@\u{00A0}[")
    let delimiters: Set<Character> = [":", ",", "\n", "\r"]
    var result = String(neutralized.map { delimiters.contains($0) ? " " : $0 })
    while result.contains("  ") {
      result = result.replacingOccurrences(of: "  ", with: " ")
    }
    return result
  }

  /// Builds piggyback channel reaction text.
  /// Format: `{emoji} reacted to "{snippet}" @[{sender}]\n{hash}`
  ///
  /// The budget is computed against the protocol's worst-case node name
  /// (`ProtocolLimits.maxUsableNameBytes`), not the actual local name: upstream MC1
  /// groups badge counts by the full phrase string, so two reactors sending the same
  /// emoji to the same message must emit byte-identical text regardless of their own
  /// name lengths. The hash suffix is always preserved — the display fields absorb
  /// the budget instead: the bracketed sender first, then the snippet.
  static func buildChannelReactionText(
    emoji: String,
    targetSender: String,
    targetText: String,
    targetTimestamp: UInt32,
    localNodeNameByteCount: Int
  ) -> String {
    let hash = generateMessageHash(text: targetText, timestamp: targetTimestamp)
    let totalBudget = max(0, ProtocolLimits.maxChannelMessageLength(
      nodeNameByteCount: max(localNodeNameByteCount, ProtocolLimits.maxUsableNameBytes)
    ) - reactionByteMargin)

    // The sender field yields before the snippet: it must survive byte-exact for
    // upstream's sender-gated matching, but a name long enough to threaten the trailing
    // hash can't be matched by anyone anyway, so clamping it is the lesser harm.
    let closing = "\"\u{0020}@[]\n\(hash)"
    let framing = "\(emoji) reacted to \"".utf8.count + closing.utf8.count
    let sender = truncateToFit(targetSender, maxBytes: max(0, totalBudget - framing))
    let prefix = "\(emoji) reacted to \""
    let suffix = "\" @[\(sender)]\n\(hash)"
    let snippetBudget = max(0, totalBudget - prefix.utf8.count - suffix.utf8.count)
    let snippet = truncateToFit(sanitizePiggybackSnippet(targetText), maxBytes: snippetBudget)
    return "\(prefix)\(snippet)\(suffix)"
  }

  /// Builds piggyback DM reaction text.
  /// Format: `{emoji} reacted to "{snippet}"\n{hash}`
  ///
  /// Capped at `ProtocolLimits.maxDirectMessageLength` minus `reactionByteMargin`;
  /// no node-name prefix is prepended on the DM path.
  static func buildDMReactionText(
    emoji: String,
    targetText: String,
    targetTimestamp: UInt32
  ) -> String {
    let hash = generateMessageHash(text: targetText, timestamp: targetTimestamp)
    let overhead = emoji.utf8.count + " reacted to \"".utf8.count + "\"\n".utf8.count + 8
    let snippetBudget = max(0, ProtocolLimits.maxDirectMessageLength - overhead - reactionByteMargin)
    let snippet = truncateToFit(sanitizePiggybackSnippet(targetText), maxBytes: snippetBudget)
    return "\(emoji) reacted to \"\(snippet)\"\n\(hash)"
  }

  /// Truncates a string to fit within a UTF-8 byte budget, appending "..." if truncated.
  /// Respects character boundaries (never splits a multi-byte character).
  private static func truncateToFit(_ text: String, maxBytes: Int) -> String {
    // Already fits: return unchanged.
    guard text.utf8.count > maxBytes else { return text }
    // Budget too small to hold even the "..." marker: return as much of the
    // ellipsis as fits (never the full text, which would blow the budget).
    guard maxBytes > 3 else { return String("...".prefix(max(0, maxBytes))) }
    let target = maxBytes - 3 // room for "..."
    var result = ""
    var byteCount = 0
    for char in text {
      let charBytes = String(char).utf8.count
      if byteCount + charBytes > target { break }
      result.append(char)
      byteCount += charBytes
    }
    return result + "..."
  }

  /// Generates message identifier for reaction wire format (8-char Crockford Base32)
  public static func generateMessageHash(text: String, timestamp: UInt32) -> String {
    var data = Data(text.utf8)
    withUnsafeBytes(of: timestamp.littleEndian) { data.append(contentsOf: $0) }
    let digest = SHA256.hash(data: data)
    let bytes = Array(digest.prefix(5))
    return encodeCrockfordBase32(bytes)
  }

  /// Builds summary string from emoji counts, sorted by count descending
  static func buildSummary(from reactions: [(emoji: String, count: Int)]) -> String {
    reactions
      .sorted { $0.count > $1.count }
      .map { "\($0.emoji):\($0.count)" }
      .joined(separator: ",")
  }

  /// Builds summary string from reaction DTOs.
  /// Sorts by count descending, then by earliest timestamp ascending for tie-breaker.
  static func buildSummary(from reactions: [ReactionDTO]) -> String {
    let grouped = Dictionary(grouping: reactions, by: \.emoji)
    let sorted = grouped.map { emoji, items in
      (emoji: emoji, count: items.count, earliest: items.map(\.receivedAt).min() ?? Date.distantPast)
    }
    .sorted { lhs, rhs in
      if lhs.count != rhs.count { return lhs.count > rhs.count }
      return lhs.earliest < rhs.earliest
    }
    return sorted.map { "\($0.emoji):\($0.count)" }.joined(separator: ",")
  }

  /// Parses summary string into emoji/count pairs.
  ///
  /// Malformed pairs are dropped rather than rendered: a cache written before the emoji
  /// field was validated on receive can hold injected delimiters, and those must not keep
  /// producing badges after the upgrade.
  public static func parseSummary(_ summary: String?) -> [(emoji: String, count: Int)] {
    guard let summary, !summary.isEmpty else { return [] }

    return summary.split(separator: ",").compactMap { part in
      let components = part.split(separator: ":")
      guard components.count == 2,
            let count = Int(components[1]), count > 0,
            isValidReactionEmoji(String(components[0])) else { return nil }
      return (String(components[0]), count)
    }
  }
}
