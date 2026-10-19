import Foundation

/// One hop of a packet path, placed on the map.
public struct TrafficHop: Sendable, Hashable {
  /// Position in the packet's path, counting from the sender. The highest index is the hop
  /// our own radio heard directly.
  public let index: Int
  public let publicKey: Data
  public let name: String
  public let coordinate: TrafficCoordinate

  public init(index: Int, publicKey: Data, name: String, coordinate: TrafficCoordinate) {
    self.index = index
    self.publicKey = publicKey
    self.name = name
    self.coordinate = coordinate
  }
}

/// Turns the hop hashes on a packet's path into located nodes.
///
/// Identity comes from ``NodeIdentityResolving``, which ranks on identity signals alone —
/// match depth, then advert recency — and deliberately keeps geography out (see
/// ``NodeIdentityResolver``'s notes). Two things are layered on top *here*, in the traffic
/// layer, because both are properties of a route rather than of a node:
///
/// 1. **Placeability.** A hop resolves to the highest-ranked candidate that can be drawn.
///    A node with no location cannot be a heatmap hop, so it is passed over rather than
///    taking the hop down with it.
/// 2. **Chain proximity.** When several nodes answer to the same hash — routine with the
///    1-byte hashes firmware usually advertises — the resolver's own ranking is a coin toss
///    between them. A route, though, is a geographic chain: the relay that actually forwarded
///    the packet is the one standing near the hop next to it. So an *ambiguous* resolution has
///    its candidate list (handed back best-first, expressly so callers can re-rank it)
///    re-ordered by distance to the neighbouring hop already placed. An unambiguous
///    resolution is never second-guessed.
///
/// Hops are walked from the receiving end backwards, because that is the end whose position we
/// actually know: the last hop is anchored on `origin` — our own radio — and each earlier hop
/// on the hop just placed. The result is returned in path order (sender first).
public struct TrafficHopResolver: Sendable {
  private let resolver: any NodeIdentityResolving

  public init(resolver: any NodeIdentityResolving = NodeIdentityResolver()) {
    self.resolver = resolver
  }

  /// Identity resolutions already computed, keyed by hop hash, for reuse across one batch of
  /// paths.
  ///
  /// The identity match depends on the hash, the candidate pool and the clock — all fixed for
  /// the length of an aggregation pass — while a 1-byte hash space is only 256 wide and a full
  /// RX log walks thousands of hops through it. What is *not* cached is the anchor-dependent
  /// pick in `pick(from:anchor:)`: which of an ambiguous hash's candidates forwarded the packet
  /// is a property of the route, not of the hash, and has to be re-decided per hop.
  ///
  /// Scoped to the caller so the resolver itself stays a value with no hidden state; hand the
  /// same cache to every path in one pass and let it go out of scope with the pass.
  public struct ResolutionCache {
    fileprivate var resolutions: [Data: NodeResolution<AnyResolvableNode>?] = [:]

    public init() {}
  }

  /// Splits `pathNodes` into `hashSize`-wide hop hashes, in path order (sender first).
  /// A trailing run shorter than `hashSize` is kept as-is, matching the firmware's own
  /// tolerance for a truncated path field.
  public static func hopHashes(pathNodes: Data, hashSize: Int) -> [Data] {
    guard hashSize > 0, !pathNodes.isEmpty else { return [] }
    return stride(from: pathNodes.startIndex, to: pathNodes.endIndex, by: hashSize).map { start in
      Data(pathNodes[start..<min(start + hashSize, pathNodes.endIndex)])
    }
  }

  /// Resolves a packet's hop hashes to located nodes, dropping the ones that cannot be placed.
  ///
  /// - Parameters:
  ///   - hashes: hop hashes in path order, sender first.
  ///   - candidates: every node the hashes may name.
  ///   - origin: where the receiving radio stands, used to anchor the last hop. `nil` leaves
  ///     the last hop on the resolver's own ranking.
  ///   - cache: identity resolutions shared with the other paths in this pass. Must be built
  ///     from the same `candidates` and `now` as this call — see ``ResolutionCache``.
  /// - Returns: the placed hops in path order, each carrying its original path index, so a
  ///   caller can still tell which one was the last hop after unplaceable hops fell out.
  public func resolve(
    hashes: [Data],
    among candidates: [AnyResolvableNode],
    origin: TrafficCoordinate?,
    now: Date,
    overrides: NodeIdentityOverrides = [:],
    cache: inout ResolutionCache
  ) -> [TrafficHop] {
    var placed: [TrafficHop] = []
    var anchor = origin

    for index in stride(from: hashes.count - 1, through: 0, by: -1) {
      let hash = hashes[index]
      let cached: NodeResolution<AnyResolvableNode>?
      if let hit = cache.resolutions[hash] {
        cached = hit
      } else {
        cached = NodeHexID(data: hash).flatMap {
          resolver.resolve($0, among: candidates, now: now, overrides: overrides)
        }
        cache.resolutions[hash] = cached
      }

      guard let resolution = cached,
            let node = pick(from: resolution, anchor: anchor)
      else { continue }

      guard let coordinate = TrafficCoordinate(node: node) else { continue }
      placed.append(TrafficHop(
        index: index,
        publicKey: node.publicKey,
        name: node.resolvableName,
        coordinate: coordinate
      ))
      anchor = coordinate
    }

    return placed.reversed()
  }

  /// Resolves one path on its own, with a cache that lives no longer than the call.
  public func resolve(
    hashes: [Data],
    among candidates: [AnyResolvableNode],
    origin: TrafficCoordinate?,
    now: Date,
    overrides: NodeIdentityOverrides = [:]
  ) -> [TrafficHop] {
    var cache = ResolutionCache()
    return resolve(
      hashes: hashes,
      among: candidates,
      origin: origin,
      now: now,
      overrides: overrides,
      cache: &cache
    )
  }

  /// The candidate this hop should be drawn as: the nearest placeable one to `anchor` when the
  /// hash is ambiguous and there is an anchor, otherwise the highest-ranked placeable one.
  private func pick(
    from resolution: NodeResolution<AnyResolvableNode>,
    anchor: TrafficCoordinate?
  ) -> AnyResolvableNode? {
    let placeable = resolution.candidates.filter { TrafficCoordinate(node: $0) != nil }
    guard resolution.isAmbiguous, let anchor else { return placeable.first }

    // `min(by:)` keeps the first of equal distances, so the resolver's ranking still breaks
    // ties — two candidates the same distance away stay in identity order.
    return placeable.min { lhs, rhs in
      guard let lhsCoordinate = TrafficCoordinate(node: lhs),
            let rhsCoordinate = TrafficCoordinate(node: rhs) else { return false }
      return lhsCoordinate.distance(to: anchor) < rhsCoordinate.distance(to: anchor)
    }
  }
}
