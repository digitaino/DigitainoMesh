import Foundation

/// Matches and ranks nodes against a free-text query.
///
/// Implementations are pure functions of their arguments — no clock, no store, no
/// ambient state — so a ranking is reproducible from its inputs alone and the whole
/// engine is unit-testable without a fixture database. Time enters only as data the
/// candidates already carry (`lastAdvertTimestamp`, `recencyDate`).
public protocol NodeSearching: Sendable {
  /// Every candidate the query matches, best first.
  func search<Node: RepeaterResolvable>(
    _ query: NodeSearchQuery,
    among candidates: [Node],
    options: NodeSearchOptions
  ) -> [NodeSearchMatch<Node>]
}

public extension NodeSearching {
  /// Searches with the default options.
  func search<Node: RepeaterResolvable>(
    _ query: NodeSearchQuery,
    among candidates: [Node]
  ) -> [NodeSearchMatch<Node>] {
    search(query, among: candidates, options: .default)
  }

  /// Ranked candidates without their match reasons, for callers that only render a list.
  func matches<Node: RepeaterResolvable>(
    _ query: NodeSearchQuery,
    among candidates: [Node],
    options: NodeSearchOptions = .default
  ) -> [Node] {
    search(query, among: candidates, options: options).map(\.node)
  }

  /// Searches raw search-field text.
  func matches<Node: RepeaterResolvable>(
    searchText: String,
    among candidates: [Node],
    options: NodeSearchOptions = .default
  ) -> [Node] {
    matches(NodeSearchQuery(searchText), among: candidates, options: options)
  }

  /// Searches saved contacts and discovered nodes as one pool — the entry point for a
  /// surface that shows both.
  func search(
    _ query: NodeSearchQuery,
    contacts: [ContactDTO],
    discoveredNodes: [DiscoveredNodeDTO],
    options: NodeSearchOptions = .default
  ) -> [NodeSearchMatch<NodeSearchCandidate>] {
    let pool = contacts.map(NodeSearchCandidate.contact) + discoveredNodes.map(NodeSearchCandidate.discovered)
    return search(query, among: pool, options: options)
  }
}

/// The app's node matcher.
///
/// Ranking, in order:
/// 1. **Relevance tier** — key-prefix match, then interior-key match, then name-only.
///    Legacy arrived at this by bug report: users type the hex they see on a node row and
///    expect that node first, not whichever node happens to sort earliest.
/// 2. **Tie-break** — recency, or the caller's own ordering (see ``NodeSearchTieBreak``).
///
/// Key matching is reached only for a strictly hex query (``NodeSearchQuery/isStrictHex``),
/// which is what stops an ordinary word from being compared against key bytes at all.
/// Within a hex query both fields are live: a node can match on its name and rank in the
/// `.name` tier even though the query could have been a key fragment.
public struct NodeSearchEngine: NodeSearching {
  public init() {}

  public func search<Node: RepeaterResolvable>(
    _ query: NodeSearchQuery,
    among candidates: [Node],
    options: NodeSearchOptions
  ) -> [NodeSearchMatch<Node>] {
    let scored: [(match: NodeSearchMatch<Node>, position: Int)] = candidates.enumerated().compactMap { position, candidate in
      guard let relevance = relevance(of: candidate, for: query, options: options) else { return nil }
      return (NodeSearchMatch(node: candidate, relevance: relevance), position)
    }

    return scored.sorted { lhs, rhs in
      if lhs.match.relevance != rhs.match.relevance {
        return lhs.match.relevance < rhs.match.relevance
      }
      switch options.tieBreak {
      case .inputOrder:
        return lhs.position < rhs.position
      case .recency:
        return Self.isMoreRecent(lhs.match.node, than: rhs.match.node, position: (lhs.position, rhs.position))
      }
    }.map(\.match)
  }

  /// The best tier this candidate qualifies for, or `nil` if it does not match at all.
  private func relevance(
    of candidate: some RepeaterResolvable,
    for query: NodeSearchQuery,
    options: NodeSearchOptions
  ) -> NodeSearchRelevance? {
    guard !query.isEmpty else { return .name }

    if let keyPrefix = query.keyPrefix {
      if keyPrefix.isPrefix(of: candidate.publicKey) { return .keyPrefix }
      if options.interiorKeyMatching.admits(keyPrefix), keyPrefix.isContained(in: candidate.publicKey) {
        return .keyInterior
      }
    }

    return query.matchesName(candidate.resolvableName) ? .name : nil
  }

  /// The recency total order, matching ``NodeIdentityResolver``'s: advert timestamp, then
  /// `recencyDate`, then name, then public key. Input position is the final fallback so
  /// two byte-identical records never sort nondeterministically.
  private static func isMoreRecent(
    _ lhs: some RepeaterResolvable,
    than rhs: some RepeaterResolvable,
    position: (lhs: Int, rhs: Int)
  ) -> Bool {
    if lhs.lastAdvertTimestamp != rhs.lastAdvertTimestamp {
      return lhs.lastAdvertTimestamp > rhs.lastAdvertTimestamp
    }
    if lhs.recencyDate != rhs.recencyDate {
      return lhs.recencyDate > rhs.recencyDate
    }
    switch lhs.resolvableName.localizedStandardCompare(rhs.resolvableName) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: break
    }
    if lhs.publicKey != rhs.publicKey {
      return lhs.publicKey.lexicographicallyPrecedes(rhs.publicKey)
    }
    return position.lhs < position.rhs
  }
}
