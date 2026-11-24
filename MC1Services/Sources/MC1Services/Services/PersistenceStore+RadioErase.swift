import Foundation
import SwiftData

extension PersistenceStore {
  public func captureReceiveScope(radioID: UUID, link: ReceiveScope.Lifetime) async throws -> ReceiveScope? {
    guard link.isCurrent, try !isRadioErasePending(radioID) else { return nil }
    if let partition = receivePartitions[radioID] {
      return ReceiveScope(radioID: radioID, link: link, partition: partition)
    }
    guard try fetchDevice(radioID: radioID) != nil else { return nil }
    try backfillTextRulesIdentities(radioID: radioID)
    let partition = ReceiveScope.Lifetime()
    receivePartitions[radioID] = partition
    return ReceiveScope(radioID: radioID, link: link, partition: partition)
  }

  func retireReceiveScope(radioID: UUID) {
    receivePartitions.removeValue(forKey: radioID)?.retire()
  }

  func fetchPendingRadioErases() throws -> [PendingRadioEraseDTO] {
    try modelContext.fetch(FetchDescriptor<PendingRadioErase>()).map(PendingRadioEraseDTO.init)
  }

  /// Whether a pending erase covers the whole identity, which blocks every radio carrying it.
  /// An erase of a radio whose identity another radio still carries is scoped to that radio
  /// (docs/RADIO_SWAP.md, R1): it never blocks the sibling's connect or receive.
  func isRadioErasePending(_ radioID: UUID) throws -> Bool {
    guard let target = try pendingRadioErase(radioID) else { return false }
    return try !isScopedToDevice(target)
  }

  /// Whether a pending erase blocks this radio: one covering the whole identity, or one aimed
  /// at this radio itself.
  func isRadioErasePending(_ radioID: UUID, deviceID: UUID) throws -> Bool {
    guard let target = try pendingRadioErase(radioID) else { return false }
    if target.deviceID == deviceID || target.pairingID == deviceID { return true }
    return try !isScopedToDevice(target)
  }

  /// An erase is scoped to its radio while another radio with a way to connect carries the
  /// identity. Once the last sibling goes, the erase covers the identity again.
  private func isScopedToDevice(_ target: PendingRadioErase) throws -> Bool {
    let radioID = target.radioID
    let deviceID = target.deviceID
    let rows = try modelContext.fetch(FetchDescriptor<Device>(predicate: #Predicate {
      $0.radioID == radioID && $0.id != deviceID
    }))
    return rows.contains { !$0.connectionMethods.isEmpty }
  }

  private func pendingEraseRadioIDSet() throws -> Set<UUID> {
    if let pendingEraseRadioIDs { return pendingEraseRadioIDs }
    let pending = try Set(fetchPendingRadioErases().map(\.radioID))
    pendingEraseRadioIDs = pending
    return pending
  }

  func beginRadioErase(_ device: DeviceDTO, isFactoryReset: Bool = false) throws -> PendingRadioEraseDTO {
    let radioID = device.radioID
    if let existing = try pendingRadioErase(radioID) {
      // One erase per identity at a time; another saved radio's pending erase is never taken over.
      let othersErase = try existing.deviceID != device.id && existing.pairingID != device.id
        && fetchDevice(id: existing.deviceID) != nil
      guard !othersErase else { throw PersistenceStoreError.deviceNotFound }
      return PendingRadioEraseDTO(existing)
    }
    guard try fetchDevice(id: device.id)?.radioID == radioID else {
      throw PersistenceStoreError.deviceNotFound
    }
    let target = PendingRadioEraseDTO(
      radioID: radioID,
      deviceID: device.id,
      pairingID: device.bluetoothPeripheralID ?? device.id,
      radioName: device.nodeName,
      isFactoryReset: isFactoryReset
    )
    try commitPendingRxLogEntries()
    do {
      modelContext.insert(PendingRadioErase(target))
      #if DEBUG
        try beginRadioEraseFaultInjection?()
      #endif
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    pendingEraseRadioIDs?.insert(radioID)
    // While a sibling carries the identity it keeps receiving into the shared history.
    if try isRadioErasePending(radioID) {
      retireReceiveScope(radioID: radioID)
    }
    return target
  }

  func cancelRadioErase(radioID: UUID) throws {
    guard let target = try pendingRadioErase(radioID) else { return }
    try commitPendingRxLogEntries()
    do {
      modelContext.delete(target)
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    pendingEraseRadioIDs?.remove(radioID)
  }

  /// Removes an erased radio's records. While another radio carries the identity only this
  /// radio's row goes and the shared history stays for the sibling; the last radio of an
  /// identity takes every row and all of its history with it.
  func completeRadioErase(radioID: UUID) throws {
    guard let target = try pendingRadioErase(radioID) else { return }
    if try isScopedToDevice(target) {
      try completeScopedRadioErase(target)
      return
    }
    try commitPendingRxLogEntries()
    do {
      try stageDeleteAllDeviceData(radioID: radioID)
      #if DEBUG
        try completeRadioEraseFaultInjection?()
      #endif
      let devices = try modelContext.fetch(FetchDescriptor<Device>(predicate: #Predicate { $0.radioID == radioID }))
      for device in devices {
        modelContext.delete(device)
      }
      modelContext.delete(target)
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    pendingEraseRadioIDs?.remove(radioID)
    publishRecentlyBlockedChange()
  }

  private func completeScopedRadioErase(_ target: PendingRadioErase) throws {
    let radioID = target.radioID
    let deviceID = target.deviceID
    let pairingID = target.pairingID
    do {
      let devices = try modelContext.fetch(FetchDescriptor<Device>(predicate: #Predicate {
        $0.radioID == radioID && ($0.id == deviceID || $0.id == pairingID)
      }))
      for device in devices {
        modelContext.delete(device)
      }
      modelContext.delete(target)
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    pendingEraseRadioIDs?.remove(radioID)
  }

  private func pendingRadioErase(_ radioID: UUID) throws -> PendingRadioErase? {
    guard try pendingEraseRadioIDSet().contains(radioID) else { return nil }
    var descriptor = FetchDescriptor<PendingRadioErase>(predicate: #Predicate { $0.radioID == radioID })
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  #if DEBUG
    func setRadioEraseFaults(
      begin: (@Sendable () throws -> Void)?,
      complete: (@Sendable () throws -> Void)?
    ) {
      beginRadioEraseFaultInjection = begin
      completeRadioEraseFaultInjection = complete
    }
  #endif
}
