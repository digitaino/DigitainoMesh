import Foundation
@testable import MC1Services
@testable import MeshCore
import Testing

/// Since pins split from radio favourites, the pin is how a user keeps a chat: every rule that
/// spares favourites spares pinned contacts too (docs/UPSTREAM_SYNC_1.6.md §3 F).
@Suite("Pinned contacts are kept")
struct PinnedContactKeepTests {
  private func publicKey(_ byte: UInt8) -> Data {
    Data(repeating: byte, count: ProtocolLimits.publicKeySize)
  }

  private func contactFrame(_ keyByte: UInt8, name: String) -> ContactFrame {
    ContactFrame(
      publicKey: publicKey(keyByte),
      type: .chat,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      name: name,
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0
    )
  }

  @Test
  func `A full sync prune keeps a pinned contact the radio no longer lists`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let saved = try await store.saveContact(radioID: radioID, from: contactFrame(0xEE, name: "Pinned"))
    try await store.setContactPinned(saved.id, isPinned: true)

    let session = MockMeshCoreSession()
    await session.setStubbedContacts([])
    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)
    _ = try await service.syncContacts(radioID: radioID, since: nil)

    #expect(try await store.fetchContact(radioID: radioID, publicKey: publicKey(0xEE)) != nil)
  }

  @Test
  func `Stale-node cleanup never matches a pinned contact`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let saved = try await store.saveContact(radioID: radioID, from: contactFrame(0xEE, name: "Quiet"))
    let unpinned = try #require(try await store.fetchContact(id: saved.id))
    #expect(unpinned.matchesStaleNodePrune(cutoff: .max))

    try await store.setContactPinned(saved.id, isPinned: true)
    let pinned = try #require(try await store.fetchContact(id: saved.id))
    #expect(!pinned.matchesStaleNodePrune(cutoff: .max))
  }
}

/// Owner decision 4: a contact's remote-CLI grant lets it administer the node that granted it,
/// so a copy or import carries it only to a radio that is that node.
@Suite("Remote CLI grants in copies and imports")
struct RemoteCLIGrantTravelTests {
  private let nodeKey = Data(repeating: 0x5A, count: ProtocolLimits.publicKeySize)
  private let otherKey = Data(repeating: 0x7B, count: ProtocolLimits.publicKeySize)

  @Test
  func `Records copied to a radio with the same key keep the grant`() {
    var config = MeshCoreNodeConfig()
    config.recordsPublicKey = nodeKey
    let sections = ConfigSections(contacts: true)
    #expect(NodeConfigService.remoteCLIGrantsTravel(config: config, sections: sections, targetPublicKey: nodeKey))
  }

  @Test
  func `Records copied to a radio with another key lose the grant`() {
    var config = MeshCoreNodeConfig()
    config.recordsPublicKey = nodeKey
    let sections = ConfigSections(contacts: true)
    #expect(!NodeConfigService.remoteCLIGrantsTravel(config: config, sections: sections, targetPublicKey: otherKey))
  }

  @Test
  func `A file that gives the radio its node's key keeps the grant`() {
    let config = MeshCoreNodeConfig(
      publicKey: nodeKey.hexString,
      privateKey: String(repeating: "ab", count: ProtocolLimits.privateKeySize)
    )
    let sections = ConfigSections(nodeIdentity: true, contacts: true)
    #expect(NodeConfigService.remoteCLIGrantsTravel(config: config, sections: sections, targetPublicKey: otherKey))
  }

  @Test
  func `A file that does not say which node it came from loses the grant`() {
    let config = MeshCoreNodeConfig()
    let sections = ConfigSections(contacts: true)
    #expect(!NodeConfigService.remoteCLIGrantsTravel(config: config, sections: sections, targetPublicKey: nodeKey))
  }
}
