import Foundation
import CryptoKit

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
    table[Int(Character("O").asciiValue!)] = 0  // O -> 0
    table[Int(Character("o").asciiValue!)] = 0
    table[Int(Character("I").asciiValue!)] = 1  // I -> 1
    table[Int(Character("i").asciiValue!)] = 1
    table[Int(Character("L").asciiValue!)] = 1  // L -> 1
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
    public let messageHash: String  // 8 Crockford Base32 chars (lowercase)

    public init(
        emoji: String,
        targetSender: String,
        messageHash: String
    ) {
        self.emoji = emoji
        self.targetSender = targetSender
        self.messageHash = messageHash
    }
}

/// Parsed DM reaction data (shorter format without sender)
public struct ParsedDMReaction: Sendable, Equatable {
    public let emoji: String
    public let messageHash: String  // 8 Crockford Base32 chars (lowercase)

    public init(emoji: String, messageHash: String) {
        self.emoji = emoji
        self.messageHash = messageHash
    }
}

/// Parses reaction wire format with support for both human-readable and legacy formats.
///
/// Human-readable (v2): `{emoji} reacted to [{sender}]: "{snippet}" ({hash})`
/// Legacy (v1): `{emoji}@[{sender}]\n{hash}`
public enum ReactionParser {

    /// Returns true if the text matches any known reaction format (PocketMesh or meshcore-open).
    public static func isReactionText(_ text: String, isDM: Bool) -> Bool {
        if MeshCoreOpenReactionParser.parse(text) != nil { return true }
        if MeshCoreOpenReactionParser.parseV1(text) != nil { return true }
        return isDM ? parseDM(text) != nil : parse(text) != nil
    }

    /// Parses channel reaction text. Tries human-readable format first, then legacy.
    public static func parse(_ text: String) -> ParsedReaction? {
        if let result = parseHumanReadable(text) { return result }
        return parseLegacy(text)
    }

    /// Parses DM reaction text. Tries human-readable format first, then legacy.
    public static func parseDM(_ text: String) -> ParsedDMReaction? {
        if let result = parseDMHumanReadable(text) { return result }
        return parseDMLegacy(text)
    }

    // MARK: - Human-Readable Format (v2)

    /// Parses human-readable channel reaction format.
    /// Format: `{emoji} reacted to [{sender}]: "{snippet}" ({hash})`
    private static func parseHumanReadable(_ text: String) -> ParsedReaction? {
        // Step 1: Extract hash from trailing " ({8-char-hash})"
        guard let hash = extractTrailingHash(text) else { return nil }
        let withoutHash = String(text[..<text.index(text.endIndex, offsetBy: -(hash.count + 3))])

        // Step 2: Find " reacted to [" to locate the sender
        guard let reactedRange = withoutHash.range(of: " reacted to [") else { return nil }

        let emoji = String(withoutHash[..<reactedRange.lowerBound])
        guard !emoji.isEmpty, emoji.first?.isEmoji == true else { return nil }

        // Step 3: Extract sender from "[sender]: " after "reacted to"
        let afterReacted = withoutHash[reactedRange.upperBound...]
        guard let closeBracket = afterReacted.range(of: "]: ") else { return nil }
        let sender = String(afterReacted[..<closeBracket.lowerBound])
        guard !sender.isEmpty else { return nil }

        return ParsedReaction(
            emoji: emoji,
            targetSender: sender,
            messageHash: hash
        )
    }

    /// Parses human-readable DM reaction format.
    /// Format: `{emoji} reacted to: "{snippet}" ({hash})`
    private static func parseDMHumanReadable(_ text: String) -> ParsedDMReaction? {
        // Reject channel format
        if text.contains(" reacted to [") { return nil }

        // Step 1: Extract hash from trailing " ({8-char-hash})"
        guard let hash = extractTrailingHash(text) else { return nil }
        let withoutHash = String(text[..<text.index(text.endIndex, offsetBy: -(hash.count + 3))])

        // Step 2: Find " reacted to: " to locate the emoji
        guard let reactedRange = withoutHash.range(of: " reacted to: ") else { return nil }

        let emoji = String(withoutHash[..<reactedRange.lowerBound])
        guard !emoji.isEmpty, emoji.first?.isEmoji == true else { return nil }

        return ParsedDMReaction(emoji: emoji, messageHash: hash)
    }

    /// Extracts an 8-char Crockford Base32 hash from a trailing " ({hash})" pattern.
    /// Returns the normalized hash string, or nil if format doesn't match.
    private static func extractTrailingHash(_ text: String) -> String? {
        // Must end with ")"
        guard text.hasSuffix(")") else { return nil }

        // Find the " (" before the hash
        let withoutParen = text.dropLast() // remove ")"
        // The hash is 8 chars, preceded by " ("
        guard withoutParen.count >= 10 else { return nil } // " (" + 8 chars minimum
        let hashStart = withoutParen.index(withoutParen.endIndex, offsetBy: -8)
        let rawHash = String(withoutParen[hashStart...])
        guard isValidCrockfordBase32(rawHash) else { return nil }

        // Verify " (" precedes the hash
        let prefix = withoutParen[..<hashStart]
        guard prefix.hasSuffix(" (") else { return nil }

        return normalizeCrockfordBase32(rawHash)
    }

    // MARK: - Legacy Format (v1)

    /// Parses legacy channel reaction format.
    /// Format: `{emoji}@[{sender}]\n{hash}`
    private static func parseLegacy(_ text: String) -> ParsedReaction? {
        guard let newlineIndex = text.lastIndex(of: "\n") else { return nil }

        let rawHash = String(text[text.index(after: newlineIndex)...])
        guard rawHash.count == 8, isValidCrockfordBase32(rawHash) else { return nil }
        let messageHash = normalizeCrockfordBase32(rawHash)

        let withoutHash = String(text[..<newlineIndex])

        guard let atBracketIndex = withoutHash.range(of: "@[") else { return nil }

        let emoji = String(withoutHash[..<atBracketIndex.lowerBound])
        guard !emoji.isEmpty, emoji.first?.isEmoji == true else { return nil }

        let afterAtBracket = withoutHash[atBracketIndex.upperBound...]
        guard afterAtBracket.hasSuffix("]") else { return nil }

        let sender = String(afterAtBracket.dropLast())
        guard !sender.isEmpty else { return nil }

        return ParsedReaction(emoji: emoji, targetSender: sender, messageHash: messageHash)
    }

    /// Parses legacy DM reaction format.
    /// Format: `{emoji}\n{hash}`
    private static func parseDMLegacy(_ text: String) -> ParsedDMReaction? {
        if text.contains("@[") { return nil }

        guard let newlineIndex = text.lastIndex(of: "\n") else { return nil }

        let rawHash = String(text[text.index(after: newlineIndex)...])
        guard rawHash.count == 8, isValidCrockfordBase32(rawHash) else { return nil }
        let messageHash = normalizeCrockfordBase32(rawHash)

        let emoji = String(text[..<newlineIndex])
        guard !emoji.isEmpty, emoji.first?.isEmoji == true else { return nil }

        return ParsedDMReaction(emoji: emoji, messageHash: messageHash)
    }

    // MARK: - Building

    /// Builds human-readable channel reaction text.
    /// Format: `{emoji} reacted to [{sender}]: "{snippet}" ({hash})`
    ///
    /// The total reaction text (in UTF-8 bytes) is capped at
    /// `ProtocolLimits.maxChannelMessageLength(nodeNameByteCount:)` so that the
    /// firmware-prepended `"{NodeName}: "` plus the reaction stays within
    /// `maxChannelMessageTotalLength`. The hash suffix is always preserved —
    /// only the snippet is shortened if needed.
    public static func buildChannelReactionText(
        emoji: String,
        targetSender: String,
        targetText: String,
        targetTimestamp: UInt32,
        localNodeNameByteCount: Int
    ) -> String {
        let hash = generateMessageHash(text: targetText, timestamp: targetTimestamp)
        let prefix = "\(emoji) reacted to [\(targetSender)]: \""
        let closing = "\" (\(hash))"
        let totalBudget = ProtocolLimits.maxChannelMessageLength(
            nodeNameByteCount: localNodeNameByteCount
        )
        let snippetBudget = max(0, totalBudget - prefix.utf8.count - closing.utf8.count)
        let snippet = truncateToFit(targetText, maxBytes: snippetBudget)
        return "\(prefix)\(snippet)\(closing)"
    }

    /// Builds human-readable DM reaction text.
    /// Format: `{emoji} reacted to: "{snippet}" ({hash})`
    public static func buildDMReactionText(
        emoji: String,
        targetText: String,
        targetTimestamp: UInt32
    ) -> String {
        let hash = generateMessageHash(text: targetText, timestamp: targetTimestamp)
        let overhead = emoji.utf8.count + " reacted to: \"".utf8.count
            + "\" (".utf8.count + 8 + ")".utf8.count
        let snippet = truncateToFit(targetText, maxBytes: 150 - overhead)
        return "\(emoji) reacted to: \"\(snippet)\" (\(hash))"
    }

    /// Truncates a string to fit within a UTF-8 byte budget, appending "..." if truncated.
    /// Respects character boundaries (never splits a multi-byte character).
    private static func truncateToFit(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 3, text.utf8.count > maxBytes else { return text }
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
    public static func buildSummary(from reactions: [(emoji: String, count: Int)]) -> String {
        reactions
            .sorted { $0.count > $1.count }
            .map { "\($0.emoji):\($0.count)" }
            .joined(separator: ",")
    }

    /// Builds summary string from reaction DTOs using Element X-style ordering.
    /// Sorts by count descending, then by earliest timestamp ascending for tie-breaker.
    public static func buildSummary(from reactions: [ReactionDTO]) -> String {
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

    /// Parses summary string into emoji/count pairs
    public static func parseSummary(_ summary: String?) -> [(emoji: String, count: Int)] {
        guard let summary, !summary.isEmpty else { return [] }

        return summary.split(separator: ",").compactMap { part in
            let components = part.split(separator: ":")
            guard components.count == 2,
                  let count = Int(components[1]) else { return nil }
            return (String(components[0]), count)
        }
    }
}
