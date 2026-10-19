import Foundation
@testable import MC1Services
@testable import MeshCore
import OSLog
import Testing

// MARK: - Slot alignment

/// docs/RADIO_SWAP.md, rule R4: a config built from this phone's records puts every channel
/// back in the slot its history is filed under, and never replaces one of the radio's own
/// channels without leave.
@Suite("Channel slot alignment")
struct ChannelSlotAlignmentTests {
  private static func secret(_ byte: UInt8) -> Data {
    Data(repeating: byte, count: ProtocolLimits.channelSecretSize)
  }

  private static func channel(_ name: String, _ byte: UInt8, slot: UInt8) -> MeshCoreNodeConfig.ChannelConfig {
    MeshCoreNodeConfig.ChannelConfig(name: name, secret: secret(byte).hexString, slot: slot)
  }

  /// `held` maps slot -> (name, secret byte); every other slot below `count` is empty.
  private static func radio(_ count: UInt8, _ held: [UInt8: (String, UInt8)] = [:]) -> [DeviceChannelSlot] {
    (0..<count).map { index in
      if let (name, byte) = held[index] {
        DeviceChannelSlot(index: index, name: name, secret: secret(byte), isConfigured: true)
      } else {
        DeviceChannelSlot(index: index, name: "", secret: Data(repeating: 0, count: 16), isConfigured: false)
      }
    }
  }

  @Test
  func `An empty radio gets every channel in its own slot, gaps kept`() throws {
    let plan = try planChannelAlignment(
      [Self.channel("Public", 0x01, slot: 0), Self.channel("Club", 0x02, slot: 2), Self.channel("Ops", 0x07, slot: 7)],
      maxChannels: 8, existingChannels: Self.radio(8), makeRoom: false
    )
    #expect(plan.writes.map(\.index) == [0, 2, 7])
    #expect(plan.clears.isEmpty)
    #expect(plan.overwrite == false)
  }

  @Test
  func `A radio that already matches needs no writes`() throws {
    let plan = try planChannelAlignment(
      [Self.channel("Public", 0x01, slot: 0), Self.channel("Club", 0x02, slot: 1)],
      maxChannels: 4, existingChannels: Self.radio(4, [0: ("Public", 0x01), 1: ("Club", 0x02)]), makeRoom: false
    )
    #expect(plan.writes.isEmpty)
    #expect(plan.clears.isEmpty)
  }

  @Test
  func `One of your channels in the wrong slot moves home and its old slot is emptied`() throws {
    let plan = try planChannelAlignment(
      [Self.channel("Club", 0x02, slot: 3)],
      maxChannels: 8, existingChannels: Self.radio(8, [5: ("Club", 0x02)]), makeRoom: false
    )
    #expect(plan.writes.map(\.index) == [3])
    #expect(plan.clears == [5])
    #expect(plan.blocked.isEmpty)
  }

  @Test
  func `Without leave, a slot holding the radio's own channel is left alone`() throws {
    let plan = try planChannelAlignment(
      [Self.channel("Club", 0x02, slot: 3)],
      maxChannels: 8, existingChannels: Self.radio(8, [3: ("Theirs", 0x09)]), makeRoom: false
    )
    #expect(plan.writes.isEmpty)
    #expect(plan.blocked == ["Club"])
    #expect(plan.relocated.isEmpty)
  }

  @Test
  func `With leave, the radio's own channel moves to a free slot before yours is written`() throws {
    let plan = try planChannelAlignment(
      [Self.channel("Public", 0x01, slot: 0), Self.channel("Club", 0x02, slot: 1)],
      maxChannels: 4, existingChannels: Self.radio(4, [0: ("Public", 0x01), 1: ("Theirs", 0x09)]), makeRoom: true
    )
    #expect(plan.relocated == ["Theirs"])
    // Relocation first (into slot 2, the first free one), then Club into its own slot.
    #expect(plan.writes.map(\.index) == [2, 1])
    #expect(plan.writes.first?.secret == Self.secret(0x09))
    #expect(plan.overwrite)
  }

  @Test
  func `A displaced channel takes the slot a moved channel vacates instead of clearing it`() throws {
    let plan = try planChannelAlignment(
      [Self.channel("Club", 0x02, slot: 3)],
      maxChannels: 8, existingChannels: Self.radio(8, [3: ("Theirs", 0x09), 6: ("Club", 0x02)]), makeRoom: true
    )
    #expect(plan.relocated == ["Theirs"])
    #expect(plan.clears.isEmpty)
    #expect(Set(plan.writes.map(\.index)) == [3, 6])
    #expect(plan.writes.first { $0.index == 6 }?.secret == Self.secret(0x09))
  }

  @Test
  func `With no free slot left, the radio's own channel is removed and reported`() throws {
    let plan = try planChannelAlignment(
      [Self.channel("Public", 0x01, slot: 0), Self.channel("Club", 0x02, slot: 1)],
      maxChannels: 2, existingChannels: Self.radio(2, [0: ("A", 0x08), 1: ("B", 0x09)]), makeRoom: true
    )
    #expect(plan.removed == ["A", "B"])
    #expect(plan.writes.map(\.index) == [0, 1])
  }

  @Test
  func `A slot is not overwritten when that would strand one of your channels whose own slot is blocked`() throws {
    // Club belongs at 5 but sits at 3; slot 5 holds the radio's own channel.
    let plan = try planChannelAlignment(
      [Self.channel("Ops", 0x03, slot: 3), Self.channel("Club", 0x02, slot: 5)],
      maxChannels: 8, existingChannels: Self.radio(8, [3: ("Club", 0x02), 5: ("Theirs", 0x09)]), makeRoom: false
    )
    #expect(plan.writes.isEmpty)
    #expect(plan.blocked == ["Ops", "Club"])
  }

  @Test
  func `A channel whose slot is past this radio's last is reported, not shifted`() throws {
    let plan = try planChannelAlignment(
      [Self.channel("Public", 0x01, slot: 0), Self.channel("Far", 0x04, slot: 9)],
      maxChannels: 8, existingChannels: Self.radio(8), makeRoom: false
    )
    #expect(plan.writes.map(\.index) == [0])
    #expect(plan.beyondCapacity == ["Far"])
  }

  @Test
  func `A renamed channel with the same secret is rewritten in place`() throws {
    let plan = try planChannelAlignment(
      [Self.channel("Club Night", 0x02, slot: 1)],
      maxChannels: 4, existingChannels: Self.radio(4, [1: ("Club", 0x02)]), makeRoom: false
    )
    #expect(plan.writes.map(\.index) == [1])
    #expect(plan.blocked.isEmpty)
  }

  @Test
  func `A file config without slots still uses the first-free-slot planner`() throws {
    let config = MeshCoreNodeConfig(channels: [
      MeshCoreNodeConfig.ChannelConfig(name: "Club", secret: Self.secret(0x02).hexString),
    ])
    let plan = try planConfigImport(
      config: config, sections: ConfigSections(channels: true), maxChannels: 4, maxContacts: 10,
      maxTxPower: 22, existingChannels: Self.radio(4, [0: ("Public", 0x01)]), existingContacts: [:]
    )
    #expect(plan.channelWrites.map(\.index) == [1])
    #expect(plan.channelClears.isEmpty)
  }

  @Test
  func `Slots never reach a config file`() throws {
    let channel = Self.channel("Club", 0x02, slot: 3)
    let json = try String(decoding: JSONEncoder().encode(channel), as: UTF8.self)
    #expect(!json.contains("slot"))
  }
}

// MARK: - Copy from this phone's records

@Suite("Copy from this phone's records")
struct RecordsConfigTests {
  private static let identityKey = Data(repeating: 0xAB, count: 32)

  /// `recordsConfig` reads only the store; the session is never started or used.
  private func makeService(store: PersistenceStore) -> NodeConfigService {
    let session = MeshCoreSession(transport: MockTransport())
    return NodeConfigService(
      session: session,
      settingsService: SettingsService(session: session),
      channelService: ChannelService(session: session, dataStore: store, rxLogService: nil),
      dataStore: store,
      syncCoordinator: nil
    )
  }

  private func frame(_ byte: UInt8, name: String) -> ContactFrame {
    ContactFrame(
      publicKey: Data(repeating: byte, count: 32), type: .chat, flags: 0,
      outPathLength: 0xFF, outPath: Data(), name: name, lastAdvertTimestamp: 100,
      latitude: 0, longitude: 0, lastModified: 200
    )
  }

  @Test
  func `Without a swap the config is the Device row, channel rows by slot, and every contact`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID, maxChannels: 8)
    _ = try await store.saveChannel(radioID: radioID, from: ChannelInfo(index: 2, name: "Club", secret: Data(repeating: 0x02, count: 16)))
    let saved = try await store.saveContact(radioID: radioID, from: frame(0xC1, name: "Friend"))
    let stored = try #require(try await store.fetchContact(radioID: radioID, publicKey: Data(repeating: 0xC1, count: 32)))
    try await store.saveContact(ContactDTO(
      id: saved.id, radioID: radioID, publicKey: stored.publicKey, name: stored.name,
      typeRawValue: stored.typeRawValue, flags: stored.flags,
      outPathLength: stored.outPathLength, outPath: stored.outPath,
      lastAdvertTimestamp: stored.lastAdvertTimestamp, latitude: 0, longitude: 0,
      lastModified: stored.lastModified, lastHeardTimestamp: nil,
      nickname: nil, isBlocked: false, isMuted: false, isFavorite: true,
      lastMessageDate: nil, unreadCount: 0
    ))

    var all = ConfigSections()
    all.selectAll()
    let config = try await makeService(store: store).recordsConfig(radioID: radioID, sections: all)

    #expect(config.privateKey == nil)
    #expect(config.name == "TestDevice")
    #expect(config.channels == [MeshCoreNodeConfig.ChannelConfig(
      name: "Club", secret: Data(repeating: 0x02, count: 16).hexString, slot: 2
    )])
    let friend = try #require(config.contacts?.first { $0.name == "Friend" })
    #expect(friend.flags & ContactFlags.favorite.rawValue != 0)
  }

  @Test
  func `With the guard armed, settings and channels come from the profile and TX power is capped`() async throws {
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    let historyRadioID = UUID()
    // The old radio: 30 dBm, channel Club at slot 3.
    let oldRadio = DeviceDTO.testDevice(radioID: historyRadioID, publicKey: Self.identityKey, nodeName: "Digitaino")
      .copy { $0.txPower = 30; $0.maxTxPower = 30; $0.frequency = 910_525 }
    try await store.saveDevice(oldRadio)
    _ = try await store.saveChannel(radioID: historyRadioID, from: ChannelInfo(index: 3, name: "Club", secret: Data(repeating: 0x02, count: 16)))

    // The new radio takes the identity: 22 dBm max, default name and frequency.
    let newRadio = DeviceDTO.testDevice(radioID: historyRadioID, publicKey: Self.identityKey, nodeName: "MeshCore-1234")
      .copy { $0.txPower = 22; $0.maxTxPower = 22 }
    try await store.saveDevice(newRadio)
    try await store.armSwapGuard(id: newRadio.id, previousDeviceID: oldRadio.id)
    try await store.deleteDevice(id: oldRadio.id)
    // The first guarded sync relabels slot 3 with the new radio's channel.
    _ = try await store.saveChannel(radioID: historyRadioID, from: ChannelInfo(index: 3, name: "Theirs", secret: Data(repeating: 0x09, count: 16)))

    var all = ConfigSections()
    all.selectAll()
    let config = try await makeService(store: store).recordsConfig(radioID: historyRadioID, sections: all)

    #expect(config.name == "Digitaino")
    #expect(config.radioSettings?.frequency == 910_525)
    #expect(config.radioSettings?.txPower == 22)
    #expect(config.channels?.map(\.name) == ["Club"])
    #expect(config.channels?.first?.slot == 3)
  }

  @Test
  func `Execution clears a vacated slot after the writes`() async throws {
    let config = MeshCoreNodeConfig(channels: [
      MeshCoreNodeConfig.ChannelConfig(name: "Club", secret: Data(repeating: 0x02, count: 16).hexString, slot: 3),
    ])
    var radio = (0..<UInt8(8)).map {
      DeviceChannelSlot(index: $0, name: "", secret: Data(repeating: 0, count: 16), isConfigured: false)
    }
    radio[5] = DeviceChannelSlot(index: 5, name: "Club", secret: Data(repeating: 0x02, count: 16), isConfigured: true)
    let sections = ConfigSections(channels: true)
    let plan = try planConfigImport(
      config: config, sections: sections, maxChannels: 8, maxContacts: 10, maxTxPower: 22,
      existingChannels: radio, existingContacts: [:]
    )

    let calls = CallLog()
    let writers = ConfigImportWriters(
      getSelfInfo: { throw CancellationError() },
      importPrivateKey: { _ in }, setNodeName: { _ in }, setLocation: { _, _ in },
      setOtherParams: { _ in }, resolveEffectiveRadioID: { id, _ in id },
      setRadioParams: { _ in }, setTxPower: { _ in },
      setChannel: { _, write in calls.append("set:\(write.index)") },
      clearChannelSlot: { _, index in calls.append("clear:\(index)") },
      addContact: { _, _ in }
    )
    try await executeConfigImport(
      plan: plan, sections: sections, radioID: UUID(), writers: writers,
      logger: Logger(subsystem: "test", category: "RadioSwapCopyTests"), onProgress: nil
    )
    #expect(calls.entries == ["set:3", "clear:5"])
  }
}

private final class CallLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  func append(_ entry: String) {
    lock.withLock { storage.append(entry) }
  }

  var entries: [String] {
    lock.withLock { storage }
  }
}
