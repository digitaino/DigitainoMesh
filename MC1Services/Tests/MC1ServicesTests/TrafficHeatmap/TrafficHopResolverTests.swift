import Foundation
@testable import MC1Services
import Testing

/// Spec source: legacy `TrafficHeatmapViewModel.aggregate`'s hop loop, plus the two rules the
/// v2 resolver deliberately left to this layer (placeability, chain proximity).
@Suite("TrafficHopResolver")
struct TrafficHopResolverTests {
  private let resolver = TrafficHopResolver()
  private let now = TrafficFixture.now

  // MARK: - Hop splitting

  /// One row of the hop-splitting table. A named type rather than a tuple: the tuple version
  /// of this table takes the type checker past its budget.
  struct HopSplitCase: Sendable {
    let pathNodes: Data
    let hashSize: Int
    let expected: [Data]
  }

  static let hopSplitCases: [HopSplitCase] = [
    HopSplitCase(
      pathNodes: Data([0x0C, 0x1A, 0x2B]),
      hashSize: 1,
      expected: [Data([0x0C]), Data([0x1A]), Data([0x2B])]
    ),
    HopSplitCase(
      pathNodes: Data([0x0C, 0x1A, 0x2B, 0x3C]),
      hashSize: 2,
      expected: [Data([0x0C, 0x1A]), Data([0x2B, 0x3C])]
    ),
    HopSplitCase(
      pathNodes: Data([0x0C, 0x1A, 0x2B]),
      hashSize: 3,
      expected: [Data([0x0C, 0x1A, 0x2B])]
    ),
    // A trailing run narrower than the hash width is kept rather than dropped.
    HopSplitCase(
      pathNodes: Data([0x0C, 0x1A, 0x2B]),
      hashSize: 2,
      expected: [Data([0x0C, 0x1A]), Data([0x2B])]
    ),
  ]

  @Test(arguments: hopSplitCases)
  func `Path bytes split into hop hashes of the advertised width`(testCase: HopSplitCase) {
    let hops = TrafficHopResolver.hopHashes(
      pathNodes: testCase.pathNodes,
      hashSize: testCase.hashSize
    )
    #expect(hops == testCase.expected)
  }

  @Test
  func `An empty or unsized path yields no hops`() {
    #expect(TrafficHopResolver.hopHashes(pathNodes: Data(), hashSize: 1).isEmpty)
    #expect(TrafficHopResolver.hopHashes(pathNodes: Data([0x0C]), hashSize: 0).isEmpty)
  }

  // MARK: - Placement

  @Test
  func `Hops come back in path order, sender first, carrying their original index`() {
    let candidates = [
      TrafficFixture.node([0x0A], name: "A", latitude: 10, longitude: 10),
      TrafficFixture.node([0x0B], name: "B", latitude: 11, longitude: 11),
      TrafficFixture.node([0x0C], name: "C", latitude: 12, longitude: 12),
    ]
    let hops = resolver.resolve(
      hashes: [Data([0x0A]), Data([0x0B]), Data([0x0C])],
      among: candidates,
      origin: nil,
      now: now
    )
    #expect(hops.map(\.name) == ["A", "B", "C"])
    #expect(hops.map(\.index) == [0, 1, 2])
  }

  @Test
  func `A hash nothing answers to drops out, and the surviving hops keep their path indices`() {
    let candidates = [
      TrafficFixture.node([0x0A], name: "A", latitude: 10, longitude: 10),
      TrafficFixture.node([0x0C], name: "C", latitude: 12, longitude: 12),
    ]
    let hops = resolver.resolve(
      hashes: [Data([0x0A]), Data([0xEE]), Data([0x0C])],
      among: candidates,
      origin: nil,
      now: now
    )
    #expect(hops.map(\.name) == ["A", "C"])
    #expect(hops.map(\.index) == [0, 2])
  }

  @Test
  func `An unlocated node cannot be a hop`() {
    let hops = resolver.resolve(
      hashes: [Data([0x0A])],
      among: [TrafficFixture.node([0x0A], name: "A")],
      origin: nil,
      now: now
    )
    #expect(hops.isEmpty)
  }

  @Test
  func `A hop skips past an unlocated front-runner to the best candidate it can actually draw`() {
    // Both answer to 0C; the fresher advert wins on identity but has no location.
    let candidates = [
      TrafficFixture.node([0x0C], fill: 0x01, name: "unlocated", advert: TrafficFixture.nowTS),
      TrafficFixture.node(
        [0x0C],
        fill: 0x02,
        name: "located",
        latitude: 12,
        longitude: 12,
        advert: TrafficFixture.nowTS - 500
      ),
    ]
    let hops = resolver.resolve(hashes: [Data([0x0C])], among: candidates, origin: nil, now: now)
    #expect(hops.map(\.name) == ["located"])
  }

  // MARK: - Chain proximity

  @Test
  func `An ambiguous hop resolves to the candidate nearest the radio that heard it`() {
    let candidates = [
      // Fresher advert, so it wins on identity alone — but it is 100 km away.
      TrafficFixture.node(
        [0x0C], fill: 0x01, name: "far", latitude: 11, longitude: 10, advert: TrafficFixture.nowTS
      ),
      TrafficFixture.node(
        [0x0C], fill: 0x02, name: "near", latitude: 10.01, longitude: 10,
        advert: TrafficFixture.nowTS - 500
      ),
    ]
    let origin = TrafficCoordinate(latitude: 10, longitude: 10)

    #expect(
      resolver.resolve(hashes: [Data([0x0C])], among: candidates, origin: origin, now: now)
        .map(\.name) == ["near"]
    )
    // Without an anchor there is nothing to prefer, so identity ranking stands.
    #expect(
      resolver.resolve(hashes: [Data([0x0C])], among: candidates, origin: nil, now: now)
        .map(\.name) == ["far"]
    )
  }

  @Test
  func `An ambiguous earlier hop anchors on the hop already placed beside it, not on the radio`() {
    let candidates = [
      // The unambiguous last hop, far to the north of the radio.
      TrafficFixture.node([0x0B], name: "last", latitude: 20, longitude: 10),
      // Two answers to 0C: one beside the radio, one beside the last hop.
      TrafficFixture.node(
        [0x0C], fill: 0x01, name: "byRadio", latitude: 10.01, longitude: 10,
        advert: TrafficFixture.nowTS
      ),
      TrafficFixture.node(
        [0x0C], fill: 0x02, name: "byLastHop", latitude: 20.01, longitude: 10,
        advert: TrafficFixture.nowTS - 500
      ),
    ]
    let hops = resolver.resolve(
      hashes: [Data([0x0C]), Data([0x0B])],
      among: candidates,
      origin: TrafficCoordinate(latitude: 10, longitude: 10),
      now: now
    )
    #expect(hops.map(\.name) == ["byLastHop", "last"])
  }

  @Test
  func `An unambiguous hop is never second-guessed by proximity`() {
    let candidates = [
      TrafficFixture.node([0x0C], name: "only", latitude: 40, longitude: 40),
      TrafficFixture.node([0x0D], name: "closer", latitude: 10.01, longitude: 10),
    ]
    let hops = resolver.resolve(
      hashes: [Data([0x0C])],
      among: candidates,
      origin: TrafficCoordinate(latitude: 10, longitude: 10),
      now: now
    )
    #expect(hops.map(\.name) == ["only"])
  }

  @Test
  func `Two candidates the same distance away leave the resolver's own ranking in charge`() {
    // Co-located: nothing to choose between them geographically.
    let candidates = [
      TrafficFixture.node(
        [0x0C], fill: 0x01, name: "fresher", latitude: 10.1, longitude: 10,
        advert: TrafficFixture.nowTS
      ),
      TrafficFixture.node(
        [0x0C], fill: 0x02, name: "staler", latitude: 10.1, longitude: 10,
        advert: TrafficFixture.nowTS - 500
      ),
    ]
    let hops = resolver.resolve(
      hashes: [Data([0x0C])],
      among: candidates,
      origin: TrafficCoordinate(latitude: 10, longitude: 10),
      now: now
    )
    #expect(hops.map(\.name) == ["fresher"])
  }

  // MARK: - Resolution cache

  @Test
  func `A cache shared across paths resolves each of them exactly as it would alone`() {
    // What the cache holds is the identity match; the anchored pick is not cached, so one
    // ambiguous hash still lands on a different node per path.
    let candidates = [
      TrafficFixture.node([0x0B], name: "north", latitude: 20, longitude: 10),
      TrafficFixture.node([0x0D], name: "south", latitude: 10, longitude: 10),
      TrafficFixture.node([0x0C], fill: 0x01, name: "byNorth", latitude: 20.01, longitude: 10),
      TrafficFixture.node([0x0C], fill: 0x02, name: "bySouth", latitude: 10.01, longitude: 10),
    ]
    let paths = [
      [Data([0x0C]), Data([0x0B])],
      [Data([0x0C]), Data([0x0D])],
    ]

    var cache = TrafficHopResolver.ResolutionCache()
    let shared = paths.map {
      resolver.resolve(hashes: $0, among: candidates, origin: nil, now: now, cache: &cache)
    }
    let alone = paths.map {
      resolver.resolve(hashes: $0, among: candidates, origin: nil, now: now)
    }

    #expect(shared == alone)
    #expect(shared.map { $0.map(\.name) } == [["byNorth", "north"], ["bySouth", "south"]])
  }

  @Test
  func `A stale discovered node stays filtered out by the identity resolver, however close it is`() {
    let candidates = [
      TrafficFixture.node(
        [0x0C], fill: 0x01, name: "stale", latitude: 10, longitude: 10,
        advert: TrafficFixture.nowTS - 8 * 24 * 3600, expiresWhenStale: true
      ),
      TrafficFixture.node(
        [0x0C], fill: 0x02, name: "fresh", latitude: 40, longitude: 40,
        advert: TrafficFixture.nowTS
      ),
    ]
    let hops = resolver.resolve(
      hashes: [Data([0x0C])],
      among: candidates,
      origin: TrafficCoordinate(latitude: 10, longitude: 10),
      now: now
    )
    #expect(hops.map(\.name) == ["fresh"])
  }
}
