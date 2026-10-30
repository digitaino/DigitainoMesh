import Foundation
@testable import MC1Services
@testable import MeshCore
import Testing

/// A node carried by several radios: the phone owns its contact favourites and writes them to
/// whichever radio connects, so the radios never erase each other's (docs/UPSTREAM_SYNC_1.6.md §3 A).
@Suite("Shared identity favourites")
struct SharedIdentityFavoriteTests {
  private func publicKey(_ byte: UInt8) -> Data {
    Data(repeating: byte, count: ProtocolLimits.publicKeySize)
  }

  private func meshContact(_ keyByte: UInt8, name: String, flags: ContactFlags = []) -> MeshContact {
    let key = publicKey(keyByte)
    return MeshContact(
      id: key.uppercaseHexString(),
      publicKey: key,
      type: .chat,
      flags: flags,
      outPathLength: 0,
      outPath: Data(),
      advertisedName: name,
      lastAdvertisement: Date(timeIntervalSince1970: 0),
      latitude: 0,
      longitude: 0,
      lastModified: Date(timeIntervalSince1970: 0)
    )
  }

  private func contactFrame(_ keyByte: UInt8, name: String, flags: UInt8) -> ContactFrame {
    ContactFrame(
      publicKey: publicKey(keyByte),
      type: .chat,
      flags: flags,
      outPathLength: 0,
      outPath: Data(),
      name: name,
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0
    )
  }

  /// A store whose node has a second radio, the way a swap leaves it.
  private func sharedStore(radioID: UUID) async throws -> PersistenceStore {
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    try await store.saveDevice(DeviceDTO.testDevice(
      radioID: radioID,
      lastConnected: Date(timeIntervalSince1970: 1_000)
    ))
    return store
  }

  @Test
  func `A sync on a second radio keeps the phone's favourite and writes it to that radio`() async throws {
    let radioID = UUID()
    let store = try await sharedStore(radioID: radioID)
    _ = try await store.saveContact(radioID: radioID, from: contactFrame(0xAA, name: "Bob", flags: 0x01))

    // The other radio has Bob, but never had the star.
    let session = MockMeshCoreSession()
    await session.setStubbedContacts([meshContact(0xAA, name: "Bob")])
    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)
    _ = try await service.syncContacts(radioID: radioID, since: nil)

    let bob = try #require(try await store.fetchContact(radioID: radioID, publicKey: publicKey(0xAA)))
    #expect(bob.isFavorite)
    let writes = await session.changeContactFlagsCalls
    #expect(writes.count == 1)
    #expect(writes.first?.contact.publicKey == publicKey(0xAA))
    #expect(writes.first?.flags.contains(.favorite) == true)
  }

  @Test
  func `An unstarred contact is not starred again by another radio's flag`() async throws {
    let radioID = UUID()
    let store = try await sharedStore(radioID: radioID)
    _ = try await store.saveContact(radioID: radioID, from: contactFrame(0xAA, name: "Bob", flags: 0))

    // Unstarred in the app while the first radio was connected; the second still has the star.
    let session = MockMeshCoreSession()
    await session.setStubbedContacts([meshContact(0xAA, name: "Bob", flags: [.favorite])])
    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)
    _ = try await service.syncContacts(radioID: radioID, since: nil)

    let bob = try #require(try await store.fetchContact(radioID: radioID, publicKey: publicKey(0xAA)))
    #expect(!bob.isFavorite)
    let writes = await session.changeContactFlagsCalls
    #expect(writes.count == 1)
    #expect(writes.first?.flags.contains(.favorite) == false)
  }

  @Test
  func `A contact new to the phone takes the radio's flag and nothing is written`() async throws {
    let radioID = UUID()
    let store = try await sharedStore(radioID: radioID)

    let session = MockMeshCoreSession()
    await session.setStubbedContacts([meshContact(0xBB, name: "Cleo", flags: [.favorite])])
    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)
    _ = try await service.syncContacts(radioID: radioID, since: nil)

    let cleo = try #require(try await store.fetchContact(radioID: radioID, publicKey: publicKey(0xBB)))
    #expect(cleo.isFavorite)
    #expect(await session.changeContactFlagsCalls.isEmpty)
  }

  @Test
  func `A node on one radio still follows that radio's flag and writes nothing`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    _ = try await store.saveContact(radioID: radioID, from: contactFrame(0xAA, name: "Bob", flags: 0x01))

    let session = MockMeshCoreSession()
    await session.setStubbedContacts([meshContact(0xAA, name: "Bob")])
    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)
    _ = try await service.syncContacts(radioID: radioID, since: nil)

    let bob = try #require(try await store.fetchContact(radioID: radioID, publicKey: publicKey(0xAA)))
    #expect(!bob.isFavorite)
    #expect(await session.changeContactFlagsCalls.isEmpty)
  }

  @Test
  func `A settings write lands on the connected radio's row, not its sibling's`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    // The sibling was connected long ago; the test store's own row is the connected one.
    let siblingID = UUID()
    try await store.saveDevice(DeviceDTO.testDevice(
      id: siblingID,
      radioID: radioID,
      nodeName: "Old name",
      lastConnected: Date(timeIntervalSince1970: 1_000)
    ))

    try await store.updateDeviceNodeName(radioID: radioID, name: "New name")
    try await store.updateDeviceTxPower(radioID: radioID, txPower: 7)

    let rows = try await store.fetchDevices(radioID: radioID)
    let connected = try #require(rows.first { $0.id == radioID })
    let sibling = try #require(rows.first { $0.id == siblingID })
    #expect(connected.nodeName == "New name")
    #expect(connected.txPower == 7)
    #expect(sibling.nodeName == "Old name")
  }
}
