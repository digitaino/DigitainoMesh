import Foundation
@testable import MC1Services
@testable import MeshCore
import Testing

@Suite("NotifSyncService")
@MainActor
struct NotifSyncServiceTests {
  private static let radioID = UUID()

  // MARK: - Blob Construction

  @Test
  func `only overrides are emitted`() async throws {
    let store = try await makeStore(
      channels: [
        .testChannel(radioID: Self.radioID, index: 0, name: "General", notificationLevel: .all),
        .testChannel(radioID: Self.radioID, index: 1, name: "Muted", notificationLevel: .muted),
        .testChannel(radioID: Self.radioID, index: 2, name: "Mentions", notificationLevel: .mentionsOnly)
      ],
      contacts: [
        .testContact(radioID: Self.radioID, publicKey: Data(repeating: 0xAA, count: 32), name: "Loud", isMuted: false),
        .testContact(radioID: Self.radioID, publicKey: Data(repeating: 0xBB, count: 32), name: "Quiet", isMuted: true)
      ]
    )
    let (service, session, _) = try await makeService(store: store)
    defer { Task { await session.stop() } }

    let blob = try await service.buildBlob(radioID: Self.radioID)

    #expect(blob.globalMode == .all)
    #expect(blob.channelRules.count == 2)
    #expect(blob.channelRules.contains(.init(channelIdx: 1, mode: .silent)))
    #expect(blob.channelRules.contains(.init(channelIdx: 2, mode: .mentions)))
    #expect(blob.contactRules == [.init(pubKeyPrefix: Data(repeating: 0xBB, count: 6), mode: .silent)])
  }

  @Test
  func `blob is scoped to the connected radio`() async throws {
    let otherRadioID = UUID()
    let store = try await makeStore(
      channels: [
        .testChannel(radioID: Self.radioID, index: 1, notificationLevel: .muted),
        .testChannel(radioID: otherRadioID, index: 2, notificationLevel: .muted)
      ],
      contacts: []
    )
    let (service, session, _) = try await makeService(store: store)
    defer { Task { await session.stop() } }

    let blob = try await service.buildBlob(radioID: Self.radioID)
    #expect(blob.channelRules == [.init(channelIdx: 1, mode: .silent)])
  }

  // MARK: - Push

  @Test
  func `syncNow writes the encoded blob to the sync slot`() async throws {
    let store = try await makeStore(
      channels: [.testChannel(radioID: Self.radioID, index: 3, notificationLevel: .muted)],
      contacts: []
    )
    let (service, session, transport) = try await makeService(store: store)
    defer { Task { await session.stop() } }

    let task = Task { try await service.syncNow(radioID: Self.radioID) }
    try await waitUntil("setSync should be sent") { await transport.sentData.count == 2 }

    let expected = NotifPrefsBlob(globalMode: .all, channelRules: [.init(channelIdx: 3, mode: .silent)])
    let sent = await transport.sentData[1]
    #expect(sent == PacketBuilder.setSync(id: .notifPrefs, payload: expected.encode()))

    await transport.simulateOK()
    try await task.value
    #expect(await service.support == .supported)
  }

  @Test
  func `an unchanged rule set does not cost a second write`() async throws {
    let store = try await makeStore(channels: [], contacts: [])
    let (service, session, transport) = try await makeService(store: store)
    defer { Task { await session.stop() } }

    let first = Task { try await service.syncNow(radioID: Self.radioID) }
    try await waitUntil("first setSync should be sent") { await transport.sentData.count == 2 }
    await transport.simulateOK()
    try await first.value

    try await service.syncNow(radioID: Self.radioID)
    #expect(await transport.sentData.count == 2)
  }

  @Test
  func `a forced sync writes even when nothing changed`() async throws {
    let store = try await makeStore(channels: [], contacts: [])
    let (service, session, transport) = try await makeService(store: store)
    defer { Task { await session.stop() } }

    let first = Task { try await service.syncNow(radioID: Self.radioID) }
    try await waitUntil("first setSync should be sent") { await transport.sentData.count == 2 }
    await transport.simulateOK()
    try await first.value

    let forced = Task { try await service.syncNow(radioID: Self.radioID, force: true) }
    try await waitUntil("forced setSync should be sent") { await transport.sentData.count == 3 }
    await transport.simulateOK()
    try await forced.value
  }

  @Test
  func `a changed rule set is written again`() async throws {
    let store = try await makeStore(channels: [], contacts: [])
    let (service, session, transport) = try await makeService(store: store)
    defer { Task { await session.stop() } }

    let first = Task { try await service.syncNow(radioID: Self.radioID) }
    try await waitUntil("first setSync should be sent") { await transport.sentData.count == 2 }
    await transport.simulateOK()
    try await first.value

    try await store.saveChannel(.testChannel(radioID: Self.radioID, index: 1, notificationLevel: .muted))

    let second = Task { try await service.syncNow(radioID: Self.radioID) }
    try await waitUntil("second setSync should be sent") { await transport.sentData.count == 3 }
    await transport.simulateOK()
    try await second.value
  }

  // MARK: - Firmware Gating

  @Test
  func `a rejected write latches unsupported and goes inert`() async throws {
    let store = try await makeStore(channels: [], contacts: [])
    let (service, session, transport) = try await makeService(store: store)
    defer { Task { await session.stop() } }

    let task = Task { try await service.syncNow(radioID: Self.radioID) }
    try await waitUntil("setSync should be sent") { await transport.sentData.count == 2 }
    await transport.simulateError(code: 1)
    try await task.value // swallowed, not thrown

    #expect(await service.support == .unsupported)

    // Every later entry point is a no-op: no further packets leave the app.
    try await store.saveChannel(.testChannel(radioID: Self.radioID, index: 1, notificationLevel: .muted))
    try await service.syncNow(radioID: Self.radioID)
    #expect(try await service.deviceBlob() == nil)
    await service.reconcileOnConnect(radioID: Self.radioID)
    #expect(await transport.sentData.count == 2)
  }

  @Test
  func `a rejected read latches unsupported`() async throws {
    let store = try await makeStore(channels: [], contacts: [])
    let (service, session, transport) = try await makeService(store: store)
    defer { Task { await session.stop() } }

    let task = Task { try await service.deviceBlob() }
    try await waitUntil("getSync should be sent") { await transport.sentData.count == 2 }
    await transport.simulateError(code: 1)

    #expect(try await task.value == nil)
    #expect(await service.support == .unsupported)
  }

  @Test
  func `a timeout does not disable the feature`() async throws {
    let store = try await makeStore(channels: [], contacts: [])
    let (service, session, _) = try await makeService(store: store, timeout: 0.2)
    defer { Task { await session.stop() } }

    await #expect(throws: MeshCoreError.self) {
      _ = try await service.deviceBlob()
    }
    #expect(await service.support == .unknown)
  }

  // MARK: - Reconcile

  @Test
  func `reconcile skips the push when the device already matches`() async throws {
    let store = try await makeStore(
      channels: [.testChannel(radioID: Self.radioID, index: 1, notificationLevel: .muted)],
      contacts: []
    )
    let (service, session, transport) = try await makeService(store: store)
    defer { Task { await session.stop() } }

    let stored = NotifPrefsBlob(globalMode: .all, channelRules: [.init(channelIdx: 1, mode: .silent)])
    let task = Task { await service.reconcileOnConnect(radioID: Self.radioID) }
    try await waitUntil("getSync should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(makeSyncValuePacket(id: .notifPrefs, blob: stored.encode()))
    await task.value

    #expect(await transport.sentData.count == 2, "A matching device needs no write")
    #expect(await service.support == .supported)
  }

  @Test
  func `reconcile pushes when the device is out of date`() async throws {
    let store = try await makeStore(
      channels: [.testChannel(radioID: Self.radioID, index: 1, notificationLevel: .muted)],
      contacts: []
    )
    let (service, session, transport) = try await makeService(store: store)
    defer { Task { await session.stop() } }

    let task = Task { await service.reconcileOnConnect(radioID: Self.radioID) }
    try await waitUntil("getSync should be sent") { await transport.sentData.count == 2 }
    // Device has nothing stored yet.
    await transport.simulateReceive(makeSyncValuePacket(id: .notifPrefs, blob: Data()))

    try await waitUntil("setSync should follow") { await transport.sentData.count == 3 }
    let expected = NotifPrefsBlob(globalMode: .all, channelRules: [.init(channelIdx: 1, mode: .silent)])
    let sent = await transport.sentData[2]
    #expect(sent == PacketBuilder.setSync(id: .notifPrefs, payload: expected.encode()))
    await transport.simulateOK()
    await task.value
  }

  @Test
  func `deviceBlob decodes what the device reports`() async throws {
    let store = try await makeStore(channels: [], contacts: [])
    let (service, session, transport) = try await makeService(store: store)
    defer { Task { await session.stop() } }

    let stored = NotifPrefsBlob(
      globalMode: .mentions,
      channelRules: [.init(channelIdx: 4, mode: .silent)],
      contactRules: [.init(pubKeyPrefix: Data(repeating: 0xCD, count: 6), mode: .silent)]
    )
    let task = Task { try await service.deviceBlob() }
    try await waitUntil("getSync should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(makeSyncValuePacket(id: .notifPrefs, blob: stored.encode()))

    #expect(try await task.value == stored)
  }

  // MARK: - Helpers

  private func makeStore(
    channels: [ChannelDTO],
    contacts: [ContactDTO]
  ) async throws -> MockPersistenceStore {
    let store = MockPersistenceStore()
    for channel in channels {
      try await store.saveChannel(channel)
    }
    for contact in contacts {
      try await store.saveContact(contact)
    }
    return store
  }

  private func makeService(
    store: MockPersistenceStore,
    timeout: TimeInterval = 10
  ) async throws -> (NotifSyncService, MeshCoreSession, MockTransport) {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: timeout, clientIdentifier: "MCTst")
    )

    let startTask = Task { try await session.start() }
    try await waitUntil("session should send app start") { await transport.sentData.count == 1 }
    await transport.simulateReceive(makeSelfInfoPacket())
    try await startTask.value

    return (NotifSyncService(session: session, dataStore: store), session, transport)
  }

  private func makeSyncValuePacket(id: SyncID, blob: Data) -> Data {
    var packet = Data([ResponseCode.syncValue.rawValue, id.rawValue])
    packet.append(contentsOf: withUnsafeBytes(of: UInt16(blob.count).littleEndian) { Array($0) })
    packet.append(blob)
    return packet
  }

  private func makeSelfInfoPacket() -> Data {
    var payload = Data()
    payload.append(1)
    payload.append(22)
    payload.append(22)
    payload.append(Data(repeating: 0x01, count: 32))
    payload.append(int32Bytes(0))
    payload.append(int32Bytes(0))
    payload.append(0)
    payload.append(0)
    payload.append(0)
    payload.append(uint32Bytes(915_000))
    payload.append(uint32Bytes(125_000))
    payload.append(7)
    payload.append(5)
    payload.append(contentsOf: "Test".utf8)

    var packet = Data([ResponseCode.selfInfo.rawValue])
    packet.append(payload)
    return packet
  }

  private func int32Bytes(_ value: Double) -> Data {
    withUnsafeBytes(of: Int32(value.rounded()).littleEndian) { Data($0) }
  }

  private func uint32Bytes(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }
}
