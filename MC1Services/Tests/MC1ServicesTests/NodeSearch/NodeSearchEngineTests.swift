import Foundation
@testable import MC1Services
import Testing

/// Spec source: the three legacy matchers this engine replaces —
/// `ContactsViewModel.filteredContacts`/`hexMatchTier` (commits `0feb2e17` search by
/// public key, `a3057d81` strict hex matching, `3cbfac71` pubkey-prefix priority) and the
/// picker's `RepeaterCandidate.matches(query:)`. Each legacy rule is one case below.
@Suite("NodeSearchEngine")
struct NodeSearchEngineTests {
  private let engine = NodeSearchEngine()

  private struct TestNode: RepeaterResolvable, Equatable {
    var publicKey: Data
    var latitude: Double = 0
    var longitude: Double = 0
    var hasLocation: Bool = false
    var lastAdvertTimestamp: UInt32 = 0
    var recencyDate: Date = .distantPast
    var resolvableName: String
    var expiresWhenStale: Bool = false
  }

  /// A 32-byte public key beginning with `prefix`, padded with `fill`.
  private static func key(_ prefix: [UInt8], fill: UInt8 = 0x77) -> Data {
    Data(prefix) + Data(repeating: fill, count: 32 - prefix.count)
  }

  private func node(
    _ name: String,
    key prefix: [UInt8] = [0x77],
    fill: UInt8 = 0x77,
    advert: UInt32 = 0,
    recency: Date = .distantPast
  ) -> TestNode {
    TestNode(
      publicKey: Self.key(prefix, fill: fill),
      lastAdvertTimestamp: advert,
      recencyDate: recency,
      resolvableName: name
    )
  }

  private func names(_ matches: [NodeSearchMatch<TestNode>]) -> [String] {
    matches.map(\.node.resolvableName)
  }

  // MARK: - Rule: a query matches names

  @Test
  func `a plain word matches names by substring, case and diacritic insensitively`() {
    let pool = [node("Alice"), node("Relay-Alpha"), node("Bob"), node("Álvaro")]
    #expect(names(engine.search(NodeSearchQuery("al"), among: pool, options: .default.ordering(.inputOrder)))
      == ["Alice", "Relay-Alpha", "Álvaro"])
  }

  @Test
  func `a query that matches nothing returns nothing`() {
    let pool = [node("Alice"), node("Bob")]
    #expect(engine.search(NodeSearchQuery("zzz"), among: pool).isEmpty)
  }

  @Test
  func `an empty query matches every candidate`() {
    let pool = [node("Alice"), node("Bob")]
    let result = engine.search(NodeSearchQuery("   "), among: pool, options: .default.ordering(.inputOrder))
    #expect(names(result) == ["Alice", "Bob"])
    #expect(result.allSatisfy { $0.relevance == .name })
  }

  // MARK: - Rule: strict hex detection — only a hex query touches key bytes

  @Test
  func `a non hex query never matches a public key`() {
    // "Zoo" is not hex; the key of the second node is irrelevant to it.
    let pool = [node("Alice", key: [0x20, 0x00]), node("Zookeeper", key: [0x20, 0x00])]
    #expect(names(engine.search(NodeSearchQuery("Zoo"), among: pool)) == ["Zookeeper"])
  }

  @Test
  func `a hex query still matches names`() {
    // "abc" is strictly hex, but a node called "abcdef" must not drop out of the results.
    let pool = [node("abcdef", key: [0x11]), node("unrelated", key: [0x22])]
    #expect(names(engine.search(NodeSearchQuery("abc"), among: pool)) == ["abcdef"])
  }

  @Test
  func `the legacy 0c versus CC false positive stays fixed`() {
    // a3057d81: `localizedCaseInsensitiveContains` matched "0c" against a key of "CC…".
    let pool = [node("Ridge", key: [0xCC, 0xCC], fill: 0xCC)]
    #expect(engine.search(NodeSearchQuery("0c"), among: pool).isEmpty)
    #expect(engine.search(NodeSearchQuery("0c"), among: pool, options: .prefixOnly).isEmpty)
  }

  @Test
  func `hex matching ignores the case the user typed`() {
    let pool = [node("HexNode", key: [0x00, 0xAA])]
    for query in ["00AA", "00aa", "00Aa"] {
      #expect(names(engine.search(NodeSearchQuery(query), among: pool)) == ["HexNode"], "query \(query)")
    }
  }

  @Test
  func `an odd width hex query pins half a byte`() {
    let pool = [node("Match", key: [0x0C, 0x13]), node("Miss", key: [0x0C, 0x23])]
    #expect(names(engine.search(NodeSearchQuery("0C1"), among: pool)) == ["Match"])
  }

  // MARK: - Rule: pubkey-prefix matches outrank name matches

  struct RankCase: Sendable {
    let query: String
    let expected: [String]
    let comment: String
  }

  /// The pool is deliberately ordered worst-first so any correct answer has to be a
  /// re-ranking rather than the input order surviving.
  private var rankingPool: [TestNode] {
    [
      node("0C13edar", key: [0xFF, 0xFF], fill: 0xFF), // name contains "0C13", key does not
      node("Interior", key: [0xF0, 0xC1, 0x3F]), // "0C13" sits inside the key, off by a nibble
      node("Prefix", key: [0x0C, 0x13]) // key starts with "0C13"
    ]
  }

  @Test(arguments: [
    RankCase(
      query: "0C13",
      expected: ["Prefix", "Interior", "0C13edar"],
      comment: "3cbfac71's tiers: key-prefix, then key-contains, then name-only"
    ),
    RankCase(
      query: "0C137777",
      expected: ["Prefix"],
      comment: "a wider query narrows to the one real key match"
    ),
    RankCase(
      query: "edar",
      expected: ["0C13edar"],
      comment: "a non-hex query is name-only, whatever the keys hold"
    )
  ])
  func `relevance tiers rank key matches above name matches`(testCase: RankCase) {
    let result = engine.search(NodeSearchQuery(testCase.query), among: rankingPool, options: .default.ordering(.inputOrder))
    #expect(names(result) == testCase.expected, Comment(rawValue: testCase.comment))
  }

  @Test
  func `each tier reports the reason it matched`() {
    let result = engine.search(NodeSearchQuery("0C13"), among: rankingPool, options: .default.ordering(.inputOrder))
    #expect(result.map(\.relevance) == [.keyPrefix, .keyInterior, .name])
  }

  // MARK: - Rule: interior key matching has a floor

  @Test
  func `interior key matching is off for queries narrower than two bytes`() {
    // A single nibble appears somewhere in almost every 32-byte key; legacy had no floor
    // and the tier swamped the results.
    let pool = [node("Interior", key: [0xF0, 0xCF]), node("Prefix", key: [0x0C, 0x13])]
    #expect(names(engine.search(NodeSearchQuery("0"), among: pool)) == ["Prefix"])
  }

  @Test
  func `interior key matching can be switched off entirely`() {
    let pool = [node("Interior", key: [0xF0, 0xC1, 0x3F]), node("Prefix", key: [0x0C, 0x13])]
    #expect(names(engine.search(NodeSearchQuery("0C13"), among: pool, options: .default.ordering(.inputOrder))) == ["Prefix", "Interior"])
    #expect(names(engine.search(NodeSearchQuery("0C13"), among: pool, options: .prefixOnly)) == ["Prefix"])
  }

  // MARK: - Rule: recency breaks ties inside a tier

  @Test
  func `within a tier the most recently advertised node ranks first`() {
    let pool = [
      node("Older", key: [0x0C, 0x01], advert: 1000),
      node("Newest", key: [0x0C, 0x02], advert: 3000),
      node("Middle", key: [0x0C, 0x03], advert: 2000)
    ]
    #expect(names(engine.search(NodeSearchQuery("0C"), among: pool)) == ["Newest", "Middle", "Older"])
  }

  @Test
  func `recency falls through to the secondary date then the name`() {
    let older = Date(timeIntervalSince1970: 1000)
    let newer = Date(timeIntervalSince1970: 2000)
    let pool = [
      node("Charlie", key: [0x0C, 0x01], advert: 500, recency: older),
      node("Alpha", key: [0x0C, 0x02], advert: 500, recency: older),
      node("Bravo", key: [0x0C, 0x03], advert: 500, recency: newer)
    ]
    #expect(names(engine.search(NodeSearchQuery("0C"), among: pool)) == ["Bravo", "Alpha", "Charlie"])
  }

  @Test
  func `recency never reorders across tiers`() {
    let pool = [
      node("0CName", key: [0xFF, 0xFF], advert: 9000), // name tier, very recent
      node("KeyMatch", key: [0x0C, 0x13], advert: 1) // key-prefix tier, ancient
    ]
    #expect(names(engine.search(NodeSearchQuery("0C"), among: pool)) == ["KeyMatch", "0CName"])
  }

  // MARK: - Rule: the caller may keep its own ordering inside a tier

  @Test
  func `input order tie break preserves the callers sort within each tier`() {
    // Legacy sorted by the user's chosen order, then stably re-sorted by tier.
    let pool = [
      node("Zulu", key: [0x0C, 0x01], advert: 10),
      node("Alpha", key: [0x0C, 0x02], advert: 9000),
      node("0CMike", key: [0xFF, 0xFF], advert: 9999)
    ]
    let result = engine.search(NodeSearchQuery("0C"), among: pool, options: .default.ordering(.inputOrder))
    #expect(names(result) == ["Zulu", "Alpha", "0CMike"])
  }

  // MARK: - Mixed pools

  @Test
  func `contacts and discovered nodes rank in one pool and keep their identity`() {
    let contact = ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Self.key([0x0C, 0x13]),
      name: "Saved Repeater",
      typeRawValue: 2,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 100,
      latitude: 0,
      longitude: 0,
      lastModified: 100,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0,
      unreadMentionCount: 0,
      ocvPreset: nil,
      customOCVArrayString: nil,
      avatarImageData: nil
    )
    let discovered = DiscoveredNodeDTO(
      id: UUID(),
      radioID: contact.radioID,
      publicKey: Self.key([0x0C, 0x99]),
      name: "Heard Repeater",
      typeRawValue: 2,
      lastHeard: Date(timeIntervalSince1970: 5000),
      lastAdvertTimestamp: 5000,
      latitude: 0,
      longitude: 0,
      outPathLength: 0,
      outPath: Data(),
      inboundHopCount: nil,
      inboundHopAdvertTimestamp: nil
    )

    let result = engine.search(NodeSearchQuery("0C"), contacts: [contact], discoveredNodes: [discovered])

    #expect(result.map(\.node) == [.discovered(discovered), .contact(contact)], "the more recent advert wins the tie")
    #expect(result.first?.node.discoveredNode?.name == "Heard Repeater")
    #expect(result.last?.node.contact?.displayName == "Saved Repeater")
  }

  @Test
  func `a contacts nickname is what gets searched`() {
    // `resolvableName` is `displayName`, so a renamed node answers to its nickname.
    let contact = ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Self.key([0x11]),
      name: "meshcore-abc123",
      typeRawValue: 0,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: "Kitchen Node",
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0,
      unreadMentionCount: 0,
      ocvPreset: nil,
      customOCVArrayString: nil,
      avatarImageData: nil
    )
    #expect(engine.search(NodeSearchQuery("Kitchen"), contacts: [contact], discoveredNodes: []).count == 1)
  }
}
