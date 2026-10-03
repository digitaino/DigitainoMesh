import Foundation
import SwiftData

public extension PersistenceStore {
  // MARK: - Device Operations

  /// Fetch all devices
  func fetchDevices() throws -> [DeviceDTO] {
    let descriptor = FetchDescriptor<Device>(
      sortBy: [SortDescriptor(\Device.lastConnected, order: .reverse)]
    )
    let devices = try modelContext.fetch(descriptor)
    return devices.map { DeviceDTO(from: $0) }
  }

  /// Fetch a device by ID
  func fetchDevice(id: UUID) throws -> DeviceDTO? {
    let targetID = id
    let predicate = #Predicate<Device> { device in
      device.id == targetID
    }
    var descriptor = FetchDescriptor(predicate: predicate)
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first.map { DeviceDTO(from: $0) }
  }

  /// The radio that most recently carried this identity. One identity can be on several
  /// radios, each with its own row sharing the `radioID` (docs/RADIO_SWAP.md, R1); the
  /// connected radio is always the most recent, since every connect stamps `lastConnected`.
  func fetchDevice(radioID: UUID) throws -> DeviceDTO? {
    try primaryDeviceModel(radioID: radioID).map { DeviceDTO(from: $0) }
  }

  /// Every radio row carrying this identity, most recently connected first.
  func fetchDevices(radioID: UUID) throws -> [DeviceDTO] {
    try deviceModels(radioID: radioID).map { DeviceDTO(from: $0) }
  }

  /// Fetch a device by public key: the most recently connected row carrying it.
  func fetchDevice(publicKey: Data) throws -> DeviceDTO? {
    let targetKey = publicKey
    let predicate = #Predicate<Device> { device in
      device.publicKey == targetKey
    }
    var descriptor = FetchDescriptor(
      predicate: predicate,
      sortBy: [SortDescriptor(\Device.lastConnected, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first.map { DeviceDTO(from: $0) }
  }

  private func deviceModels(radioID: UUID) throws -> [Device] {
    let targetRadioID = radioID
    let predicate = #Predicate<Device> { device in
      device.radioID == targetRadioID
    }
    return try modelContext.fetch(FetchDescriptor(
      predicate: predicate,
      sortBy: [SortDescriptor(\Device.lastConnected, order: .reverse)]
    ))
  }

  private func primaryDeviceModel(radioID: UUID) throws -> Device? {
    let targetRadioID = radioID
    let predicate = #Predicate<Device> { device in
      device.radioID == targetRadioID
    }
    var descriptor = FetchDescriptor(
      predicate: predicate,
      sortBy: [SortDescriptor(\Device.lastConnected, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  /// Fetch the active device
  func fetchActiveDevice() throws -> DeviceDTO? {
    let predicate = #Predicate<Device> { device in
      device.isActive == true
    }
    var descriptor = FetchDescriptor(predicate: predicate)
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first.map { DeviceDTO(from: $0) }
  }

  /// Save or update a device
  func saveDevice(_ dto: DeviceDTO) throws {
    let targetID = dto.id
    let predicate = #Predicate<Device> { device in
      device.id == targetID
    }
    var descriptor = FetchDescriptor(predicate: predicate)
    descriptor.fetchLimit = 1

    if let existing = try modelContext.fetch(descriptor).first {
      existing.apply(dto)
    } else {
      modelContext.insert(Device(dto: dto))
    }

    try modelContext.save()
  }

  /// Set a device as active (deactivates others)
  func setActiveDevice(id: UUID) throws {
    // Deactivate all devices first
    let allDevices = try modelContext.fetch(FetchDescriptor<Device>())
    for device in allDevices {
      device.isActive = false
    }

    // Activate the specified device
    let targetID = id
    let predicate = #Predicate<Device> { device in
      device.id == targetID
    }
    var descriptor = FetchDescriptor(predicate: predicate)
    descriptor.fetchLimit = 1

    if let device = try modelContext.fetch(descriptor).first {
      device.isActive = true
      device.lastConnected = Date()
    }

    try modelContext.save()
  }

  /// Update the lastContactSync timestamp for a device.
  /// Used to track incremental sync progress.
  ///
  /// The stamp is radio-RTC `max(contact.lastmod)`, not phone time. Store it
  /// verbatim. Firmware filters with `contact.lastmod > since`; a phone-clock
  /// upper bound can pin the watermark below every lastmod when the radio RTC
  /// leads the phone, so every delta re-matches the full table and never
  /// converges.
  ///
  /// The watermark belongs to one radio's table, so it is written to the radio that most
  /// recently carried the identity: the one just synced.
  func updateDeviceLastContactSync(radioID: UUID, timestamp: UInt32) throws {
    guard let device = try primaryDeviceModel(radioID: radioID) else {
      throw PersistenceStoreError.deviceNotFound
    }
    device.lastContactSync = timestamp
    try modelContext.save()
  }

  // MARK: - Swap Guard

  /// Arms every part of the ``SwapGuard`` on a radio that has just taken on an identity's
  /// history, clears its contact watermark, and stores the ``IdentityProfile`` it should take on.
  /// The watermark is the previous radio's RTC `lastmod` and means nothing against this radio's
  /// table, so the next contact sync must read the whole table.
  ///
  /// The profile comes from `previousDeviceID`'s row (the radio the identity was on) and the
  /// channel rows, read before any sync against the new radio has touched them. When that row's
  /// own swap was never settled, its rows may already mix two radios' channels, so its stored
  /// profile carries forward instead. With no `previousDeviceID` the row itself is the previous
  /// state (a key change on known hardware).
  func armSwapGuard(id: UUID, previousDeviceID: UUID? = nil) throws {
    guard let device = try fetchDeviceModel(id: id) else {
      throw PersistenceStoreError.deviceNotFound
    }
    let previous = try previousDeviceID.flatMap { try fetchDeviceModel(id: $0) } ?? device
    device.swapProfile = try swapProfileData(inheritingFrom: previous)
    device.swapGuard = SwapGuard.all.rawValue
    device.lastContactSync = 0
    try modelContext.save()
  }

  func fetchSwapProfile(radioID: UUID) throws -> IdentityProfile? {
    guard let data = try primaryDeviceModel(radioID: radioID)?.swapProfile else { return nil }
    return try? JSONDecoder().decode(IdentityProfile.self, from: data)
  }

  /// The profile a radio taking over from `previous` should carry: `previous`'s own stored
  /// profile while its swap is unsettled, otherwise a fresh capture of `previous` and the
  /// channel rows of its partition.
  private func swapProfileData(inheritingFrom previous: Device) throws -> Data? {
    if previous.swapGuard != 0, let carried = previous.swapProfile {
      return carried
    }
    let profile = IdentityProfile.capture(
      device: DeviceDTO(from: previous),
      channels: try fetchChannels(radioID: previous.radioID)
    )
    return try JSONEncoder().encode(profile)
  }

  private func fetchDeviceModel(id: UUID) throws -> Device? {
    let targetID = id
    let predicate = #Predicate<Device> { device in
      device.id == targetID
    }
    var descriptor = FetchDescriptor(predicate: predicate)
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  func fetchSwapGuard(radioID: UUID) throws -> SwapGuard {
    guard let device = try primaryDeviceModel(radioID: radioID) else { return [] }
    return SwapGuard(rawValue: device.swapGuard)
  }

  func releaseSwapGuard(radioID: UUID, _ parts: SwapGuard) throws {
    guard let device = try primaryDeviceModel(radioID: radioID) else { return }

    let remaining = SwapGuard(rawValue: device.swapGuard).subtracting(parts)
    guard remaining.rawValue != device.swapGuard else { return }
    device.swapGuard = remaining.rawValue
    try modelContext.save()
  }

  /// Adds a known region if not already present. Regions belong to the identity, so every
  /// radio row carrying it gets the region.
  func addDeviceKnownRegion(radioID: UUID, region: String) throws {
    let devices = try deviceModels(radioID: radioID)
    guard !devices.isEmpty else {
      throw PersistenceStoreError.deviceNotFound
    }

    var changed = false
    for device in devices where !device.knownRegions.contains(region) {
      device.knownRegions.append(region)
      changed = true
    }
    guard changed else { return }
    try modelContext.save()
  }

  /// Removes a known region from a device and resets channels that had been scoped
  /// to the removed region back to ``ChannelFloodScope/inherit``.
  func removeDeviceKnownRegion(radioID: UUID, region: String) throws {
    let targetRadioID = radioID
    let devices = try deviceModels(radioID: radioID)
    guard !devices.isEmpty else {
      throw PersistenceStoreError.deviceNotFound
    }

    for device in devices {
      device.knownRegions.removeAll { $0 == region }
    }

    let channelPredicate = #Predicate<Channel> { $0.radioID == targetRadioID }
    let channels = try modelContext.fetch(FetchDescriptor<Channel>(predicate: channelPredicate))
    for channel in channels where channel.floodScope == .region(region) {
      channel.floodScope = .inherit
    }

    try modelContext.save()
  }

  /// Delete all data associated with a device.
  /// Deletes: reactions, room messages, remote node sessions, blocked channel senders,
  /// RX log entries, discovered nodes, contacts, messages, channels, and saved trace paths.
  /// Does NOT delete the Device record itself.
  func deleteDeviceData(id: UUID) throws {
    try _deleteAllDeviceData(id: id)
    try modelContext.save()
  }

  /// Delete a device record only. Does NOT delete associated data.
  func deleteDevice(id: UUID) throws {
    let targetID = id
    let devicePredicate = #Predicate<Device> { device in
      device.id == targetID
    }
    if let device = try modelContext.fetch(FetchDescriptor(predicate: devicePredicate)).first {
      modelContext.delete(device)
    }
    try modelContext.save()
  }

  /// Demotes a device row to a "ghost": preserves `publicKey` and `radioID` so the
  /// publicKey ↔ radioID bridge survives, but assigns a fresh `id`, clears `isActive`,
  /// and strips ALL connection methods so the row is hidden from
  /// `DeviceSelectionSheet`. Used in place of `deleteDevice(id:)` whenever the user
  /// removes a device but keeps their data — the next time the same physical radio
  /// is re-paired (or its keypair is restored via config import), reconciliation can
  /// rejoin the orphaned children to the new pairing.
  ///
  /// Distinct from `DeviceDTO.cleanedForImport()`, which strips only Bluetooth and
  /// keeps WiFi (so a `.mc1backup`-restored radio stays reachable over WiFi without
  /// re-pairing). Demote-on-remove is the user saying "make this go away"; preserving
  /// any connection method would leave the row showing in `DeviceSelectionSheet`
  /// because `DeviceSelectionFilter.isConnectable` matches any WiFi method.
  func demoteDeviceToGhost(id: UUID) throws {
    let targetID = id
    let predicate = #Predicate<Device> { device in
      device.id == targetID
    }
    var descriptor = FetchDescriptor(predicate: predicate)
    descriptor.fetchLimit = 1
    guard let existing = try modelContext.fetch(descriptor).first else { return }

    let ghostDTO = DeviceDTO(from: existing).copy {
      $0.id = UUID()
      $0.isActive = false
      $0.connectionMethods = []
    }

    modelContext.delete(existing)
    let ghost = Device(dto: ghostDTO)
    // Model-only swap state is not in the DTO; carry it so an unsettled swap survives a
    // forget-and-re-pair.
    ghost.swapGuard = existing.swapGuard
    ghost.swapProfile = existing.swapProfile
    modelContext.insert(ghost)
    try modelContext.save()
  }

  /// The other radios carrying this radio's identity: rows sharing its `radioID` that still
  /// have a way to connect (ghosts and backup shadows have none).
  func otherRadios(sharingIdentityWith id: UUID) throws -> [DeviceDTO] {
    guard let device = try fetchDeviceModel(id: id) else { return [] }
    return try deviceModels(radioID: device.radioID)
      .filter { $0.id != id && !$0.connectionMethods.isEmpty }
      .map { DeviceDTO(from: $0) }
  }

  /// Removes one radio's row while keeping its history. With another radio still carrying
  /// the identity, the history stays with that radio and the row simply goes. Otherwise the
  /// row becomes a ghost, keeping the key-to-history bridge for a later re-pair.
  /// - Returns: whether another radio still carries the identity.
  @discardableResult
  func forgetRadio(id: UUID) throws -> Bool {
    guard let device = try fetchDeviceModel(id: id) else { return false }
    guard try !otherRadios(sharingIdentityWith: id).isEmpty else {
      try demoteDeviceToGhost(id: id)
      return false
    }
    modelContext.delete(device)
    try modelContext.save()
    return true
  }

  /// Delete a device and all its associated data atomically (single save).
  /// Use for factory reset and explicit "delete all data" user action.
  func deleteDeviceAndData(id: UUID) throws {
    try _deleteAllDeviceData(id: id)

    let targetID = id
    let devicePredicate = #Predicate<Device> { device in
      device.id == targetID
    }
    if let device = try modelContext.fetch(FetchDescriptor(predicate: devicePredicate)).first {
      modelContext.delete(device)
    }
    try modelContext.save()
  }

  /// Looks for a ghost `Device` row whose `publicKey` matches `newPublicKey`
  /// (left by a prior remove-from-MC1, or a `.mc1backup` shadow row). If found,
  /// rewrites the current device's `radioID` and `publicKey` to the ghost's values
  /// and deletes the ghost. All child rows (Contact, Message, Channel, etc.) keyed
  /// by the ghost's `radioID` are now linked to the current device for free.
  ///
  /// The predicate filters by `isActive == false`, but that alone isn't a ghost
  /// marker — `setActiveDevice(id:)` deactivates every other Device row, so a
  /// saved-but-not-currently-active real device also has `isActive == false`. To
  /// avoid ever deleting a real device row (defense against an upstream publicKey-dedup
  /// violation), we additionally require the matched row to have **no Bluetooth
  /// connection methods**: demoted ghosts strip all methods, `.mc1backup` shadow rows
  /// strip BLE via `cleanedForImport()`, and a real saved device retains its BLE
  /// `ConnectionMethod`. SwiftData `#Predicate` cannot reliably introspect array
  /// elements, so the BLE check happens post-fetch in code.
  ///
  /// - Parameters:
  ///   - currentDeviceID: The BLE peripheral UUID of the live, currently-paired device.
  ///   - newPublicKey: The radio's `selfInfo.publicKey` after `importPrivateKey`.
  /// - Returns: The new `radioID` if reconciliation occurred, otherwise `nil`.
  ///
  /// A rejoin arms the current row's ``SwapGuard``, clears its contact watermark, and stores
  /// the ghost's ``IdentityProfile`` on it.
  func reconcileGhostIdentity(currentDeviceID: UUID, newPublicKey: Data) throws -> UUID? {
    let lookupKey = newPublicKey
    let lookupID = currentDeviceID
    let ghostPredicate = #Predicate<Device> { device in
      device.publicKey == lookupKey && device.id != lookupID && device.isActive == false
    }
    var ghostDescriptor = FetchDescriptor(predicate: ghostPredicate)
    ghostDescriptor.fetchLimit = 1
    guard let ghost = try modelContext.fetch(ghostDescriptor).first else { return nil }

    // Defensive: refuse to delete a row that still carries a Bluetooth method.
    // It's a real saved-but-inactive device (per `setActiveDevice` semantics),
    // not a ghost. Returning nil here is safe — no reconciliation, no data loss.
    if ghost.connectionMethods.contains(where: \.isBluetooth) {
      return nil
    }

    let currentPredicate = #Predicate<Device> { device in
      device.id == lookupID
    }
    var currentDescriptor = FetchDescriptor(predicate: currentPredicate)
    currentDescriptor.fetchLimit = 1
    guard let current = try modelContext.fetch(currentDescriptor).first else { return nil }

    let newRadioID = ghost.radioID
    current.radioID = newRadioID
    current.publicKey = newPublicKey
    // This radio's tables were never synced against the ghost's history: hold back the
    // deletions a full sync would make, drop the watermark of the partition it left, and
    // keep the ghost's settings and channel layout for "Copy to This Radio".
    current.swapProfile = try swapProfileData(inheritingFrom: ghost)
    current.swapGuard = SwapGuard.all.rawValue
    current.lastContactSync = 0
    for method in ghost.connectionMethods where !method.isBluetooth {
      if !current.connectionMethods.contains(where: { $0.id == method.id }) {
        current.connectionMethods.append(method)
      }
    }

    modelContext.delete(ghost)
    try modelContext.save()
    return newRadioID
  }

  /// Stages deletion of all device-scoped data without calling save().
  /// Used by both `deleteDeviceData` and `deleteDeviceAndData` to compose
  /// operations while maintaining single-save atomicity.
  private func _deleteAllDeviceData(id: UUID) throws {
    // Look up the Device's radioID since child records are keyed by radioID, not BLE UUID
    let targetBLEID = id
    let devicePredicate = #Predicate<Device> { device in
      device.id == targetBLEID
    }
    guard let device = try modelContext.fetch(FetchDescriptor(predicate: devicePredicate)).first else {
      return
    }
    let targetRadioID = device.radioID

    // Delete reactions (references messages via messageID)
    let reactionPredicate = #Predicate<Reaction> { reaction in
      reaction.radioID == targetRadioID
    }
    let reactions = try modelContext.fetch(FetchDescriptor(predicate: reactionPredicate))
    for reaction in reactions {
      modelContext.delete(reaction)
    }

    // Delete room messages via their sessions, then clean up NodeStatusSnapshots
    let sessionPredicate = #Predicate<RemoteNodeSession> { session in
      session.radioID == targetRadioID
    }
    let sessions = try modelContext.fetch(FetchDescriptor(predicate: sessionPredicate))

    // Collect publicKeys before deleting sessions for NodeStatusSnapshot cleanup
    let sessionPublicKeys = sessions.map(\.publicKey)

    for session in sessions {
      let sessionID = session.id
      let roomMessagePredicate = #Predicate<RoomMessage> { message in
        message.sessionID == sessionID
      }
      let roomMessages = try modelContext.fetch(FetchDescriptor(predicate: roomMessagePredicate))
      for roomMessage in roomMessages {
        modelContext.delete(roomMessage)
      }
      modelContext.delete(session)
    }

    // Delete NodeStatusSnapshots only when no other session references that node
    for pubKey in sessionPublicKeys {
      let remainingPredicate = #Predicate<RemoteNodeSession> { session in
        session.publicKey == pubKey
      }
      let remainingCount = try modelContext.fetchCount(FetchDescriptor(predicate: remainingPredicate))
      guard remainingCount == 0 else { continue }

      let snapshotPredicate = #Predicate<NodeStatusSnapshot> { snapshot in
        snapshot.nodePublicKey == pubKey
      }
      let snapshots = try modelContext.fetch(FetchDescriptor(predicate: snapshotPredicate))
      for snapshot in snapshots {
        modelContext.delete(snapshot)
      }
    }

    // Delete blocked channel senders
    let blockedPredicate = #Predicate<BlockedChannelSender> { blocked in
      blocked.radioID == targetRadioID
    }
    let blockedSenders = try modelContext.fetch(FetchDescriptor(predicate: blockedPredicate))
    for blocked in blockedSenders {
      modelContext.delete(blocked)
    }

    // Delete RX log entries; drop the count cache so the next save re-seeds
    // from disk instead of pruning against a stale pre-delete count.
    let rxLogPredicate = #Predicate<RxLogEntry> { entry in
      entry.radioID == targetRadioID
    }
    let rxLogEntries = try modelContext.fetch(FetchDescriptor(predicate: rxLogPredicate))
    for entry in rxLogEntries {
      modelContext.delete(entry)
    }
    rxLogEntryCountsByDevice[targetRadioID] = nil

    // Delete discovered nodes
    let discoveredPredicate = #Predicate<DiscoveredNode> { node in
      node.radioID == targetRadioID
    }
    let discoveredNodes = try modelContext.fetch(FetchDescriptor(predicate: discoveredPredicate))
    for node in discoveredNodes {
      modelContext.delete(node)
    }

    // Delete contacts
    let contactPredicate = #Predicate<Contact> { contact in
      contact.radioID == targetRadioID
    }
    let contacts = try modelContext.fetch(FetchDescriptor(predicate: contactPredicate))
    for contact in contacts {
      modelContext.delete(contact)
    }

    // Delete messages — cascade PendingSend and MessageRepeat first.
    // Bulk `delete(model:where:)` bypasses `@Relationship(deleteRule: .cascade)`,
    // and `purgeOrphanPendingSends` cannot reap radio-scoped PendingSends
    // while the Device row survives (deleteDeviceData preserves it).
    let messagePredicate = #Predicate<Message> { message in
      message.radioID == targetRadioID
    }
    let messages = try modelContext.fetch(FetchDescriptor(predicate: messagePredicate))
    let messageIDs = messages.map(\.id)
    try _deletePendingSendsForMessageIDsWithoutSaving(messageIDs: messageIDs)
    if !messageIDs.isEmpty {
      let chunkSize = 500
      for start in stride(from: 0, to: messageIDs.count, by: chunkSize) {
        let chunk = Array(messageIDs[start..<min(start + chunkSize, messageIDs.count)])
        try modelContext.delete(model: MessageRepeat.self, where: #Predicate {
          chunk.contains($0.messageID)
        })
      }
    }
    // Defensive: reap PendingSend rows for this radio that have no matching
    // Message (e.g. from a same-millisecond race between deleteMessage and
    // upsertPendingSend, or historical bugs). The messageIDs cascade above
    // does not see them; purgeOrphanPendingSends does not see them while
    // the Device row survives.
    try modelContext.delete(model: PendingSend.self, where: #Predicate<PendingSend> { row in
      row.radioID == targetRadioID
    })
    // Delete Message rows with a store-level batch, not per-object: a per-object delete
    // enters cascade propagation over Message.repeats and traps resolving the
    // already-batch-deleted MessageRepeat rows.
    try modelContext.delete(model: Message.self, where: messagePredicate)

    // Delete channels
    let channelPredicate = #Predicate<Channel> { channel in
      channel.radioID == targetRadioID
    }
    let channels = try modelContext.fetch(FetchDescriptor(predicate: channelPredicate))
    for channel in channels {
      modelContext.delete(channel)
    }

    // Delete saved trace paths
    let pathPredicate = #Predicate<SavedTracePath> { path in
      path.radioID == targetRadioID
    }
    let paths = try modelContext.fetch(FetchDescriptor(predicate: pathPredicate))
    for path in paths {
      modelContext.delete(path)
    }
  }
}
