import Foundation
import MeshCore
import SwiftData

/// Dependency injection container for MC1Services.
///
/// `ServiceContainer` creates and manages all services needed by the DigitainoMesh app,
/// handling the dependency graph between services. It provides a single point of
/// initialization for the service layer.
///
/// ## Lifetime
///
/// The container is per-connection, not a singleton: `ConnectionManager` builds a
/// fresh `ServiceContainer` (and a fresh session) on every connection in
/// `buildServicesAndSaveDevice`, and tears it down via `tearDown()` on disconnect
/// before nilling its reference. The `PersistenceStore` is injected and
/// process-lifetime on `ConnectionManager`; it is not minted here. Anything
/// else that must survive reconnects (for example detected platform or
/// last-clean-sync state) lives on `ConnectionManager`, not here. `init` also
/// reassigns the `DebugLogBuffer.shared` global to this container's buffer,
/// so a stale container's services must not keep running past teardown.
///
/// ## Usage
///
/// ```swift
/// // Create container with session and model container
/// let container = ServiceContainer(
///     session: meshCoreSession,
///     dataStore: persistenceStore,
///     radioID: radioUUID
/// )
///
/// // Start event monitoring when device is connected
/// await container.startEventMonitoring(radioID: radioUUID)
/// ```
///
/// ## Dependency injection
///
/// `init` constructs services in dependency order, so a fully wired container
/// exists as soon as `init` returns. Stable one-to-one dependencies are
/// constructor-injected. One-to-many notifications flow through typed event
/// streams (`SyncDataEvent`, `AdvertisementEvent`, `MessageStatusEvent`,
/// `HeardRepeatEvent`, `RemoteNodeEvent`, `RoomServerEvent`,
/// `ContactServiceEvent`, and the RX log entry stream), every one of which is
/// finished in `tearDown()` so consumer loops cannot outlive the container.
///
/// Setter injection survives only where ordering or a reference cycle forces it:
/// - `MessagePollingService` ingestion handlers: installed by
///   `SyncCoordinator.wireMessageHandlers` before event monitoring starts,
///   cleared in `tearDown()`.
/// - `SyncCoordinator.setSyncActivityCallbacks`: installed by
///   `ConnectionUIState.wireCallbacks` before `onConnectionEstablished` so the
///   count-paired started/ended events keep the sync pill accurate.
/// - `SyncCoordinator.setCleanChannelSyncCallback` /
///   `setChannelSyncAttemptedCallback`: installed by
///   `ConnectionManager.wireCleanChannelSyncCallback` at container build.
/// - `NotificationService` action closures and `getBadgeCount`: installed by
///   `AppState` and `NavigationCoordinator` when notification handling is
///   configured. The action closures are cleared in `tearDown()` because they
///   capture `NotificationActionHandler`, which strong-holds the service back.
/// - `ChannelService.setDraftClearHandler` and
///   `DeviceService.setDeviceUpdateCallback`: installed by
///   `AppState.wireServicesIfConnected` per connection.
/// - `NodeConfigService.setOnPostIdentityImport`: installed by
///   `ConnectionManager.buildServicesAndSaveDevice`; a cycle-forced upward
///   call into `ConnectionManager`.
@Observable
@MainActor
public final class ServiceContainer {
  // MARK: - Core Infrastructure

  /// The MeshCore session for device communication
  public let session: MeshCoreSession

  /// The persistence store for SwiftData operations
  public let dataStore: PersistenceStore

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

  /// Service-layer outbound chat queue. Replaces the per-view-model
  /// `dmSendQueue` / `channelSendQueue` instances. Hydrates from
  /// `PendingSend` on construction; drain gated on `ConnectionManager`
  /// transport state via `BLETransportOpenedSignal`.
  ///
  /// Constructed eagerly in `ServiceContainer.init` because `radioID`
  /// is known at container-build time (`buildServicesAndSaveDevice`
  /// resolves the device record before instantiating the container).
  /// Eager construction closes the visibility window where the
  /// container exists but the service is `nil`.
  public let chatSendQueueService: ChatSendQueueService

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

  /// Whether service event listeners are active or currently starting.
  var isEventMonitoringActive: Bool {
    eventMonitoringState == .starting || eventMonitoringState == .active
  }

  // MARK: - Initialization

  /// Creates a new service container.
  ///
  /// - Parameters:
  ///   - session: The MeshCoreSession for device communication
  ///   - dataStore: Process-lifetime persistence store. Injected by
  ///     `ConnectionManager`; the container does not mint its own.
  ///   - radioID: The connected device's radio ID. Used to scope the
  ///     chat send queue's pending-send rows so two radios cannot share
  ///     drain state across reconnects.
  ///   - appStateProvider: Optional provider for app foreground/background state
  ///   - phoneLocationProvider: Optional read-only source of the phone's cached
  ///     GPS fix, for stamping receive-time location onto live messages
  ///   - connectionStateEvents: Optional broadcaster of connection-state
  ///     changes. When provided, the chat send queue observes it to wake
  ///     parked drains on each disconnected-to-connected edge.
  ///   - initialConnectionState: The connection state at container build
  ///     time. Connect paths reach `.connected` before constructing the
  ///     container, so the queue's edge detection treats an
  ///     already-connected initial value as a fired edge.
  init(
    session: MeshCoreSession,
    dataStore: PersistenceStore,
    radioID: UUID,
    appStateProvider: AppStateProvider? = nil,
    phoneLocationProvider: PhoneLocationProvider? = nil,
    connectionStateEvents: EventBroadcaster<DeviceConnectionState>? = nil,
    initialConnectionState: DeviceConnectionState = .disconnected
  ) {
    self.session = session
    self.appStateProvider = appStateProvider
    self.phoneLocationProvider = phoneLocationProvider
    self.dataStore = dataStore
    inlineImageDimensionsStore = InlineImageDimensionsStore()

    // Independent services (no dependencies)
    keychainService = KeychainService()
    notificationService = NotificationService()
    syncCoordinator = SyncCoordinator()

    // Core services, constructed so every dependency exists before its consumer
    heardRepeatsService = HeardRepeatsService(dataStore: dataStore)
    rxLogService = RxLogService(
      session: session,
      dataStore: dataStore,
      heardRepeatsService: heardRepeatsService
    )
    remoteNodeService = RemoteNodeService(
      session: session,
      dataStore: dataStore,
      keychainService: keychainService
    )
    let cleanupCoordinator = ContactCleanupCoordinator(
      dataStore: dataStore,
      syncCoordinator: syncCoordinator,
      notificationService: notificationService,
      remoteNodeService: remoteNodeService
    )
    contactService = ContactService(
      session: session,
      dataStore: dataStore,
      syncCoordinator: syncCoordinator,
      cleanupCoordinator: cleanupCoordinator
    )
    messageService = MessageService(
      session: session,
      dataStore: dataStore,
      contactService: contactService,
      phoneLocationProvider: phoneLocationProvider
    )
    channelService = ChannelService(
      session: session,
      dataStore: dataStore,
      rxLogService: rxLogService
    )
    settingsService = SettingsService(session: session)
    deviceService = DeviceService(dataStore: dataStore)
    advertisementService = AdvertisementService(session: session, dataStore: dataStore)
    messagePollingService = MessagePollingService(session: session, dataStore: dataStore)
    binaryProtocolService = BinaryProtocolService(session: session, dataStore: dataStore)
    debugLogBuffer = DebugLogBuffer(dataStore: dataStore)
    DebugLogBuffer.shared = debugLogBuffer
    reactionService = ReactionService()
    nodeConfigService = NodeConfigService(
      session: session,
      settingsService: settingsService,
      channelService: channelService,
      dataStore: dataStore,
      syncCoordinator: syncCoordinator
    )
    nodeSnapshotService = NodeSnapshotService(dataStore: dataStore)
    adaptivePowerService = AdaptivePowerService(txPowerApplier: settingsService)
    notifSyncService = NotifSyncService(session: session, dataStore: dataStore)

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
      dataStore: dataStore
    )

    chatSendQueueService = ChatSendQueueService(
      radioID: radioID,
      dataStore: dataStore,
      messageService: messageService,
      channelService: channelService,
      reactionService: reactionService
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
    // Claim synchronously before the awaits below so an overlapping caller
    // (SyncCoordinator.onConnectionEstablished racing the foreground health
    // check) cannot pass the guard and double-start every monitor.
    guard eventMonitoringState == .stopped else { return }
    eventMonitoringState = .starting

    await heardRepeatsService.configure(radioID: radioID)

    // Start event monitoring for services that need it
    if enableAdvertisementMonitoring {
      await advertisementService.startEventMonitoring(radioID: radioID)
    }
    await rxLogService.startEventMonitoring(radioID: radioID)
    await messageService.startEventMonitoring()
    await messageService.startAckExpiryChecking()

    await remoteNodeService.startEventMonitoring()

    // Always start message event monitoring so handlers are ready for polled messages
    await messagePollingService.startMessageEventMonitoring(radioID: radioID)
    if enableAutoFetch {
      await messagePollingService.startAutoFetch(radioID: radioID)
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
    // Claimed synchronously, mirroring startEventMonitoring, so two teardown
    // paths interleaving at the awaits below cannot double-stop.
    guard eventMonitoringState == .active else { return }
    eventMonitoringState = .stopping

    await advertisementService.stopEventMonitoring()
    await rxLogService.stopEventMonitoring()
    await messageService.stopEventMonitoring()
    // Do not fail in-flight DMs on disconnect. The firmware retains the
    // expected ACK and re-emits the delivery confirmation whenever it
    // returns, so a routine BLE cycle must not mark a delivered message
    // `.failed`. Stop only the expiry checker; pending entries resolve on
    // reconnect within the same session or expire via `ackGiveUpWindow`.
    await messageService.stopAckExpiryChecking()
    await messagePollingService.stopMessageEventMonitoring()
    // RemoteNodeService event monitoring is per-session, handled internally

    // Flush debug log buffer
    await debugLogBuffer.shutdown()

    eventMonitoringState = .stopped
  }

  /// Full container teardown. Must be awaited before nulling the container
  /// so the chat send queue drains. `stopEventMonitoring()` alone does not
  /// cover that.
  func tearDown() async {
    await stopEventMonitoring()

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

  // MARK: - Convenience Methods

  /// Performs initial database warm-up.
  ///
  /// Call this early during app launch to avoid lazy initialization delays.
  func warmUp() async throws {
    try await dataStore.warmUp()
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
