import Foundation
@testable import MC1Services
import MeshCore
import SwiftData
import Testing

/// The swap guard's storage rules (docs/RADIO_SWAP.md, rule R2): who arms it, that the
/// contact watermark goes with it, and that no DTO save can release it.
@Suite("Radio swap guard")
struct RadioSwapGuardTests {
  private func createStore() async throws -> PersistenceStore {
    let container = try PersistenceStore.createContainer(inMemory: true)
    return PersistenceStore(modelContainer: container)
  }

  private static let identityKey = Data(repeating: 0xAB, count: 32)

  private static func makeSelfInfo(publicKey: Data = identityKey) -> SelfInfo {
    SelfInfo(
      advertisementType: 0,
      txPower: 20,
      maxTxPower: 20,
      publicKey: publicKey,
      latitude: 0,
      longitude: 0,
      multiAcks: 2,
      advertisementLocationPolicy: 0,
      telemetryModeEnvironment: 0,
      telemetryModeLocation: 0,
      telemetryModeBase: 2,
      manualAddContacts: false,
      radioFrequency: 915.0,
      radioBandwidth: 250.0,
      radioSpreadingFactor: 10,
      radioCodingRate: 5,
      name: "TestNode"
    )
  }

  private static let capabilities = DeviceCapabilities(
    firmwareVersion: 9,
    maxContacts: 100,
    maxChannels: 8,
    blePin: 0,
    firmwareBuild: "01 Jan 2025",
    model: "T-Deck",
    version: "v1.13.0"
  )

  // MARK: - Store

  @Test
  func `A device starts with nothing held back`() async throws {
    let store = try await createStore()
    let device = DeviceDTO.testDevice(radioID: UUID())
    try await store.saveDevice(device)

    #expect(try await store.fetchSwapGuard(radioID: device.radioID).isEmpty)
    #expect(try await store.fetchSwapGuard(radioID: UUID()).isEmpty)
  }

  @Test
  func `Arming holds back contacts and channels and clears the contact watermark`() async throws {
    let store = try await createStore()
    let device = DeviceDTO.testDevice(radioID: UUID(), lastContactSync: 1_700_000_000)
    try await store.saveDevice(device)

    try await store.armSwapGuard(id: device.id)

    #expect(try await store.fetchSwapGuard(radioID: device.radioID) == .all)
    #expect(try await store.fetchDevice(id: device.id)?.lastContactSync == 0)
  }

  @Test
  func `Releasing one part leaves the other armed`() async throws {
    let store = try await createStore()
    let device = DeviceDTO.testDevice(radioID: UUID())
    try await store.saveDevice(device)
    try await store.armSwapGuard(id: device.id)

    try await store.releaseSwapGuard(radioID: device.radioID, .contacts)

    #expect(try await store.fetchSwapGuard(radioID: device.radioID) == .channels)
  }

  @Test
  func `A stale DTO save cannot release the guard`() async throws {
    let store = try await createStore()
    let device = DeviceDTO.testDevice(radioID: UUID())
    try await store.saveDevice(device)
    // Snapshot taken before arming, saved after: the read-snapshot-then-save pattern
    // settings refreshes use.
    let snapshot = try #require(try await store.fetchDevice(id: device.id))
    try await store.armSwapGuard(id: device.id)

    try await store.saveDevice(snapshot.copy { $0.nodeName = "Renamed" })

    #expect(try await store.fetchSwapGuard(radioID: device.radioID) == .all)
  }

  @Test
  func `A ghost rejoin arms the guard and drops the interim watermark`() async throws {
    let store = try await createStore()
    let historyRadioID = UUID()
    let oldRadio = DeviceDTO.testDevice(radioID: historyRadioID, publicKey: Self.identityKey, isActive: true)
    try await store.saveDevice(oldRadio)
    try await store.demoteDeviceToGhost(id: oldRadio.id)

    // The replacement radio was paired under its own key first, then given the identity.
    let newRadio = DeviceDTO.testDevice(
      radioID: UUID(),
      publicKey: Data(repeating: 0x02, count: 32),
      lastContactSync: 1_700_000_000,
      isActive: true
    )
    try await store.saveDevice(newRadio)

    let rejoined = try await store.reconcileGhostIdentity(currentDeviceID: newRadio.id, newPublicKey: Self.identityKey)

    #expect(rejoined == historyRadioID)
    #expect(try await store.fetchSwapGuard(radioID: historyRadioID) == .all)
    #expect(try await store.fetchDevice(id: newRadio.id)?.lastContactSync == 0)
  }

  // MARK: - Identity profile

  @Test
  func `Arming captures the previous radio's settings and the channel rows before any sync`() async throws {
    let store = try await createStore()
    let historyRadioID = UUID()
    let oldRadio = DeviceDTO.testDevice(radioID: historyRadioID, publicKey: Self.identityKey, nodeName: "Digitaino")
      .copy { $0.frequency = 910_525 }
    try await store.saveDevice(oldRadio)
    _ = try await store.saveChannel(
      radioID: historyRadioID, from: ChannelInfo(index: 4, name: "Club", secret: Data(repeating: 0x02, count: 16))
    )
    let newRadio = DeviceDTO.testDevice(radioID: historyRadioID, publicKey: Self.identityKey, nodeName: "MeshCore-1234")
    try await store.saveDevice(newRadio)

    try await store.armSwapGuard(id: newRadio.id, previousDeviceID: oldRadio.id)
    try await store.deleteDevice(id: oldRadio.id)

    let profile = try #require(try await store.fetchSwapProfile(radioID: historyRadioID))
    #expect(profile.nodeName == "Digitaino")
    #expect(profile.radio.frequency == 910_525)
    #expect(profile.channels == [IdentityProfile.Channel(slot: 4, name: "Club", secret: Data(repeating: 0x02, count: 16))])
  }

  @Test
  func `An unsettled swap carries its profile to the next radio`() async throws {
    let store = try await createStore()
    let historyRadioID = UUID()
    let first = DeviceDTO.testDevice(radioID: historyRadioID, publicKey: Self.identityKey, nodeName: "Digitaino")
    try await store.saveDevice(first)
    _ = try await store.saveChannel(
      radioID: historyRadioID, from: ChannelInfo(index: 1, name: "Club", secret: Data(repeating: 0x02, count: 16))
    )
    let second = DeviceDTO.testDevice(radioID: historyRadioID, publicKey: Self.identityKey, nodeName: "Second")
    try await store.saveDevice(second)
    try await store.armSwapGuard(id: second.id, previousDeviceID: first.id)
    try await store.deleteDevice(id: first.id)
    // The second radio's guarded sync relabels slot 1; its swap is never settled.
    _ = try await store.saveChannel(
      radioID: historyRadioID, from: ChannelInfo(index: 1, name: "Theirs", secret: Data(repeating: 0x09, count: 16))
    )

    let third = DeviceDTO.testDevice(radioID: historyRadioID, publicKey: Self.identityKey, nodeName: "Third")
    try await store.saveDevice(third)
    try await store.armSwapGuard(id: third.id, previousDeviceID: second.id)
    try await store.deleteDevice(id: second.id)

    let profile = try #require(try await store.fetchSwapProfile(radioID: historyRadioID))
    #expect(profile.nodeName == "Digitaino")
    #expect(profile.channels.map(\.name) == ["Club"])
  }

  @Test
  func `Forgetting a radio mid-swap keeps its guard and profile on the ghost, and a rejoin takes them`() async throws {
    let store = try await createStore()
    let historyRadioID = UUID()
    let oldRadio = DeviceDTO.testDevice(radioID: historyRadioID, publicKey: Self.identityKey, nodeName: "Digitaino")
    try await store.saveDevice(oldRadio)
    let swapped = DeviceDTO.testDevice(radioID: historyRadioID, publicKey: Self.identityKey, nodeName: "Swapped")
    try await store.saveDevice(swapped)
    try await store.armSwapGuard(id: swapped.id, previousDeviceID: oldRadio.id)
    try await store.deleteDevice(id: oldRadio.id)

    try await store.demoteDeviceToGhost(id: swapped.id)
    let replacement = DeviceDTO.testDevice(radioID: UUID(), publicKey: Data(repeating: 0x02, count: 32))
    try await store.saveDevice(replacement)
    _ = try await store.reconcileGhostIdentity(currentDeviceID: replacement.id, newPublicKey: Self.identityKey)

    #expect(try await store.fetchSwapGuard(radioID: historyRadioID) == .all)
    #expect(try await store.fetchSwapProfile(radioID: historyRadioID)?.nodeName == "Digitaino")
  }

  // MARK: - One identity, several radios

  private static func bluetooth(_ id: UUID) -> [ConnectionMethod] {
    [.bluetooth(peripheralUUID: id, displayName: nil)]
  }

  @Test
  func `Reads by identity go to the radio that connected most recently`() async throws {
    let store = try await createStore()
    let radioID = UUID()
    let older = DeviceDTO.testDevice(radioID: radioID, publicKey: Self.identityKey)
      .copy { $0.lastConnected = Date(timeIntervalSinceReferenceDate: 1000); $0.lastContactSync = 111 }
    let newer = DeviceDTO.testDevice(radioID: radioID, publicKey: Self.identityKey)
      .copy { $0.lastConnected = Date(timeIntervalSinceReferenceDate: 2000); $0.lastContactSync = 222 }
    try await store.saveDevice(older)
    try await store.saveDevice(newer)

    #expect(try await store.fetchDevice(radioID: radioID)?.id == newer.id)
    try await store.updateDeviceLastContactSync(radioID: radioID, timestamp: 333)
    #expect(try await store.fetchDevice(id: newer.id)?.lastContactSync == 333)
    #expect(try await store.fetchDevice(id: older.id)?.lastContactSync == 111)
  }

  @Test
  func `Forgetting one of two radios removes only its row and keeps the shared history`() async throws {
    let store = try await createStore()
    let radioID = UUID()
    let first = DeviceDTO.testDevice(radioID: radioID, publicKey: Self.identityKey)
    let second = DeviceDTO.testDevice(radioID: radioID, publicKey: Self.identityKey)
    try await store.saveDevice(first.copy { $0.connectionMethods = Self.bluetooth(first.id) })
    try await store.saveDevice(second.copy { $0.connectionMethods = Self.bluetooth(second.id) })
    _ = try await store.saveChannel(radioID: radioID, from: ChannelInfo(index: 0, name: "Public", secret: Data(repeating: 0x01, count: 16)))

    #expect(try await store.otherRadios(sharingIdentityWith: first.id).map(\.id) == [second.id])
    #expect(try await store.forgetRadio(id: first.id))

    #expect(try await store.fetchDevice(id: first.id) == nil)
    #expect(try await store.fetchDevices(radioID: radioID).map(\.id) == [second.id])
    #expect(try await store.fetchChannels(radioID: radioID).count == 1)
  }

  @Test
  func `Forgetting the only radio leaves a ghost that keeps the key-to-history bridge`() async throws {
    let store = try await createStore()
    let radioID = UUID()
    let only = DeviceDTO.testDevice(radioID: radioID, publicKey: Self.identityKey)
    try await store.saveDevice(only.copy { $0.connectionMethods = Self.bluetooth(only.id) })

    #expect(try await store.forgetRadio(id: only.id) == false)

    let ghost = try #require(try await store.fetchDevice(publicKey: Self.identityKey))
    #expect(ghost.radioID == radioID)
    #expect(ghost.connectionMethods.isEmpty)
    #expect(try await store.otherRadios(sharingIdentityWith: ghost.id).isEmpty)
  }

  @Test
  func `Known regions belong to the identity, so every radio carrying it gets them`() async throws {
    let store = try await createStore()
    let radioID = UUID()
    let first = DeviceDTO.testDevice(radioID: radioID, publicKey: Self.identityKey)
    let second = DeviceDTO.testDevice(radioID: radioID, publicKey: Self.identityKey)
    try await store.saveDevice(first)
    try await store.saveDevice(second)

    try await store.addDeviceKnownRegion(radioID: radioID, region: "us-nm")

    #expect(try await store.fetchDevice(id: first.id)?.knownRegions == ["us-nm"])
    #expect(try await store.fetchDevice(id: second.id)?.knownRegions == ["us-nm"])
  }

  @Test
  func `A new radio borrows only what belongs to the identity from the radio carrying it`() {
    let sibling = DeviceDTO.testDevice(radioID: UUID(), publicKey: Self.identityKey, lastContactSync: 1_700_000_000)
      .copy {
        $0.connectionMethods = Self.bluetooth(UUID())
        $0.ocvPreset = "liFePO4"
        $0.knownRegions = ["us-nm"]
      }

    let template = ConnectionManager.identityTemplate(from: sibling)

    #expect(template.radioID == sibling.radioID)
    #expect(template.knownRegions == ["us-nm"])
    #expect(template.connectionMethods.isEmpty)
    #expect(template.ocvPreset == nil)
    #expect(template.lastContactSync == 0)
  }

  // MARK: - createDevice

  @Test
  @MainActor
  func `createDevice drops the previous radio's watermark when it takes on the identity`() throws {
    let (cm, _) = try ConnectionManager.createForTesting()
    let previous = DeviceDTO.testDevice(publicKey: Self.identityKey, lastContactSync: 1_700_000_000)

    let swapped = cm.createDevice(
      deviceID: UUID(),
      radioID: previous.radioID,
      selfInfo: Self.makeSelfInfo(),
      capabilities: Self.capabilities,
      autoAddConfig: AutoAddConfig(bitmask: 0),
      existingDevice: previous,
      tookOnIdentity: true
    )
    #expect(swapped.lastContactSync == 0)

    let reconnected = cm.createDevice(
      deviceID: previous.id,
      radioID: previous.radioID,
      selfInfo: Self.makeSelfInfo(),
      capabilities: Self.capabilities,
      autoAddConfig: AutoAddConfig(bitmask: 0),
      existingDevice: previous
    )
    #expect(reconnected.lastContactSync == 1_700_000_000)
  }
}
