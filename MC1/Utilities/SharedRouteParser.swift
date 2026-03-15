import Foundation
import os.log

private let logger = Logger(subsystem: "com.pocketmesh", category: "SharedRouteParser")

/// Parsed shared route data extracted from "RX via ..." message text.
/// Represents a route that was embedded by another user via "Reply with Route".
struct SharedRoute: Sendable, Hashable, Identifiable {
    /// Raw hex ID strings (e.g., ["80", "8F", "0C"])
    let hexIDs: [String]
    /// Number of hops stated in the text
    let hopCount: Int
    /// Optional distance string (e.g., "2.3 mi", "≥ 12 km")
    let distanceText: String?

    var id: String { hexIDs.joined(separator: ",") }

    /// Convert hex strings back to Data for RepeaterResolver lookups.
    /// Each hex string is 2, 4, or 6 characters → 1, 2, or 3 bytes.
    var hashBytesPerHop: [Data] {
        hexIDs.compactMap { hex in
            var bytes = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
                if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                    bytes.append(byte)
                }
                index = nextIndex
            }
            return bytes.isEmpty ? nil : bytes
        }
    }
}

/// Parses "RX via ..." route info from message text.
enum SharedRouteParser {

    // Pattern: "RX via {hex1},{hex2},...{hexN}. {N} hop(s){optional distance}"
    // Hex IDs: 2-6 uppercase hex digits each (1-3 byte hash)
    // Example: "RX via 80,8F,0C. 3 hops 2.3 mi"
    private static let regex: NSRegularExpression? = {
        let pattern = #"RX via ([0-9A-Fa-f]{2,6}(?:,[0-9A-Fa-f]{2,6})*)\.\s+(\d+)\s+hops?(.*)"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Parse "RX via ..." pattern from message text. Returns nil if not found.
    static func parse(_ text: String) -> SharedRoute? {
        guard let regex else {
            logger.error("SharedRouteParser: regex failed to compile")
            return nil
        }

        // Log the text we're trying to parse (truncated for readability)
        let preview = text.count > 200 ? String(text.prefix(200)) + "…" : text
        let escapedPreview = preview.replacingOccurrences(of: "\n", with: "\\n")
        logger.debug("SharedRouteParser: parsing text: \"\(escapedPreview, privacy: .public)\"")

        // Check if "RX via" appears at all before regex
        if text.contains("RX via") {
            logger.info("SharedRouteParser: found 'RX via' substring in text")
            // Extract the line containing "RX via" for closer inspection
            if let rxRange = text.range(of: "RX via") {
                let lineStart = text[..<rxRange.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                let lineEnd = text[rxRange.upperBound...].firstIndex(of: "\n") ?? text.endIndex
                let rxLine = String(text[lineStart..<lineEnd])
                logger.info("SharedRouteParser: RX line: \"\(rxLine, privacy: .public)\"")
            }
        } else {
            logger.debug("SharedRouteParser: no 'RX via' substring found")
            return nil
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange) else {
            logger.warning("SharedRouteParser: regex did NOT match despite 'RX via' being present")
            return nil
        }

        // Group 1: comma-separated hex IDs
        guard let hexRange = Range(match.range(at: 1), in: text) else {
            logger.error("SharedRouteParser: match found but group 1 (hexIDs) range invalid")
            return nil
        }
        let hexString = String(text[hexRange])
        let hexIDs = hexString.split(separator: ",").map(String.init)
        guard !hexIDs.isEmpty else {
            logger.error("SharedRouteParser: hex string parsed but empty: \"\(hexString, privacy: .public)\"")
            return nil
        }

        // Group 2: hop count
        guard let hopRange = Range(match.range(at: 2), in: text),
              let hopCount = Int(text[hopRange]) else {
            logger.error("SharedRouteParser: match found but hop count group invalid")
            return nil
        }

        // Group 3: optional distance text (may be empty)
        let distanceText: String?
        if match.range(at: 3).location != NSNotFound,
           let distRange = Range(match.range(at: 3), in: text) {
            let trimmed = text[distRange].trimmingCharacters(in: .whitespacesAndNewlines)
            distanceText = trimmed.isEmpty ? nil : trimmed
        } else {
            distanceText = nil
        }

        logger.info("SharedRouteParser: ✓ parsed route — hexIDs=\(hexIDs, privacy: .public), hops=\(hopCount), distance=\(distanceText ?? "none", privacy: .public)")
        return SharedRoute(hexIDs: hexIDs, hopCount: hopCount, distanceText: distanceText)
    }
}
