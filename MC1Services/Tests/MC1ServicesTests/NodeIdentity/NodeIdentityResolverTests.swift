import Foundation
@testable import MC1Services
import MeshCore
import Testing

/// Spec source: legacy `MC1/Utilities/RepeaterResolver.swift` — `filterFresh`,
/// `buildNodePool` and `sortedCandidates`. The geographic (user/anchor distance)
/// ranking is deliberately not ported; see the module docs.
@Suite("NodeIdentityResolver")
struct NodeIdentityResolverTests {
  // MARK: - Fixtures

  /// Fixed clock so nothing in these tests depends on the wall clock.
  private static let now = Date(timeIntervalSince1970: 1_700_000_000)
  private static let nowTS: UInt32 = 1_700_000_000
  /// `now` minus the 7-day stale window: an advert exactly here is stale.
  private static let staleBoundaryTS: UInt32 = 1_700_000_000 - 7 * 24 * 3600

  private struct TestNode: RepeaterResolvable, Equatable {
    var publicKey: Data
    var latitude: Double = 0
    var longitude: Double = 0
    var hasLocation: Bool = false
    var lastAdvertTimestamp: UInt32 = 0
    var recencyDate: Date = .distantPast
    var resolvableName: String = ""
    var expiresWhenStale: Bool = false
  }

  /// A 32-byte public key beginning with `prefix`, padded with `fill`.
  private static func key(_ prefix: [UInt8], fill: UInt8 = 0x77) -> Data {
    Data(prefix) + Data(repeating: fill, count: 32 - prefix.count)
  }

  private func node(
    _ prefix: [UInt8],
    fill: UInt8 = 0x77,
    name: String = "node",
    advert: UInt32 = 0,
    recency: Date = .distantPast,
    expiresWhenStale: Bool = false
  ) -> TestNode {
    TestNode(
      publicKey: Self.key(prefix, fill: fill),
      lastAdvertTimestamp: advert,
      recencyDate: recency,
      resolvableName: name,
      expiresWhenStale: expiresWhenStale
    )
  }

  private func hexID(_ text: String) throws -> NodeHexID {
    try #require(NodeHexID(text))
  }

  private let resolver = NodeIdentityResolver()

  // MARK: - Matching

  @Test
  func `Resolution returns nil when no candidate's public key starts with the id`() throws {
    let candidates = [node([0x0D]), node([0xAB])]
    #expect(try resolver.resolve(hexID("0C"), among: candidates, now: Self.now) == nil)
    #expect(try resolver.bestMatch(for: hexID("0C"), among: candidates, now: Self.now) == nil)
  }

  @Test
  func `Resolution returns nil for an empty candidate pool`() throws {
    #expect(try resolver.resolve(hexID("0C"), among: [TestNode](), now: Self.now) == nil)
  }

  @Test
  func `A single prefix match resolves to that candidate and is not ambiguous`() throws {
    let match = node([0x0C, 0x13], name: "Summit")
    let result = try #require(try resolver.resolve(hexID("0C"), among: [node([0xAB]), match], now: Self.now))
    #expect(result.best == match)
    #expect(result.candidates == [match])
    #expect(result.isAmbiguous == false)
  }

  // MARK: - Collision ranking

  @Test
  func `On a hash collision the most recently advertised candidate wins`() throws {
    let stale = node([0x0C], fill: 0x01, name: "Older", advert: Self.nowTS - 3600)
    let recent = node([0x0C], fill: 0x02, name: "Newer", advert: Self.nowTS - 60)
    let result = try #require(try resolver.resolve(hexID("0C"), among: [stale, recent], now: Self.now))
    #expect(result.best == recent)
    #expect(result.isAmbiguous)
    #expect(result.candidates == [recent, stale]) // sorted best-first
  }

  @Test
  func `Equal advert timestamps fall through to the secondary recency date`() throws {
    let older = node([0x0C], fill: 0x01, name: "A", advert: Self.nowTS, recency: Self.now.addingTimeInterval(-600))
    let newer = node([0x0C], fill: 0x02, name: "B", advert: Self.nowTS, recency: Self.now)
    let result = try #require(try resolver.resolve(hexID("0C"), among: [older, newer], now: Self.now))
    #expect(result.best == newer)
  }

  @Test
  func `Candidates equal on both recency signals are ordered by name`() throws {
    let zulu = node([0x0C], fill: 0x01, name: "Zulu", advert: Self.nowTS, recency: Self.now)
    let alpha = node([0x0C], fill: 0x02, name: "Alpha", advert: Self.nowTS, recency: Self.now)
    let result = try #require(try resolver.resolve(hexID("0C"), among: [zulu, alpha], now: Self.now))
    #expect(result.best == alpha)
    #expect(result.candidates == [alpha, zulu])
  }

  @Test
  func `A longer agreed prefix outranks a more recent shallower match`() throws {
    // A truncated 1-byte key can only agree on one byte; the full key agrees on two.
    let shallowButRecent = TestNode(
      publicKey: Data([0x0C]),
      lastAdvertTimestamp: Self.nowTS,
      recencyDate: Self.now,
      resolvableName: "Shallow"
    )
    let deepButOld = node([0x0C, 0x13], name: "Deep", advert: Self.nowTS - 86400)
    let result = try #require(try resolver.resolve(hexID("0C13"), among: [shallowButRecent, deepButOld], now: Self.now))
    #expect(result.best == deepButOld)
  }

  @Test
  func `Ids of different widths resolve against the same candidate pool`() throws {
    let target = node([0x0C, 0x13, 0xAB], name: "Target")
    for width in ["0C", "0C13", "0C13AB"] {
      let result = try #require(try resolver.resolve(hexID(width), among: [target, node([0xFF])], now: Self.now))
      #expect(result.best == target, "width \(width)")
    }
    // ...and a wider id that diverges does not match.
    #expect(try resolver.resolve(hexID("0C14"), among: [target], now: Self.now) == nil)
  }

  // MARK: - Stale filtering (7 days)

  @Test
  func `A stale-eligible candidate is filtered at exactly the 7-day boundary`() throws {
    let atBoundary = node([0x0C], fill: 0x01, name: "AtBoundary", advert: Self.staleBoundaryTS, expiresWhenStale: true)
    #expect(try resolver.resolve(hexID("0C"), among: [atBoundary], now: Self.now) == nil)

    let oneSecondFresher = node([0x0C], fill: 0x01, name: "Fresh", advert: Self.staleBoundaryTS + 1, expiresWhenStale: true)
    #expect(try resolver.bestMatch(for: hexID("0C"), among: [oneSecondFresher], now: Self.now) == oneSecondFresher)
  }

  @Test
  func `A stale discovered node never beats an active one, however recently it was stored`() throws {
    let staleButRichlyStored = node(
      [0x0C],
      fill: 0x01,
      name: "Ghost",
      advert: Self.staleBoundaryTS - 86400,
      recency: Self.now,
      expiresWhenStale: true
    )
    let active = node([0x0C], fill: 0x02, name: "Active", advert: Self.nowTS - 3600, expiresWhenStale: true)
    let result = try #require(try resolver.resolve(hexID("0C"), among: [staleButRichlyStored, active], now: Self.now))
    #expect(result.best == active)
    #expect(result.candidates == [active]) // the ghost is filtered out entirely, not just outranked
  }

  @Test
  func `Candidates that never advertised are never treated as stale`() throws {
    let neverAdvertised = node([0x0C], name: "Silent", advert: 0, expiresWhenStale: true)
    #expect(try resolver.bestMatch(for: hexID("0C"), among: [neverAdvertised], now: Self.now) == neverAdvertised)
  }

  @Test
  func `Candidates that do not expire survive an arbitrarily old advert`() throws {
    let ancientContact = node([0x0C], name: "SavedContact", advert: 1, expiresWhenStale: false)
    #expect(try resolver.bestMatch(for: hexID("0C"), among: [ancientContact], now: Self.now) == ancientContact)
  }

  @Test
  func `A now earlier than the stale window does not underflow into filtering everything`() throws {
    let earlyClock = Date(timeIntervalSince1970: 60)
    let node1 = node([0x0C], name: "Early", advert: 30, expiresWhenStale: true)
    #expect(try resolver.bestMatch(for: hexID("0C"), among: [node1], now: earlyClock) == node1)
  }

  @Test
  func `The clock is an input: the same pool resolves differently as now advances`() throws {
    let candidate = node([0x0C], name: "Fading", advert: Self.nowTS, expiresWhenStale: true)
    #expect(try resolver.bestMatch(for: hexID("0C"), among: [candidate], now: Self.now) == candidate)
    let muchLater = Self.now.addingTimeInterval(8 * 24 * 3600)
    #expect(try resolver.bestMatch(for: hexID("0C"), among: [candidate], now: muchLater) == nil)
  }

  @Test
  func `The stale window is configurable without changing the default`() throws {
    #expect(NodeIdentityResolver.defaultStaleInterval == 7 * 24 * 3600)
    let candidate = node([0x0C], name: "Fading", advert: Self.nowTS - 3600, expiresWhenStale: true)
    let strict = NodeIdentityResolver(staleInterval: 60)
    #expect(try strict.bestMatch(for: hexID("0C"), among: [candidate], now: Self.now) == nil)
  }

  // MARK: - User corrections overlay

  @Test
  func `An override pins a candidate ahead of the recency winner`() throws {
    let id = try hexID("0C")
    let recent = node([0x0C], fill: 0x02, name: "Newer", advert: Self.nowTS)
    let corrected = node([0x0C], fill: 0x01, name: "UserPick", advert: Self.nowTS - 86400)

    let withoutOverride = try #require(resolver.resolve(id, among: [recent, corrected], now: Self.now))
    #expect(withoutOverride.best == recent)

    let withOverride = try #require(
      resolver.resolve(id, among: [recent, corrected], now: Self.now, overrides: [id: corrected.publicKey])
    )
    #expect(withOverride.best == corrected)
    #expect(withOverride.candidates == [corrected, recent]) // the loser stays available
  }

  @Test
  func `An override keyed to a public-key prefix still pins the right candidate`() throws {
    let id = try hexID("0C")
    let recent = node([0x0C], fill: 0x02, name: "Newer", advert: Self.nowTS)
    let corrected = node([0x0C], fill: 0x01, name: "UserPick", advert: Self.nowTS - 86400)
    let result = try #require(
      resolver.resolve(id, among: [recent, corrected], now: Self.now, overrides: [id: corrected.publicKey.prefix(6)])
    )
    #expect(result.best == corrected)
  }

  @Test
  func `An override for a different id, or for an absent node, changes nothing`() throws {
    let id = try hexID("0C")
    let other = try hexID("AB")
    let recent = node([0x0C], fill: 0x02, name: "Newer", advert: Self.nowTS)
    let corrected = node([0x0C], fill: 0x01, name: "UserPick", advert: Self.nowTS - 86400)

    let wrongKey = try #require(
      resolver.resolve(id, among: [recent, corrected], now: Self.now, overrides: [other: corrected.publicKey])
    )
    #expect(wrongKey.best == recent)

    let absentNode = try #require(
      resolver.resolve(id, among: [recent, corrected], now: Self.now, overrides: [id: Self.key([0xEE])])
    )
    #expect(absentNode.best == recent)
  }

  @Test
  func `An override cannot resurrect a stale candidate`() throws {
    let id = try hexID("0C")
    let ghost = node([0x0C], fill: 0x01, name: "Ghost", advert: Self.staleBoundaryTS - 1, expiresWhenStale: true)
    let active = node([0x0C], fill: 0x02, name: "Active", advert: Self.nowTS, expiresWhenStale: true)
    let result = try #require(
      resolver.resolve(id, among: [ghost, active], now: Self.now, overrides: [id: ghost.publicKey])
    )
    #expect(result.best == active)
  }

  // MARK: - DTO conformances and the mixed pool

  @Test
  func `Only discovered nodes opt into stale expiry; saved contacts never do`() {
    #expect(ContactDTO.testContact().expiresWhenStale == false)
    #expect(discoveredNode(publicKey: Self.key([0x0C]), advert: 0).expiresWhenStale == true)
  }

  @Test
  func `The mixed pool entry point filters stale discovered nodes but keeps stale contacts`() throws {
    let ancientContact = ContactDTO.testContact(
      publicKey: Self.key([0x0C], fill: 0x01),
      name: "SavedRepeater",
      lastAdvertTimestamp: 1
    )
    let ghost = discoveredNode(
      publicKey: Self.key([0x0C], fill: 0x02),
      name: "Ghost",
      advert: Self.staleBoundaryTS
    )
    let result = try #require(
      try resolver.resolve(
        hexID("0C"),
        contacts: [ancientContact],
        discoveredNodes: [ghost],
        now: Self.now
      )
    )
    #expect(result.candidates.count == 1)
    #expect(result.best.resolvableName == "SavedRepeater")
    #expect(result.best.publicKey == ancientContact.publicKey)
  }

  @Test
  func `A fresh discovered node outranks a long-dormant contact in the mixed pool`() throws {
    let dormantContact = ContactDTO.testContact(
      publicKey: Self.key([0x0C], fill: 0x01),
      name: "SavedRepeater",
      lastAdvertTimestamp: Self.nowTS - 6 * 24 * 3600
    )
    let heardJustNow = discoveredNode(
      publicKey: Self.key([0x0C], fill: 0x02),
      name: "Ghost",
      advert: Self.nowTS - 30
    )
    let result = try #require(
      try resolver.resolve(
        hexID("0C"),
        contacts: [dormantContact],
        discoveredNodes: [heardJustNow],
        now: Self.now
      )
    )
    #expect(result.best.publicKey == heardJustNow.publicKey)
    #expect(result.isAmbiguous)
  }

  @Test
  func `AnyResolvableNode forwards every resolvable field`() {
    let contact = ContactDTO.testContact(
      publicKey: Self.key([0x0C]),
      name: "Ridge",
      lastAdvertTimestamp: 42,
      latitude: 12.5,
      longitude: -7.25,
      lastModified: 99
    )
    let erased = AnyResolvableNode(contact)
    #expect(erased.publicKey == contact.publicKey)
    #expect(erased.latitude == contact.latitude)
    #expect(erased.longitude == contact.longitude)
    #expect(erased.hasLocation == contact.hasLocation)
    #expect(erased.lastAdvertTimestamp == contact.lastAdvertTimestamp)
    #expect(erased.recencyDate == contact.recencyDate)
    #expect(erased.resolvableName == contact.resolvableName)
    #expect(erased.expiresWhenStale == contact.expiresWhenStale)
  }

  // MARK: - Helpers

  private func discoveredNode(
    publicKey: Data,
    name: String = "Discovered",
    advert: UInt32
  ) -> DiscoveredNodeDTO {
    DiscoveredNodeDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: publicKey,
      name: name,
      typeRawValue: ContactType.repeater.rawValue,
      lastHeard: Date(timeIntervalSince1970: Double(advert)),
      lastAdvertTimestamp: advert,
      latitude: 0,
      longitude: 0,
      outPathLength: 0xFF,
      outPath: Data(),
      inboundHopCount: nil,
      inboundHopAdvertTimestamp: nil
    )
  }
}
