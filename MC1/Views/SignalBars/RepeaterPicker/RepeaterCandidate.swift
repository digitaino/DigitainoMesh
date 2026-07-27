import Foundation
import MC1Services

/// A repeater the user can point a tool at.
///
/// Identity is the public key, because that is what a probe is addressed with: a repeater
/// heard passively but never saved has no contact record and no name, and a saved contact
/// that has gone quiet still has a perfectly good key. Display is
/// ``NodeHexID``-based — hex plus a resolved name where one exists — so nothing here
/// string-compares hashes.
///
/// TODO(Phase5): retarget onto NodeSearch. §2.2 replaces the ad-hoc name/hex filtering in
/// `RepeaterPickerView` with the shared search engine and its ranking rules; this type
/// becomes a projection of a search result rather than its own loader.
struct RepeaterCandidate: Identifiable, Hashable {
  /// Full public key. Required — a candidate without one cannot be probed.
  let publicKey: Data
  /// Resolved display name, or `nil` when only the hash is known.
  let name: String?
  /// Hash at the radio's current path hash width.
  let hexID: NodeHexID
  let isFavorite: Bool
  /// When the node was last heard or last modified, for recency ordering.
  let lastSeen: Date?
  /// Whether the repeater is currently in the signal-bars table.
  let isHeard: Bool
  /// Quality of the RX leg when it is in the table.
  let rxQuality: SNRQuality

  var id: Data {
    publicKey
  }

  /// What the picker shows as the primary line.
  var displayName: String {
    name ?? hexID.hex
  }

  /// Whether a name was actually resolved, so the row can avoid printing the hash twice.
  var hasResolvedName: Bool {
    name != nil
  }

  /// Full-width hex, for hex-prefix search.
  var publicKeyHex: String {
    publicKey.map { String(format: "%02X", $0) }.joined()
  }

  /// The engine's view of this candidate.
  var benchmarkTarget: BenchmarkTarget {
    BenchmarkTarget(publicKey: publicKey, name: displayName)
  }

  /// Whether the free-text query matches this candidate by name or by hex prefix.
  func matches(query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return true }
    if let name, name.localizedStandardContains(trimmed) { return true }
    let hex = trimmed.uppercased()
    guard hex.allSatisfy(\.isHexDigit) else { return false }
    return publicKeyHex.hasPrefix(hex)
  }
}
