import Foundation
@testable import MC1Services
@testable import MeshCore
import Testing

/// Upstream wipes a slot's messages when a different secret lands at it (70b4bcfd). Channel
/// history is keyed by slot, and a radio that has just taken on this identity reports its own
/// slots, so on a radio switch that rule would delete the identity's history before the copy is
/// offered. While the channel swap guard is armed a slot change keeps its messages
/// (docs/UPSTREAM_SYNC.md §3 A, docs/RADIO_SWAP.md).
@Suite("Channel history across a radio swap")
struct ChannelHistorySwapTests {
  private static func info(_ index: UInt8, _ name: String, secret byte: UInt8) -> ChannelInfo {
    ChannelInfo(index: index, name: name, secret: Data(repeating: byte, count: ProtocolLimits.channelSecretSize))
  }

  private static func seed(
    _ store: PersistenceStore, radioID: UUID, index: UInt8, name: String, secret: UInt8, count: Int
  ) async throws {
    let channelID = try await store.saveChannel(radioID: radioID, from: info(index, name, secret: secret))
    for i in 0..<count {
      try await store.saveMessage(.testChannelMessage(
        radioID: radioID, channelIndex: index, text: "\(name) \(i)", direction: .incoming
      ))
      try await store.incrementChannelUnreadCount(channelID: channelID)
    }
  }

  private static func messageCount(_ store: PersistenceStore, radioID: UUID, index: UInt8) async throws -> Int {
    try await store.fetchMessages(radioID: radioID, channelIndex: index, limit: 100).count
  }

  @Test
  func `A guarded sync relabels a slot without deleting its messages, and the copy back finds them`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    try await Self.seed(store, radioID: radioID, index: 3, name: "Survey", secret: 0x33, count: 4)
    try await store.armSwapGuard(id: radioID)

    // The new radio holds its own channel in slot 3.
    _ = try await store.batchSaveChannels(
      radioID: radioID,
      configured: [Self.info(3, "Theirs", secret: 0x99)],
      unconfiguredIndices: [],
      pruneBeyond: nil
    )
    #expect(try await Self.messageCount(store, radioID: radioID, index: 3) == 4)
    #expect(try await store.fetchChannel(radioID: radioID, index: 3)?.unreadCount == 4)

    // "Copy to This Radio" writes the identity's channel back.
    _ = try await store.saveChannel(radioID: radioID, from: Self.info(3, "Survey", secret: 0x33))
    #expect(try await store.fetchChannel(radioID: radioID, index: 3)?.name == "Survey")
    #expect(try await Self.messageCount(store, radioID: radioID, index: 3) == 4)
  }

  @Test
  func `Once the channel guard is released a new secret at a slot wipes it again`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    try await Self.seed(store, radioID: radioID, index: 3, name: "Survey", secret: 0x33, count: 4)
    try await store.armSwapGuard(id: radioID)
    try await store.releaseSwapGuard(radioID: radioID, .channels)

    _ = try await store.saveChannel(radioID: radioID, from: Self.info(3, "Replacement", secret: 0x99))

    #expect(try await Self.messageCount(store, radioID: radioID, index: 3) == 0)
  }

  @Test
  func `Clearing a duplicate slot moves its messages to the channel's own slot`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    // The copy wrote #wx into slot 1; the radio also had it in slot 5, where it collected messages.
    try await Self.seed(store, radioID: radioID, index: 1, name: "#wx", secret: 0x77, count: 2)
    try await Self.seed(store, radioID: radioID, index: 5, name: "#wx", secret: 0x77, count: 3)

    try await store.vacateChannelSlot(radioID: radioID, index: 5)

    #expect(try await store.fetchChannel(radioID: radioID, index: 5) == nil)
    #expect(try await Self.messageCount(store, radioID: radioID, index: 5) == 0)
    #expect(try await Self.messageCount(store, radioID: radioID, index: 1) == 5)
    #expect(try await store.fetchChannel(radioID: radioID, index: 1)?.unreadCount == 5)
  }

  @Test
  func `Clearing a slot with no other copy of its channel keeps the messages where they are`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    try await Self.seed(store, radioID: radioID, index: 5, name: "Lone", secret: 0x55, count: 2)

    try await store.vacateChannelSlot(radioID: radioID, index: 5)

    #expect(try await store.fetchChannel(radioID: radioID, index: 5) == nil)
    #expect(try await Self.messageCount(store, radioID: radioID, index: 5) == 2)
  }

  @Test
  func `A moved channel message keeps deduplicating at its new slot`() {
    let key = DeduplicationKey.contentBased(
      contactID: nil, channelIndex: 5, senderNodeName: "Ana", timestamp: 1_700_000_000, content: "hi"
    )
    let moved = DeduplicationKey.movingChannel(key, from: 5, to: 1)

    #expect(moved == DeduplicationKey.contentBased(
      contactID: nil, channelIndex: 1, senderNodeName: "Ana", timestamp: 1_700_000_000, content: "hi"
    ))
    #expect(DeduplicationKey.movingChannel(key, from: 4, to: 1) == key)
  }
}
