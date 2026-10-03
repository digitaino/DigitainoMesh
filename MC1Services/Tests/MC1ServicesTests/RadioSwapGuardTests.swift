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
