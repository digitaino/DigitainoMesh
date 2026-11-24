#if canImport(UIKit)
  import AccessorySetupKit
#endif
import Foundation
@testable import MC1Services
import MeshCore
import Testing

@Suite("Authenticated registration rekey boundary")
@MainActor
struct ConnectionRegistrationRekeyTests {
  /// `savedBluetooth`: the saved row has a Bluetooth link to another peripheral, so it is another
  /// radio carrying the identity and the new id gets a sibling row (fork rule). Without it the
  /// saved row is Wi-Fi-only, which the fork still adopts and rekeys in place as upstream does.
  @Test(arguments: [true, false])
  func `superseded authenticated registration leaves a durable row that reconnects through its saved target`(savedBluetooth: Bool) async throws {
    let env = try ConnectionManagerRadioTestHarness(publicKey: Data(repeating: 0xD5, count: 32))
    let manager = env.manager
    let oldID = UUID()
    let newID = UUID()
    let wifi = ConnectionMethod.wifi(host: "saved.radio", port: 5123, displayName: "Saved WiFi")
    let lastConnected = Date(timeIntervalSince1970: 1_700_000_000)
    let savedMethods: [ConnectionMethod] = savedBluetooth
      ? [wifi, .bluetooth(peripheralUUID: oldID, displayName: "Field Bluetooth")] : [wifi]
    let saved = DeviceDTO.testDevice(id: oldID, publicKey: env.ble.publicKey, lastConnected: lastConnected, isActive: false).copy {
      $0.connectionMethods = savedMethods
    }
    var connecting: Task<ConnectionResult, Error>?
    var superseding: Task<ConnectionLossReceipt, Never>?
    do {
      try await manager.persistenceStore.saveDevice(saved)
      let pending = try await seedPendingSend(store: manager.persistenceStore, radioID: saved.radioID, radio: env.ble)
      env.pairing.isSessionActive = true
      env.pairing.setPairedAccessories([ASAccessory(bluetoothIdentifier: newID, displayName: "New pairing")])
      var capabilities = Data([ResponseCode.deviceInfo.rawValue, 14, 1, 1])
      capabilities.append(Data(repeating: 0, count: 76))
      capabilities.append(1)
      await env.ble.setResponsePackets(for: .deviceQuery, packets: [capabilities])
      await env.ble.setResponsePackets(for: .getRepeatFreq, packets: [Data([ResponseCode.allowedRepeatFreq.rawValue])])
      await env.ble.holdReplies(for: .getRepeatFreq)
      let attempt = Task { try await manager.connect(to: newID, forceFullSync: true, forceReconnect: true) }
      connecting = attempt
      try await waitUntil {
        await env.ble.sentData.contains { $0.first == CommandCode.getRepeatFreq.rawValue }
      }
      #expect(try await manager.persistenceStore.fetchDevice(id: newID)?.radioID == saved.radioID)
      #expect(manager.installedLink == nil)
      let disconnecting = Task { await manager.disconnect(reason: .userInitiated) }
      superseding = disconnecting
      try await waitUntil { manager.desiredRequest?.target == .disconnected }
      await env.ble.releaseReplies(for: .getRepeatFreq)
      let outcome = try await attempt.value
      if case .superseded = outcome {} else { Issue.record("Registration attempt must lose publication to the admitted disconnect") }
      _ = await disconnecting.value
      await manager.metadataCommitTask?.value

      let registered = try #require(try await manager.persistenceStore.fetchDevice(id: newID))
      #expect(registered.radioID == saved.radioID)
      #expect(!registered.isActive)
      #expect(try await manager.persistenceStore.fetchPendingSends(radioID: registered.radioID).contains { $0.id == pending.id })
      if savedBluetooth {
        // Fork: a row on another peripheral is a sibling, never rekeyed or deleted (docs/RADIO_SWAP.md R1).
        let kept = try #require(try await manager.persistenceStore.fetchDevice(id: oldID))
        #expect(kept.connectionMethods == savedMethods)
        #expect(kept.lastConnected == lastConnected)
        // Fork: a new sibling row has no methods and lastConnected = .distantPast until selection (docs/RADIO_SWAP.md R1).
        #expect(registered.connectionMethods.isEmpty)
        #expect(registered.lastConnected == .distantPast)
        #expect(registered.savedDeviceConnectTarget == .bluetooth(peripheralID: newID))
        // Fork: the unselected sibling never stands in for the identity; the saved radio stays its most recent (R1).
        #expect(try await manager.persistenceStore.fetchDevice(radioID: saved.radioID)?.id == oldID)
        // Fork: the saved Wi-Fi address still belongs to the saved radio, not the sibling (R1).
        #expect(await manager.wifiDeviceID(publicKey: registered.publicKey) == oldID)
      } else {
        // Fork: a Wi-Fi-only row is this radio's own and is adopted and rekeyed in place, as upstream (R1).
        #expect(try await manager.persistenceStore.fetchDevice(id: oldID) == nil)
        #expect(registered.connectionMethods == [wifi])
        #expect(registered.savedDeviceConnectTarget == .wifi(host: "saved.radio", port: 5123))
        #expect(registered.lastConnected == lastConnected)
        #expect(await manager.wifiDeviceID(publicKey: registered.publicKey) == newID)
      }

      let reconnected: ConnectionResult = switch registered.savedDeviceConnectTarget {
      case let .bluetooth(peripheralID):
        try await manager.connect(to: peripheralID, forceFullSync: true, forceReconnect: true)
      case let .wifi(host, port):
        try await manager.connectViaWiFi(host: host, port: port, forceFullSync: true)
      }
      let snapshot: ConnectionSnapshot
      if case let .operational(current) = reconnected { snapshot = current } else { throw ConnectionError.notConnected }
      #expect(snapshot.device.id == newID)
      #expect(snapshot.device.radioID == saved.radioID)
      _ = try await snapshot.services.session.getTime()
      #expect(try await manager.persistenceStore.fetchPendingSends(radioID: snapshot.device.radioID).contains { $0.id == pending.id })
      if savedBluetooth {
        // Fork: the sibling does not inherit the saved radio's Wi-Fi method; that row keeps it (R1).
        #expect(snapshot.device.wifiConnectionMethod == nil)
        #expect(try await manager.persistenceStore.fetchDevice(id: oldID)?.connectionMethods == savedMethods)
        // Fork: selection stamps the sibling, which is now the identity's connected row (R1).
        #expect(snapshot.device.lastConnected > lastConnected)
        #expect(try await manager.persistenceStore.fetchDevice(radioID: saved.radioID)?.id == newID)
      } else {
        // Selection stores the dialed Wi-Fi method, which carries no display name, so compare the address.
        #expect(snapshot.device.savedDeviceConnectTarget == .wifi(host: "saved.radio", port: 5123))
        #expect(snapshot.device.bluetoothPeripheralID == nil)
      }
    } catch {
      await env.ble.releaseAllGates()
      _ = await connecting?.result
      _ = await superseding?.value
      await env.close()
      throw error
    }
    await env.close()
  }

  @Test(arguments: [false, true])
  func `registration does not invent or infer Bluetooth methods from a WiFi observation`(existingBluetooth: Bool) async throws {
    let env = try ConnectionManagerRadioTestHarness()
    do {
      let oldID = UUID()
      let newID = UUID()
      let wifi = ConnectionMethod.wifi(host: "saved.radio", port: 5123, displayName: "WiFi")
      let methods: [ConnectionMethod] = existingBluetooth
        ? [.bluetooth(peripheralUUID: oldID, displayName: "Bluetooth"), wifi] : [wifi]
      let saved = DeviceDTO.testDevice(id: oldID, isActive: false).copy { $0.connectionMethods = methods }
      try await env.manager.persistenceStore.saveDevice(saved)
      let observed = saved.copy { $0.id = newID }
      let registered = try await env.manager.persistenceStore.registerConnectionDevice(observed, bluetoothPeripheralID: nil)
      // Fork: a row with Bluetooth on another peripheral is a sibling; the new row gets no methods (docs/RADIO_SWAP.md R1).
      let expectedMethods: [ConnectionMethod] = existingBluetooth ? [] : methods
      #expect(registered.connectionMethods == expectedMethods)
      #expect(registered.radioID == saved.radioID)
      #expect(!registered.isActive)
      // Fork: a new sibling row is saved with lastConnected = .distantPast until selection (R1).
      #expect(registered.lastConnected == (existingBluetooth ? .distantPast : saved.lastConnected))
      if existingBluetooth {
        // Fork: the other radio's row is left untouched, not rekeyed or deleted (R1).
        let kept = try #require(try await env.manager.persistenceStore.fetchDevice(id: oldID))
        #expect(kept.connectionMethods == methods)
        #expect(kept.radioID == saved.radioID)
      } else {
        #expect(try await env.manager.persistenceStore.fetchDevice(id: oldID) == nil)
      }
      let roundTrip = try JSONDecoder().decode(DeviceDTO.self, from: JSONEncoder().encode(registered))
      #expect(roundTrip.connectionMethods == expectedMethods)
      #expect(roundTrip.radioID == saved.radioID)
    } catch { await env.close(); throw error }
    await env.close()
  }

  @Test(arguments: [false, true])
  func `authenticated Bluetooth registration does not create a method before selection`(hasWiFi: Bool) async throws {
    let env = try ConnectionManagerRadioTestHarness()
    do {
      let oldID = UUID()
      let newID = UUID()
      let methods: [ConnectionMethod] = hasWiFi ? [.wifi(host: "saved.radio", port: 5123, displayName: "WiFi")] : []
      let saved = DeviceDTO.testDevice(id: oldID, isActive: false).copy { $0.connectionMethods = methods }
      try await env.manager.persistenceStore.saveDevice(saved)
      let observed = saved.copy { $0.id = newID }
      let registered = try await env.manager.persistenceStore.registerConnectionDevice(observed, bluetoothPeripheralID: newID)
      #expect(registered.connectionMethods == methods)
      #expect(registered.radioID == saved.radioID)
      #expect(!registered.isActive)
      #expect(registered.lastConnected == saved.lastConnected)
    } catch { await env.close(); throw error }
    await env.close()
  }

  private func seedPendingSend(store: PersistenceStore, radioID: UUID, radio: ConnectionTestRadioTransport) async throws -> PendingSendDTO {
    let contact = ContactDTO.testContact(radioID: radioID)
    try await store.saveContact(contact)
    let message = MessageDTO(from: Message(radioID: radioID, contactID: contact.id, text: "Queued before re-pair", timestamp: 1_700_000_000))
    try await store.saveMessage(message)
    let pending = PendingSendDTO(
      id: UUID(), radioID: radioID, messageID: message.id, kind: .dm, contactID: contact.id,
      channelIndex: nil, isResend: false, messageText: message.text, messageTimestamp: message.timestamp,
      localNodeName: "Field radio", sequence: 1, enqueuedAt: Date()
    )
    try await store.upsertPendingSend(pending)
    var packet = Data([ResponseCode.contact.rawValue])
    packet.append(contact.publicKey)
    packet.append(contentsOf: [ContactType.chat.rawValue, 0, 0xFF])
    packet.append(Data(repeating: 0, count: 64))
    let name = Data(contact.name.utf8.prefix(31))
    packet.append(name)
    packet.append(Data(repeating: 0, count: 32 - name.count))
    packet.append(Data(repeating: 0, count: 16))
    await radio.setResponsePackets(for: .getContacts, packets: [
      Data([ResponseCode.contactStart.rawValue, 1, 0, 0, 0]), packet,
      Data([ResponseCode.contactEnd.rawValue, 1, 0, 0, 0])
    ])
    return pending
  }
}
