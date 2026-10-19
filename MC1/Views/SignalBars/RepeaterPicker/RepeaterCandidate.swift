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
/// Conforming to ``RepeaterResolvable`` is what lets ``NodeSearchEngine`` rank these
/// directly: the picker's search field runs the same matcher, with the same strict-hex
/// and prefix-priority rules, as the contacts and discovery lists.
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

  /// The engine's view of this candidate.
  var benchmarkTarget: BenchmarkTarget {
    BenchmarkTarget(publicKey: publicKey, name: displayName)
  }
}

// MARK: - RepeaterResolvable

extension RepeaterCandidate: RepeaterResolvable {
  /// The picker searches what it shows. An unnamed candidate is labelled with its hash, so
  /// typing that hash finds it by name as well as by key — either route reaches the row.
  var resolvableName: String {
    displayName
  }

  /// Candidates carry no advert timestamp of their own; ``lastSeen`` is the recency signal,
  /// and ``recencyDate`` is where the search engine looks for it.
  var lastAdvertTimestamp: UInt32 {
    0
  }

  var recencyDate: Date {
    lastSeen ?? .distantPast
  }

  /// The picker has no map, and a candidate is worth probing wherever it is.
  var latitude: Double {
    0
  }

  var longitude: Double {
    0
  }

  var hasLocation: Bool {
    false
  }
}
