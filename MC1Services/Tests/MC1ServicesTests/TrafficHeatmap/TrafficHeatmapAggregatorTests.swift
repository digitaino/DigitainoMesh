import Foundation
@testable import MC1Services
import MeshCore
import os
import Testing

/// Spec source: legacy `TrafficHeatmapViewModel.aggregate` — one test per rule it encoded,
/// including the SNR-applies-to-the-last-hop-only rule its comment called out.
@Suite("TrafficHeatmapAggregator")
struct TrafficHeatmapAggregatorTests {
  private let aggregator = TrafficHeatmapAggregator()
  private let now = TrafficFixture.now

  /// Three located nodes in a line, one hash byte each.
  private let mesh = [
    TrafficFixture.node([0x0A], name: "A", latitude: 10, longitude: 10),
    TrafficFixture.node([0x0B], name: "B", latitude: 11, longitude: 10),
    TrafficFixture.node([0x0C], name: "C", latitude: 12, longitude: 10),
  ]

  private func aggregate(
    _ entries: [RxLogEntryDTO],
    candidates: [AnyResolvableNode]? = nil,
    window: TrafficTimeWindow = .all
  ) -> TrafficHeatmapSnapshot {
    aggregator.aggregate(
      entries: entries,
      candidates: candidates ?? mesh,
      window: window,
      now: now
    )
  }

  // MARK: - Entries that carry no route

  @Test
  func `An empty log aggregates to an empty snapshot`() {
    #expect(aggregate([]) == .empty)
  }

  @Test
  func `TRACE packets are skipped: their path field is per-hop SNR, not node hashes`() {
    let snapshot = aggregate([
      TrafficFixture.entry(hops: [[0x0A], [0x0B]], payloadType: .trace),
    ])
    #expect(snapshot.nodes.isEmpty)
    #expect(snapshot.segments.isEmpty)
    // It was still inside the window, so it counts as analyzed but contributes nothing.
    #expect(snapshot.analyzedEntryCount == 1)
    #expect(snapshot.contributingEntryCount == 0)
  }

  @Test
  func `A packet that arrived with no path at all contributes nothing`() {
    let snapshot = aggregate([TrafficFixture.entry(hops: [])])
    #expect(snapshot.nodes.isEmpty)
    #expect(snapshot.analyzedEntryCount == 1)
    #expect(snapshot.contributingEntryCount == 0)
  }

  @Test
  func `A packet whose every hop is unknown contributes nothing`() {
    let snapshot = aggregate([TrafficFixture.entry(hops: [[0xEE], [0xEF]])])
    #expect(snapshot.nodes.isEmpty)
    #expect(snapshot.contributingEntryCount == 0)
  }

  // MARK: - Node weights

  @Test
  func `A node's weight is how many hops it relayed, counted across every packet`() {
    let snapshot = aggregate([
      TrafficFixture.entry(hops: [[0x0A], [0x0B]]),
      TrafficFixture.entry(hops: [[0x0B]]),
      TrafficFixture.entry(hops: [[0x0B], [0x0C]]),
    ])
    #expect(snapshot.contributingEntryCount == 3)

    let counts = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.name, $0.packetCount) })
    #expect(counts == ["A": 1, "B": 3, "C": 1])
  }

  @Test
  func `Node weights are normalized against the busiest node in the snapshot`() throws {
    let snapshot = aggregate([
      TrafficFixture.entry(hops: [[0x0A], [0x0B]]),
      TrafficFixture.entry(hops: [[0x0B]]),
      TrafficFixture.entry(hops: [[0x0B]]),
      TrafficFixture.entry(hops: [[0x0B]]),
    ])
    let busiest = try #require(snapshot.nodes.first)
    #expect(busiest.name == "B")
    #expect(busiest.normalizedWeight == 1.0)

    let quiet = try #require(snapshot.nodes.first { $0.name == "A" })
    #expect(quiet.normalizedWeight == 0.25)
  }

  @Test
  func `Nodes come back busiest first`() {
    let snapshot = aggregate([
      TrafficFixture.entry(hops: [[0x0A], [0x0B], [0x0C]]),
      TrafficFixture.entry(hops: [[0x0B], [0x0C]]),
      TrafficFixture.entry(hops: [[0x0C]]),
    ])
    #expect(snapshot.nodes.map(\.name) == ["C", "B", "A"])
  }

  @Test
  func `A node's last-heard time is the most recent packet it relayed`() throws {
    let older = now.addingTimeInterval(-3600)
    let snapshot = aggregate([
      TrafficFixture.entry(hops: [[0x0A]], receivedAt: now),
      TrafficFixture.entry(hops: [[0x0A]], receivedAt: older),
    ])
    #expect(try #require(snapshot.nodes.first).lastHeard == now)
  }

  // MARK: - SNR attribution

  @Test
  func `SNR lands on the last hop only — the one link our radio actually heard`() throws {
    let snapshot = aggregate([TrafficFixture.entry(hops: [[0x0A], [0x0B]], snr: 8)])

    let last = try #require(snapshot.nodes.first { $0.name == "B" })
    #expect(last.averageSNR == 8)
    #expect(last.snrSampleCount == 1)

    let intermediate = try #require(snapshot.nodes.first { $0.name == "A" })
    #expect(intermediate.averageSNR == nil)
    #expect(intermediate.snrSampleCount == 0)
  }

  @Test
  func `Last-hop readings average, and hops heard without one add no sample`() throws {
    let snapshot = aggregate([
      TrafficFixture.entry(hops: [[0x0A]], snr: 10),
      TrafficFixture.entry(hops: [[0x0A]], snr: 4),
      TrafficFixture.entry(hops: [[0x0A]], snr: nil),
    ])
    let node = try #require(snapshot.nodes.first)
    #expect(node.averageSNR == 7)
    #expect(node.snrSampleCount == 2)
    #expect(node.packetCount == 3)
  }

  @Test
  func `A last hop that could not be placed takes its SNR with it`() throws {
    let snapshot = aggregate([TrafficFixture.entry(hops: [[0x0A], [0xEE]], snr: 8)])
    let node = try #require(snapshot.nodes.first)
    #expect(node.name == "A")
    #expect(node.averageSNR == nil)
  }

  // MARK: - Links

  @Test
  func `Consecutive hops make a link, weighted by how many packets crossed it`() throws {
    let snapshot = aggregate([
      TrafficFixture.entry(hops: [[0x0A], [0x0B]]),
      TrafficFixture.entry(hops: [[0x0A], [0x0B]]),
      TrafficFixture.entry(hops: [[0x0B], [0x0C]]),
    ])
    #expect(snapshot.segments.count == 2)

    let busiest = try #require(snapshot.segments.first)
    #expect(Set([busiest.endpointA.name, busiest.endpointB.name]) == ["A", "B"])
    #expect(busiest.packetCount == 2)
    #expect(busiest.normalizedWeight == 1.0)
    #expect(try #require(snapshot.segments.last).normalizedWeight == 0.5)
  }

  @Test
  func `A link is undirected: both directions accumulate onto one segment with one id`() throws {
    let snapshot = aggregate([
      TrafficFixture.entry(hops: [[0x0A], [0x0B]]),
      TrafficFixture.entry(hops: [[0x0B], [0x0A]]),
    ])
    let segment = try #require(snapshot.segments.first)
    #expect(snapshot.segments.count == 1)
    #expect(segment.packetCount == 2)
    #expect(segment.endpointA.name == "A")
    #expect(segment.endpointB.name == "B")
  }

  @Test
  func `A hop that could not be placed does not break the chain either side of it`() throws {
    let snapshot = aggregate([TrafficFixture.entry(hops: [[0x0A], [0xEE], [0x0C]])])
    let segment = try #require(snapshot.segments.first)
    #expect(Set([segment.endpointA.name, segment.endpointB.name]) == ["A", "C"])
  }

  @Test
  func `A path that doubles back onto the same node makes no self-link`() {
    let snapshot = aggregate([TrafficFixture.entry(hops: [[0x0A], [0x0A]])])
    #expect(snapshot.segments.isEmpty)
    #expect(snapshot.nodes.first?.packetCount == 2)
  }

  @Test
  func `A single-hop packet places its node but makes no link`() {
    let snapshot = aggregate([TrafficFixture.entry(hops: [[0x0A]])])
    #expect(snapshot.nodes.count == 1)
    #expect(snapshot.segments.isEmpty)
  }

  @Test
  func `A link's endpoints carry the placed positions of its two nodes`() throws {
    let snapshot = aggregate([TrafficFixture.entry(hops: [[0x0A], [0x0B]])])
    let segment = try #require(snapshot.segments.first)
    #expect(segment.endpointA.coordinate == TrafficCoordinate(latitude: 10, longitude: 10))
    #expect(segment.endpointB.coordinate == TrafficCoordinate(latitude: 11, longitude: 10))
  }

  @Test
  func `A link's id is stable whichever direction the packet took`() throws {
    let forward = try #require(aggregate([TrafficFixture.entry(hops: [[0x0A], [0x0B]])]).segments.first)
    let reverse = try #require(aggregate([TrafficFixture.entry(hops: [[0x0B], [0x0A]])]).segments.first)
    #expect(forward.id == reverse.id)
  }

  // MARK: - Wider hashes

  @Test
  func `Two- and three-byte path hashes resolve the same way one-byte hashes do`() {
    let candidates = [
      TrafficFixture.node([0x0A, 0x11], name: "A", latitude: 10, longitude: 10),
      TrafficFixture.node([0x0A, 0x22], name: "A2", latitude: 11, longitude: 10),
    ]
    let snapshot = aggregate(
      [TrafficFixture.entry(hops: [[0x0A, 0x11], [0x0A, 0x22]], hashSize: 2)],
      candidates: candidates
    )
    #expect(snapshot.nodes.map(\.name).sorted() == ["A", "A2"])
    #expect(snapshot.segments.count == 1)
  }

  // MARK: - Time window

  @Test
  func `Entries outside the window are not analyzed at all`() {
    let entries = [
      TrafficFixture.entry(hops: [[0x0A]], receivedAt: now.addingTimeInterval(-60)),
      TrafficFixture.entry(hops: [[0x0B]], receivedAt: now.addingTimeInterval(-7200)),
    ]
    let snapshot = aggregate(entries, window: .hour1)
    #expect(snapshot.analyzedEntryCount == 1)
    #expect(snapshot.nodes.map(\.name) == ["A"])

    let everything = aggregate(entries, window: .all)
    #expect(everything.analyzedEntryCount == 2)
    #expect(everything.nodes.count == 2)
  }

  @Test
  func `The reported oldest entry is the oldest inside the window, not the oldest on record`() {
    let entries = [
      TrafficFixture.entry(hops: [[0x0A]], receivedAt: now.addingTimeInterval(-60)),
      TrafficFixture.entry(hops: [[0x0A]], receivedAt: now.addingTimeInterval(-1800)),
      TrafficFixture.entry(hops: [[0x0A]], receivedAt: now.addingTimeInterval(-7200)),
    ]
    #expect(aggregate(entries, window: .hour1).oldestEntryDate == now.addingTimeInterval(-1800))
    #expect(aggregate(entries, window: .all).oldestEntryDate == now.addingTimeInterval(-7200))
  }

  // MARK: - Determinism

  @Test
  func `Aggregating the same log twice yields an identical snapshot`() {
    let entries = [
      TrafficFixture.entry(hops: [[0x0A], [0x0B]]),
      TrafficFixture.entry(hops: [[0x0B], [0x0C]]),
      TrafficFixture.entry(hops: [[0x0C], [0x0A]]),
    ]
    #expect(aggregate(entries) == aggregate(entries))
  }

  // MARK: - Resolution cache

  @Test
  func `Identity resolution runs once per distinct hop hash, however long the log`() {
    let counting = CountingResolver()
    let counted = TrafficHeatmapAggregator(resolver: counting)
    let entries = Array(repeating: TrafficFixture.entry(hops: [[0x0A], [0x0B], [0x0C]]), count: 20)

    let snapshot = counted.aggregate(entries: entries, candidates: mesh, now: now)

    // Three hashes across sixty hops, and the same snapshot the uncounted aggregator produces.
    #expect(counting.callCount == 3)
    #expect(snapshot == aggregate(entries))
  }

  @Test
  func `The cache does not freeze an ambiguous hash: each hop still picks by its own anchor`() {
    // `0x0A` names two nodes 30 degrees apart. Which one relayed a packet is decided by the hop
    // beside it, so the same hash resolves differently on two paths — the part of resolution
    // that must stay out of the cache.
    let candidates = [
      TrafficFixture.node([0x0A], fill: 0x11, name: "A-north", latitude: 40, longitude: 10),
      TrafficFixture.node([0x0A], fill: 0x22, name: "A-south", latitude: 10, longitude: 10),
      TrafficFixture.node([0x0B], name: "B-north", latitude: 40.1, longitude: 10),
      TrafficFixture.node([0x0C], name: "C-south", latitude: 10.1, longitude: 10),
    ]
    let snapshot = aggregate(
      [
        TrafficFixture.entry(hops: [[0x0A], [0x0B]]),
        TrafficFixture.entry(hops: [[0x0A], [0x0C]]),
      ],
      candidates: candidates
    )

    #expect(snapshot.nodes.map(\.name).sorted() == ["A-north", "A-south", "B-north", "C-south"])
  }

  // MARK: - Source pooling

  @Test
  func `Contacts and discovered nodes resolve out of one pool`() {
    let contact = ContactDTO.testContact(
      publicKey: TrafficFixture.key([0x0A]),
      latitude: 10,
      longitude: 10
    )
    let snapshot = aggregator.aggregate(
      entries: [TrafficFixture.entry(hops: [[0x0A]])],
      contacts: [contact],
      discoveredNodes: [],
      now: now
    )
    #expect(snapshot.nodes.count == 1)
  }
}

/// The real resolver with a tally, so a test can pin how much work a log actually costs.
private final class CountingResolver: NodeIdentityResolving {
  private let wrapped = NodeIdentityResolver()
  private let count = OSAllocatedUnfairLock(initialState: 0)

  var callCount: Int {
    count.withLock { $0 }
  }

  func resolve<Candidate: RepeaterResolvable>(
    _ id: NodeHexID,
    among candidates: [Candidate],
    now: Date,
    overrides: NodeIdentityOverrides
  ) -> NodeResolution<Candidate>? {
    count.withLock { $0 += 1 }
    return wrapped.resolve(id, among: candidates, now: now, overrides: overrides)
  }
}
