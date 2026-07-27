import Foundation
import MC1Services

// MARK: - Service Wiring Helpers

extension AppState {
  /// Consume the sync coordinator's data event stream for SwiftUI observation
  /// (actors don't participate in SwiftUI's observation system).
  /// Message events are ignored here; `MessageEventDispatcher` owns them.
  /// Re-subscribes per connection because `ServiceContainer` is rebuilt.
  func wireSyncDataEvents(services: ServiceContainer) {
    syncDataEventsTask?.cancel()
    let events = services.syncCoordinator.dataEvents()
    syncDataEventsTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case .contactsChanged:
          contactsVersion += 1
          // A newly added repeater contact should name its signal-bars row now, not
          // whenever the directory's cache window happens to lapse.
          await services.signalBarsNodeDirectory.invalidate()
        case .conversationsChanged:
          refreshConversations()
        case .directMessageReceived, .channelMessageReceived, .roomMessageReceived, .reactionReceived:
          break
        }
      }
    }
  }

  /// Seed the adaptive power service from this device's stored preferences.
  ///
  /// The service lives on `ServiceContainer` and is rebuilt per connection, so it starts
  /// unconfigured (disabled, default base step) and only becomes live once the device
  /// record — which carries `maxTxPower` — and its `DevicePreferenceStore` entries are
  /// available. Re-running this for the same container is harmless: `configure` resets
  /// to base, which is the correct state on any reconnect.
  func configureAdaptivePower(services: ServiceContainer) {
    guard let device = connectedDevice else { return }
    let preferences = DevicePreferenceStore()
    services.adaptivePowerService.configure(
      paGainDb: preferences.paGainDb(deviceID: device.id),
      radioMaxDbm: device.maxTxPower,
      baseStepIndex: preferences.adaptivePowerBaseStep(deviceID: device.id),
      enabled: preferences.isAdaptivePowerEnabled(deviceID: device.id)
    )
  }

  /// Pull the firmware's stored notification rules and push ours if they differ.
  ///
  /// Runs once per post-sync `.ready` transition. Inert on firmware without the sync
  /// registry, and never throws: the rules are an optimisation of on-device alerting,
  /// not something a connection can fail on.
  func reconcileNotifSync() async {
    guard let services, let radioID = currentRadioID else { return }
    await services.notifSyncService.reconcileOnConnect(radioID: radioID)
  }

  /// Consume settings service event stream.
  /// Updates connectedDevice when settings are changed via SettingsService.
  func wireSettingsEventStream(services: ServiceContainer) async {
    settingsEventsTask?.cancel()
    let events = await services.settingsService.events()
    settingsEventsTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case let .deviceUpdated(selfInfo):
          await MainActor.run {
            self.connectionManager.updateDevice(from: selfInfo)
          }
        case let .autoAddConfigUpdated(config):
          await MainActor.run {
            self.connectionManager.updateAutoAddConfig(config)
            // Clear storage full flag when overwrite oldest is enabled
            if config.bitmask & AutoAddConfig.overwriteOldestBit != 0 {
              self.connectionUI.isNodeStorageFull = false
            }
          }
        case let .clientRepeatUpdated(enabled):
          await MainActor.run {
            self.connectionManager.updateClientRepeat(enabled)
          }
        case let .pathHashModeUpdated(mode):
          await MainActor.run {
            self.connectionManager.updatePathHashMode(mode)
            // Probes are addressed with `mode + 1` key bytes and the table tracks hashes
            // of that width, so the engine has to hear about a runtime change.
            self.applyPathHashModeToSignalBars(mode)
          }
        case let .allowedRepeatFreqUpdated(ranges):
          await MainActor.run {
            self.connectionManager.allowedRepeatFreqRanges = ranges
          }
        case let .defaultFloodScopeUpdated(name):
          await MainActor.run {
            self.connectionManager.updateDefaultFloodScopeName(name)
          }
        }
      }
    }
  }

  /// Wire device update and contact change callbacks.
  /// Updates connectedDevice when local device settings (like OCV) are changed via DeviceService,
  /// and handles contact updates/deletions for real-time Discover page updates.
  func wireDeviceUpdateCallbacks(services: ServiceContainer) async {
    await services.deviceService.setDeviceUpdateCallback { [weak self] deviceDTO in
      await MainActor.run {
        self?.connectionManager.updateDevice(with: deviceDTO)
      }
    }

    // Contact updates bump contactsVersion for real-time Discover page
    // updates; contact-deleted cleanup removes notifications and refreshes
    // the badge when the device auto-deletes a contact via 0x8F.
    // Re-subscribes per connection because ServiceContainer is rebuilt.
    advertisementEventsTask?.cancel()
    let advertisementEvents = services.advertisementService.events()
    advertisementEventsTask = Task { [weak self] in
      for await event in advertisementEvents {
        guard let self else { return }
        switch event {
        case .contactUpdated:
          contactsVersion += 1
          PersistentLogger(subsystem: "com.mc1", category: "discover-trace")
            .info("B4 contactUpdated bump contactsVersion=\(contactsVersion)")
        case let .contactDeletedCleanup(contactID, _):
          logger.info("Overwrite oldest: running cleanup for deleted contact \(contactID) - removing notifications and updating badge")
          await self.services?.notificationService.removeDeliveredNotifications(forContactID: contactID)
          await self.services?.notificationService.updateBadgeCount()
        case .newContactDiscovered, .nodeStorageFullChanged,
             .pathDiscoveryResponse, .traceResponse, .traceSnrObserved:
          break
        }
      }
    }
  }

  /// Wire the message event streams. Delegates to `MessageEventDispatcher`,
  /// which subscribes to the service event streams and fans them out to
  /// `messageEventStream` and `sessionStateChangeCount`.
  func wireMessageEvents(services: ServiceContainer) {
    messageEventDispatcher.wire(services: services)
  }

  /// Wire Live Activity callbacks for RX freshness, battery, and connection lifecycle.
  func wireLiveActivityCallbacks(services: ServiceContainer) async {
    // Every received RF packet refreshes Live Activity freshness and may
    // trigger an overdue battery read. Re-subscribes per connection
    // because ServiceContainer is rebuilt.
    rxLogEventsTask?.cancel()
    let rxLogEntries = services.rxLogService.entryStream()
    rxLogEventsTask = Task { [weak self] in
      for await _ in rxLogEntries {
        guard let self else { return }
        await liveActivityManager.handlePacketReceived()
        if liveActivityManager.hasActiveActivity {
          await batteryMonitor.fetchBatteryIfOverdue(
            services: self.services, device: connectedDevice
          )
        }
      }
    }

    batteryMonitor.onBatteryChanged = { [weak self] battery in
      Task { @MainActor [weak self] in
        await self?.liveActivityManager.handleBatteryChanged(battery: battery)
      }
    }

    let device = connectedDevice
    let ocvArray = batteryMonitor.activeBatteryOCVArray(for: device)
    let unreadCount = await totalUnreadCount(from: services)

    if let device {
      await liveActivityManager.handleConnectionReady(
        device: device,
        ocvArray: ocvArray,
        unreadCount: unreadCount
      )
    }
  }

  /// `Activity.request` only succeeds in the foreground, so a `startActivity`
  /// triggered from background (e.g. BLE auto-reconnect after the disconnect
  /// grace timer fired) throws and leaves `currentActivity` nil. iOS may also
  /// end an activity from background — 8-hour active cap, 12-hour total, or
  /// memory pressure — in which case the `.dismissed` branch in
  /// `validateActivityState` clears the reference without restarting. Both
  /// leave the radio connected with no LA on screen.
  func restartLiveActivityIfMissing() async {
    guard connectionState.isConnected,
          liveActivityManager.isEnabled,
          !liveActivityManager.hasActiveActivity,
          let device = connectedDevice,
          let services else { return }

    let ocvArray = batteryMonitor.activeBatteryOCVArray(for: device)
    let unreadCount = await totalUnreadCount(from: services)
    await liveActivityManager.handleConnectionReady(
      device: device,
      ocvArray: ocvArray,
      unreadCount: unreadCount
    )
  }

  func totalUnreadCount(from services: ServiceContainer) async -> Int {
    guard let radioID = currentRadioID else { return 0 }
    let counts = await (try? services.dataStore.getTotalUnreadCounts(radioID: radioID))
      ?? (contacts: 0, channels: 0, rooms: 0)
    return counts.contacts + counts.channels + counts.rooms
  }
}
