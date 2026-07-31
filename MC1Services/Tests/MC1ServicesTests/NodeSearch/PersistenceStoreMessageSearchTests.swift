import Foundation
@testable import MC1Services
import MeshCore
import SwiftData
import Testing

/// Spec source: legacy `PersistenceStore+Messages.swift` search methods and the
/// `PersistenceStoreProtocol` additions from commit `959b42fa`, restated against
/// upstream's `radioID` naming and `sortDate` ordering.
@Suite("PersistenceStore message search")
struct PersistenceStoreMessageSearchTests {
  private func makeStore() throws -> PersistenceStore {
    let container = try PersistenceStore.createContainer(inMemory: true)
    return PersistenceStore(modelContainer: container)
  }

  private func contactFrame(name: String) -> ContactFrame {
    ContactFrame(
      publicKey: Data((0..<ProtocolLimits.publicKeySize).map { _ in UInt8.random(in: 0...255) }),
      type: .chat,
      flags: 0,
      outPathLength: 2,
      outPath: Data([0x01, 0x02]),
      name: name,
      lastAdvertTimestamp: UInt32(Date().timeIntervalSince1970),
      latitude: 0,
      longitude: 0,
      lastModified: UInt32(Date().timeIntervalSince1970)
    )
  }

  /// Saves one message. `minutesAgo` drives both `createdAt` and `sortDate` so the
  /// ordering assertions below are about the store's sort, not about clock jitter.
  /// `senderTimestamp` overrides the wire timestamp the same-sender reorder keys on.
  @discardableResult
  private func save(
    _ text: String,
    to store: PersistenceStore,
    radioID: UUID,
    contactID: UUID? = nil,
    channelIndex: UInt8? = nil,
    minutesAgo: Int = 0,
    secondsAgo: Int = 0,
    outgoing: Bool = false,
    status: MessageStatus = .delivered,
    senderNodeName: String? = nil,
    senderTimestamp: UInt32? = nil
  ) async throws -> UUID {
    let date = Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60 - Double(secondsAgo))
    let message = MessageDTO(from: Message(
      radioID: radioID,
      contactID: contactID,
      channelIndex: channelIndex,
      text: text,
      timestamp: senderTimestamp ?? UInt32(date.timeIntervalSince1970),
      createdAt: date,
      sortDate: date,
      directionRawValue: outgoing ? MessageDirection.outgoing.rawValue : MessageDirection.incoming.rawValue,
      statusRawValue: status.rawValue,
      senderNodeName: senderNodeName
    ))
    try await store.saveMessage(message)
    return message.id
  }

  /// The wire text a sent DM reaction carries: it quotes the target verbatim, which is why
  /// every hit on a reacted-to message also hits its carrier.
  private func dmReactionText(for targetText: String, targetTimestamp: UInt32 = 1_700_000_000) -> String {
    ReactionParser.buildDMReactionText(
      emoji: "👍",
      targetText: targetText,
      targetTimestamp: targetTimestamp
    )
  }

  private func channelReactionText(for targetText: String, targetTimestamp: UInt32 = 1_700_000_000) -> String {
    ReactionParser.buildChannelReactionText(
      emoji: "👍",
      targetSender: "Alice",
      targetText: targetText,
      targetTimestamp: targetTimestamp,
      localNodeNameByteCount: "MyNode".utf8.count
    )
  }

  // MARK: - Global search

  @Test
  func `global search finds matches across every conversation, newest first`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let alice = try await store.saveContact(radioID: radioID, from: contactFrame(name: "Alice")).id

    let older = try await save("antenna is up", to: store, radioID: radioID, contactID: alice, minutesAgo: 30)
    let newer = try await save("antenna swap tomorrow", to: store, radioID: radioID, channelIndex: 0, minutesAgo: 5)
    try await save("nothing to see", to: store, radioID: radioID, contactID: alice, minutesAgo: 1)

    let results = try await store.searchMessages(radioID: radioID, query: "antenna")

    #expect(results.map(\.id) == [newer, older])
    #expect(results.first?.conversation == .channel(index: 0))
    #expect(results.last?.conversation == .direct(contactID: alice))
  }

  @Test
  func `global search is case and diacritic insensitive`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    try await save("Café is open", to: store, radioID: radioID, channelIndex: 0)

    for query in ["café", "CAFE", "cafe"] {
      let results = try await store.searchMessages(radioID: radioID, query: query)
      #expect(results.count == 1, "query \(query)")
    }
  }

  @Test
  func `global search is scoped to one radio`() async throws {
    let store = try makeStore()
    let mine = UUID()
    let theirs = UUID()
    try await save("shared word", to: store, radioID: mine, channelIndex: 0)
    try await save("shared word", to: store, radioID: theirs, channelIndex: 0)

    #expect(try await store.searchMessages(radioID: mine, query: "shared").count == 1)
  }

  @Test
  func `a blank query matches nothing rather than everything`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    try await save("something", to: store, radioID: radioID, channelIndex: 0)

    #expect(try await store.searchMessages(radioID: radioID, query: "").isEmpty)
    #expect(try await store.searchMessages(radioID: radioID, query: "   ").isEmpty)
    #expect(try await store.searchMessagesCount(radioID: radioID, query: " ") == 0)
  }

  @Test
  func `the result carries what a snippet row draws`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let id = try await save(
      "repeater on the ridge",
      to: store,
      radioID: radioID,
      channelIndex: 3,
      senderNodeName: "Ridge Runner"
    )

    let result = try #require(try await store.searchMessages(radioID: radioID, query: "ridge").first)
    #expect(result.id == id)
    #expect(result.text == "repeater on the ridge")
    #expect(result.senderNodeName == "Ridge Runner")
    #expect(result.channelIndex == 3)
    #expect(result.radioID == radioID)
    #expect(result.isOutgoing == false)
  }

  @Test
  func `outgoing messages are searchable and report their direction`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    try await save("my own words", to: store, radioID: radioID, channelIndex: 0, outgoing: true)

    let result = try #require(try await store.searchMessages(radioID: radioID, query: "own").first)
    #expect(result.isOutgoing)
  }

  // MARK: - Reaction carriers

  @Test
  func `a sent reaction carrier is not a result, even though its text quotes the match`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let alice = try await store.saveContact(radioID: radioID, from: contactFrame(name: "Alice")).id

    let target = try await save("see you at the meetup", to: store, radioID: radioID, contactID: alice, minutesAgo: 10)
    // The carrier is newer than what it reacts to, so unfiltered it is the *first* result —
    // which is the row the results list opens on.
    try await save(
      dmReactionText(for: "see you at the meetup"),
      to: store,
      radioID: radioID,
      contactID: alice,
      minutesAgo: 9,
      outgoing: true,
      status: .sent
    )

    #expect(try await store.searchMessages(radioID: radioID, query: "meetup").map(\.id) == [target])
    #expect(try await store.searchMessageIDs(contactID: alice, query: "meetup") == [target])
  }

  @Test
  func `a channel reaction carrier is not a result`() async throws {
    let store = try makeStore()
    let radioID = UUID()

    let target = try await save(
      "net starts at eight",
      to: store,
      radioID: radioID,
      channelIndex: 2,
      minutesAgo: 10,
      senderNodeName: "Alice"
    )
    try await save(
      channelReactionText(for: "net starts at eight"),
      to: store,
      radioID: radioID,
      channelIndex: 2,
      minutesAgo: 9,
      outgoing: true,
      status: .sent
    )

    #expect(try await store.searchMessages(radioID: radioID, query: "eight").map(\.id) == [target])
    #expect(try await store.searchMessageIDs(radioID: radioID, channelIndex: 2, query: "eight") == [target])
  }

  /// A failed carrier is a visible timeline row the user can retry, so it stays findable —
  /// the exclusion mirrors what the timeline hides, nothing more.
  @Test
  func `a failed reaction carrier stays searchable`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let alice = try await store.saveContact(radioID: radioID, from: contactFrame(name: "Alice")).id

    let target = try await save("bring the mast", to: store, radioID: radioID, contactID: alice, minutesAgo: 10)
    let carrier = try await save(
      dmReactionText(for: "bring the mast"),
      to: store,
      radioID: radioID,
      contactID: alice,
      minutesAgo: 9,
      outgoing: true,
      status: .failed
    )

    #expect(try await store.searchMessages(radioID: radioID, query: "mast").map(\.id) == [carrier, target])
  }

  /// Incoming reaction-shaped text is a bubble in the timeline, so it is a legitimate hit.
  @Test
  func `an incoming reaction-shaped message stays searchable`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let alice = try await store.saveContact(radioID: radioID, from: contactFrame(name: "Alice")).id

    let incoming = try await save(
      dmReactionText(for: "spare battery"),
      to: store,
      radioID: radioID,
      contactID: alice
    )

    #expect(try await store.searchMessages(radioID: radioID, query: "battery").map(\.id) == [incoming])
  }

  /// Carriers are dropped after the fetch, so a page that filtered some must be refilled
  /// from further down the history rather than handed back short.
  @Test
  func `a page stays full when carriers are filtered out of it`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let alice = try await store.saveContact(radioID: radioID, from: contactFrame(name: "Alice")).id

    // Interleaved newest-first: hit 0, carrier, hit 1, carrier, hit 2 …
    for index in 0..<4 {
      try await save("hit \(index)", to: store, radioID: radioID, contactID: alice, minutesAgo: index * 2)
      try await save(
        dmReactionText(for: "hit \(index)"),
        to: store,
        radioID: radioID,
        contactID: alice,
        minutesAgo: index * 2,
        secondsAgo: 30,
        outgoing: true,
        status: .sent
      )
    }

    let page = try await store.searchMessages(radioID: radioID, query: "hit", limit: 3, offset: 0)
    #expect(page.map(\.text) == ["hit 0", "hit 1", "hit 2"])
  }

  // MARK: - Paging and counting

  @Test
  func `limit caps the page and offset walks past it`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    for index in 0..<5 {
      try await save("hit \(index)", to: store, radioID: radioID, channelIndex: 0, minutesAgo: index)
    }

    let firstPage = try await store.searchMessages(radioID: radioID, query: "hit", limit: 2, offset: 0)
    let secondPage = try await store.searchMessages(radioID: radioID, query: "hit", limit: 2, offset: 2)

    #expect(firstPage.map(\.text) == ["hit 0", "hit 1"])
    #expect(secondPage.map(\.text) == ["hit 2", "hit 3"])
    #expect(Set(firstPage.map(\.id)).isDisjoint(with: secondPage.map(\.id)))
  }

  @Test
  func `the count ignores the page limit`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    for index in 0..<7 {
      try await save("hit \(index)", to: store, radioID: radioID, channelIndex: 0, minutesAgo: index)
    }

    #expect(try await store.searchMessages(radioID: radioID, query: "hit", limit: 3, offset: 0).count == 3)
    #expect(try await store.searchMessagesCount(radioID: radioID, query: "hit") == 7)
  }

  // MARK: - Within one conversation

  @Test
  func `direct message search returns ids oldest first and only for that contact`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let alice = try await store.saveContact(radioID: radioID, from: contactFrame(name: "Alice")).id
    let bob = try await store.saveContact(radioID: radioID, from: contactFrame(name: "Bob")).id

    let first = try await save("ping one", to: store, radioID: radioID, contactID: alice, minutesAgo: 30)
    let second = try await save("ping two", to: store, radioID: radioID, contactID: alice, minutesAgo: 10)
    try await save("ping elsewhere", to: store, radioID: radioID, contactID: bob, minutesAgo: 20)

    #expect(try await store.searchMessageIDs(contactID: alice, query: "ping") == [first, second])
  }

  @Test
  func `channel search returns ids oldest first and only for that channel`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let first = try await save("net check", to: store, radioID: radioID, channelIndex: 1, minutesAgo: 30)
    let second = try await save("net check again", to: store, radioID: radioID, channelIndex: 1, minutesAgo: 10)
    try await save("net check other channel", to: store, radioID: radioID, channelIndex: 2, minutesAgo: 20)

    #expect(try await store.searchMessageIDs(radioID: radioID, channelIndex: 1, query: "net") == [first, second])
  }

  @Test
  func `an in conversation blank query matches nothing`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let alice = try await store.saveContact(radioID: radioID, from: contactFrame(name: "Alice")).id
    try await save("anything", to: store, radioID: radioID, contactID: alice)

    #expect(try await store.searchMessageIDs(contactID: alice, query: "  ").isEmpty)
    #expect(try await store.searchMessageIDs(radioID: radioID, channelIndex: 0, query: "").isEmpty)
  }

  /// The cap has to bite at the *old* end: the bar opens on the newest match, so dropping the
  /// newest ones would open on a hit that is neither the nearest nor the one the counter claims.
  @Test
  func `the in conversation match cap keeps the newest matches`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let alice = try await store.saveContact(radioID: radioID, from: contactFrame(name: "Alice")).id
    var ids: [UUID] = []
    for index in 0..<6 {
      ids.append(try await save("hit \(index)", to: store, radioID: radioID, contactID: alice, minutesAgo: 60 - index))
    }

    let capped = try await store.searchMessageIDs(contactID: alice, query: "hit", limit: 4)

    #expect(capped == Array(ids.suffix(4)))
  }

  /// The timeline re-sorts narrow same-sender clusters by sender timestamp, so raw sort order
  /// would have next/prev step to a row that renders *above* the one it started from.
  @Test
  func `in conversation order matches the timeline's same-sender reordering`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let alice = try await store.saveContact(radioID: radioID, from: contactFrame(name: "Alice")).id

    // Relayed out of order: the row that arrived first claims the later send time, and the two
    // land inside the cluster window.
    let arrivedFirst = try await save(
      "ping one",
      to: store,
      radioID: radioID,
      contactID: alice,
      secondsAgo: 2,
      senderTimestamp: 1_700_000_000
    )
    let arrivedSecond = try await save(
      "ping two",
      to: store,
      radioID: radioID,
      contactID: alice,
      secondsAgo: 1,
      senderTimestamp: 1_699_999_990
    )

    let ordered = try await store.searchMessageIDs(contactID: alice, query: "ping")

    #expect(ordered == [arrivedSecond, arrivedFirst])
  }
}
