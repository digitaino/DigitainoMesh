import Foundation
@testable import MC1Services
@testable import MeshCore
import Testing

/// docs/RADIO_SWAP.md 4.4: a deletion made while one radio is connected reaches the
/// identity's other radios when they next sync, and storing the item again undoes it.
@Suite("Deletions across radios")
struct IdentityDeletionTests {
  private static func key(_ byte: UInt8) -> Data {
    Data(repeating: byte, count: ProtocolLimits.publicKeySize)
  }

  private static func meshContact(_ byte: UInt8, name: String, lastModified: Date) -> MeshContact {
    MeshContact(
      id: key(byte).hexString,
      publicKey: key(byte),
      type: .chat,
      flags: ContactFlags(rawValue: 0),
      outPathLength: 0,
      outPath: Data(),
      advertisedName: name,
      lastAdvertisement: lastModified,
      latitude: 0,
      longitude: 0,
      lastModified: lastModified
    )
  }

  private static func frame(_ byte: UInt8, name: String) -> ContactFrame {
    ContactFrame(
      publicKey: key(byte), type: .chat, flags: 0, outPathLength: 0, outPath: Data(),
      name: name, lastAdvertTimestamp: 0, latitude: 0, longitude: 0, lastModified: 0
    )
  }

  // MARK: - Store

  @Test
  func `Storing a contact or channel again clears its deletion`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    try await store.recordIdentityDeletion(radioID: radioID, kind: .contact, key: Self.key(0xAA))
    try await store.recordIdentityDeletion(radioID: radioID, kind: .channel, key: Data(repeating: 0x02, count: 16))
    #expect(try await store.fetchIdentityDeletions(radioID: radioID, kind: .contact).keys.contains(Self.key(0xAA)))

    _ = try await store.saveContact(radioID: radioID, from: Self.frame(0xAA, name: "Back"))
    _ = try await store.saveChannel(radioID: radioID, from: ChannelInfo(index: 1, name: "Club", secret: Data(repeating: 0x02, count: 16)))

    #expect(try await store.fetchIdentityDeletions(radioID: radioID, kind: .contact).isEmpty)
    #expect(try await store.fetchIdentityDeletions(radioID: radioID, kind: .channel).isEmpty)
  }

  @Test
  func `A deleted channel drops out of the stored swap profile`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    _ = try await store.saveChannel(radioID: radioID, from: ChannelInfo(index: 1, name: "Club", secret: Data(repeating: 0x02, count: 16)))
    _ = try await store.saveChannel(radioID: radioID, from: ChannelInfo(index: 2, name: "Ops", secret: Data(repeating: 0x03, count: 16)))
    try await store.armSwapGuard(id: radioID)

    try await store.recordIdentityDeletion(radioID: radioID, kind: .channel, key: Data(repeating: 0x02, count: 16))

    #expect(try await store.fetchSwapProfile(radioID: radioID)?.channels.map(\.name) == ["Ops"])
  }

  // MARK: - Contacts

  @Test
  func `Deleting a contact records the deletion`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    _ = try await store.saveContact(radioID: radioID, from: Self.frame(0xAA, name: "Gone"))
    let service = ContactService(session: MockMeshCoreSession(), dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)

    try await service.removeContact(radioID: radioID, publicKey: Self.key(0xAA))

    #expect(try await store.fetchContact(radioID: radioID, publicKey: Self.key(0xAA)) == nil)
    #expect(try await store.fetchIdentityDeletions(radioID: radioID, kind: .contact).keys.contains(Self.key(0xAA)))
  }

  @Test
  func `Another radio's older copy of a deleted contact is removed from it and not brought back`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    try await store.recordIdentityDeletion(radioID: radioID, kind: .contact, key: Self.key(0xAA))

    let session = MockMeshCoreSession()
    await session.setStubbedContacts([
      Self.meshContact(0xAA, name: "Gone", lastModified: Date(timeIntervalSince1970: 1_700_000_000)),
      Self.meshContact(0xBB, name: "Kept", lastModified: Date(timeIntervalSince1970: 1_700_000_000)),
    ])
    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)

    _ = try await service.syncContacts(radioID: radioID, since: nil)

    #expect(try await store.fetchContact(radioID: radioID, publicKey: Self.key(0xAA)) == nil)
    #expect(try await store.fetchContact(radioID: radioID, publicKey: Self.key(0xBB)) != nil)
    #expect(await session.removeContactPublicKeys == [Self.key(0xAA)])
    // Still deleted: the next radio that holds a copy loses it too.
    #expect(try await store.fetchIdentityDeletions(radioID: radioID, kind: .contact).keys.contains(Self.key(0xAA)))
  }

  @Test
  func `A copy the radio wrote after the deletion is a re-add and comes back`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    try await store.recordIdentityDeletion(radioID: radioID, kind: .contact, key: Self.key(0xAA))

    let session = MockMeshCoreSession()
    await session.setStubbedContacts([
      Self.meshContact(0xAA, name: "Heard again", lastModified: Date().addingTimeInterval(120)),
    ])
    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)

    _ = try await service.syncContacts(radioID: radioID, since: nil)

    #expect(try await store.fetchContact(radioID: radioID, publicKey: Self.key(0xAA)) != nil)
    #expect(await session.removeContactPublicKeys.isEmpty)
    #expect(try await store.fetchIdentityDeletions(radioID: radioID, kind: .contact).isEmpty)
  }
}
