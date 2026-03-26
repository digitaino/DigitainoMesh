import Foundation
import os.log

private let logger = Logger(subsystem: "com.pocketmesh", category: "HexPathParser")

/// A manually-entered path of hex IDs for visualization on a map.
/// Unlike `SharedRoute`, this has no sender/receiver and no distance metadata.
struct HexPath: Sendable, Hashable, Identifiable {
    /// Raw hex ID strings (e.g., ["A3", "7F42", "A3B5C9"])
    let hexIDs: [String]
    /// Optional server-hosted share URL (e.g., "https://mesh.digitaino.com/p/a3Kx9m")
    let shareURL: URL?

    var id: String { hexIDs.joined(separator: ",") }

    /// Number of hops in the path.
    var hopCount: Int { hexIDs.count }

    /// Convert hex strings to Data for RepeaterResolver lookups.
    /// Handles 1-3 byte hashes (2-6 hex chars) and full 32-byte keys (64 hex chars).
    /// Full keys are truncated to a 3-byte prefix for matching.
    var hashBytesPerHop: [Data] {
        hexIDs.compactMap { hex in
            var workingHex = hex
            // Full 32-byte public key (64 hex chars) — truncate to 6 chars (3 bytes)
            if hex.count == 64 { workingHex = String(hex.prefix(6)) }
            var bytes = Data()
            var index = workingHex.startIndex
            while index < workingHex.endIndex {
                let nextIndex = workingHex.index(index, offsetBy: 2, limitedBy: workingHex.endIndex) ?? workingHex.endIndex
                if let byte = UInt8(workingHex[index..<nextIndex], radix: 16) {
                    bytes.append(byte)
                }
                index = nextIndex
            }
            return bytes.isEmpty ? nil : bytes
        }
    }

    /// Convert to a `SharedRoute` for compatibility with `SharedRouteMapViewModel`.
    var asSharedRoute: SharedRoute {
        SharedRoute(hexIDs: hexIDs, hopCount: hopCount, distanceText: nil, shareURL: shareURL)
    }
}

/// Parses hex path chains from user input and chat messages.
enum HexPathParser {

    /// Valid hex token lengths: 2, 4, 6 (1-3 byte hashes) or 64 (full 32-byte key).
    private static let validLengths: Set<Int> = [2, 4, 6, 64]

    private static let hexCharacterSet = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")

    /// Parse a free-form hex chain from user input (lenient mode).
    /// Accepts: "A3, 7F, 42" or "A3 7F 42" or "A3,7F,42" or mixed delimiters.
    /// Requires at least 2 valid hex tokens.
    static func parse(_ text: String) -> HexPath? {
        let tokens = tokenize(text)
        guard tokens.count >= 2 else { return nil }

        let validTokens = tokens.filter { isValidHexToken($0) }
        guard validTokens.count == tokens.count else { return nil }

        let hexIDs = validTokens.map { $0.uppercased() }
        logger.debug("HexPathParser: parsed \(hexIDs.count) hex IDs from input")
        return HexPath(hexIDs: hexIDs, shareURL: nil)
    }

    /// Detect a hex chain pattern in a chat message (strict mode).
    /// Requires 3+ tokens to reduce false positives.
    /// Skips messages containing "RX via" (handled by SharedRouteParser).
    static func detectInMessage(_ text: String) -> HexPath? {
        // Don't conflict with the formal "RX via ..." pattern
        if text.contains("RX via") { return nil }

        // Try to find a run of 3+ consecutive hex tokens in the message
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        var currentRun: [String] = []
        var bestRun: [String] = []

        for word in words {
            // Split word further by commas (handles "A3,7F,42" within text)
            let subTokens = word.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }

            for token in subTokens {
                if isValidHexToken(token) {
                    currentRun.append(token.uppercased())
                } else {
                    if currentRun.count > bestRun.count {
                        bestRun = currentRun
                    }
                    currentRun = []
                }
            }
        }
        if currentRun.count > bestRun.count {
            bestRun = currentRun
        }

        guard bestRun.count >= 3 else { return nil }

        logger.info("HexPathParser: detected \(bestRun.count) hex IDs in message")
        return HexPath(hexIDs: bestRun, shareURL: nil)
    }

    // MARK: - Private Helpers

    /// Split input text on commas and/or whitespace, producing clean tokens.
    private static func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ", \t\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Check if a string is a valid hex token (correct length and all hex chars).
    private static func isValidHexToken(_ token: String) -> Bool {
        guard validLengths.contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy { hexCharacterSet.contains($0) }
    }
}
