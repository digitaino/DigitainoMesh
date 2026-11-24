import Foundation
import SwiftData

extension PersistenceStore {
  /// Applies an accepted field update without yielding between the fresh read and save.
  @discardableResult
  func updateConnectionDevice(id: UUID, update: @Sendable (DeviceDTO) -> DeviceDTO?) throws -> Bool {
    guard let current = try fetchDevice(id: id), let updated = update(current) else { return false }
    try saveDevice(updated)
    return true
  }

  /// Registers authenticated radio observations while preserving the store's current local state.
  ///
  /// The row is the observation's own, else `adoptingRowID`, else the most recent row carrying the
  /// key when it is this radio's own earlier row (``adoptsAsOwnRow(_:deviceID:)``). An adopted row
  /// moves to the observation's id. A row of another radio carrying the key is never taken over:
  /// this radio gets a new sibling row sharing the history (docs/RADIO_SWAP.md, R1).
  ///
  /// A new row is saved without a connection method and with no last-connected date, so a
  /// cancelled attempt is neither the identity's most recent radio nor listed; selection stamps it.
  ///
  /// `armsSwapGuard` arms the registered row's ``SwapGuard`` with the profile of
  /// `previousDeviceID` (see ``armSwapGuard(id:previousDeviceID:)``), which also clears its contact
  /// watermark, in the same actor turn and before an adopted row is removed, so the profile can
  /// still be read from it.
  func registerConnectionDevice(
    _ observation: DeviceDTO, bluetoothPeripheralID: UUID?, adoptingRowID: UUID? = nil,
    armsSwapGuard: Bool = false, previousDeviceID: UUID? = nil
  ) throws -> DeviceDTO {
    let current: DeviceDTO? = if let own = try fetchDevice(id: observation.id) {
      own
    } else if let adoptingRowID {
      try fetchDevice(id: adoptingRowID).flatMap { row in
        row.publicKey == observation.publicKey && Self.adoptsAsOwnRow(row, deviceID: observation.id) ? row : nil
      }
    } else {
      try fetchDevice(publicKey: observation.publicKey).flatMap { row in
        Self.adoptsAsOwnRow(row, deviceID: observation.id) ? row : nil
      }
    }
    guard try !isRadioErasePending(current?.radioID ?? observation.radioID, deviceID: current?.id ?? observation.id) else {
      throw ConnectionError.deviceNotFound
    }
    let merged: DeviceDTO = if let current {
      current.copy {
        $0.id = observation.id
        if let bluetoothPeripheralID {
          $0.connectionMethods = $0.connectionMethods.map { method in
            guard case let .bluetooth(_, displayName) = method else { return method }
            return .bluetooth(peripheralUUID: bluetoothPeripheralID, displayName: displayName)
          }
        }
        $0.publicKey = observation.publicKey
        $0.nodeName = observation.nodeName
        $0.firmwareVersion = observation.firmwareVersion
        $0.firmwareVersionString = observation.firmwareVersionString
        $0.manufacturerName = observation.manufacturerName
        $0.buildDate = observation.buildDate
        $0.maxContacts = observation.maxContacts
        $0.maxChannels = observation.maxChannels
        $0.frequency = observation.frequency
        $0.bandwidth = observation.bandwidth
        $0.spreadingFactor = observation.spreadingFactor
        $0.codingRate = observation.codingRate
        $0.txPower = observation.txPower
        $0.maxTxPower = observation.maxTxPower
        $0.latitude = observation.latitude
        $0.longitude = observation.longitude
        $0.blePin = observation.blePin
        $0.manualAddContacts = observation.manualAddContacts
        $0.autoAddConfig = observation.autoAddConfig
        $0.autoAddMaxHops = observation.autoAddMaxHops
        $0.multiAcks = observation.multiAcks
        $0.telemetryModeBase = observation.telemetryModeBase
        $0.telemetryModeLoc = observation.telemetryModeLoc
        $0.telemetryModeEnv = observation.telemetryModeEnv
        $0.advertLocationPolicy = observation.advertLocationPolicy
        $0.clientRepeat = observation.clientRepeat
        $0.pathHashMode = observation.pathHashMode
        if $0.ocvPreset == nil { $0.ocvPreset = observation.ocvPreset }
        if !observation.clientRepeat {
          $0.preRepeatFrequency = nil
          $0.preRepeatBandwidth = nil
          $0.preRepeatSpreadingFactor = nil
          $0.preRepeatCodingRate = nil
        }
      }
    } else {
      observation.copy {
        $0.isActive = false
        $0.connectionMethods = []
        $0.lastConnected = .distantPast
      }
    }
    try saveDevice(merged)
    if armsSwapGuard {
      try armSwapGuard(id: merged.id, previousDeviceID: previousDeviceID)
    }
    if let current, current.id != merged.id { try deleteDevice(id: current.id) }
    return try armsSwapGuard ? fetchDevice(id: merged.id) ?? merged : merged
  }

  /// Whether a row found by this radio's key is this radio's own earlier row, which the radio
  /// adopts: a ghost or backup shadow (no methods), a Wi-Fi-only row, or a legacy row whose
  /// Bluetooth link is this very peripheral. A row with a Bluetooth link to another peripheral
  /// is another radio carrying the identity (docs/RADIO_SWAP.md, R1).
  static func adoptsAsOwnRow(_ row: DeviceDTO, deviceID: UUID) -> Bool {
    !row.connectionMethods.contains { method in
      guard case let .bluetooth(peripheralUUID, _) = method else { return false }
      return peripheralUUID != deviceID
    }
  }

  /// Selects from a fresh row so a delayed connection cannot restore old preferences or endpoints.
  /// Selection stamps `lastConnected`, which makes this radio the identity's most recent.
  func selectConnectionDevice(id: UUID, method: ConnectionMethod?) throws -> DeviceDTO {
    guard let current = try fetchDevice(id: id) else { throw PersistenceStoreError.deviceNotFound }
    guard try !isRadioErasePending(current.radioID, deviceID: id) else { throw ConnectionError.deviceNotFound }
    let selected = current.copy {
      if let method {
        $0.connectionMethods.removeAll { $0.isBluetooth == method.isBluetooth }
        $0.connectionMethods.append(method)
      }
    }
    try saveDevice(selected)
    try setActiveDevice(id: id)
    return try fetchDevice(id: id) ?? selected
  }

  func clearActiveConnection() throws {
    for device in try modelContext.fetch(FetchDescriptor<Device>()) {
      device.isActive = false
    }
    try modelContext.save()
  }
}
