import Foundation

/// Why a candidate matched, and therefore how highly it ranks.
///
/// The order is the legacy tiering, preserved: a node whose key *starts with* what the
/// user typed is what they meant; a node whose key merely *contains* it is a plausible
/// second guess; a name match is the fallback. `<` means "ranks higher".
public enum NodeSearchRelevance: Int, Sendable, Hashable, CaseIterable, Comparable {
  /// The public key begins with the query.
  case keyPrefix = 0
  /// The query appears somewhere inside the public key, but not at its start.
  case keyInterior = 1
  /// The node's name contains the query; its key does not match at all.
  case name = 2

  public static func < (lhs: NodeSearchRelevance, rhs: NodeSearchRelevance) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// How candidates that matched equally well are ordered against each other.
public enum NodeSearchTieBreak: Sendable, Hashable {
  /// Most recently advertised first, then ``RepeaterResolvable/recencyDate``, then name,
  /// then public key — the same total order ``NodeIdentityResolver`` uses, so a node's
  /// position never depends on the order it happened to be fetched in.
  case recency
  /// Preserve the order the candidates were supplied in.
  ///
  /// For callers that already sort — the contacts list has a name/last-heard/distance
  /// control, the repeater picker puts heard nodes first — this keeps their ordering and
  /// applies only the relevance tiers on top of it, which is exactly what legacy's
  /// "stable re-sort by tier" did.
  case inputOrder
}

/// A candidate that matched, with the reason it did.
public struct NodeSearchMatch<Node: RepeaterResolvable>: Sendable {
  /// The matching candidate, in its original type — so callers keep its identity and any
  /// fields the search protocol does not expose.
  public let node: Node

  /// Why it matched.
  public let relevance: NodeSearchRelevance

  public init(node: Node, relevance: NodeSearchRelevance) {
    self.node = node
    self.relevance = relevance
  }
}

extension NodeSearchMatch: Equatable where Node: Equatable {}
