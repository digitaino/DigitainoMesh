import Foundation

/// Shared interface for types that can be matched by ``NodeIdentityResolver``.
/// Both `ContactDTO` and `DiscoveredNodeDTO` conform.
public protocol RepeaterResolvable: Sendable {
  var publicKey: Data { get }
  var latitude: Double { get }
  var longitude: Double { get }
  var hasLocation: Bool { get }
  var lastAdvertTimestamp: UInt32 { get }
  /// Secondary recency tiebreaker (ContactDTO → lastModified, DiscoveredNodeDTO → lastHeard).
  var recencyDate: Date { get }
  /// Display name used for path hops and resolver tiebreaking.
  var resolvableName: String { get }
  /// Whether this candidate drops out of resolution once it goes stale.
  ///
  /// `true` for passively discovered nodes, which may have been deleted or moved since
  /// they were last heard and must not win a hash collision against an active node.
  /// `false` — the default — for records the user deliberately keeps, such as saved
  /// contacts, which stay resolvable however long they have been quiet.
  var expiresWhenStale: Bool { get }
}

public extension RepeaterResolvable {
  var expiresWhenStale: Bool {
    false
  }
}
