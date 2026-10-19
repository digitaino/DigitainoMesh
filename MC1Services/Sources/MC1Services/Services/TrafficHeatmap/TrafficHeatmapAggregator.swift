import Foundation
import MeshCore

/// Turns RX log entries into per-node and per-link traffic weights.
///
/// A pure function of its arguments — entries in, value types out, caller supplies the clock —
/// so the whole of the traffic heatmap's logic is testable without a store, a radio, or a map.
/// Nothing here knows how any of it is drawn.
///
/// The rules, all inherited from legacy's `TrafficHeatmapViewModel.aggregate`:
///
/// - **TRACE packets are skipped.** Their path field carries per-hop SNR readings, not node
///   hashes, so parsing it as a route invents links that never existed.
/// - **A node's weight is its hop count.** Every appearance on a path counts once, so a node
///   relaying more of the mesh's traffic draws heavier.
/// - **SNR belongs to the last hop only.** The entry's SNR describes the link into our own
///   radio, so only the final hop on the path earns an SNR sample; every earlier link's
///   quality is unknown and stays unknown. Links themselves therefore carry no SNR at all.
/// - **Links join consecutive *placed* hops.** A hop that cannot be resolved or located does
///   not break the chain — the placed hops either side of it are joined, since the packet
///   demonstrably travelled between them.
/// - **Links are undirected**, and a hop that resolves to the node before it (a hash collision
///   with itself, or a path that doubles back) makes no link.
public struct TrafficHeatmapAggregator: Sendable {
  private let hopResolver: TrafficHopResolver

  public init(resolver: any NodeIdentityResolving = NodeIdentityResolver()) {
    hopResolver = TrafficHopResolver(resolver: resolver)
  }

  public init(hopResolver: TrafficHopResolver) {
    self.hopResolver = hopResolver
  }

  // MARK: - Aggregation

  /// Aggregates every entry inside `window`.
  ///
  /// - Parameters:
  ///   - candidates: the pool hop hashes resolve against, contacts and discovered nodes alike.
  ///   - origin: where the receiving radio stands; anchors the hop chain (see
  ///     ``TrafficHopResolver``). Aggregation works without it, just with weaker
  ///     disambiguation.
  public func aggregate(
    entries: [RxLogEntryDTO],
    candidates: [AnyResolvableNode],
    window: TrafficTimeWindow = .all,
    now: Date,
    origin: TrafficCoordinate? = nil,
    overrides: NodeIdentityOverrides = [:]
  ) -> TrafficHeatmapSnapshot {
    var nodes: [Data: NodeAccumulator] = [:]
    var links: [LinkKey: Int] = [:]
    var analyzedEntryCount = 0
    var contributingEntryCount = 0
    var oldestEntryDate: Date?
    // One identity match per distinct hop hash for the whole pass; the pool and the clock are
    // fixed here, and the route-dependent half of resolution stays per hop.
    var resolutionCache = TrafficHopResolver.ResolutionCache()

    for entry in entries where window.contains(entry.receivedAt, now: now) {
      analyzedEntryCount += 1
      if let oldest = oldestEntryDate {
        oldestEntryDate = Swift.min(oldest, entry.receivedAt)
      } else {
        oldestEntryDate = entry.receivedAt
      }

      guard entry.payloadType != .trace else { continue }
      let hashes = TrafficHopResolver.hopHashes(
        pathNodes: entry.pathNodes,
        hashSize: entry.pathHashSize
      )
      guard !hashes.isEmpty else { continue }

      let hops = hopResolver.resolve(
        hashes: hashes,
        among: candidates,
        origin: origin,
        now: now,
        overrides: overrides,
        cache: &resolutionCache
      )
      guard !hops.isEmpty else { continue }
      contributingEntryCount += 1

      let lastHopIndex = hashes.count - 1
      for hop in hops {
        let isLastHop = hop.index == lastHopIndex
        let snr = isLastHop ? entry.snr : nil
        nodes[hop.publicKey, default: NodeAccumulator(hop: hop)]
          .record(snr: snr, receivedAt: entry.receivedAt)
      }

      for (from, to) in zip(hops, hops.dropFirst()) where from.publicKey != to.publicKey {
        links[LinkKey(from.publicKey, to.publicKey), default: 0] += 1
      }
    }

    return snapshot(
      nodes: nodes,
      links: links,
      analyzedEntryCount: analyzedEntryCount,
      contributingEntryCount: contributingEntryCount,
      oldestEntryDate: oldestEntryDate
    )
  }

  /// Aggregation over the two node sources the app keeps separately.
  public func aggregate(
    entries: [RxLogEntryDTO],
    contacts: [ContactDTO],
    discoveredNodes: [DiscoveredNodeDTO],
    window: TrafficTimeWindow = .all,
    now: Date,
    origin: TrafficCoordinate? = nil,
    overrides: NodeIdentityOverrides = [:]
  ) -> TrafficHeatmapSnapshot {
    aggregate(
      entries: entries,
      candidates: contacts.map(AnyResolvableNode.init) + discoveredNodes.map(AnyResolvableNode.init),
      window: window,
      now: now,
      origin: origin,
      overrides: overrides
    )
  }

  // MARK: - Snapshot assembly

  private func snapshot(
    nodes: [Data: NodeAccumulator],
    links: [LinkKey: Int],
    analyzedEntryCount: Int,
    contributingEntryCount: Int,
    oldestEntryDate: Date?
  ) -> TrafficHeatmapSnapshot {
    // Weights are relative to the busiest node/link in this snapshot, so the ramp always
    // spans its full range however quiet or busy the mesh happens to be.
    let heaviestNode = nodes.values.map(\.packetCount).max() ?? 1
    let heaviestLink = links.values.max() ?? 1

    // Heaviest first, ties broken on a stable key so re-aggregating unchanged data is identical.
    let unsortedNodes: [TrafficNodeLoad] = nodes.values.map { $0.load(relativeTo: heaviestNode) }
    let nodeLoads: [TrafficNodeLoad] = unsortedNodes.sorted { lhs, rhs in
      if lhs.packetCount != rhs.packetCount { return lhs.packetCount > rhs.packetCount }
      return lhs.publicKey.hexDescription < rhs.publicKey.hexDescription
    }

    var unsortedSegments: [TrafficSegmentLoad] = []
    unsortedSegments.reserveCapacity(links.count)
    for (key, packetCount) in links {
      guard let a = nodes[key.lower], let b = nodes[key.upper] else { continue }
      let weight = Double(packetCount) / Double(heaviestLink)
      unsortedSegments.append(TrafficSegmentLoad(
        id: key.id,
        endpointA: a.endpoint,
        endpointB: b.endpoint,
        packetCount: packetCount,
        normalizedWeight: weight
      ))
    }
    let segmentLoads: [TrafficSegmentLoad] = unsortedSegments.sorted { lhs, rhs in
      if lhs.packetCount != rhs.packetCount { return lhs.packetCount > rhs.packetCount }
      return lhs.id < rhs.id
    }

    return TrafficHeatmapSnapshot(
      nodes: nodeLoads,
      segments: segmentLoads,
      analyzedEntryCount: analyzedEntryCount,
      contributingEntryCount: contributingEntryCount,
      oldestEntryDate: oldestEntryDate
    )
  }

  // MARK: - Accumulators

  private struct NodeAccumulator {
    let hop: TrafficHop
    var packetCount = 0
    var snrTotal = 0.0
    var snrSampleCount = 0
    var lastHeard = Date.distantPast

    init(hop: TrafficHop) {
      self.hop = hop
    }

    mutating func record(snr: Double?, receivedAt: Date) {
      packetCount += 1
      if let snr {
        snrTotal += snr
        snrSampleCount += 1
      }
      lastHeard = Swift.max(lastHeard, receivedAt)
    }

    var endpoint: TrafficSegmentLoad.Endpoint {
      TrafficSegmentLoad.Endpoint(
        publicKey: hop.publicKey,
        name: hop.name,
        coordinate: hop.coordinate
      )
    }

    func load(relativeTo heaviest: Int) -> TrafficNodeLoad {
      TrafficNodeLoad(
        publicKey: hop.publicKey,
        name: hop.name,
        coordinate: hop.coordinate,
        packetCount: packetCount,
        averageSNR: snrSampleCount > 0 ? snrTotal / Double(snrSampleCount) : nil,
        snrSampleCount: snrSampleCount,
        lastHeard: lastHeard,
        normalizedWeight: Double(packetCount) / Double(heaviest)
      )
    }
  }

  /// An undirected link, keyed on its two public keys in ascending order so both directions
  /// accumulate onto one entry.
  private struct LinkKey: Hashable {
    let lower: Data
    let upper: Data

    init(_ a: Data, _ b: Data) {
      if a.lexicographicallyPrecedes(b) {
        lower = a
        upper = b
      } else {
        lower = b
        upper = a
      }
    }

    var id: String {
      "\(lower.hexDescription)-\(upper.hexDescription)"
    }
  }
}

private extension Data {
  var hexDescription: String {
    uppercaseHexString()
  }
}
