import Foundation
import MeshCore

extension ConnectionManager {
  struct PreparedConnection: Sendable {
    let services: ServiceContainer
    let device: DeviceDTO
    let repeatRanges: [MeshCore.FrequencyRange]
  }

  func enqueueMetadata<T: Sendable>(
    _ operation: @escaping @MainActor @Sendable (PersistenceStore) async throws -> T
  ) -> Task<T, Error> {
    let predecessor = metadataCommitTask
    let store = persistenceStore
    let work = Task {
      await predecessor?.value
      return try await operation(store)
    }
    metadataCommitTask = Task { _ = await work.result }
    return work
  }

  func prepareConnection(
    _ request: ConnectionRequest,
    attempt: ConnectionAttempt,
    resource: ConnectionResource,
    selfInfo: SelfInfo,
    capabilities: DeviceCapabilities
  ) async throws -> PreparedConnection {
    attempt.identity.publicKey = selfInfo.publicKey
    try requireAttemptOwnership(request, attempt)
    let wifiAddress: (host: String, port: UInt16)? = if case let .wifi(host, port) = attempt.target {
      (host, port)
    } else {
      nil
    }
    var deviceID: UUID = if let bluetoothID = attempt.target.deviceID {
      bluetoothID
    } else {
      await wifiDeviceID(publicKey: selfInfo.publicKey, host: wifiAddress?.host, port: wifiAddress?.port)
    }
    try requireAttemptOwnership(request, attempt)
    let byID = try await persistenceStore.fetchDevice(id: deviceID)
    try requireAttemptOwnership(request, attempt)
    // Another radio's row found by key never stands in for this radio (docs/RADIO_SWAP.md, R1).
    let existing: DeviceDTO? = if let byID { byID } else {
      try await persistenceStore.fetchDevice(publicKey: selfInfo.publicKey).flatMap { row in
        PersistenceStore.adoptsAsOwnRow(row, deviceID: deviceID) ? row : nil
      }
    }
    attempt.identity.deviceID = existing?.id ?? deviceID
    attempt.identity.radioID = existing?.radioID
    try requireAttemptOwnership(request, attempt)
    let reconciled = try await reconcilePendingIdentity(
      request: request, attempt: attempt, deviceID: deviceID, selfInfo: selfInfo
    )
    try requireAttemptOwnership(request, attempt)
    if reconciled, attempt.target.transportType == .wifi {
      deviceID = await wifiDeviceID(publicKey: selfInfo.publicKey, host: wifiAddress?.host, port: wifiAddress?.port)
      try requireAttemptOwnership(request, attempt)
    }
    let canonicalExisting = try await persistenceStore.fetchDevice(id: deviceID)
    try requireAttemptOwnership(request, attempt)
    // A row found by key with a Bluetooth link to another peripheral is another radio carrying
    // this identity, not a leftover: this radio gets its own row beside it, sharing the history
    // (docs/RADIO_SWAP.md, R1). It lends the new row only what belongs to the identity, never
    // its connection methods or its battery curve. Anything else is this radio's own earlier
    // row and is adopted and removed at registration: a ghost or backup shadow (no links), a
    // Wi-Fi-only row, or a legacy row whose Bluetooth link is this very peripheral.
    let deviceByPublicKey: DeviceDTO? = if canonicalExisting == nil {
      try await persistenceStore.fetchDevice(publicKey: selfInfo.publicKey)
    } else {
      nil
    }
    try requireAttemptOwnership(request, attempt)
    let siblingRadio = deviceByPublicKey.flatMap { PersistenceStore.adoptsAsOwnRow($0, deviceID: deviceID) ? nil : $0 }
    let adoptedRow = siblingRadio == nil ? deviceByPublicKey : nil
    let effectiveExisting = canonicalExisting ?? siblingRadio.map(Self.identityTemplate(from:)) ?? adoptedRow ?? existing
    attempt.identity.deviceID = canonicalExisting?.id ?? adoptedRow?.id ?? deviceID
    attempt.identity.radioID = effectiveExisting?.radioID
    let config = await (try? resource.session.getAutoAddConfig()) ?? AutoAddConfig(bitmask: 0)
    try requireAttemptOwnership(request, attempt)
    let bluetoothPeripheralID = attempt.target.deviceID
    let preparedDeviceID = deviceID
    let initialRadioID = effectiveExisting?.radioID ?? UUID()
    // Every BLE recovery runs this again, so each step below is a no-op once the radio is
    // settled: the ghost is gone, the join is done, and selection made this radio the identity's
    // most recent, so nothing re-arms the guard.
    let registration = enqueueMetadata { store in
      var radioID = initialRadioID

      // A row already known by BLE id can still be the wrong home for this identity: "Forget
      // Device (keep data)" leaves a ghost row that holds the old key, radioID and every chat,
      // and a replacement radio paired *before* it received that key gets its own row and
      // radioID. Rejoin on connect as well as at key import, so the order stops mattering. The
      // predicate only ever matches an inactive row with no Bluetooth method, so a real saved
      // radio is never merged away.
      var rejoinedGhost = false
      if canonicalExisting != nil,
         let rejoinedRadioID = try? await store.reconcileGhostIdentity(
           currentDeviceID: preparedDeviceID, newPublicKey: selfInfo.publicKey
         ) {
        self.logger.info("Rejoined ghost identity on connect: radioID \(rejoinedRadioID)")
        radioID = rejoinedRadioID
        rejoinedGhost = true
      }

      // A radio this phone already knows can also be given a key another saved radio carries
      // (erased and reflashed, then handed the node's key back, in the app or with another
      // tool). It belongs with that radio's history, not the partition its old key had.
      var joinedSibling: DeviceDTO?
      if !rejoinedGhost, let canonicalExisting,
         let sibling = try? await store.fetchSiblingRadio(publicKey: selfInfo.publicKey, excluding: preparedDeviceID),
         sibling.radioID != canonicalExisting.radioID,
         let joinedRadioID = try? await store.joinSiblingIdentity(
           currentDeviceID: preparedDeviceID, newPublicKey: selfInfo.publicKey
         ) {
        self.logger.info(
          "Radio \(preparedDeviceID.uuidString.prefix(8)) now carries the key of \(sibling.id.uuidString.prefix(8)); joining radioID \(joinedRadioID)"
        )
        radioID = joinedRadioID
        joinedSibling = sibling
      }

      // This radio is taking on history it has never been synced against: a known key on a
      // radio this phone has no row for, a ghost rejoin, or a key that changed on a known radio.
      // Its contact table and channel slots say nothing about that history yet, so the first
      // syncs must not delete from it (docs/RADIO_SWAP.md, rule R2). A switch counts too: a radio
      // this phone knows, connecting while another radio was the last to carry the identity.
      // Its tables were last synced before the identity moved on, so it gets the same protection
      // and the same profile of where the identity is now. Read before selection stamps this
      // radio as the most recent.
      let lastRadioForIdentity = try? await store.fetchDevice(radioID: radioID)
      let switchedFromRadio = lastRadioForIdentity.flatMap { row in
        row.id == preparedDeviceID || row.id == adoptedRow?.id ? nil : row
      }
      let tookOnIdentity = rejoinedGhost
        || joinedSibling != nil
        || deviceByPublicKey != nil
        || switchedFromRadio != nil
        || (canonicalExisting.map { $0.publicKey != selfInfo.publicKey } ?? false)
      let previousID = rejoinedGhost ? nil : (switchedFromRadio ?? joinedSibling ?? deviceByPublicKey)?.id

      let observation = DeviceDTO(from: self.createDevice(
        deviceID: preparedDeviceID, radioID: radioID, selfInfo: selfInfo,
        capabilities: capabilities, autoAddConfig: config, existingDevice: effectiveExisting,
        tookOnIdentity: tookOnIdentity
      ))
      // Arms before any sync runs, in this same job. A failure fails the connect rather than
      // letting the first full sync prune against a table that never held this history.
      let device = try await store.registerConnectionDevice(
        observation, bluetoothPeripheralID: bluetoothPeripheralID, adoptingRowID: adoptedRow?.id,
        armsSwapGuard: tookOnIdentity, previousDeviceID: previousID
      )
      if tookOnIdentity {
        self.logger.notice(
          "Radio swap guard armed: radio \(preparedDeviceID.uuidString.prefix(8)) took on radioID \(device.radioID)"
        )
      }
      try await store.backfillTextRulesIdentities(radioID: device.radioID)
      return device
    }
    let device = try await registration.value
    attempt.identity = ConnectionDeviceIdentity(device)
    try requireAttemptOwnership(request, attempt)
    if membershipBatch?.radioID != device.radioID { membershipBatch = nil }
    let ranges = await capabilities.clientRepeat ? ((try? resource.session.getRepeatFreq()) ?? []) : []
    try requireAttemptOwnership(request, attempt)
    let container = try await buildServiceContainer(
      request, attempt: attempt, resource: resource, device: device
    )
    return PreparedConnection(services: container, device: device, repeatRanges: ranges)
  }

  func buildServiceContainer(
    _ request: ConnectionRequest,
    attempt: ConnectionAttempt,
    resource: ConnectionResource,
    device: DeviceDTO
  ) async throws -> ServiceContainer {
    let wifiState = radioWiFiState(for: device.radioID)
    wifiState.openAdmission()
    let container = ServiceContainer(
      session: resource.session, dataStore: persistenceStore, radioID: device.radioID,
      appStateProvider: appStateProvider, phoneLocationProvider: phoneLocationProvider,
      connectionStateEvents: connectionStateEvents,
      initialConnectionState: .connected, radioWiFiState: wifiState,
      notificationService: notificationServiceForTesting(), ackEvents: attempt.ackEvents,
      textRulesPreference: { [weak self] in await self?.textRulesPreference }
    )
    attempt.preparedServices = container
    await wireCleanChannelSyncCallback(on: container)
    try requireAttemptOwnership(request, attempt)
    await container.nodeConfigService.setIdentityImportHandler { [weak self, weak container] key in
      guard let self, let container else { throw CancellationError() }
      return try await self.importIdentity(key, expectedServices: container, deviceID: device.id)
    }
    try requireAttemptOwnership(request, attempt)
    try await container.warmUp()
    try requireAttemptOwnership(request, attempt)
    return container
  }

  func commitConnection(
    _ request: ConnectionRequest,
    attempt: ConnectionAttempt,
    link: ConnectionLink,
    repeatRanges: [MeshCore.FrequencyRange]
  ) async throws {
    try requireAttemptOwnership(request, attempt)
    let id = link.device.id
    let method = link.target.method
    let selection = enqueueMetadata { store in
      #if DEBUG
        try await self.testConnectionSelectionHandler?(request.id)
      #endif
      return try await store.selectConnectionDevice(id: id, method: method)
    }
    link.device = try await selection.value
    try requireAttemptOwnership(request, attempt)
    persistConnection(deviceID: id, radioID: link.device.radioID, deviceName: link.device.nodeName)
    try publish(link, repeatRanges: repeatRanges)
    request.committedGeneration = link.generation
    attempt.resource = nil
    attempt.preparedServices = nil
  }

  // MARK: - Session Helpers

  private static let sessionInitializationTimeout: Duration = .seconds(10)

  private static let floodScopeBaselineMinimumFirmwareVersion: UInt8 = 8

  /// Starts a session and queries device capabilities.
  func initializeSession(
    _ session: MeshCoreSession,
    attempt: ConnectionAttempt? = nil
  ) async throws -> (SelfInfo, DeviceCapabilities) {
    if let attempt {
      attempt.ackEvents = await session.events(filter: .anyAcknowledgement)
    }
    do {
      try await withTimeout(Self.sessionInitializationTimeout, operationName: "session.start") {
        try await session.start(disconnectTransportOnFailure: false)
      }
    } catch {
      logger.warning("[BLE] session.start() timed out or failed: \(error.localizedDescription)")
      throw error
    }

    guard let selfInfo = await session.currentSelfInfo else {
      logger.warning("[BLE] selfInfo is nil after session.start()")
      throw ConnectionError.initializationFailed("Failed to get device self info")
    }
    if let attempt {
      attempt.identity.publicKey = selfInfo.publicKey
      guard let request = desiredRequest else { throw CancellationError() }
      try requireAttemptOwnership(request, attempt)
    }
    let capabilities: DeviceCapabilities
    do {
      capabilities = try await withTimeout(Self.sessionInitializationTimeout, operationName: "queryDevice") {
        try await session.queryDevice()
      }
    } catch {
      logger.warning("[BLE] queryDevice() timed out or failed: \(error.localizedDescription)")
      throw error
    }
    if let attempt {
      guard let request = desiredRequest else { throw CancellationError() }
      try requireAttemptOwnership(request, attempt)
    }
    // Clear an override left by a previous connection before publishing the session.
    if capabilities.firmwareVersion >= Self.floodScopeBaselineMinimumFirmwareVersion {
      do {
        try await withTimeout(Self.sessionInitializationTimeout, operationName: "floodScopeBaseline") {
          try await session.setFloodScope(scopeKey: FloodScope.disabled.scopeKey())
        }
      } catch {
        logger.warning("[BLE] flood scope baseline timed out or failed: \(error.localizedDescription)")
        throw error
      }
      if let attempt {
        guard let request = desiredRequest else { throw CancellationError() }
        try requireAttemptOwnership(request, attempt)
      }
    }
    return (selfInfo, capabilities)
  }

  // MARK: - Service Wiring Helpers

  /// Records clean channel sync completion for the next connection's sync policy.
  func wireCleanChannelSyncCallback(on services: ServiceContainer) async {
    await services.syncCoordinator.setCleanChannelSyncCallback { [weak self, weak services] radioID in
      await MainActor.run {
        guard let self, let services, self.services === services,
              self.connectedDevice?.radioID == radioID else { return }
        self.lastCleanChannelSync = (radioID: radioID, completedAt: Date())
      }
    }
    await services.syncCoordinator.setChannelSyncAttemptedCallback { [weak self, weak services] radioID in
      await MainActor.run {
        guard let self, let services, self.services === services,
              self.connectedDevice?.radioID == radioID else { return }
        self.lastAttemptedChannelSync = (radioID: radioID, attemptedAt: Date())
      }
    }
  }

  /// What a new radio row borrows from another radio carrying the same identity: the
  /// partition and the identity-level settings. Connection methods, the battery curve and the
  /// pre-repeat radio settings belong to that radio's hardware, and the watermark to its table.
  nonisolated static func identityTemplate(from sibling: DeviceDTO) -> DeviceDTO {
    sibling.copy {
      $0.connectionMethods = []
      $0.ocvPreset = nil
      $0.customOCVArrayString = nil
      $0.preRepeatFrequency = nil
      $0.preRepeatBandwidth = nil
      $0.preRepeatSpreadingFactor = nil
      $0.preRepeatCodingRate = nil
      $0.lastContactSync = 0
    }
  }

  /// Uses the same resolved Radio ID as `ServiceContainer` so persisted Device and
  /// `PendingSend` rows share a partition, including on first pair.
  ///
  /// `tookOnIdentity` drops the contact watermark: it is the previous radio's RTC `lastmod`
  /// and means nothing against the table of a radio that has just taken on this identity.
  func createDevice(
    deviceID: UUID,
    radioID: UUID,
    selfInfo: MeshCore.SelfInfo,
    capabilities: MeshCore.DeviceCapabilities,
    autoAddConfig: MeshCore.AutoAddConfig,
    existingDevice: DeviceDTO? = nil,
    connectionMethods: [ConnectionMethod] = [],
    tookOnIdentity: Bool = false
  ) -> Device {
    // Merge new connection methods with existing ones, replacing by transport type
    var mergedMethods = ConnectionMethod.canonicalized(existingDevice?.connectionMethods ?? [])
    for method in connectionMethods {
      if method.isWiFi {
        mergedMethods.removeAll { $0.isWiFi }
      } else if method.isBluetooth {
        mergedMethods.removeAll { $0.isBluetooth }
      }
      mergedMethods.append(method)
    }

    let device = Device(
      id: deviceID,
      radioID: radioID,
      publicKey: selfInfo.publicKey,
      nodeName: selfInfo.name,
      firmwareVersion: capabilities.firmwareVersion,
      firmwareVersionString: capabilities.version,
      manufacturerName: capabilities.model,
      buildDate: capabilities.firmwareBuild,
      maxContacts: UInt16(capabilities.maxContacts),
      maxChannels: UInt8(min(capabilities.maxChannels, 255)),
      frequency: UInt32(selfInfo.radioFrequency * 1000), // Convert MHz to kHz
      bandwidth: UInt32(selfInfo.radioBandwidth * 1000), // Convert kHz to Hz
      spreadingFactor: selfInfo.radioSpreadingFactor,
      codingRate: selfInfo.radioCodingRate,
      txPower: selfInfo.txPower,
      maxTxPower: selfInfo.maxTxPower,
      latitude: selfInfo.latitude,
      longitude: selfInfo.longitude,
      blePin: capabilities.blePin,
      clientRepeat: capabilities.clientRepeat,
      pathHashMode: capabilities.pathHashMode,
      defaultFloodScopeName: existingDevice?.defaultFloodScopeName,
      preRepeatFrequency: existingDevice?.preRepeatFrequency,
      preRepeatBandwidth: existingDevice?.preRepeatBandwidth,
      preRepeatSpreadingFactor: existingDevice?.preRepeatSpreadingFactor,
      preRepeatCodingRate: existingDevice?.preRepeatCodingRate,
      manualAddContacts: selfInfo.manualAddContacts,
      autoAddConfig: autoAddConfig.bitmask,
      autoAddMaxHops: autoAddConfig.maxHops,
      multiAcks: selfInfo.multiAcks,
      telemetryModeBase: selfInfo.telemetryModeBase,
      telemetryModeLoc: selfInfo.telemetryModeLocation,
      telemetryModeEnv: selfInfo.telemetryModeEnvironment,
      advertLocationPolicy: selfInfo.advertisementLocationPolicy,
      lastConnected: Date(),
      lastContactSync: tookOnIdentity ? 0 : existingDevice?.lastContactSync ?? 0,
      isActive: true,
      ocvPreset: existingDevice?.ocvPreset
        ?? OCVPreset.preset(forManufacturer: capabilities.model)?.rawValue,
      appliedRadioPresetID: existingDevice?.appliedRadioPresetID,
      customOCVArrayString: existingDevice?.customOCVArrayString,
      connectionMethods: mergedMethods,
      knownRegions: existingDevice?.knownRegions ?? []
    )

    // If repeat mode was disabled externally, clear orphaned pre-repeat settings
    if !capabilities.clientRepeat, existingDevice?.preRepeatFrequency != nil {
      device.preRepeatFrequency = nil
      device.preRepeatBandwidth = nil
      device.preRepeatSpreadingFactor = nil
      device.preRepeatCodingRate = nil
    }

    return device
  }
}
