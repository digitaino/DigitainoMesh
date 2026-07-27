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
  @discardableResult
  private func save(
    _ text: String,
    to store: PersistenceStore,
    radioID: UUID,
    contactID: UUID? = nil,
    channelIndex: UInt8? = nil,
    minutesAgo: Int = 0,
    outgoing: Bool = false,
    senderNodeName: String? = nil
  ) async throws -> UUID {
    let date = Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60)
    let message = MessageDTO(from: Message(
      radioID: radioID,
      contactID: contactID,
      channelIndex: channelIndex,
      text: text,
      timestamp: UInt32(date.timeIntervalSince1970),
      createdAt: date,
      sortDate: date,
      directionRawValue: outgoing ? MessageDirection.outgoing.rawValue : MessageDirection.incoming.rawValue,
      senderNodeName: senderNodeName
    ))
    try await store.saveMessage(message)
    return message.id
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

  @Test
  func `the in conversation match cap is honoured`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let alice = try await store.saveContact(radioID: radioID, from: contactFrame(name: "Alice")).id
    for index in 0..<6 {
      try await save("hit \(index)", to: store, radioID: radioID, contactID: alice, minutesAgo: 60 - index)
    }

    #expect(try await store.searchMessageIDs(contactID: alice, query: "hit", limit: 4).count == 4)
  }
}
