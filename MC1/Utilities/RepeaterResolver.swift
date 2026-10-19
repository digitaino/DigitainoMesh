import CoreLocation
import Foundation
import MC1Services

struct ResolvedNode<T: RepeaterResolvable> {
  let node: T
  let matchKind: NodeNameMatchKind
}

/// A neighbor resolution that also carries the resolved node's location so callers
/// (the SNR map) can place it. The coordinate is stored as the `Double` pair (not
/// `CLLocationCoordinate2D`, which is neither `Sendable` nor `Hashable`) so the struct
/// stays `Sendable`, matching its file siblings.
struct ResolvedNeighbor {
  let displayName: String
  let matchKind: NodeNameMatchKind
  let latitude: Double?
  let longitude: Double?

  var coordinate: CLLocationCoordinate2D? {
    guard let latitude, let longitude else { return nil }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}

/// A single routing hop (hash bytes shown as hex) resolved to a repeater name, ready to display.
struct ResolvedPathHop: Identifiable {
  let id: Int
  let hex: String
  let resolution: NodeNameResolution
}

/// Resolves repeater collisions by proximity and recency.
enum RepeaterResolver {
  private static let exactPrefixLength = 6

  /// Whether a candidate opted into expiry (`expiresWhenStale`) and has outlived
  /// the shared stale window — `NodeIdentityResolver`'s exact rule: rows that
  /// never advertised are exempt, and the cutoff saturates at zero so a clock
  /// near the epoch (tests) cannot expire everything.
  static func isExpiredCandidate(_ node: some RepeaterResolvable, now: Date = .now) -> Bool {
    guard node.expiresWhenStale, node.lastAdvertTimestamp != 0 else { return false }
    let nowSeconds = now.timeIntervalSince1970
    guard nowSeconds > NodeIdentityResolver.defaultStaleInterval else { return false }
    return node.lastAdvertTimestamp <= UInt32(nowSeconds - NodeIdentityResolver.defaultStaleInterval)
  }

  /// Drops expired candidates from one hop's matches — but only while a live
  /// candidate answers the same hash. A dead advert row left behind by a
  /// re-key (or a node that moved away) must not veto or outrank the living
  /// node, yet when every candidate is stale the quiet ones are still the
  /// best answer there is, so an all-stale pool is kept whole. Relative, not
  /// absolute, on purpose: an absolute cutoff would go dark on every
  /// discovered-only repeater the moment its region falls quiet.
  static func pruneExpiredRivals<T: RepeaterResolvable>(_ nodes: [T], now: Date = .now) -> [T] {
    let live = nodes.filter { !isExpiredCandidate($0, now: now) }
    return live.isEmpty ? nodes : live
  }

  /// The cross-table form of `pruneExpiredRivals`: liveness is judged over the
  /// contact and discovered pools *jointly*, because the live rival that
  /// disqualifies a stale discovered row is usually the saved contact holding
  /// the node's current key (the re-key case).
  static func pruneExpiredRivals<C: RepeaterResolvable, D: RepeaterResolvable>(
    contacts: [C],
    discoveredNodes: [D],
    now: Date = .now
  ) -> (contacts: [C], discoveredNodes: [D]) {
    let anyLive = contacts.contains { !isExpiredCandidate($0, now: now) }
      || discoveredNodes.contains { !isExpiredCandidate($0, now: now) }
    guard anyLive else { return (contacts, discoveredNodes) }
    return (
      contacts.filter { !isExpiredCandidate($0, now: now) },
      discoveredNodes.filter { !isExpiredCandidate($0, now: now) }
    )
  }

  /// Match using a PathHop: exact public key match first, then hash bytes fallback.
  static func bestMatch<T: RepeaterResolvable>(
    for hop: PathHop,
    in nodes: [T],
    userLocation: CLLocation?
  ) -> T? {
    resolve(for: hop, in: nodes, userLocation: userLocation)?.node
  }

  static func resolve<T: RepeaterResolvable>(
    for hop: PathHop,
    in nodes: [T],
    userLocation: CLLocation?
  ) -> ResolvedNode<T>? {
    if let key = hop.publicKey,
       let exact = nodes.first(where: { $0.publicKey == key }) {
      return ResolvedNode(node: exact, matchKind: .exact)
    }
    return resolve(for: hop.hashBytes, in: nodes, userLocation: userLocation)
  }

  /// Match using hash bytes (1-3 byte prefix)
  static func bestMatch<T: RepeaterResolvable>(
    for hashBytes: Data,
    in nodes: [T],
    userLocation: CLLocation?
  ) -> T? {
    resolve(for: hashBytes, in: nodes, userLocation: userLocation)?.node
  }

  static func resolve<T: RepeaterResolvable>(
    for hashBytes: Data,
    in nodes: [T],
    userLocation: CLLocation?
  ) -> ResolvedNode<T>? {
    guard !hashBytes.isEmpty else { return nil }

    let prefixLen = hashBytes.count
    let matched = pruneExpiredRivals(nodes.filter { $0.publicKey.prefix(prefixLen) == hashBytes })
    let candidates = matched.map { node -> (T, Double?) in
      let distance: Double?
      if let userLocation, node.hasLocation {
        let nodeLocation = CLLocation(latitude: node.latitude, longitude: node.longitude)
        distance = userLocation.distance(from: nodeLocation)
      } else {
        distance = nil
      }

      return (node, distance)
    }

    guard !candidates.isEmpty else { return nil }

    let sorted = candidates.sorted { lhs, rhs in
      switch (lhs.1, rhs.1) {
      case let (left?, right?):
        if left != right { return left < right }
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      case (.none, .none):
        break
      }

      if lhs.0.lastAdvertTimestamp != rhs.0.lastAdvertTimestamp {
        return lhs.0.lastAdvertTimestamp > rhs.0.lastAdvertTimestamp
      }

      if lhs.0.recencyDate != rhs.0.recencyDate {
        return lhs.0.recencyDate > rhs.0.recencyDate
      }

      return lhs.0.resolvableName.localizedStandardCompare(rhs.0.resolvableName) == .orderedAscending
    }

    guard let node = sorted.first?.0 else { return nil }
    let matchingPublicKeys = Set(candidates.map(\.0.publicKey))
    let matchKind: NodeNameMatchKind = prefixLen >= exactPrefixLength || matchingPublicKeys.count == 1
      ? .exact
      : .fallback
    return ResolvedNode(node: node, matchKind: matchKind)
  }
}

enum NeighborNameResolver {
  /// Single resolution core: resolves a neighbor prefix to a name, match confidence, and the
  /// resolved node's location. Contacts are preferred over discovered nodes, and the cross-source
  /// `matchKind` refinement is applied here so every caller reads identical name/matchKind/coordinate.
  static func resolveLocated(
    for prefix: Data,
    contacts: [ContactDTO],
    discoveredNodes: [DiscoveredNodeDTO],
    userLocation: CLLocation?
  ) -> ResolvedNeighbor? {
    if let contact = RepeaterResolver.resolve(for: prefix, in: contacts, userLocation: userLocation) {
      return located(
        node: contact.node,
        resolvedMatchKind: contact.matchKind,
        prefix: prefix,
        contacts: contacts,
        discoveredNodes: discoveredNodes
      )
    }

    if let node = RepeaterResolver.resolve(for: prefix, in: discoveredNodes, userLocation: userLocation) {
      return located(
        node: node.node,
        resolvedMatchKind: node.matchKind,
        prefix: prefix,
        contacts: contacts,
        discoveredNodes: discoveredNodes
      )
    }

    return nil
  }

  private static func located(
    node: some RepeaterResolvable,
    resolvedMatchKind: NodeNameMatchKind,
    prefix: Data,
    contacts: [ContactDTO],
    discoveredNodes: [DiscoveredNodeDTO]
  ) -> ResolvedNeighbor {
    // The two tables describe one physical node per key: a row that never
    // recorded a fix must not hide the located row behind the same full key
    // on the other table, or the SNR map loses a neighbor the app can place.
    var coordinate: (latitude: Double, longitude: Double)?
    if node.hasLocation {
      coordinate = (node.latitude, node.longitude)
    } else if let twin = contacts.first(where: { $0.publicKey == node.publicKey && $0.hasLocation }) {
      coordinate = (twin.latitude, twin.longitude)
    } else if let twin = discoveredNodes.first(where: {
      $0.publicKey == node.publicKey
        && CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude).isValidFix
    }) {
      coordinate = (twin.latitude, twin.longitude)
    }
    return ResolvedNeighbor(
      displayName: node.resolvableName,
      matchKind: matchKind(for: prefix, resolvedMatchKind: resolvedMatchKind, contacts: contacts, discoveredNodes: discoveredNodes),
      latitude: coordinate?.latitude,
      longitude: coordinate?.longitude
    )
  }

  static func resolve(
    for prefix: Data,
    contacts: [ContactDTO],
    discoveredNodes: [DiscoveredNodeDTO],
    userLocation: CLLocation?
  ) -> NodeNameResolution? {
    guard let resolved = resolveLocated(
      for: prefix,
      contacts: contacts,
      discoveredNodes: discoveredNodes,
      userLocation: userLocation
    ) else { return nil }

    return NodeNameResolution(displayName: resolved.displayName, matchKind: resolved.matchKind)
  }

  private static func matchKind(
    for prefix: Data,
    resolvedMatchKind: NodeNameMatchKind,
    contacts: [ContactDTO],
    discoveredNodes: [DiscoveredNodeDTO]
  ) -> NodeNameMatchKind {
    guard resolvedMatchKind != .unresolved, prefix.count < 6 else {
      return resolvedMatchKind
    }

    // Ambiguity is judged among the candidates that could still BE the hop:
    // an expired advert row (a re-keyed repeater's old identity, a node that
    // moved away) must not turn its own living successor into a "guess" —
    // the same pruning the map's plottability rule applies, so a hop can
    // never be named a fallback in the list while the map pins it as exact.
    let (matchingContacts, matchingDiscovered) = RepeaterResolver.pruneExpiredRivals(
      contacts: contacts.filter { $0.publicKey.prefix(prefix.count) == prefix },
      discoveredNodes: discoveredNodes.filter { $0.publicKey.prefix(prefix.count) == prefix }
    )

    return Set(matchingContacts.map(\.publicKey) + matchingDiscovered.map(\.publicKey)).count > 1
      ? .fallback
      : .exact
  }

  static func resolveName(
    for prefix: Data,
    contacts: [ContactDTO],
    discoveredNodes: [DiscoveredNodeDTO],
    userLocation: CLLocation?
  ) -> String? {
    resolve(
      for: prefix,
      contacts: contacts,
      discoveredNodes: discoveredNodes,
      userLocation: userLocation
    )?.displayName
  }

  static let minimumKeyDisplayByteCount = 2
  static let maximumKeyDisplayByteCount = 3

  /// Bytes of public-key prefix to show for a neighbour identity hex string.
  /// Uses `DeviceDTO.hashSize` when present, clamped between `minimumKeyDisplayByteCount`
  /// and `maximumKeyDisplayByteCount`.
  static func keyDisplayByteCount(deviceHashSize: Int?) -> Int {
    guard let size = deviceHashSize else { return minimumKeyDisplayByteCount }
    return min(max(size, minimumKeyDisplayByteCount), maximumKeyDisplayByteCount)
  }

  /// Uppercase hex of the leading `byteCount` bytes.
  /// Clamps to `maximumKeyDisplayByteCount` and the available prefix so the full wire
  /// prefix is never shown as a fallback title.
  static func fallbackName(for prefix: Data, byteCount: Int) -> String {
    let n = min(max(byteCount, 0), maximumKeyDisplayByteCount, prefix.count)
    return prefix.prefix(n).uppercaseHexString()
  }

  /// Resolves every hop of a node's stored path to a repeater name, falling back to a placeholder
  /// when no repeater matches a hop. Only repeaters can relay, so contacts and discovered nodes are
  /// narrowed to repeaters before matching, matching the login sheet's path display.
  static func resolvePath(
    _ hops: [(data: Data, hex: String)],
    contacts: [ContactDTO],
    discoveredNodes: [DiscoveredNodeDTO],
    userLocation: CLLocation?
  ) -> [ResolvedPathHop] {
    let repeaters = contacts.filter { $0.type == .repeater }
    let discoveredRepeaters = discoveredNodes.filter { $0.nodeType == .repeater }

    return hops.enumerated().map { index, hop in
      let resolution = resolve(
        for: hop.data,
        contacts: repeaters,
        discoveredNodes: discoveredRepeaters,
        userLocation: userLocation
      ) ?? NodeNameResolution(
        displayName: L10n.RemoteNodes.RemoteNodes.Auth.pathHopUnknown,
        matchKind: .unresolved
      )
      return ResolvedPathHop(id: index, hex: hop.hex, resolution: resolution)
    }
  }
}
