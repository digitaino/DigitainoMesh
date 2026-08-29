import Foundation
@testable import MC1Services
import MeshCore
import MeshCoreTestSupport
import SwiftData
import Testing

@Suite("SyncCoordinator Message Handler Tests")
@MainActor
struct SyncCoordinatorMessageHandlerTests {
  // MARK: - Test Helpers

  private func createTestDataStore(radioID: UUID) async throws -> PersistenceStore {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let device = DeviceDTO.testDevice(id: radioID, nodeName: "TestNode")
    try await store.saveDevice(device)
    return store
  }

  private func createTestServices() async throws -> (MeshCoreSession, ServiceContainer) {
    let transport = SimulatorMockTransport()
    let session = MeshCoreSession(transport: transport)
    let services = try await ServiceContainer.forTesting(session: session)
    return (session, services)
  }

  // MARK: - parseChannelMessage Tests

  @Test
  func `parseChannelMessage parses standard 'Name: text' format`() {
    let (sender, text) = SyncCoordinator.parseChannelMessage("NodeAlpha: Hello world")
    #expect(sender == "NodeAlpha")
    #expect(text == "Hello world")
  }

  @Test
  func `parseChannelMessage handles multiple colons`() {
    let (sender, text) = SyncCoordinator.parseChannelMessage("Node: time is 12:30:00")
    #expect(sender == "Node")
    #expect(text == "time is 12:30:00")
  }

  @Test
  func `parseChannelMessage returns nil sender for text without colon`() {
    let (sender, text) = SyncCoordinator.parseChannelMessage("just plain text")
    #expect(sender == nil)
    #expect(text == "just plain text")
  }

  @Test
  func `parseChannelMessage returns nil sender for empty string`() {
    let (sender, text) = SyncCoordinator.parseChannelMessage("")
    #expect(sender == nil)
    #expect(text == "")
  }

  @Test
  func `parseChannelMessage handles colon only — split omits empty subsequences`() {
    let (sender, text) = SyncCoordinator.parseChannelMessage(":")
    #expect(sender == nil)
    #expect(text == ":")
  }

  @Test
  func `parseChannelMessage trims whitespace from sender and text`() {
    let (sender, text) = SyncCoordinator.parseChannelMessage("  NodeName  :  hello there  ")
    #expect(sender == "NodeName")
    #expect(text == "hello there")
  }

  @Test
  func `parseChannelMessage handles colon at start — leading empty part omitted by split`() {
    let (sender, text) = SyncCoordinator.parseChannelMessage(": some text")
    #expect(sender == nil)
    #expect(text == ": some text")
  }

  @Test
  func `parseChannelMessage handles emoji in name`() {
    let (sender, text) = SyncCoordinator.parseChannelMessage("Node🔥: hello")
    #expect(sender == "Node🔥")
    #expect(text == "hello")
  }

  @Test
  func `parseChannelMessage handles unicode characters`() {
    let (sender, text) = SyncCoordinator.parseChannelMessage("Ñoño: café time")
    #expect(sender == "Ñoño")
    #expect(text == "café time")
  }

  @Test
  func `parseChannelMessage handles text with only sender and colon — trailing empty part omitted`() {
    let (sender, text) = SyncCoordinator.parseChannelMessage("NodeName:")
    #expect(sender == nil)
    #expect(text == "NodeName:")
  }

  // MARK: - Blocked Sender Cache Tests

  @Test
  func `isBlockedSender returns false for empty cache`() async {
    let coordinator = SyncCoordinator()
    let result = await coordinator.isBlockedSender("SomeNode")
    #expect(!result)
  }

  @Test
  func `refreshBlockedContactsCache loads blocked contacts by name`() async throws {
    let coordinator = SyncCoordinator()
    let radioID = UUID()
    let dataStore = try await createTestDataStore(radioID: radioID)

    let blockedContact = ContactDTO.testContact(
      radioID: radioID,
      name: "BlockedPerson",
      isBlocked: true
    )
    try await dataStore.saveContact(blockedContact)

    await coordinator.refreshBlockedContactsCache(radioID: radioID, dataStore: dataStore)

    let result = await coordinator.isBlockedSender("BlockedPerson")
    #expect(result, "Blocked contact name should be in cache")
  }

  @Test
  func `refreshBlockedContactsCache does not cache non-blocked contacts`() async throws {
    let coordinator = SyncCoordinator()
    let radioID = UUID()
    let dataStore = try await createTestDataStore(radioID: radioID)

    let normalContact = ContactDTO.testContact(
      radioID: radioID,
      name: "NormalPerson",
      isBlocked: false
    )
    try await dataStore.saveContact(normalContact)

    await coordinator.refreshBlockedContactsCache(radioID: radioID, dataStore: dataStore)

    let result = await coordinator.isBlockedSender("NormalPerson")
    #expect(!result, "Non-blocked contact name should not be in cache")
  }

  @Test
  func `refreshBlockedContactsCache replaces previous cache`() async throws {
    let coordinator = SyncCoordinator()
    let radioID = UUID()
    let dataStore = try await createTestDataStore(radioID: radioID)

    // First: add a blocked contact
    let contact = ContactDTO.testContact(
      id: UUID(),
      radioID: radioID,
      name: "WasBlocked",
      isBlocked: true
    )
    try await dataStore.saveContact(contact)
    await coordinator.refreshBlockedContactsCache(radioID: radioID, dataStore: dataStore)
    #expect(await coordinator.isBlockedSender("WasBlocked"))

    // Delete the contact and refresh — cache should be empty
    try await dataStore.deleteContact(id: contact.id)
    await coordinator.refreshBlockedContactsCache(radioID: radioID, dataStore: dataStore)
    #expect(await !coordinator.isBlockedSender("WasBlocked"))
  }

  @Test
  func `isBlockedSender returns false for nil name`() async {
    let coordinator = SyncCoordinator()
    let result = await coordinator.isBlockedSender(nil)
    #expect(!result)
  }

  @Test
  func `blockedSenderNames returns snapshot of cached names`() async throws {
    let coordinator = SyncCoordinator()
    let radioID = UUID()
    let dataStore = try await createTestDataStore(radioID: radioID)

    let blocked1 = ContactDTO.testContact(radioID: radioID, name: "Blocked1", isBlocked: true)
    let blocked2 = ContactDTO.testContact(radioID: radioID, name: "Blocked2", isBlocked: true)
    try await dataStore.saveContact(blocked1)
    try await dataStore.saveContact(blocked2)

    await coordinator.refreshBlockedContactsCache(radioID: radioID, dataStore: dataStore)

    let names = await coordinator.blockedSenderNames()
    #expect(names.contains("Blocked1"))
    #expect(names.contains("Blocked2"))
  }

  // MARK: - Handler Wiring Smoke Tests

  @Test
  func `wireMessageHandlers completes without error`() async throws {
    let coordinator = SyncCoordinator()
    let radioID = UUID()
    let (_, services) = try await createTestServices()
    try await services.dataStore.saveDevice(DeviceDTO.testDevice(id: radioID, nodeName: "TestNode"))

    await coordinator.wireMessageHandlers(dependencies: services.syncDependencies, radioID: radioID)
  }

  @Test
  func `startDiscoveryEventMonitoring completes without error`() async throws {
    let coordinator = SyncCoordinator()
    let radioID = UUID()
    let (_, services) = try await createTestServices()

    await coordinator.startDiscoveryEventMonitoring(dependencies: services.syncDependencies, radioID: radioID)
    await coordinator.cancelDiscoveryEventMonitoring()
  }

  // MARK: - Unresolved Channel Notification Guard

  @Test
  func `Channel message that resolves to no local channel must not post a notification`() {
    #expect(SyncCoordinator.shouldPostChannelNotification(forResolvedChannel: nil) == false)
  }

  @Test
  func `Channel message that resolves to a known local channel posts a notification`() {
    let channel = ChannelDTO(
      id: UUID(),
      radioID: UUID(),
      index: 3,
      name: "Test",
      secret: Data(repeating: 1, count: 16),
      isEnabled: true,
      lastMessageDate: nil,
      unreadCount: 0,
      floodScope: .inherit
    )
    #expect(SyncCoordinator.shouldPostChannelNotification(forResolvedChannel: channel) == true)
  }

  // MARK: - Receive-Time Location Stamping

  private struct FixedPhoneLocationProvider: PhoneLocationProvider {
    let fix: PhoneLocationFix?
    func currentFix() async -> PhoneLocationFix? { fix }
  }

  /// Wires the real ingest pipeline over a fresh in-memory store with the
  /// captured-handler mock, so tests can push one wire message through and
  /// inspect the saved row. `contact: nil` on invocation keeps every
  /// post-save side effect (reactions, unreads, notifications) inert.
  private func makeStampingHarness(
    provider: PhoneLocationProvider?
  ) async throws -> (
    handler: @Sendable (ContactMessage, ContactDTO?, DeliveryContext) async -> Void,
    container: ModelContainer,
    coordinator: SyncCoordinator
  ) {
    let (_, services) = try await createTestServices()
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let polling = MockMessagePollingService()
    let deps = SyncDependencies(
      dataStore: store,
      contactService: services.contactService,
      channelService: services.channelService,
      messagePollingService: polling,
      notificationService: services.notificationService,
      reactionService: services.reactionService,
      advertisementService: services.advertisementService,
      rxLogService: services.rxLogService,
      roomServerService: services.roomServerService,
      roomAdminService: services.roomAdminService,
      repeaterAdminService: services.repeaterAdminService,
      appStateProvider: nil,
      phoneLocationProvider: provider,
      startEventMonitoring: { _, _ in },
      exportPrivateKey: { Data() }
    )
    let coordinator = SyncCoordinator()
    await coordinator.wireMessageHandlers(dependencies: deps, radioID: UUID())
    let handler = try #require(await polling.capturedContactMessageHandler)
    return (handler, container, coordinator)
  }

  private func makeWireMessage(text: String = "hello", senderTimestamp: Date = Date()) -> ContactMessage {
    ContactMessage(
      senderPublicKeyPrefix: Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]),
      pathLength: 0,
      textType: TextType.plain.rawValue,
      senderTimestamp: senderTimestamp,
      signature: nil,
      text: text,
      snr: nil
    )
  }

  private func savedMessages(in container: ModelContainer) throws -> [Message] {
    try ModelContext(container).fetch(FetchDescriptor<Message>())
  }

  @Test
  func `Live delivery with a fresh fix stamps the message`() async throws {
    let fix = PhoneLocationFix(latitude: 30.2672, longitude: -97.7431, timestamp: Date())
    let harness = try await makeStampingHarness(provider: FixedPhoneLocationProvider(fix: fix))

    await harness.handler(makeWireMessage(), nil, .live)

    let saved = try savedMessages(in: harness.container)
    #expect(saved.count == 1)
    #expect(saved.first?.userLatitude == 30.2672)
    #expect(saved.first?.userLongitude == -97.7431)
  }

  @Test
  func `Backlog drain never stamps — drain-time GPS is not reception geography`() async throws {
    let fix = PhoneLocationFix(latitude: 30.2672, longitude: -97.7431, timestamp: Date())
    let harness = try await makeStampingHarness(provider: FixedPhoneLocationProvider(fix: fix))

    await harness.handler(makeWireMessage(), nil, .initialSync(anchor: Date()))

    let saved = try savedMessages(in: harness.container)
    #expect(saved.count == 1)
    #expect(saved.first?.userLatitude == nil)
    #expect(saved.first?.userLongitude == nil)
  }

  @Test
  func `An aged fix never stamps — it describes where the phone used to be`() async throws {
    let agedTimestamp = Date().addingTimeInterval(-(NodeLocationStalenessPolicy.maxFixAge + 60))
    let fix = PhoneLocationFix(latitude: 30.2672, longitude: -97.7431, timestamp: agedTimestamp)
    let harness = try await makeStampingHarness(provider: FixedPhoneLocationProvider(fix: fix))

    await harness.handler(makeWireMessage(), nil, .live)

    let saved = try savedMessages(in: harness.container)
    #expect(saved.count == 1)
    #expect(saved.first?.userLatitude == nil)
    #expect(saved.first?.userLongitude == nil)
  }

  @Test
  func `No provider leaves the message unstamped`() async throws {
    let harness = try await makeStampingHarness(provider: nil)

    await harness.handler(makeWireMessage(), nil, .live)

    let saved = try savedMessages(in: harness.container)
    #expect(saved.count == 1)
    #expect(saved.first?.userLatitude == nil)
    #expect(saved.first?.userLongitude == nil)
  }

  @Test
  func `A fresh null-island fix never stamps`() async throws {
    let fix = PhoneLocationFix(latitude: 0, longitude: 0, timestamp: Date())
    let harness = try await makeStampingHarness(provider: FixedPhoneLocationProvider(fix: fix))

    await harness.handler(makeWireMessage(), nil, .live)

    let saved = try savedMessages(in: harness.container)
    #expect(saved.count == 1)
    #expect(saved.first?.userLatitude == nil)
    #expect(saved.first?.userLongitude == nil)
  }

  @Test
  func `Unbounded sender-to-phone transit never stamps — a radio-queued message delivered live on resume is not a fresh arrival`() async throws {
    let fix = PhoneLocationFix(latitude: 30.2672, longitude: -97.7431, timestamp: Date())
    let harness = try await makeStampingHarness(provider: FixedPhoneLocationProvider(fix: fix))

    let queuedOvernight = Date().addingTimeInterval(-(SyncCoordinator.maxStampTransitInterval + 60))
    await harness.handler(makeWireMessage(senderTimestamp: queuedOvernight), nil, .live)

    let saved = try savedMessages(in: harness.container)
    #expect(saved.count == 1)
    #expect(saved.first?.userLatitude == nil)
    #expect(saved.first?.userLongitude == nil)
  }

  // MARK: - lastHeard mesh-liveness stamps

  @Test
  func `inbound DM stamps contact lastHeard`() async throws {
    let radioID = UUID()
    let dataStore = try await createTestDataStore(radioID: radioID)
    let publicKey = Data(repeating: 0xAB, count: 32)
    let contact = ContactDTO.testContact(
      radioID: radioID,
      publicKey: publicKey,
      name: "Peer",
      lastHeardTimestamp: 0
    )
    try await dataStore.saveContact(contact)

    let mockPolling = MockMessagePollingService()
    let (_, services) = try await createTestServices()
    let dependencies = services.syncDependencies
      .with(dataStore: dataStore, messagePollingService: mockPolling)

    let coordinator = SyncCoordinator()
    await coordinator.wireMessageHandlers(dependencies: dependencies, radioID: radioID)

    let message = ContactMessage(
      senderPublicKeyPrefix: Data(publicKey.prefix(6)),
      pathLength: 0,
      textType: 0,
      senderTimestamp: Date(),
      signature: nil,
      text: "hello mesh",
      snr: nil
    )
    await mockPolling.capturedContactMessageHandler?(message, contact, .live)

    let updated = try #require(
      await dataStore.fetchContact(radioID: radioID, publicKey: publicKey)
    )
    #expect((updated.lastHeardTimestamp ?? 0) > 0)
  }

  @Test
  func `inbound channel message does not stamp lastHeard on a contact`() async throws {
    let radioID = UUID()
    let dataStore = try await createTestDataStore(radioID: radioID)
    let publicKey = Data(repeating: 0xCD, count: 32)
    let contact = ContactDTO.testContact(
      radioID: radioID,
      publicKey: publicKey,
      name: "ChannelPeer",
      lastHeardTimestamp: 0
    )
    try await dataStore.saveContact(contact)

    let mockPolling = MockMessagePollingService()
    let (_, services) = try await createTestServices()
    let dependencies = services.syncDependencies
      .with(dataStore: dataStore, messagePollingService: mockPolling)

    let coordinator = SyncCoordinator()
    await coordinator.wireMessageHandlers(dependencies: dependencies, radioID: radioID)

    let channelMessage = ChannelMessage(
      channelIndex: 0,
      pathLength: 0,
      textType: 0,
      senderTimestamp: Date(),
      text: "ChannelPeer: hello channel",
      snr: nil
    )
    await mockPolling.capturedChannelMessageHandler?(channelMessage, nil, .live)

    let updated = try #require(
      await dataStore.fetchContact(radioID: radioID, publicKey: publicKey)
    )
    #expect((updated.lastHeardTimestamp ?? 0) == 0)
  }

  // MARK: - Live receive region propagation

  @Test
  func `live channel receive copies regionScope and regionScopeMatches from RxLog onto Message`() async throws {
    let radioID = UUID()
    let dataStore = try await createTestDataStore(radioID: radioID)
    let channelIndex: UInt8 = 0
    // Fixed integer epoch so ChannelMessage.senderTimestamp and RxLogEntry
    // correlate without fractional-second truncation.
    let senderTimestamp: UInt32 = 1_704_000_500
    let expectedScope: String? = "Germany"
    let expectedMatches = ["Germany"]

    let parsed = ParsedRxLogData(
      snr: 5,
      rssi: -80,
      rawPayload: Data([0x10, 0x20, 0x30]),
      routeType: .flood,
      payloadType: .groupText,
      payloadVersion: 0,
      payloadTypeBits: 5,
      transportCode: nil,
      pathLength: 0,
      pathNodes: [],
      packetPayload: Data([0xAA, 0xBB, 0xCC])
    )
    let rxEntry = RxLogEntryDTO(
      radioID: radioID,
      from: parsed,
      channelIndex: channelIndex,
      channelName: "Public",
      decryptStatus: .success,
      senderTimestamp: senderTimestamp,
      regionScope: expectedScope,
      regionScopeMatches: expectedMatches
    )
    try await dataStore.saveRxLogEntry(rxEntry)

    let mockPolling = MockMessagePollingService()
    let (_, services) = try await createTestServices()
    let dependencies = services.syncDependencies
      .with(dataStore: dataStore, messagePollingService: mockPolling)

    let coordinator = SyncCoordinator()
    await coordinator.wireMessageHandlers(dependencies: dependencies, radioID: radioID)

    let channelMessage = ChannelMessage(
      channelIndex: channelIndex,
      pathLength: 0,
      textType: 0,
      senderTimestamp: Date(timeIntervalSince1970: TimeInterval(senderTimestamp)),
      text: "NodeAlpha: region scope test",
      snr: nil
    )
    await mockPolling.capturedChannelMessageHandler?(channelMessage, nil, .live)

    let saved = try await dataStore.fetchMessages(radioID: radioID, channelIndex: channelIndex)
    let message = try #require(saved.first)
    #expect(message.regionScope == expectedScope)
    #expect(Set(message.regionScopeMatches) == Set(expectedMatches))
  }
}

// MARK: - SyncDependencies test helpers

extension SyncDependencies {
  /// Copy with a different data store and message polling service for tests.
  func with(
    dataStore: any PersistenceStoreProtocol,
    messagePollingService: any MessagePollingServiceProtocol
  ) -> SyncDependencies {
    SyncDependencies(
      dataStore: dataStore,
      contactService: contactService,
      channelService: channelService,
      messagePollingService: messagePollingService,
      notificationService: notificationService,
      reactionService: reactionService,
      advertisementService: advertisementService,
      rxLogService: rxLogService,
      roomServerService: roomServerService,
      roomAdminService: roomAdminService,
      repeaterAdminService: repeaterAdminService,
      appStateProvider: appStateProvider,
      startEventMonitoring: startEventMonitoring,
      exportPrivateKey: exportPrivateKey
    )
  }
}
