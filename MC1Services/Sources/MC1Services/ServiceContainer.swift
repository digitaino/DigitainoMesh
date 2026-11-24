import Foundation
import MeshCore
import MeshWX
import SwiftData

/// Owns the service graph for one connection; retirement joins `tearDown()` before replacement.
/// `ConnectionManager` injects its process-lifetime `PersistenceStore` so reconnects share one store.
@Observable
@MainActor
public final class ServiceContainer {
  // MARK: - Core Infrastructure

  /// The MeshCore session for device communication
  public let session: MeshCoreSession

  /// The persistence store for SwiftData operations
  public let dataStore: PersistenceStore
  let receiveLifetime = ReceiveScope.Lifetime()

  /// Persists inline-image aspect ratios for chat link previews. Built early
  /// because downstream caches and the prefetcher depend on it.
  public let inlineImageDimensionsStore: InlineImageDimensionsStore

  // MARK: - Independent Services

  /// Keychain service for secure credential storage
  let keychainService: KeychainService

  /// Notification service for local notifications
  public let notificationService: NotificationService

  // MARK: - Core Services

  /// Service for managing contacts
  public let contactService: ContactService

  /// Service for sending messages, retry logic, and ACK/delivery tracking.
  /// It does not receive: inbound messages arrive through `MessagePollingService`
  /// and the handlers `SyncCoordinator.wireMessageHandlers` installs there.
  public let messageService: MessageService

  /// Service for managing channels (groups)
  public let channelService: ChannelService

  /// Service for device settings management
  public let settingsService: SettingsService

  /// Service for device data persistence
  public let deviceService: DeviceService

  /// Service for advertisements and path discovery
  public let advertisementService: AdvertisementService

  /// Service for polling and routing messages
  let messagePollingService: MessagePollingService

  /// Service for binary protocol operations (telemetry, status, etc.)
  public let binaryProtocolService: BinaryProtocolService

  /// Service for RX log packet capture
  public let rxLogService: RxLogService

  /// Service for tracking heard repeats of sent messages
  public let heardRepeatsService: HeardRepeatsService

  /// Buffer for batching debug log entries to persistence
  public let debugLogBuffer: DebugLogBuffer

  /// Service for handling emoji reactions on channel messages
  public let reactionService: ReactionService

  /// Service for exporting/importing node configuration
  public let nodeConfigService: NodeConfigService

  /// Service for node status history snapshots
  public let nodeSnapshotService: NodeSnapshotService

  /// Adaptive TX power control. Per-connection by design: the active power step
  /// and the device's confirmation state are meaningless across a radio change,
  /// so a fresh container starts back at the user's persisted base step. The app
  /// layer calls `configure(paGainDb:radioMaxDbm:baseStepIndex:enabled:)` once
  /// the device record and its preferences are known.
  public let adaptivePowerService: AdaptivePowerService

  /// Pushes per-channel and per-contact notification preferences to Digitaino custom
  /// firmware (`SyncID.notifPrefs`). Per-connection because its firmware-support
  /// classification and its last-pushed blob are both properties of the connected
  /// device, not of the app.
  public let notifSyncService: NotifSyncService

  /// MeshWX weather bots on `#meshwx`: channel-datagram ingest, per-bot state, and the
  /// app's `>` requests (docs/MESHWX.md). State persists across connections in a shared file.
  public let weatherService: WeatherService

  /// Raises a local notification for a warning covering a watched place (docs/MESHWX_UI.md
  /// §16). It lives here rather than on the Weather tool's model because the model exists only
  /// while the tool is open, and the whole point is a notification with it closed. Subscriptions
  /// are read from the phone's own saved places; nothing is watched until a bell is turned on.
  public let weatherAlertNotifier: WeatherAlertNotifier

  /// Classifies the connected radio's sync-registry support. Per-connection because the
  /// classification is a property of the firmware on the other end of the link; a fresh
  /// container starts back at `.unknown` so a device swap or a reflash re-probes.
  public let syncRegistryProbe: SyncRegistryProbe

  /// Pushes the phone's movement level to the radio (`SyncID.motionHint`) so its ping
  /// cadence adapts without GPS. Inert unless `syncRegistryProbe` advertises the slot.
  public let motionHintService: MotionHintService

  /// The phone's latest movement level, written by the app target's CoreMotion monitor and
  /// read by `signalBarsEngine`. Lives here because the engine needs it at construction and
  /// MC1Services must not import CoreMotion.
  public let movementHintRelay: MovementHintRelay

  /// The phone's (or radio's) latest position, written by the app target and read by
  /// `signalBarsEngine` to break repeater hash collisions by proximity. Same shape as
  /// `movementHintRelay`, for the same reason: the engine needs it at construction and the
  /// location frameworks stay in the app target.
  public let referenceLocationRelay: ReferenceLocationRelay

  /// Tracks how well this radio and the repeaters around it hear each other. Started by
  /// `AppState` once `syncRegistryProbe` has decided between viewer and engine mode; stopped
  /// and finished in `tearDown()`.
  public let signalBarsEngine: SignalBarsEngine

  /// The node pool `signalBarsEngine` resolves repeater hashes against.
  public let signalBarsNodeDirectory: PersistedSignalBarsNodeDirectory

  /// Runs repeater benchmarks. Lives here rather than on the benchmark screen so a run
  /// survives navigating away from it — a ten-probe batch across five targets takes minutes,
  /// and the tool is useless if leaving the tab abandons it. Stopped in `tearDown()`.
  public let repeaterBenchmarkEngine: RepeaterBenchmarkEngine

  /// Benchmark history, stored as saved trace paths scoped to this radio.
  public let benchmarkHistoryStore: BenchmarkHistoryStore

  // MARK: - Remote Node Services

  /// Service for remote node session management
  public let remoteNodeService: RemoteNodeService

  /// Service for repeater administration
  public let repeaterAdminService: RepeaterAdminService

  /// Service for room server administration (telemetry, settings)
  public let roomAdminService: RoomAdminService

  /// Service for room server operations
  public let roomServerService: RoomServerService

  // MARK: - Sync Coordination

  /// Sync coordinator for managing sync lifecycle
  public let syncCoordinator: SyncCoordinator

  // MARK: - Chat Send Queue

  /// Hydrates this Radio ID's `PendingSend` rows during connection setup.
  /// Connection-state events wake parked sends when the connection becomes ready.
  public let chatSendQueueService: ChatSendQueueService

  let plainTextSendGate: PlainTextSendGate

  // MARK: - Notification Actions

  /// Executes the multi-service transactions behind notification actions
  /// (quick reply, mark-as-read, reactions). `AppState` installs
  /// `NotificationService` forwarders that delegate here and injects the
  /// app-layer inputs via `configure(isConnectionReady:localNodeName:)`.
  public let notificationActionHandler: NotificationActionHandler

  // MARK: - App State

  /// Provider for checking app foreground/background state
  /// Used to determine sync behavior (full vs incremental)
  let appStateProvider: AppStateProvider?
  let phoneLocationProvider: PhoneLocationProvider?

  // MARK: - State

  /// Event-monitoring lifecycle. Tri-state (not a Bool) so start and stop can
  /// claim the transition synchronously before their first await; two callers
  /// interleaving at those suspension points must not double-start or
  /// double-stop every per-service monitor.
  private enum EventMonitoringState {
    case stopped
    case starting
    case active
    case stopping
  }

  private var eventMonitoringState: EventMonitoringState = .stopped
  private var eventMonitoringStartTask: Task<Void, Never>?
  private var eventMonitoringStopTask: Task<Void, Never>?
  private var tearDownTask: Task<Void, Never>?
  private var isTornDown = false

  public var isAcceptingRuntimeWork: Bool {
    !isTornDown
  }

  #if DEBUG
    var testEventMonitoringStartHandler: (@MainActor () async -> Void)?
  #endif

  /// Whether service event listeners are active or currently starting.
  var isEventMonitoringActive: Bool {
    eventMonitoringState == .starting || eventMonitoringState == .active
  }

  // MARK: - Initialization

  /// Constructs the connection's services around the shared store and resolved Radio ID.
  /// An initially ready connection or a later ready event wakes parked sends.
  /// `phoneLocationProvider` is the read-only source of the phone's cached GPS fix that stamps
  /// receive-time and send-time location onto messages; nil stamps nothing.
  init(
    session: MeshCoreSession,
    dataStore: PersistenceStore,
    radioID: UUID,
    appStateProvider: AppStateProvider? = nil,
    phoneLocationProvider: PhoneLocationProvider? = nil,
    connectionStateEvents: EventBroadcaster<DeviceConnectionState>? = nil,
    initialConnectionState: DeviceConnectionState = .disconnected,
    radioWiFiState: RadioWiFiState? = nil,
    notificationService suppliedNotificationService: NotificationService? = nil,
    ackEvents: AsyncStream<MeshEvent>? = nil,
    messageConfig: MessageServiceConfig = .default,
    textRulesPreference: @escaping @Sendable () async -> TextRulesPreference? = { nil }
  ) {
    self.session = session
    self.appStateProvider = appStateProvider
    self.phoneLocationProvider = phoneLocationProvider
    self.dataStore = dataStore
    inlineImageDimensionsStore = InlineImageDimensionsStore()

    // Independent services (no dependencies)
    keychainService = KeychainService()
    notificationService = suppliedNotificationService ?? NotificationService()
    syncCoordinator = SyncCoordinator()

    // Core services, constructed so every dependency exists before its consumer
    heardRepeatsService = HeardRepeatsService(dataStore: dataStore)
    rxLogService = RxLogService(
      session: session,
      dataStore: dataStore,
      heardRepeatsService: heardRepeatsService
    )
    let contactRadioOwner = ContactRadioOwner()
    remoteNodeService = RemoteNodeService(
      session: session,
      dataStore: dataStore,
      keychainService: keychainService,
      contactRadioOwner: contactRadioOwner,
      textRulesPreference: textRulesPreference,
      receiveLifetime: receiveLifetime,
      radioID: radioID
    )
    let cleanupCoordinator = ContactCleanupCoordinator(
      dataStore: dataStore,
      syncCoordinator: syncCoordinator,
      notificationService: notificationService,
      remoteNodeService: remoteNodeService,
      radioID: radioID
    )
    contactService = ContactService(
      session: session,
      dataStore: dataStore,
      syncCoordinator: syncCoordinator,
      cleanupCoordinator: cleanupCoordinator
    )
    contactRadioOwner.bind(contactService)
    let plainTextSendGate = PlainTextSendGate()
    self.plainTextSendGate = plainTextSendGate
    messageService = MessageService(
      session: session,
      dataStore: dataStore,
      contactService: contactService,
      config: messageConfig,
      ackEvents: ackEvents,
      dmSendBudget: { DMSendBudget.current() },
      plainTextSendGate: plainTextSendGate,
      phoneLocationProvider: phoneLocationProvider
    )
    channelService = ChannelService(
      session: session,
      dataStore: dataStore,
      rxLogService: rxLogService
    )
    settingsService = SettingsService(session: session, radioWiFiState: radioWiFiState ?? RadioWiFiState(radioID: radioID))
    deviceService = DeviceService(dataStore: dataStore)
    advertisementService = AdvertisementService(
      session: session,
      dataStore: dataStore,
      contactService: contactService,
      appStateProvider: appStateProvider,
      notificationService: self.notificationService
    )
    messagePollingService = MessagePollingService(
      session: session,
      dataStore: dataStore,
      radioID: radioID,
      textRulesPreference: textRulesPreference,
      receiveLifetime: receiveLifetime
    )
    let messagePollingService = messagePollingService
    binaryProtocolService = BinaryProtocolService(
      session: session,
      radioID: radioID,
      contactRadio: contactService
    )
    debugLogBuffer = DebugLogBuffer(dataStore: dataStore)
    DebugLogBuffer.shared = debugLogBuffer
    reactionService = ReactionService()
    nodeConfigService = NodeConfigService(
      session: session,
      settingsService: settingsService,
      channelService: channelService,
      dataStore: dataStore,
      syncCoordinator: syncCoordinator,
      contactRadio: contactService
    )
    nodeSnapshotService = NodeSnapshotService(dataStore: dataStore)
    adaptivePowerService = AdaptivePowerService(txPowerApplier: settingsService)
    notifSyncService = NotifSyncService(session: session, dataStore: dataStore)
    let sessionWeatherTransport = SessionWeatherTransport(
      session: session,
      storedChannelSecret: { [dataStore] index in
        try? await dataStore.fetchChannel(radioID: radioID, index: index)?.secret
      },
      // Weather drained from the firmware queue at connect is backlog, not proof the bot
      // is in range now.
      isDrainingBacklog: { await messagePollingService.isDrainingBacklog },
      // Whether a `>` request can go out as a flooded datagram at all (spec §11): the same
      // firmware gate the screen reads as `firmwareSupportsWeather`. Older radios have no
      // send-channel-data command and keep the DM.
      supportsChannelData: { [dataStore] in
        (try? await dataStore.fetchDevice(radioID: radioID)?.supportsChannelDatagrams) ?? false
      },
      // The slot `#meshwx` is in, from the table the channel sync fills: by secret, which is
      // what decrypts the channel, then by name for a row whose secret has not synced.
      storedWeatherSlot: { [dataStore] in
        guard let channels = try? await dataStore.fetchChannels(radioID: radioID) else { return nil }
        return (channels.first { $0.secret == WeatherChannel.secret }
          ?? channels.first { $0.name == WeatherChannel.name })?.index
      }
    )
    #if DEBUG
    // Development only: with MESHWX_BRIDGE_URL and MESHWX_BRIDGE_TOKEN in the launch
    // environment, the weather tool talks to a real bot over its debug bridge and not to
    // this radio (RemoteBotWeatherTransport). Absent them, nothing changes.
    let weatherTransport: any WeatherTransport =
      RemoteBotWeatherTransport.fromEnvironment() ?? sessionWeatherTransport
    #else
    let weatherTransport: any WeatherTransport = sessionWeatherTransport
    #endif
    weatherService = WeatherService(
      transport: weatherTransport,
      store: FileWeatherStateStore.default(),
      // The channel traffic screen's log (docs/MESHWX_UI.md §12): a ring of 300 datagrams beside
      // the weather state, shared across connections because the channel is the channel whichever
      // radio is listening to it.
      trafficLogStore: FileWeatherTrafficLogStore.default(),
      // What the cap on bot states never evicts (phase 2): the bot the user picked and any holding
      // a warning in force near a watched place. The pages' own sources the tool's model adds
      // (`WeatherService.useSources`).
      protectedBotIDs: { states, now in
        WeatherBotRetention.protectedBotIDs(
          states: states, pickedBotID: WeatherBotPickStore().pick?.botID,
          watch: DefaultsWeatherAlertWatchStore().watch(), geometry: MeshWXGeometry.shared, tables: .shared,
          now: now)
      }
    )
    let weatherService = weatherService
    weatherAlertNotifier = WeatherAlertNotifier(
      states: { await weatherService.allStates() },
      events: { weatherService.events() },
      // The bot's own name for the notification's source line, read once per bot from the
      // contact its advert created.
      botName: { [dataStore] botID in
        let contacts = try? await dataStore.fetchContacts(radioID: radioID)
        return contacts?.lazy.compactMap(WeatherBot.init(contact:)).first { $0.botID == botID }?.name
      },
      // Phase 2: an id two radios answer to — two adverts with one name, or two keys sharing the
      // two bytes the wire carries — notifies nothing until the user picks it.
      suspendedBotIDs: { [dataStore] in
        let contacts = (try? await dataStore.fetchContacts(radioID: radioID)) ?? []
        var suspended = Set(WeatherBot.conflicts(among: contacts.compactMap(WeatherBot.init(contact:))).keys)
        if let picked = WeatherBotPickStore().pick?.botID { suspended.remove(picked) }
        return suspended
      }
    )

    // Signal bars. The engine is built here so it exists for the whole connection, but it
    // stays idle until `AppState` probes the firmware and calls `start(mode:pathHashMode:)`
    // — the mode is a property of the radio, and the path hash mode of the device record,
    // neither of which is known at container-build time.
    syncRegistryProbe = SyncRegistryProbe(session: session)
    motionHintService = MotionHintService(session: session, registry: syncRegistryProbe)
    movementHintRelay = MovementHintRelay()
    referenceLocationRelay = ReferenceLocationRelay()
    signalBarsNodeDirectory = PersistedSignalBarsNodeDirectory(
      dataStore: dataStore,
      radioID: radioID
    )
    signalBarsEngine = SignalBarsEngine(
      session: session,
      directory: signalBarsNodeDirectory,
      movementHints: movementHintRelay,
      referenceLocation: referenceLocationRelay
    )

    // The benchmark's trace geometry comes from the device record, which the app applies
    // with `configure(traceHashSize:traceFlags:localNodeName:)` when the screen opens.
    repeaterBenchmarkEngine = RepeaterBenchmarkEngine(session: session)
    benchmarkHistoryStore = BenchmarkHistoryStore(dataStore: dataStore, radioID: radioID)

    // Higher-level services (depend on other services)
    repeaterAdminService = RepeaterAdminService(
      session: session,
      remoteNodeService: remoteNodeService,
      dataStore: dataStore
    )
    roomAdminService = RoomAdminService(
      remoteNodeService: remoteNodeService,
      dataStore: dataStore
    )
    roomServerService = RoomServerService(
      session: session,
      remoteNodeService: remoteNodeService,
      dataStore: dataStore,
      radioID: radioID,
      plainTextSendGate: plainTextSendGate,
      textRulesPreference: textRulesPreference,
      receiveLifetime: receiveLifetime
    )

    chatSendQueueService = ChatSendQueueService(
      radioID: radioID,
      dataStore: dataStore,
      messageService: messageService,
      channelService: channelService,
      reactionService: reactionService,
      plainTextSendGate: plainTextSendGate
    )
    notificationActionHandler = NotificationActionHandler(
      dataStore: dataStore,
      messageService: messageService,
      notificationService: notificationService,
      roomServerService: roomServerService,
      syncCoordinator: syncCoordinator
    )
    if let connectionStateEvents {
      chatSendQueueService.observeConnectionState(
        initial: initialConnectionState,
        events: connectionStateEvents.subscribe()
      )
    }
  }

  // MARK: - Event Monitoring

  /// Starts event monitoring for all services.
  ///
  /// Call this after a device is connected to begin processing events
  /// from the MeshCoreSession.
  ///
  /// - Parameters:
  ///   - radioID: The connected device's radio ID for data scoping
  ///   - enableAutoFetch: Whether to start message auto-fetch immediately (default true)
  ///   - enableAdvertisementMonitoring: Whether to start advertisement monitoring immediately (default true)
  func startEventMonitoring(
    radioID: UUID,
    enableAutoFetch: Bool = true,
    enableAdvertisementMonitoring: Bool = true
  ) async {
    guard !isTornDown else { return }
    if let eventMonitoringStartTask {
      await eventMonitoringStartTask.value
      return
    }
    guard eventMonitoringState == .stopped else { return }
    eventMonitoringState = .starting
    let worker = Task {
      await performEventMonitoringStart(
        radioID: radioID,
        enableAutoFetch: enableAutoFetch,
        enableAdvertisementMonitoring: enableAdvertisementMonitoring
      )
    }
    eventMonitoringStartTask = worker
    await worker.value
    eventMonitoringStartTask = nil
  }

  private func performEventMonitoringStart(
    radioID: UUID,
    enableAutoFetch: Bool,
    enableAdvertisementMonitoring: Bool
  ) async {
    guard eventMonitoringState == .starting else { return }
    await heardRepeatsService.configure(radioID: radioID)
    #if DEBUG
      await testEventMonitoringStartHandler?()
    #endif
    guard eventMonitoringState == .starting, !isTornDown else { return }

    // Start event monitoring for services that need it
    if enableAdvertisementMonitoring {
      await advertisementService.startEventMonitoring(radioID: radioID)
      guard eventMonitoringState == .starting, !isTornDown else { return }
    }
    // Before the message polling service drains the firmware queue: datagrams queued while
    // the phone was away are delivered through the same dispatcher and must find this
    // subscriber already registered.
    await weatherService.startEventMonitoring()
    // After the service, whose subscription is registered synchronously: the notifier watches the
    // same stream and a warning in the connect-time backlog must reach both.
    await weatherAlertNotifier.start()
    await rxLogService.startEventMonitoring(radioID: radioID)
    guard eventMonitoringState == .starting, !isTornDown else { return }
    await messageService.startEventMonitoring()
    guard eventMonitoringState == .starting, !isTornDown else { return }
    await messageService.startAckExpiryChecking()
    guard eventMonitoringState == .starting, !isTornDown else { return }

    await remoteNodeService.startEventMonitoring()
    guard eventMonitoringState == .starting, !isTornDown else { return }

    // Always start message event monitoring so handlers are ready for polled messages
    await messagePollingService.startMessageEventMonitoring(radioID: radioID)
    guard eventMonitoringState == .starting, !isTornDown else { return }
    if enableAutoFetch {
      await messagePollingService.startAutoFetch(radioID: radioID)
      guard eventMonitoringState == .starting, !isTornDown else { return }
    }

    // Prune debug logs on connection
    Task {
      try? await dataStore.pruneDebugLogEntries(
        olderThan: Date().addingTimeInterval(-DebugLogRetention.window),
        keepCount: DebugLogRetention.maxEntries
      )
    }

    // Prune node status snapshots older than 1 year
    Task {
      let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: .now)!
      await nodeSnapshotService.pruneOldSnapshots(olderThan: oneYearAgo)
    }

    eventMonitoringState = .active
  }

  /// Stops event monitoring for all services.
  ///
  /// Call this when disconnecting from a device.
  func stopEventMonitoring() async {
    if let eventMonitoringStopTask {
      await eventMonitoringStopTask.value
      return
    }
    guard eventMonitoringState == .active || eventMonitoringState == .starting else { return }
    eventMonitoringState = .stopping
    let starting = eventMonitoringStartTask
    let worker = Task {
      await starting?.value
      await performEventMonitoringStop()
    }
    eventMonitoringStopTask = worker
    await worker.value
    eventMonitoringStopTask = nil
  }

  private func performEventMonitoringStop() async {
    await advertisementService.stopEventMonitoring()
    await rxLogService.stopEventMonitoring()
    try? await dataStore.flushPendingRxLogEntries()
    await weatherAlertNotifier.stop()
    await weatherService.stopEventMonitoring()
    await messageService.stopEventMonitoring()
    // Do not fail in-flight DMs on disconnect. The firmware retains the
    // expected ACK and re-emits the delivery confirmation whenever it
    // returns, so a routine BLE cycle must not mark a delivered message
    // `.failed`. Stop only the expiry checker; pending entries resolve on
    // reconnect within the same session or expire via `ackGiveUpWindow`.
    await messageService.stopAckExpiryChecking()
    await messagePollingService.stopMessageEventMonitoring()
    await remoteNodeService.stopEventMonitoring()

    // Flush debug log buffer
    await debugLogBuffer.shutdown()

    eventMonitoringState = .stopped
  }

  /// Full container teardown. Must be awaited before nulling the container
  /// so the chat send queue drains. `stopEventMonitoring()` alone does not
  /// cover that.
  func tearDown() async {
    receiveLifetime.retire()
    isTornDown = true
    if let tearDownTask {
      await tearDownTask.value
      return
    }
    let worker = Task { await performTearDown() }
    tearDownTask = worker
    await worker.value
  }

  private func performTearDown() async {
    await plainTextSendGate.invalidate()
    await remoteNodeService.beginRetirement()
    await messageService.retireInlineSends()
    await messageService.waitForAcknowledgementSaves()
    await stopEventMonitoring()
    await remoteNodeService.retire()

    // Break the retain cycles the wired handlers form. The message
    // closures and the discovery event task capture this container's
    // services strongly (via SyncDependencies), so without this the whole
    // service graph leaks on every reconnect. Cleared after
    // `stopEventMonitoring()` so the event tasks reading them are cancelled.
    await messagePollingService.clearMessageHandlers()
    await syncCoordinator.cancelDiscoveryEventMonitoring()

    // Finishing the event streams ends every consumer's for-await loop,
    // releasing the strong service references those loops hold.
    syncCoordinator.finishDataEvents()
    advertisementService.finishEvents()
    messageService.finishStatusEvents()
    heardRepeatsService.finishEvents()
    remoteNodeService.finishEvents()
    roomServerService.finishEvents()
    contactService.finishEvents()
    rxLogService.finishEntryStream()
    weatherService.finishEvents()

    // The engine owns two long-lived tasks (event ingest and its probe loop) and a
    // broadcaster the observable façade is parked on. Stopping cancels the tasks; finishing
    // ends the façade's for-await loop so it releases this container.
    await signalBarsEngine.stop()
    signalBarsEngine.finishSnapshots()

    // A benchmark in flight is measuring a radio that is going away; stop it and end its
    // façade's loop the same way.
    await repeaterBenchmarkEngine.shutdown()

    // The action forwarders AppState installs capture notificationActionHandler
    // strongly, and the handler strong-holds notificationService back, forming a
    // cycle that outlives the container. Clear them so the per-connection service
    // graph is released on teardown.
    notificationService.onQuickReply = nil
    notificationService.onChannelQuickReply = nil
    notificationService.onMarkAsRead = nil
    notificationService.onChannelMarkAsRead = nil
    notificationService.onRoomMarkAsRead = nil

    await chatSendQueueService.shutdown()
  }

  func prepareForIdentityImport() async {
    isTornDown = true
    await plainTextSendGate.invalidate()
    await messageService.retireInlineSends()
    await remoteNodeService.retire()
    await chatSendQueueService.shutdown()
    await stopEventMonitoring()
    await syncCoordinator.cancelDiscoveryEventMonitoring()
  }

  // MARK: - Convenience Methods

  /// Performs initial database warm-up.
  ///
  /// Call this early during app launch to avoid lazy initialization delays.
  func warmUp() async throws {
    await messageService.captureAcknowledgementEvents()
    try await dataStore.warmUp()
    try await messageService.restorePendingAcknowledgements(radioID: chatSendQueueService.radioID)
  }

  /// Resets all remote node session connections.
  ///
  /// Call this on app launch since connections don't persist across app restarts.
  func resetRemoteNodeConnections() async throws {
    try await dataStore.resetAllRemoteNodeSessionConnections()
  }
}

// MARK: - Factory Methods

extension ServiceContainer {
  /// Creates a service container with a new in-memory model container.
  ///
  /// Useful for testing and previews. The container is fully wired by `init`,
  /// matching production behavior.
  ///
  /// - Parameters:
  ///   - session: The MeshCoreSession for device communication
  ///   - radioID: Radio ID to scope the chat send queue (default: synthesized `UUID()`)
  /// - Returns: A configured ServiceContainer with in-memory storage
  static func forTesting(
    session: MeshCoreSession,
    radioID: UUID = UUID()
  ) async throws -> ServiceContainer {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    return ServiceContainer(
      session: session,
      dataStore: store,
      radioID: radioID
    )
  }
}
