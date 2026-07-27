import Foundation

/// User corrections applied on top of automatic resolution: a hash ID pinned to the
/// public key (or a leading prefix of it) the user says it belongs to.
///
/// The disambiguation UI that produced these was dropped from the v2 scope, so nothing
/// populates the map yet; resolution accepts it now so adding that feature later is a
/// call-site change rather than a signature change.
public typealias NodeIdentityOverrides = [NodeHexID: Data]

/// The outcome of resolving a ``NodeHexID`` against a pool of candidates.
public struct NodeResolution<Candidate: RepeaterResolvable>: Sendable {
  /// The winning candidate.
  public let best: Candidate
  /// Every candidate that survived filtering, ranked best-first. Callers that can add
  /// their own signal — geographic proximity to a neighbouring hop, for instance — can
  /// re-rank this list instead of re-running the match.
  public let candidates: [Candidate]

  /// Whether more than one node answers to this hash, i.e. the answer is a best guess.
  public var isAmbiguous: Bool {
    candidates.count > 1
  }

  public init(best: Candidate, candidates: [Candidate]) {
    self.best = best
    self.candidates = candidates
  }
}

/// Resolves a node hash to the node it most likely names.
///
/// Implementations must be pure functions of their arguments — the caller supplies the
/// clock — so resolution is reproducible and unit-testable.
public protocol NodeIdentityResolving: Sendable {
  func resolve<Candidate: RepeaterResolvable>(
    _ id: NodeHexID,
    among candidates: [Candidate],
    now: Date,
    overrides: NodeIdentityOverrides
  ) -> NodeResolution<Candidate>?
}

public extension NodeIdentityResolving {
  /// Resolves without user corrections.
  func resolve<Candidate: RepeaterResolvable>(
    _ id: NodeHexID,
    among candidates: [Candidate],
    now: Date
  ) -> NodeResolution<Candidate>? {
    resolve(id, among: candidates, now: now, overrides: [:])
  }

  /// The winning candidate only, for callers that do not care about ambiguity.
  func bestMatch<Candidate: RepeaterResolvable>(
    for id: NodeHexID,
    among candidates: [Candidate],
    now: Date,
    overrides: NodeIdentityOverrides = [:]
  ) -> Candidate? {
    resolve(id, among: candidates, now: now, overrides: overrides)?.best
  }

  /// Resolves across both node sources at once — the entry point most callers want.
  func resolve(
    _ id: NodeHexID,
    contacts: [ContactDTO],
    discoveredNodes: [DiscoveredNodeDTO],
    now: Date,
    overrides: NodeIdentityOverrides = [:]
  ) -> NodeResolution<AnyResolvableNode>? {
    let pool = contacts.map(AnyResolvableNode.init) + discoveredNodes.map(AnyResolvableNode.init)
    return resolve(id, among: pool, now: now, overrides: overrides)
  }
}

/// The app's node-hash resolver.
///
/// Ranking, in order:
/// 1. **User correction** — a candidate pinned by ``NodeIdentityOverrides`` wins outright.
/// 2. **Match depth** — the candidate agreeing with the ID on the most bytes. This only
///    separates candidates when one holds a truncated key; full keys all match at the
///    ID's own width.
/// 3. **Recency** — the most recently advertised candidate. With a 1-byte hash there are
///    only 256 values, so collisions are routine and the node the radio heard most
///    recently is overwhelmingly the one that relayed the packet.
/// 4. **Secondary recency** — `recencyDate` (a contact's last modification, a discovered
///    node's last sighting).
/// 5. **Name**, then public key, so the order is total and the result deterministic.
///
/// Before ranking, candidates that opt into ``RepeaterResolvable/expiresWhenStale`` and
/// have not advertised within ``staleInterval`` are dropped entirely — a repeater that
/// has been silent for a week may have been deleted or moved, and must never outrank an
/// active one on a hash collision. Candidates that never advertised at all
/// (`lastAdvertTimestamp == 0`) are not treated as stale.
///
/// Geographic ranking is deliberately absent. Legacy biased route-hop resolution toward
/// proximity to the previous hop; that belongs with the traffic heatmap's route logic and
/// can be layered on ``NodeResolution/candidates`` when it lands, rather than pulling
/// CoreLocation into node identity.
public struct NodeIdentityResolver: NodeIdentityResolving {
  /// Seven days — how long a passively discovered node stays resolvable after its last advert.
  public static let defaultStaleInterval: TimeInterval = 7 * 24 * 3600

  /// The stale window applied to candidates that expire.
  public let staleInterval: TimeInterval

  public init(staleInterval: TimeInterval = NodeIdentityResolver.defaultStaleInterval) {
    self.staleInterval = staleInterval
  }

  public func resolve<Candidate: RepeaterResolvable>(
    _ id: NodeHexID,
    among candidates: [Candidate],
    now: Date,
    overrides: NodeIdentityOverrides
  ) -> NodeResolution<Candidate>? {
    let cutoff = staleCutoff(now: now)
    let matches = candidates.compactMap { candidate -> (node: Candidate, depth: Int)? in
      guard !isStale(candidate, cutoff: cutoff) else { return nil }
      guard let depth = id.matchedByteCount(againstPublicKey: candidate.publicKey) else { return nil }
      return (candidate, depth)
    }
    guard !matches.isEmpty else { return nil }

    let pinnedKey = overrides[id].flatMap { $0.isEmpty ? nil : $0 }
    let ranked: [Candidate] = matches.sorted { lhs, rhs in
      if let pinnedKey {
        let lhsPinned = lhs.node.publicKey.starts(with: pinnedKey)
        let rhsPinned = rhs.node.publicKey.starts(with: pinnedKey)
        if lhsPinned != rhsPinned { return lhsPinned }
      }
      if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
      if lhs.node.lastAdvertTimestamp != rhs.node.lastAdvertTimestamp {
        return lhs.node.lastAdvertTimestamp > rhs.node.lastAdvertTimestamp
      }
      if lhs.node.recencyDate != rhs.node.recencyDate {
        return lhs.node.recencyDate > rhs.node.recencyDate
      }
      switch lhs.node.resolvableName.localizedStandardCompare(rhs.node.resolvableName) {
      case .orderedAscending: return true
      case .orderedDescending: return false
      case .orderedSame: return lhs.node.publicKey.lexicographicallyPrecedes(rhs.node.publicKey)
      }
    }.map(\.node)

    guard let best = ranked.first else { return nil }
    return NodeResolution(best: best, candidates: ranked)
  }

  /// The advert timestamp at or below which an expiring candidate counts as stale.
  /// Saturates at zero so a clock inside the stale window of the epoch — which only
  /// happens in tests — cannot underflow into filtering everything out.
  private func staleCutoff(now: Date) -> UInt32 {
    let nowSeconds = now.timeIntervalSince1970
    guard nowSeconds > staleInterval else { return 0 }
    return UInt32(nowSeconds - staleInterval)
  }

  private func isStale(_ candidate: some RepeaterResolvable, cutoff: UInt32) -> Bool {
    guard candidate.expiresWhenStale else { return false }
    guard candidate.lastAdvertTimestamp != 0 else { return false }
    return candidate.lastAdvertTimestamp <= cutoff
  }
}
