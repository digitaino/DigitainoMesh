import Foundation
@testable import MC1Services
import Testing

@Suite("PersistedSignalBarsNodeDirectory")
struct SignalBarsNodeDirectoryTests {
  private static let radioID = UUID()
  private static let otherRadioID = UUID()

  // MARK: - Pool composition

  @Test
  func `both contacts and discovered nodes reach the pool`() async throws {
    let store = MockPersistenceStore()
    try await store.saveContact(.testContact(
      radioID: Self.radioID,
      publicKey: SignalBarsFixtures.publicKey([0x0C, 0x13]),
      name: "Saved Repeater"
    ))
    _ = try await store.upsertDiscoveredNode(
      radioID: Self.radioID,
      from: discoveredFrame(publicKey: SignalBarsFixtures.publicKey([0xAB]), name: "Heard Repeater")
    )

    let directory = PersistedSignalBarsNodeDirectory(dataStore: store, radioID: Self.radioID)
    let nodes = await directory.resolvableNodes()

    #expect(nodes.count == 2)
    #expect(nodes.contains { $0.resolvableName == "Saved Repeater" })
    #expect(nodes.contains { $0.resolvableName == "Heard Repeater" })
  }

  @Test
  func `the pool is scoped to the connected radio`() async throws {
    let store = MockPersistenceStore()
    try await store.saveContact(.testContact(
      radioID: Self.radioID,
      publicKey: SignalBarsFixtures.publicKey([0x01]),
      name: "Mine"
    ))
    try await store.saveContact(.testContact(
      radioID: Self.otherRadioID,
      publicKey: SignalBarsFixtures.publicKey([0x02]),
      name: "Someone else's"
    ))

    let directory = PersistedSignalBarsNodeDirectory(dataStore: store, radioID: Self.radioID)
    let nodes = await directory.resolvableNodes()

    #expect(nodes.map(\.resolvableName) == ["Mine"])
  }

  @Test
  func `discovered nodes expire when stale and contacts do not`() async throws {
    let store = MockPersistenceStore()
    try await store.saveContact(.testContact(
      radioID: Self.radioID,
      publicKey: SignalBarsFixtures.publicKey([0x01]),
      name: "Contact"
    ))
    _ = try await store.upsertDiscoveredNode(
      radioID: Self.radioID,
      from: discoveredFrame(publicKey: SignalBarsFixtures.publicKey([0x02]), name: "Discovered")
    )

    let directory = PersistedSignalBarsNodeDirectory(dataStore: store, radioID: Self.radioID)
    let nodes = await directory.resolvableNodes()

    let contact = try #require(nodes.first { $0.resolvableName == "Contact" })
    let discovered = try #require(nodes.first { $0.resolvableName == "Discovered" })
    #expect(contact.expiresWhenStale == false)
    #expect(discovered.expiresWhenStale)
  }

  // MARK: - Resolution

  @Test
  func `a repeater hash resolves to the matching node`() async throws {
    let store = MockPersistenceStore()
    try await store.saveContact(.testContact(
      radioID: Self.radioID,
      publicKey: SignalBarsFixtures.publicKey([0x0C, 0x13]),
      name: "Hilltop"
    ))
    try await store.saveContact(.testContact(
      radioID: Self.radioID,
      publicKey: SignalBarsFixtures.publicKey([0x7F]),
      name: "Valley"
    ))

    let directory = PersistedSignalBarsNodeDirectory(dataStore: store, radioID: Self.radioID)
    let nodes = await directory.resolvableNodes()
    let match = NodeIdentityResolver().bestMatch(for: nodeID("0C"), among: nodes, now: Date())

    #expect(match?.resolvableName == "Hilltop")
  }

  // MARK: - Caching

  @Test
  func `a repeat lookup inside the cache window does not re-read the store`() async throws {
    let clock = TestClock()
    let store = MockPersistenceStore()
    try await store.saveContact(.testContact(
      radioID: Self.radioID,
      publicKey: SignalBarsFixtures.publicKey([0x01]),
      name: "First"
    ))

    let directory = PersistedSignalBarsNodeDirectory(
      dataStore: store,
      radioID: Self.radioID,
      cacheLifetime: 30,
      now: clock.provider
    )
    _ = await directory.resolvableNodes()

    try await store.saveContact(.testContact(
      radioID: Self.radioID,
      publicKey: SignalBarsFixtures.publicKey([0x02]),
      name: "Second"
    ))
    clock.advance(29)

    #expect(await directory.resolvableNodes().count == 1)
  }

  @Test
  func `the store is re-read once the cache window elapses`() async throws {
    let clock = TestClock()
    let store = MockPersistenceStore()
    try await store.saveContact(.testContact(
      radioID: Self.radioID,
      publicKey: SignalBarsFixtures.publicKey([0x01]),
      name: "First"
    ))

    let directory = PersistedSignalBarsNodeDirectory(
      dataStore: store,
      radioID: Self.radioID,
      cacheLifetime: 30,
      now: clock.provider
    )
    _ = await directory.resolvableNodes()

    try await store.saveContact(.testContact(
      radioID: Self.radioID,
      publicKey: SignalBarsFixtures.publicKey([0x02]),
      name: "Second"
    ))
    clock.advance(31)

    #expect(await directory.resolvableNodes().count == 2)
  }

  @Test
  func `invalidate forces the next lookup to re-read`() async throws {
    let clock = TestClock()
    let store = MockPersistenceStore()
    try await store.saveContact(.testContact(
      radioID: Self.radioID,
      publicKey: SignalBarsFixtures.publicKey([0x01]),
      name: "First"
    ))

    let directory = PersistedSignalBarsNodeDirectory(
      dataStore: store,
      radioID: Self.radioID,
      cacheLifetime: 30,
      now: clock.provider
    )
    _ = await directory.resolvableNodes()

    try await store.saveContact(.testContact(
      radioID: Self.radioID,
      publicKey: SignalBarsFixtures.publicKey([0x02]),
      name: "Second"
    ))
    await directory.invalidate()

    #expect(await directory.resolvableNodes().count == 2)
  }

  // MARK: - Helpers

  private func discoveredFrame(publicKey: Data, name: String) -> ContactFrame {
    ContactFrame(
      publicKey: publicKey,
      type: .repeater,
      flags: 0,
      outPathLength: 0xFF,
      outPath: Data(),
      name: name,
      lastAdvertTimestamp: UInt32(Date().timeIntervalSince1970),
      latitude: 0,
      longitude: 0,
      lastModified: 0
    )
  }
}

@Suite("MovementHintRelay")
struct MovementHintRelayTests {
  @Test
  func `the relay starts stationary`() async {
    let relay = MovementHintRelay()
    #expect(await relay.currentMovementHint() == .stationary)
  }

  @Test
  func `a pushed level is what the engine reads back`() async {
    let relay = MovementHintRelay()
    await relay.update(.fast)
    #expect(await relay.currentMovementHint() == .fast)
  }

  @Test
  func `only a differing level reports a change`() async {
    let relay = MovementHintRelay()
    #expect(await relay.update(.slow))
    #expect(await relay.update(.slow) == false)
    #expect(await relay.update(.fast))
  }

  @Test
  func `reset returns the relay to stationary`() async {
    let relay = MovementHintRelay()
    await relay.update(.fast)
    await relay.reset()
    #expect(await relay.currentMovementHint() == .stationary)
  }
}
