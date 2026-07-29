import Foundation

/// A route another user embedded in message text via Reply with Route
/// ("RX via 80,8F,0C. 3 hops 2.3 mi"), as opposed to the path recorded on the
/// message itself (`MessageDTO.pathNodes`). Hex IDs are kept as the sender
/// wrote them; `hashBytesPerHop` is the lossless byte form used for repeater
/// resolution, which must not silently shorten a multi-byte hash — a hop that
/// fails to decode is dropped rather than truncated.
public struct SharedRoute: Sendable, Hashable, Identifiable {
  /// Raw hex ID strings as they appeared in the text (e.g. ["80", "8F", "0C"]).
  public let hexIDs: [String]
  /// Hop count stated in the text. Kept separate from `hexIDs.count` because
  /// the sender's stated count is what the card displays, even if it disagrees.
  /// For a detected chain there is no stated count, so it is the ID count.
  public let hopCount: Int
  /// Distance text as written by the sender (e.g. "2.3 mi", "≥ 12 km"). Not
  /// recomputed locally: the sender resolved hops we may not know about.
  public let distanceText: String?

  public var id: String { hexIDs.joined(separator: ",") }

  public init(hexIDs: [String], hopCount: Int, distanceText: String?) {
    self.hexIDs = hexIDs
    self.hopCount = hopCount
    self.distanceText = distanceText
  }

  /// Per-hop hash bytes for repeater resolution. Each hex ID is 2, 4, or 6
  /// characters → 1, 2, or 3 bytes (multi-byte hashes come from newer
  /// firmware). A full 64-character public key is truncated to its 3-byte
  /// prefix, which is the longest form the resolvers match on.
  public var hashBytesPerHop: [Data] {
    hexIDs.compactMap { hex in
      let workingHex = hex.count == 64 ? String(hex.prefix(6)) : hex
      var bytes = Data()
      var index = workingHex.startIndex
      while index < workingHex.endIndex {
        let next = workingHex.index(index, offsetBy: 2, limitedBy: workingHex.endIndex) ?? workingHex.endIndex
        guard let byte = UInt8(workingHex[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
      }
      return bytes.isEmpty ? nil : bytes
    }
  }
}

/// Single source of truth for detecting "RX via ..." shared routes in message
/// text. The fragment builder (inline card) and anything else that reacts to
/// shared routes must route through this so they never disagree on what counts
/// as one.
public enum SharedRouteParser {

  // swiftlint:disable force_try
  /// Matches "RX via {hex},{hex},...  {N} hop(s){optional distance tail}".
  /// Hex IDs are 2–6 hex digits each (1–3 byte hash). The tail is captured
  /// verbatim to end-of-line and trimmed, so unit/precision stay exactly as the
  /// sender wrote them. `try!` is intentional: the pattern is a literal, so an
  /// init failure is a programmer error that must crash at first use rather
  /// than silently disable route cards.
  private static let routeRegex = try! NSRegularExpression(
    pattern: #"RX via ([0-9A-Fa-f]{2,6}(?:,[0-9A-Fa-f]{2,6})*)\.\s+(\d+)\s+hops?([^\n]*)"#
  )
  // swiftlint:enable force_try

  /// Parse the first "RX via ..." route in the text, or nil if none matches.
  public static func parse(_ text: String) -> SharedRoute? {
    // Fast path: skip regex engine entry for the vast majority of messages.
    guard text.contains("RX via") else { return nil }

    let nsRange = NSRange(text.startIndex..., in: text)
    guard let match = routeRegex.firstMatch(in: text, range: nsRange),
          match.numberOfRanges == 4,
          let hexRange = Range(match.range(at: 1), in: text),
          let hopRange = Range(match.range(at: 2), in: text),
          let hopCount = Int(text[hopRange]) else { return nil }

    let hexIDs = text[hexRange].split(separator: ",").map(String.init)
    guard !hexIDs.isEmpty else { return nil }

    var distanceText: String?
    if let tailRange = Range(match.range(at: 3), in: text) {
      let trimmed = text[tailRange].trimmingCharacters(in: .whitespaces)
      distanceText = trimmed.isEmpty ? nil : trimmed
    }

    return SharedRoute(hexIDs: hexIDs, hopCount: hopCount, distanceText: distanceText)
  }

  /// Valid token lengths for a chain hop: 2, 4, or 6 hex chars (1–3 byte
  /// hashes) or 64 (a full 32-byte public key).
  private static let chainTokenLengths: Set<Int> = [2, 4, 6, 64]

  private static let hexCharacters = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")

  /// Detect a bare hex-ID chain pasted into a message ("51fb,1776,e19e,42da"),
  /// the informal cousin of Reply with Route. Returns the longest run of 2+
  /// consecutive valid tokens; a lone token is too ambiguous to card. At least
  /// one token in the run must contain a hex letter — an all-digit run is far
  /// more likely a list of numbers ("2024, 2025") than a path. Never fires on
  /// "RX via" text, which `parse` owns.
  public static func detectChain(_ text: String) -> SharedRoute? {
    if text.contains("RX via") { return nil }

    var currentRun: [String] = []
    var bestRun: [String] = []

    for word in text.components(separatedBy: .whitespacesAndNewlines) {
      for token in word.split(separator: ",").map(String.init) {
        if isValidChainToken(token) {
          currentRun.append(token.uppercased())
        } else {
          if currentRun.count > bestRun.count { bestRun = currentRun }
          currentRun = []
        }
      }
    }
    if currentRun.count > bestRun.count { bestRun = currentRun }

    guard bestRun.count >= 2,
          bestRun.contains(where: { $0.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEF")) != nil })
    else { return nil }

    return SharedRoute(hexIDs: bestRun, hopCount: bestRun.count, distanceText: nil)
  }

  private static func isValidChainToken(_ token: String) -> Bool {
    guard chainTokenLengths.contains(token.count) else { return false }
    return token.unicodeScalars.allSatisfy { hexCharacters.contains($0) }
  }
}
