import AVFoundation
import SwiftUI
import SwiftData
import UserNotifications
import MC1Services
import MeshCore
import CoreLocation
import OSLog
import TipKit


/// Simplified app-wide state management.
/// Composes ConnectionManager for connection lifecycle.
/// Handles only UI state, navigation, and notification wiring.
@Observable
@MainActor
public final class AppState {

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.mc1", category: "AppState")

    // MARK: - Location

    /// App-wide location service for permission management
    public let locationService = LocationService()

    // MARK: - Weather

    /// In-memory cache for MeshWX weather data from the #meshwx channel
    let weatherCache = WeatherCache()

    /// Result of a weather refresh request attempt.
    enum WeatherRefreshResult {
        case sent
        case noDataChannel
        case noLocation
        case rateLimited
        case notConnected
        case botNotFound
    }

    /// When the last refresh request was sent (for client-side rate limiting).
    private var weatherLastRefreshAt: Date?

    /// Cached weather bot contact, resolved by configured name for DM requests.
    private var weatherBotContact: ContactDTO?

    /// User-configured name of the weather bot contact (e.g. "MeshWX").
    /// Persisted in UserDefaults. Used to look up the bot in the contact list for DM requests.
    var weatherBotName: String = UserDefaults.standard.string(forKey: "weatherBotName") ?? "" {
        didSet { UserDefaults.standard.set(weatherBotName, forKey: "weatherBotName") }
    }

    /// When true, display METAR/TAF temperatures in °F instead of the default °C.
    /// Persisted in UserDefaults. Defaults to false (Celsius) since METAR/TAF are aviation products.
    var wxAviationUsesF: Bool = UserDefaults.standard.bool(forKey: "wxAviationUsesF") {
        didSet { UserDefaults.standard.set(wxAviationUsesF, forKey: "wxAviationUsesF") }
    }

    /// When true, the MeshWX weather system is active: the Weather tab is shown, channels are
    /// auto-provisioned, and incoming weather data is processed. Defaults to true.
    var isWeatherEnabled: Bool = (UserDefaults.standard.object(forKey: "isWeatherEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(isWeatherEnabled, forKey: "isWeatherEnabled") }
    }

    /// How weather requests are transmitted to the bot.
    enum WXRequestMode: String, CaseIterable {
        case dm = "dm"
        case channel = "channel"

        var displayName: String {
            switch self {
            case .dm: return "Direct Message"
            case .channel: return "Channel"
            }
        }
    }

    /// Whether requests go out as DMs or channel messages. Persisted in UserDefaults.
    var wxRequestMode: WXRequestMode = {
        let raw = UserDefaults.standard.string(forKey: "wxRequestMode") ?? "channel"
        return WXRequestMode(rawValue: raw) ?? .channel
    }() {
        didSet { UserDefaults.standard.set(wxRequestMode.rawValue, forKey: "wxRequestMode") }
    }

    /// Channel name used when `wxRequestMode == .channel`. Persisted in UserDefaults.
    var wxCommandChannelName: String = UserDefaults.standard.string(forKey: "wxCommandChannelName") ?? "#digitaino-wx-bot" {
        didSet { UserDefaults.standard.set(wxCommandChannelName, forKey: "wxCommandChannelName") }
    }

    /// State of a manual bot-discovery scan.
    enum WXDiscoveryState: Equatable {
        case idle
        case scanning(secondsRemaining: Int)
        case done
    }

    /// Current state of the manual bot-discovery scan (updated on @MainActor).
    @MainActor var discoveryState: WXDiscoveryState = .idle

    /// Channel names (without `#`) of bot data channels the user has joined.
    /// Persisted in UserDefaults so the UI can show "Joined" across restarts.
    @MainActor private(set) var joinedWXBotChannels: Set<String> = {
        let stored = UserDefaults.standard.stringArray(forKey: "joinedWXBotChannels") ?? []
        return Set(stored)
    }()

    @MainActor private func saveJoinedWXBotChannels() {
        UserDefaults.standard.set(Array(joinedWXBotChannels), forKey: "joinedWXBotChannels")
    }

    // MARK: - Connection (via ConnectionManager)

    /// The connection manager for device lifecycle
    public let connectionManager: ConnectionManager
    private let bootstrapDebugLogBuffer: DebugLogBuffer

    // Convenience accessors
    public var connectionState: MC1Services.ConnectionState { connectionManager.connectionState }
    public var connectedDevice: DeviceDTO? { connectionManager.connectedDevice }
    public var services: ServiceContainer? { connectionManager.services }

    /// Local node name with fallback for display purposes.
    public var localNodeName: String { connectedDevice?.nodeName ?? "Me" }

    /// The sync coordinator for data synchronization
    public private(set) var syncCoordinator: SyncCoordinator?

    /// Incremented when services change (device switch, reconnect). Views observe this to reload.
    public private(set) var servicesVersion: Int = 0

    // MARK: - Offline Data Access

    /// Cached standalone persistence store for offline browsing
    private var cachedOfflineStore: PersistenceStore?

    /// Device ID for data access - returns connected device or last-connected device for offline browsing
    public var currentDeviceID: UUID? {
        connectedDevice?.id ?? connectionManager.lastConnectedDeviceID
    }

    /// Data store that works regardless of connection state - uses services when connected,
    /// cached standalone store when disconnected
    public var offlineDataStore: PersistenceStore? {
        if let services {
            cachedOfflineStore = nil  // Clear cache when services available
            return services.dataStore
        }
        guard connectionManager.lastConnectedDeviceID != nil else {
            cachedOfflineStore = nil
            return nil
        }
        if cachedOfflineStore == nil {
            cachedOfflineStore = connectionManager.createStandalonePersistenceStore()
        }
        return cachedOfflineStore
    }

    /// Incremented when contacts data changes. Views observe this to reload contact lists.
    public private(set) var contactsVersion: Int = 0

    /// Incremented when conversations data changes. Views observe this to reload chat lists.
    public private(set) var conversationsVersion: Int = 0

    // MARK: - Connection UI State

    /// Connection UI state (status pills, sync activity, alerts, pairing)
    let connectionUI = ConnectionUIState()

    /// Battery monitoring (polling, thresholds, low-battery notifications)
    let batteryMonitor = BatteryMonitor()

    /// Live Activity lifecycle (start/update/stop on Lock Screen and Dynamic Island)
    let liveActivityManager = LiveActivityManager()

    /// Task chain that serializes BLE lifecycle transitions across scene-phase changes.
    /// Do not cancel this task externally -- cancelling breaks the serialization
    /// guarantee because Task<Void, Never>.value returns immediately on cancellation.
    private var bleLifecycleTransitionTask: Task<Void, Never>?

    /// Fallback task that re-runs foreground recovery shortly after activation when the
    /// app is still disconnected. Covers edge cases where scene-phase callbacks are missed.
    private var activeRecoveryFallbackTask: Task<Void, Never>?

    /// Task consuming SettingsService event stream, canceled on disconnect
    private var settingsEventsTask: Task<Void, Never>?

#if DEBUG
    /// Optional test-only hooks for deterministic lifecycle ordering tests.
    private var bleEnterBackgroundOverride: (@MainActor () async -> Void)?
    private var bleBecomeActiveOverride: (@MainActor () async -> Void)?
#endif

    // MARK: - Onboarding State

    /// Onboarding state (completion flag, navigation path)
    let onboarding = OnboardingState()

    // MARK: - Navigation State

    /// Navigation coordinator (tab selection, pending targets, cross-tab navigation)
    let navigation = NavigationCoordinator()

    // MARK: - UI Coordination

    /// Message event broadcaster for UI updates
    let messageEventBroadcaster = MessageEventBroadcaster()

    // MARK: - Repeater Sharing

    /// Service for periodically sharing known repeater locations with the community server.
    private let repeaterSharingService = RepeaterSharingService()

    /// Background task that periodically shares repeaters while the app is foregrounded.
    private var repeaterSharingTask: Task<Void, Never>?

    // MARK: - Signal Survey

    /// Whether a signal survey session is currently recording.
    var isSurveyActive = false

    /// Live status broadcast by the survey ViewModel for the floating indicator.
    var surveyLiveStatus = SurveyLiveStatus()

    // MARK: - Signal Bars

    /// Service tracking live repeater signal quality for the toolbar indicator.
    let signalBarsService = SignalBarsService()

    // MARK: - Watched Repeater

    /// Hex ID of the repeater being actively watched for range testing.
    /// Persisted across app launches.
    var watchedRepeaterHexID: String? = UserDefaults.standard.string(forKey: "watchedRepeaterHexID") {
        didSet {
            if let id = watchedRepeaterHexID {
                UserDefaults.standard.set(id, forKey: "watchedRepeaterHexID")
            } else {
                UserDefaults.standard.removeObject(forKey: "watchedRepeaterHexID")
                UserDefaults.standard.removeObject(forKey: "watchedRepeaterName")
            }
            signalBarsService.watchedRepeaterHexID = watchedRepeaterHexID
        }
    }

    /// Resolved display name for the watched repeater.
    var watchedRepeaterName: String? = UserDefaults.standard.string(forKey: "watchedRepeaterName") {
        didSet { UserDefaults.standard.set(watchedRepeaterName, forKey: "watchedRepeaterName") }
    }

    /// Whether to play an audible tone when the watched repeater is heard.
    var watchedRepeaterSoundEnabled: Bool = UserDefaults.standard.bool(forKey: "watchedRepeaterSoundEnabled") {
        didSet { UserDefaults.standard.set(watchedRepeaterSoundEnabled, forKey: "watchedRepeaterSoundEnabled") }
    }

    /// Raw value of the selected WatchTone for the alert sound.
    var watchedRepeaterToneID: String = UserDefaults.standard.string(forKey: "watchedRepeaterToneID") ?? WatchTone.note.rawValue {
        didSet { UserDefaults.standard.set(watchedRepeaterToneID, forKey: "watchedRepeaterToneID") }
    }

    /// Latest RX signal quality from the watched repeater (drives banner display).
    var watchedRepeaterRxQuality: SNRQuality?

    /// Latest TX signal quality from the watched repeater.
    var watchedRepeaterTxSnr: Double?

    /// Packet count since watch started.
    var watchedRepeaterPacketCount: Int = 0

    /// Timestamp of the most recent packet from the watched repeater.
    var watchedRepeaterLastHeard: Date?

    /// Incremented on each watched repeater packet — drives flash animation.
    var watchedRepeaterFlashTick: UInt = 0

    /// Start watching a specific repeater.
    func watchRepeater(hexID: String, name: String?) {
        watchedRepeaterHexID = hexID
        watchedRepeaterName = name
        watchedRepeaterRxQuality = nil
        watchedRepeaterTxSnr = nil
        watchedRepeaterPacketCount = 0
        watchedRepeaterLastHeard = nil
        watchedRepeaterFlashTick = 0
    }

    /// Stop watching the current repeater.
    func clearWatchedRepeater() {
        watchedRepeaterHexID = nil
        watchedRepeaterName = nil
        watchedRepeaterRxQuality = nil
        watchedRepeaterTxSnr = nil
        watchedRepeaterPacketCount = 0
        watchedRepeaterLastHeard = nil
    }

    /// Retained audio player so it doesn't deallocate mid-playback.
    private var watchTonePlayer: AVAudioPlayer?

    /// Plays a short ping tone through AirPods/speakers even when the phone is on silent.
    /// Uses AVAudioSession `.playback` category which bypasses the hardware mute switch.
    private func playWatchedRepeaterTone() {
        let tone = WatchTone.current(from: watchedRepeaterToneID)
        let url = URL(fileURLWithPath: tone.filePath)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            watchTonePlayer = try AVAudioPlayer(contentsOf: url)
            watchTonePlayer?.volume = 0.8
            watchTonePlayer?.play()
        } catch {
            logger.debug("Watch tone playback failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Adaptive Power

    /// Service managing adaptive TX power control with optional PA gain offset.
    let adaptivePowerService = AdaptivePowerService()

    /// Whether the adaptive power detail sheet is presented.
    var showAdaptivePowerSheet = false

    // MARK: - CLI Tool

    /// Persistent CLI tool view model (survives tab switches, reset on device disconnect)
    var cliToolViewModel: CLIToolViewModel?

    /// Tracks the device ID for CLI state - reset CLI when device changes
    private var lastConnectedDeviceIDForCLI: UUID?

    // MARK: - Status Pill

    /// The current status pill state, computed from all relevant conditions
    /// Priority: failed > syncing > ready > connecting > disconnected > hidden
    var statusPillState: StatusPillState {
        if connectionUI.syncFailedPillVisible {
            return .failed(message: L10n.Localizable.StatusPill.syncFailed)
        }
        if connectionUI.syncActivityCount > 0 || connectionState == .syncing {
            return .syncing
        }
        if connectionUI.showReadyToast {
            return .ready
        }
        if connectionState == .connecting {
            return .connecting
        }
        if connectionUI.disconnectedPillVisible {
            return .disconnected
        }
        return .hidden
    }

    /// Whether Settings startup reads should run right now.
    var canRunSettingsStartupReads: Bool {
        if connectionState == .ready { return true }
        return connectionState == .connected && connectionUI.currentSyncPhase == .messages
    }

    // MARK: - Initialization

    init(modelContainer: ModelContainer) {
        let bootstrapStore = PersistenceStore(modelContainer: modelContainer)
        let bootstrapBuffer = DebugLogBuffer(dataStore: bootstrapStore)
        self.bootstrapDebugLogBuffer = bootstrapBuffer
        DebugLogBuffer.shared = bootstrapBuffer

        self.connectionManager = ConnectionManager(modelContainer: modelContainer)

        // Wire app state provider for incremental sync support
        connectionManager.appStateProvider = AppStateProviderImpl()

        // Wire connection ready callback - automatically updates UI when connection completes
        connectionManager.onConnectionReady = { [weak self] in
            await self?.wireServicesIfConnected()
        }

        // Wire connection lost callback - updates UI when connection is lost
        connectionManager.onConnectionLost = { [weak self] in
            await self?.wireServicesIfConnected()
        }

        // Wire device synced callback - runs after sync completes and state is .ready
        connectionManager.onDeviceSynced = { [weak self] in
            self?.performStaleNodeCleanup()
        }

        // Wire survey active provider - prevents orphan cleanup from closing active survey on BLE reconnect
        connectionManager.isSurveyActiveProvider = { [weak self] in
            self?.isSurveyActive ?? false
        }
    }

    // MARK: - Lifecycle

    /// Initialize on app launch
    func initialize() async {
        // Recover any existing Live Activity before activate() so that onConnectionReady
        // (which fires during activate) finds currentActivity populated and can update it.
        await liveActivityManager.recoverExistingActivity()
        liveActivityManager.startObservingEnablement()
        await connectionManager.activate()
        // Check if disconnected pill should show (for fresh launch after termination)
        connectionUI.updateDisconnectedPillState(
            connectionState: connectionState,
            lastConnectedDeviceID: connectionManager.lastConnectedDeviceID,
            shouldSuppressDisconnectedPill: connectionManager.shouldSuppressDisconnectedPill
        )
    }

    /// Wire services to message event broadcaster
    func wireServicesIfConnected() async {
        guard let services else {
            settingsEventsTask?.cancel()
            settingsEventsTask = nil
            syncCoordinator = nil
            weatherBotContact = nil
            connectionUI.handleDisconnect(
                connectionState: connectionState,
                lastConnectedDeviceID: connectionManager.lastConnectedDeviceID,
                shouldSuppressDisconnectedPill: connectionManager.shouldSuppressDisconnectedPill
            )
            cliToolViewModel?.reset()
            batteryMonitor.stop()
            batteryMonitor.clearThresholds()
            signalBarsService.stop()
            adaptivePowerService.setEnabled(false)
            await liveActivityManager.handleConnectionLost()
            return
        }

        // Wire ConnectionUI callbacks (sync activity, node storage, pills, VoiceOver)
        // IMPORTANT: Must be set before onConnectionEstablished to avoid race condition
        await connectionUI.wireCallbacks(
            syncCoordinator: services.syncCoordinator,
            advertisementService: services.advertisementService,
            contactService: services.contactService,
            connectionManager: connectionManager
        )

        // Reset CLI if device changed (handles device switch where onConnectionLost doesn't fire)
        if let newDeviceID = connectedDevice?.id,
           let oldDeviceID = lastConnectedDeviceIDForCLI,
           newDeviceID != oldDeviceID {
            cliToolViewModel?.reset()
        }
        lastConnectedDeviceIDForCLI = connectedDevice?.id

        // Store syncCoordinator reference
        syncCoordinator = services.syncCoordinator

        // Provide the phone's GPS to services so messages can record the user's
        // location at send/receive time for accurate route map visualizations.
        // Returns cached location immediately — never blocks message sending.
        let locationProvider: @Sendable () async -> (latitude: Double, longitude: Double)? = { [weak self] in
            guard let self else { return nil }
            let loc: CLLocation? = await MainActor.run { self.locationService.currentLocation }
            guard let loc else { return nil }
            return (latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        }
        await services.syncCoordinator.setUserLocationProvider(locationProvider)
        await services.messageService.setUserLocationProvider(locationProvider)

        // Wire survey service location provider
        let surveyLocationProvider: @Sendable () async -> SurveyLocationFix? = { [weak self] in
            guard let self else { return nil }
            let loc: CLLocation? = await MainActor.run { self.locationService.currentLocation }
            guard let loc else { return nil }
            return SurveyLocationFix(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                altitude: loc.altitude,
                horizontalAccuracy: loc.horizontalAccuracy,
                speed: loc.speed >= 0 ? loc.speed : nil,
                timestamp: loc.timestamp
            )
        }
        await services.surveyService.setLocationProvider(surveyLocationProvider)

        // After a message is saved, request a fresh GPS fix in the background and
        // patch the message's coordinates if the cached location was stale or nil.
        let patchDataStore = services.dataStore
        let locationPatchHandler: @Sendable (UUID) async -> Void = { [weak self] messageID in
            guard let self else { return }

            // Read cached location age on the main actor
            let cachedAge: TimeInterval? = await MainActor.run {
                self.locationService.currentLocation.map { abs($0.timestamp.timeIntervalSinceNow) }
            }

            // If cached location is fresh (< 30s), no patch needed
            if let age = cachedAge, age < 30 { return }

            // Fire background task to get fresh GPS and patch
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let freshLoc = try await self.locationService.requestCurrentLocation(timeout: .seconds(10))
                    try await patchDataStore.updateMessageUserLocation(
                        id: messageID,
                        latitude: freshLoc.coordinate.latitude,
                        longitude: freshLoc.coordinate.longitude
                    )
                } catch {
                    // Fresh GPS unavailable — cached location (if any) was already saved
                }
            }
        }
        await services.messageService.setLocationPatchHandler(locationPatchHandler)
        await services.syncCoordinator.setLocationPatchHandler(locationPatchHandler)

        await wireWeatherHandler(services: services)
        weatherCache.loadPersistedData()
        weatherCache.startExpiryTimer()
        if let deviceID = connectedDevice?.id {
            Task { await provisionWeatherChannelIfNeeded(services: services, deviceID: deviceID) }
        }
        await wireChannelMessageDebugObserver(services: services)
        await wireDataChangeCallbacks(services: services)
        wireSettingsEventStream(services: services)
        await wireDeviceUpdateCallbacks(services: services)
        await wireMessageBroadcasting(services: services)
        await wireLiveActivityCallbacks(services: services)

        // Increment version to trigger UI refresh in views observing this
        servicesVersion += 1

        // Set up notification center delegate, wire localized strings, then register categories
        UNUserNotificationCenter.current().delegate = services.notificationService
        services.notificationService.setStringProvider(NotificationStringProviderImpl())
        await services.notificationService.setup()

        // Configure badge count callback
        services.notificationService.getBadgeCount = { [weak self, dataStore = services.dataStore] in
            let deviceID = await MainActor.run { self?.currentDeviceID }
            guard let deviceID else {
                return (contacts: 0, channels: 0, rooms: 0)
            }
            do {
                return try await dataStore.getTotalUnreadCounts(deviceID: deviceID)
            } catch {
                return (contacts: 0, channels: 0, rooms: 0)
            }
        }

        // Configure notification interaction handlers
        configureNotificationHandlers()

        // Defer battery bootstrap so connection setup is not blocked by device request timeouts.
        batteryMonitor.start(services: services, device: connectedDevice)

        // Start signal bars service for toolbar repeater signal monitoring
        if let device = connectedDevice {
            logger.info("wireServicesIfConnected: starting SignalBarsService for device \(device.id.uuidString.prefix(8)), pathHashMode=\(device.pathHashMode)")
            signalBarsService.start(deviceID: device.id, pathHashMode: device.pathHashMode)
            signalBarsService.setSendTraceHandler { [services] (tag: UInt32, flags: UInt8, path: Data) in
                let sentInfo = try await services.binaryProtocolService.sendTrace(
                    tag: tag, flags: flags, path: path
                )
                return SendTraceResult(suggestedTimeoutMs: Int(sentInfo.suggestedTimeoutMs))
            }
            signalBarsService.setSendDiscoverHandler { [services] in
                _ = try await services.binaryProtocolService.sendNodeDiscoverRequest(
                    filter: 0x04, prefixOnly: true
                )
            }

            // Wire watched repeater tracking
            signalBarsService.watchedRepeaterHexID = watchedRepeaterHexID
            signalBarsService.onWatchedRepeaterHeard = { [weak self] hexID, rxSnr, rxQuality, txSnr in
                guard let self else { return }
                self.watchedRepeaterRxQuality = rxQuality
                self.watchedRepeaterTxSnr = txSnr
                self.watchedRepeaterPacketCount += 1
                self.watchedRepeaterLastHeard = Date()
                self.watchedRepeaterFlashTick &+= 1
                if self.watchedRepeaterSoundEnabled {
                    self.playWatchedRepeaterTone()
                }
            }

            // Configure adaptive power service
            let prefs = DevicePreferenceStore()
            adaptivePowerService.configure(
                paGainDb: prefs.paGainDb(deviceID: device.id),
                radioMaxDbm: device.maxTxPower,
                baseStepIndex: prefs.adaptivePowerBaseStep(deviceID: device.id),
                enabled: prefs.isAdaptivePowerEnabled(deviceID: device.id)
            )
            let settingsService = services.settingsService
            adaptivePowerService.setTxPowerHandler = { dbm in
                let info = try await settingsService.setTxPowerVerified(dbm)
                return info.txPower
            }
        }

    }

    // MARK: - Service Wiring Helpers

    /// Wire data change callbacks for SwiftUI observation
    /// (actors don't participate in SwiftUI's observation system, so we need callbacks)
    private func wireDataChangeCallbacks(services: ServiceContainer) async {
        await services.syncCoordinator.setDataChangeCallbacks(
            onContactsChanged: { @MainActor [weak self] in
                self?.contactsVersion += 1
                // Debounce repeater sharing check on contact changes
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    self?.updateRepeaterSharing()
                }
            },
            onConversationsChanged: { @MainActor [weak self] in
                self?.conversationsVersion += 1
                Task { @MainActor [weak self] in
                    guard let self, let services = self.services else { return }
                    let total = await self.totalUnreadCount(from: services)
                    await self.liveActivityManager.handleUnreadCountChanged(unreadCount: total)
                }
            }
        )
    }

    /// Consume settings service event stream.
    /// Updates connectedDevice when settings are changed via SettingsService.
    private func wireSettingsEventStream(services: ServiceContainer) {
        settingsEventsTask?.cancel()
        settingsEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in await services.settingsService.events() {
                switch event {
                case .deviceUpdated(let selfInfo):
                    await MainActor.run {
                        self.connectionManager.updateDevice(from: selfInfo)
                    }
                case .autoAddConfigUpdated(let config):
                    await MainActor.run {
                        self.connectionManager.updateAutoAddConfig(config)
                        // Clear storage full flag when overwrite oldest is enabled (bit 0x01)
                        if config.bitmask & 0x01 != 0 {
                            self.connectionUI.isNodeStorageFull = false
                        }
                    }
                case .clientRepeatUpdated(let enabled):
                    await MainActor.run {
                        self.connectionManager.updateClientRepeat(enabled)
                    }
                case .pathHashModeUpdated(let mode):
                    await MainActor.run {
                        self.connectionManager.updatePathHashMode(mode)
                    }
                case .allowedRepeatFreqUpdated(let ranges):
                    await MainActor.run {
                        self.connectionManager.allowedRepeatFreqRanges = ranges
                    }
                }
            }
        }
    }

    /// Wire device update and contact change callbacks.
    /// Updates connectedDevice when local device settings (like OCV) are changed via DeviceService,
    /// and handles contact updates/deletions for real-time Discover page updates.
    private func wireDeviceUpdateCallbacks(services: ServiceContainer) async {
        await services.deviceService.setDeviceUpdateCallback { [weak self] deviceDTO in
            await MainActor.run {
                self?.connectionManager.updateDevice(with: deviceDTO)
            }
        }

        // Wire contact updated callback for real-time Discover page updates
        await services.advertisementService.setContactUpdatedHandler { @MainActor [weak self] in
            self?.contactsVersion += 1
        }

        // Wire contact deleted cleanup callback
        // Removes notifications and updates badge when device auto-deletes a contact via 0x8F
        await services.advertisementService.setContactDeletedCleanupHandler { [weak self] contactID, _ in
            guard let self else { return }
            self.logger.info("Overwrite oldest: running cleanup for deleted contact \(contactID) - removing notifications and updating badge")
            await self.services?.notificationService.removeDeliveredNotifications(forContactID: contactID)
            await self.services?.notificationService.updateBadgeCount()
        }
    }

    /// Wire message event broadcaster callbacks for conversation and reaction updates.
    /// Wire handler to intercept binary MeshWX messages from the #wx-broadcast channel.
    /// Sends a binary 0x01 refresh request on the #meshwx data channel.
    ///
    /// The server responds on the channel (everyone benefits). Client-side rate-limited to
    /// once per 5 minutes. The request is COBS-encoded and sent directly via the session
    /// to avoid polluting the message store.
    /// Resolves the weather bot contact: uses cache if valid, otherwise looks up by `weatherBotName`.
    private func resolveBotContact(services: ServiceContainer) async -> ContactDTO? {
        if let cached = weatherBotContact { return cached }
        guard !weatherBotName.isEmpty, let deviceID = connectedDevice?.id else { return nil }
        let contact = try? await services.dataStore.fetchContacts(deviceID: deviceID)
            .first(where: { $0.name == weatherBotName })
        if let contact {
            weatherBotContact = contact
            logger.info("MeshWX bot contact resolved by name: \(contact.name)")
        }
        return contact
    }

    // MARK: - Weather Channel Auto-Provisioning

    /// Ensures weather channels exist on the companion device:
    /// - `#wx-broadcast` — the binary data/broadcast channel (muted)
    /// - `wxCommandChannelName` (e.g. `#digitaino-wx-bot`) — the request command channel (muted)
    /// - Any previously joined bot data channels (e.g. `#aus-meshwx-v4`) — re-provisioned if missing
    /// Called silently on each connection and when weather is re-enabled.
    /// No-ops for any channel already present; skips if no free slot is available.
    private func provisionWeatherChannelIfNeeded(services: ServiceContainer, deviceID: UUID) async {
        guard isWeatherEnabled else { return }
        guard let device = connectedDevice else { return }
        do {
            let channels = try await services.dataStore.fetchChannels(deviceID: deviceID)
            let maxChannels = device.maxChannels
            var usedSlots = Set(channels.map(\.index))

            // --- v4 migration: remove legacy #wx-broadcast and command channels ---
            for channel in channels {
                let lower = channel.name.lowercased()
                let isLegacyBroadcast = lower == "#wx-broadcast" || lower == "wx-broadcast"
                let isLegacyCommand = lower.hasSuffix("-wx-bot") || lower == "wx-bot"
                if isLegacyBroadcast || isLegacyCommand {
                    try await services.channelService.clearChannel(deviceID: deviceID, index: channel.index)
                    usedSlots.remove(channel.index)
                    logger.info("WeatherChannel: migrated away legacy '\(channel.name)' from slot \(channel.index)")
                }
            }

            // Channels to provision: #meshwx-discover + any joined bot data channels
            var channelsToProvision: [(name: String, mute: Bool)] = [
                ("#meshwx-discover", true)
            ]
            for botChannel in joinedWXBotChannels {
                let name = botChannel.hasPrefix("#") ? botChannel : "#\(botChannel)"
                channelsToProvision.append((name, true))
            }

            for (channelName, shouldMute) in channelsToProvision {
                // Skip if already present (check by name)
                if channels.contains(where: { $0.name.lowercased() == channelName.lowercased() }) { continue }

                guard let freeSlot = (1..<maxChannels).first(where: { !usedSlots.contains($0) }) else {
                    logger.warning("WeatherChannel: no free slot for '\(channelName)' — skipping")
                    continue
                }
                usedSlots.insert(freeSlot)

                try await services.channelService.setChannel(
                    deviceID: deviceID,
                    index: freeSlot,
                    name: channelName,
                    passphrase: channelName
                )

                if shouldMute,
                   let channel = try await services.dataStore.fetchChannel(deviceID: deviceID, index: freeSlot) {
                    try await services.dataStore.setChannelNotificationLevel(channel.id, level: .muted)
                }

                logger.info("WeatherChannel: auto-provisioned '\(channelName)' on slot \(freeSlot)")
            }
        } catch {
            logger.error("WeatherChannel: auto-provision failed: \(error)")
        }
    }

    /// Pings the #meshwx-discover channel, collects bot beacons for 10 seconds, then sets state to `.done`.
    /// Provisions the discovery channel if it isn't on the device yet.
    @MainActor
    func scanForWeatherBots() async {
        guard let services = services, let deviceID = connectedDevice?.id else { return }

        // Provision #meshwx-discover if missing
        do {
            let channels = try await services.dataStore.fetchChannels(deviceID: deviceID)
            let discoverName = "#meshwx-discover"
            let existing = channels.first(where: { SyncCoordinator.isDiscoveryChannel($0.name) })
            if let wrong = existing, wrong.name != discoverName {
                // Old slot has wrong name (e.g. "meshwx-discover" without #) — reuse the slot with correct name
                try await services.channelService.setChannel(
                    deviceID: deviceID, index: wrong.index,
                    name: discoverName, passphrase: discoverName
                )
                logger.info("WeatherDiscovery: corrected channel name to '\(discoverName)' on slot \(wrong.index)")
            } else if existing == nil {
                let maxChannels = connectedDevice?.maxChannels ?? 8
                let usedSlots = Set(channels.map(\.index))
                if let freeSlot = (1..<maxChannels).first(where: { !usedSlots.contains($0) }) {
                    try await services.channelService.setChannel(
                        deviceID: deviceID, index: freeSlot,
                        name: discoverName, passphrase: discoverName
                    )
                    if let ch = try? await services.dataStore.fetchChannel(deviceID: deviceID, index: freeSlot) {
                        try? await services.dataStore.setChannelNotificationLevel(ch.id, level: .muted)
                    }
                    logger.info("WeatherDiscovery: provisioned \(discoverName) on slot \(freeSlot)")
                }
            }
        } catch {
            logger.error("WeatherDiscovery: channel provision failed: \(error)")
        }

        // Clear previous results and start scan
        weatherCache.clearDiscoveredBots()
        discoveryState = .scanning(secondsRemaining: 10)

        // Send a ping on the discovery channel so bots respond
        do {
            let channels = try await services.dataStore.fetchChannels(deviceID: deviceID)
            if let discoverChannel = channels.first(where: { SyncCoordinator.isDiscoveryChannel($0.name) }) {
                _ = try await services.messageService.sendChannelMessage(
                    text: "PING", channelIndex: discoverChannel.index, deviceID: deviceID
                )
                logger.info("WeatherDiscovery: ping sent on #\(discoverChannel.name)")
            }
        } catch {
            logger.error("WeatherDiscovery: ping failed: \(error)")
        }

        // 10-second countdown
        for remaining in stride(from: 9, through: 0, by: -1) {
            try? await Task.sleep(for: .seconds(1))
            guard case .scanning = discoveryState else { return }  // cancelled externally
            discoveryState = remaining > 0 ? .scanning(secondsRemaining: remaining) : .done
        }
    }

    /// Provisions the bot's data channel on the device and marks it as joined.
    /// The channel name from the beacon (e.g. `aus-meshwx-v4`) gets a `#` prefix when added.
    @MainActor
    func joinWXBotDataChannel(_ beacon: MeshWXBeacon) async {
        guard let services = services, let deviceID = connectedDevice?.id else { return }
        let channelName = "#\(beacon.channelName)"
        do {
            let channels = try await services.dataStore.fetchChannels(deviceID: deviceID)
            if !channels.contains(where: { $0.name.lowercased() == channelName.lowercased() }) {
                let maxChannels = connectedDevice?.maxChannels ?? 8
                let usedSlots = Set(channels.map(\.index))
                guard let freeSlot = (1..<maxChannels).first(where: { !usedSlots.contains($0) }) else {
                    logger.warning("WXBotJoin: no free slot for '\(channelName)'")
                    return
                }
                try await services.channelService.setChannel(
                    deviceID: deviceID, index: freeSlot,
                    name: channelName, passphrase: channelName
                )
                if let ch = try? await services.dataStore.fetchChannel(deviceID: deviceID, index: freeSlot) {
                    try? await services.dataStore.setChannelNotificationLevel(ch.id, level: .muted)
                }
                logger.info("WXBotJoin: provisioned '\(channelName)' on slot \(freeSlot)")
            }
            joinedWXBotChannels.insert(beacon.channelName)
            saveJoinedWXBotChannels()
        } catch {
            logger.error("WXBotJoin: failed to join '\(channelName)': \(error)")
        }
    }

    /// Removes a bot data channel from the device and marks it as no longer joined.
    /// - Parameter channelName: The channel name without `#` prefix (e.g. `aus-meshwx-v4`).
    @MainActor
    func leaveWXBotDataChannel(_ channelName: String) async {
        joinedWXBotChannels.remove(channelName)
        saveJoinedWXBotChannels()
        guard let services = services, let deviceID = connectedDevice?.id else { return }
        let fullName = "#\(channelName)"
        do {
            let channels = try await services.dataStore.fetchChannels(deviceID: deviceID)
            if let channel = channels.first(where: { $0.name.lowercased() == fullName.lowercased() }) {
                try await services.channelService.clearChannel(deviceID: deviceID, index: channel.index)
                logger.info("WXBotLeave: removed '\(fullName)' from slot \(channel.index)")
            }
        } catch {
            logger.error("WXBotLeave: failed to remove '\(fullName)': \(error)")
        }
    }

    /// Removes all weather system channels (discover, bot data, legacy broadcast/command) from the companion device.
    /// Called when the user disables the weather system.
    @MainActor
    func removeWeatherChannels() async {
        guard let services = services, let deviceID = connectedDevice?.id else { return }
        do {
            let channels = try await services.dataStore.fetchChannels(deviceID: deviceID)
            for channel in channels {
                let isWeatherChannel = SyncCoordinator.isWeatherSystemChannel(channel.name, commandChannelName: wxCommandChannelName)
                    || SyncCoordinator.isDiscoveryChannel(channel.name)
                    || SyncCoordinator.isWeatherDataChannel(channel.name)
                if isWeatherChannel {
                    try await services.channelService.clearChannel(deviceID: deviceID, index: channel.index)
                    logger.info("WeatherChannel: removed '\(channel.name)' from slot \(channel.index)")
                }
            }
        } catch {
            logger.error("WeatherChannel: failed to remove channels: \(error)")
        }
    }

    /// Enables or disables the weather system, provisioning or removing channels as needed.
    @MainActor
    func setWeatherEnabled(_ enabled: Bool) async {
        isWeatherEnabled = enabled
        if enabled {
            guard let services = services, let deviceID = connectedDevice?.id else { return }
            await provisionWeatherChannelIfNeeded(services: services, deviceID: deviceID)
        } else {
            // Redirect off the weather tab before hiding it
            if navigation.selectedTab == 3 {
                navigation.selectedTab = 0
            }
            await removeWeatherChannels()
        }
    }

    // MARK: - Weather Bot DM Helpers

    /// Sends a weather bot DM with automatic retry and flood routing fallback.
    /// Returns `true` if delivery was confirmed via ACK, `false` if all attempts failed.
    private func sendWeatherBotDM(text: String, to botContact: ContactDTO, services: ServiceContainer) async -> Bool {
        do {
            _ = try await services.messageService.sendMessageWithRetry(text: text, to: botContact)
            return true
        } catch {
            logger.error("WeatherBot DM delivery failed: \(error)")
            return false
        }
    }

    /// Sends a weather request on the first joined bot data channel (channel mode).
    /// Returns `true` if the message was sent without throwing.
    private func sendWeatherBotChannelMessage(text: String, services: ServiceContainer) async -> Bool {
        guard let deviceID = connectedDevice?.id else { return false }
        do {
            let channels = try await services.dataStore.fetchChannels(deviceID: deviceID)
            // Find the first joined bot data channel on the device (e.g. #aus-meshwx-v4)
            guard let channel = channels.first(where: { ch in
                joinedWXBotChannels.contains(where: { bot in
                    let fullName = bot.hasPrefix("#") ? bot : "#\(bot)"
                    return ch.name.lowercased() == fullName.lowercased()
                })
            }) else {
                logger.warning("WeatherBot: no joined bot data channel found on device")
                return false
            }
            _ = try await services.messageService.sendChannelMessage(
                text: text,
                channelIndex: channel.index,
                deviceID: deviceID
            )
            logger.info("WeatherBot: sent '\(text)' on channel '\(channel.name)'")
            return true
        } catch {
            logger.error("WeatherBot channel send failed: \(error)")
            return false
        }
    }

    /// Dispatches a weather request via DM or channel based on `wxRequestMode`.
    private func sendWeatherBotRequest(text: String, services: ServiceContainer) async -> Bool {
        switch wxRequestMode {
        case .dm:
            guard let botContact = await resolveBotContact(services: services) else { return false }
            return await sendWeatherBotDM(text: text, to: botContact, services: services)
        case .channel:
            return await sendWeatherBotChannelMessage(text: text, services: services)
        }
    }

    /// Watches a pending weather request key. If still pending after `timeout` seconds,
    /// calls `retryBlock` (which should re-send the DM and return whether delivery succeeded).
    /// If still no response after a second `timeout`, gives up and clears the key.
    private func watchPendingKey(
        _ key: String,
        timeout: TimeInterval = 45,
        retryBlock: @escaping () async -> Bool
    ) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, self.weatherCache.isPending(key) else { return }
            self.logger.info("WeatherBot: '\(key)' still pending after \(Int(timeout))s — retrying")
            let delivered = await retryBlock()
            guard delivered else {
                self.logger.warning("WeatherBot: retry delivery failed for '\(key)' — marking unavailable")
                self.weatherCache.markUnavailable(key, reason: 0x04)
                return
            }
            try? await Task.sleep(for: .seconds(timeout))
            guard self.weatherCache.isPending(key) else { return }
            self.logger.warning("WeatherBot: giving up on '\(key)' after \(Int(timeout * 2))s — marking unavailable")
            self.weatherCache.markUnavailable(key, reason: 0x04)
        }
    }

    ///
    /// - Returns: A `WeatherRefreshResult` describing the outcome.
    func sendWeatherRefreshRequest() async -> WeatherRefreshResult {
        guard connectionState == .ready, let services, let deviceID = connectedDevice?.id else {
            return .notConnected
        }

        // Client-side rate limit: at most one request per 5 minutes
        if let last = weatherLastRefreshAt, Date().timeIntervalSince(last) < 300 {
            return .rateLimited
        }

        // Determine the target region.
        // Prefer GPS fix → fall back to first cached region (handles GPS-not-ready-yet on launch).
        let region: MeshWXRegion
        if let location = locationService.currentLocation,
           let gpsRegion = MeshWXRegion.region(for: location.coordinate) {
            region = gpsRegion
        } else if let firstCachedID = weatherCache.radarFrames.keys.sorted().first,
                  let cachedRegion = MeshWXRegion.all[firstCachedID] {
            region = cachedRegion
            logger.info("WeatherRefresh: GPS not ready, falling back to cached region \(firstCachedID)")
        } else {
            return .noLocation
        }

        if wxRequestMode == .dm, await resolveBotContact(services: services) == nil {
            return .botNotFound
        }

        // Build "MWX" request: "MWX" + region_byte (hex) + client_newest (8 hex chars, UInt32 Unix minutes)
        // region_byte = (region_id << 4) | request_type; 0x3 = both radar and warnings
        let newestTimestamp: UInt32
        if let frames = weatherCache.radarFrames[region.id], let latest = frames.last {
            newestTimestamp = latest.timestamp
        } else {
            newestTimestamp = 0
        }
        let regionByte: UInt8 = (region.id & 0x0F) << 4 | 0x03
        let mwxText = String(format: "MWX%02X%08X", regionByte, newestTimestamp)

        let delivered = await sendWeatherBotRequest(text: mwxText, services: services)
        if delivered {
            weatherLastRefreshAt = Date()
            logger.info("WeatherRefresh: sent MWX for region \(region.id) (\(region.name)) via \(self.wxRequestMode.rawValue)")
            return .sent
        } else {
            logger.error("WeatherRefresh: delivery failed for region \(region.id)")
            return .noDataChannel
        }
    }

    /// Sends a 0x01 radar refresh request for a specific region ID (explicit, no GPS required).
    /// Use this when the user manually picks a region. No client-side rate limit applied.
    func sendRadarRequest(regionID: UInt8) async -> WeatherRefreshResult {
        guard connectionState == .ready, let services else { return .notConnected }
        if wxRequestMode == .dm, await resolveBotContact(services: services) == nil { return .botNotFound }

        let newestTimestamp: UInt32
        if let frames = weatherCache.radarFrames[regionID], let latest = frames.last {
            newestTimestamp = latest.timestamp
        } else {
            newestTimestamp = 0
        }
        let regionByte: UInt8 = (regionID & 0x0F) << 4 | 0x03
        let mwxText = String(format: "MWX%02X%08X", regionByte, newestTimestamp)

        let delivered = await sendWeatherBotRequest(text: mwxText, services: services)
        if delivered {
            logger.info("WeatherRefresh: sent MWX for explicit region \(regionID) via \(self.wxRequestMode.rawValue)")
        }
        return delivered ? .sent : .noDataChannel
    }

    /// Send a 0x02 LOC_PFM_POINT data request for a specific NWS forecast point.
    /// Sent as a DM to the weather bot with "WXQ" + hex-encoded payload prefix.
    /// The bot responds on #wx-broadcast (broadcast, not a DM reply).
    /// Bot contact is discovered automatically from incoming weather channel messages.
    /// - Parameter pfmPointIndex: Array index into pfm_points.json (0-based).
    /// - Parameter originICAO: Optional ICAO of the station that triggered this forecast request.
    ///   When set, the forecast will be grouped with that station in the weather view.
    func sendWeatherDataRequest(pfmPointIndex: Int, originICAO: String? = nil) async -> WeatherRefreshResult {
        let payload = MeshWXDecoder.buildForecastRequest(pfmPointIndex: pfmPointIndex)
        let forecastKey = "\(pfmPointIndex)"
        return await sendForecastPayload(payload, forecastKey: forecastKey, originICAO: originICAO)
    }

    func sendForecastRequest(placeIndex: Int) async -> WeatherRefreshResult {
        let payload = MeshWXDecoder.buildForecastRequest(placeIndex: placeIndex)
        let forecastKey = "place:\(placeIndex)"
        return await sendForecastPayload(payload, forecastKey: forecastKey, originICAO: nil)
    }

    private func sendForecastPayload(_ payload: Data, forecastKey: String, originICAO: String?) async -> WeatherRefreshResult {
        guard connectionState == .ready, let services else { return .notConnected }
        if wxRequestMode == .dm, await resolveBotContact(services: services) == nil {
            return .botNotFound
        }
        let dmText = "WXQ" + payload.map { String(format: "%02x", $0) }.joined()
        let delivered = await sendWeatherBotRequest(text: dmText, services: services)
        if delivered {
            logger.info("▶︎ MESHWX_TX forecast key=\(forecastKey) via \(self.wxRequestMode.rawValue)")
            if let icao = originICAO {
                weatherCache.setForecastOrigin(forecastKey: forecastKey, icao: icao)
            }
            let pendingKey = "forecast:\(forecastKey)"
            weatherCache.addPending(pendingKey)
            watchPendingKey(pendingKey) { [weak self] in
                guard let self, let services = self.services, self.connectionState == .ready else { return false }
                return await self.sendWeatherBotRequest(text: dmText, services: services)
            }
            return .sent
        } else {
            return .noDataChannel
        }
    }

    /// Generic helper: sends a raw 0x02 data request payload as a WXQ DM to the weather bot.
    private func sendWXDataRequest(payload: Data) async -> WeatherRefreshResult {
        guard connectionState == .ready, let services else { return .notConnected }
        if wxRequestMode == .dm, await resolveBotContact(services: services) == nil { return .botNotFound }
        let hexString = payload.map { String(format: "%02x", $0) }.joined()
        let dmText = "WXQ" + hexString
        let delivered = await sendWeatherBotRequest(text: dmText, services: services)
        if delivered {
            logger.info("▶︎ MESHWX_TX data via \(self.wxRequestMode.rawValue) payload=\(dmText)")
        }
        return delivered ? .sent : .noDataChannel
    }

    func sendOutlookRequest(pfmPointIndex: Int) async -> WeatherRefreshResult {
        await sendWXDataRequest(payload: MeshWXDecoder.buildOutlookRequest(pfmPointIndex: pfmPointIndex))
    }

    func sendStormReportsRequest(pfmPointIndex: Int) async -> WeatherRefreshResult {
        await sendWXDataRequest(payload: MeshWXDecoder.buildStormReportsRequest(pfmPointIndex: pfmPointIndex))
    }

    func sendRainObsRequest(pfmPointIndex: Int) async -> WeatherRefreshResult {
        await sendWXDataRequest(payload: MeshWXDecoder.buildRainObsRequest(pfmPointIndex: pfmPointIndex))
    }

    func sendTAFRequest(icao: String) async -> WeatherRefreshResult {
        let payload = MeshWXDecoder.buildTAFRequest(icao: icao)
        let result = await sendWXDataRequest(payload: payload)
        if case .sent = result {
            let pendingKey = "taf:\(icao)"
            weatherCache.addPending(pendingKey)
            watchPendingKey(pendingKey) { [weak self] in
                guard let self, let services = self.services, self.connectionState == .ready else { return false }
                let hex = payload.map { String(format: "%02x", $0) }.joined()
                return await self.sendWeatherBotRequest(text: "WXQ" + hex, services: services)
            }
        }
        return result
    }

    func sendMetarRequest(icao: String) async -> WeatherRefreshResult {
        let payload = MeshWXDecoder.buildMetarRequest(icao: icao)
        let result = await sendWXDataRequest(payload: payload)
        if case .sent = result {
            let pendingKey = "metar:\(icao)"
            weatherCache.addPending(pendingKey)
            watchPendingKey(pendingKey) { [weak self] in
                guard let self, let services = self.services, self.connectionState == .ready else { return false }
                let hex = payload.map { String(format: "%02x", $0) }.joined()
                return await self.sendWeatherBotRequest(text: "WXQ" + hex, services: services)
            }
        }
        return result
    }

    /// Sends a DATA_WX observation request for a city (place).
    /// The bot resolves the place's coordinates to the nearest zone and returns
    /// weather data with LOC_PLACE echoed back for proper city name display.
    func sendObservationRequest(placeIndex: Int, zoneCode: String?) async -> WeatherRefreshResult {
        let payload = MeshWXDecoder.buildObservationRequest(placeIndex: placeIndex)
        let result = await sendWXDataRequest(payload: payload)
        if case .sent = result {
            let pendingKey = "wx:place:\(placeIndex)"
            weatherCache.addPending(pendingKey)
            watchPendingKey(pendingKey) { [weak self] in
                guard let self, let services = self.services, self.connectionState == .ready else { return false }
                let hex = payload.map { String(format: "%02x", $0) }.joined()
                return await self.sendWeatherBotRequest(text: "WXQ" + hex, services: services)
            }
            logger.info("▶︎ MESHWX_TX observation place=\(placeIndex) via \(self.wxRequestMode.rawValue)")
        }
        return result
    }

    func sendWarningsNearRequest(pfmPointIndex: Int) async -> WeatherRefreshResult {
        await sendWXDataRequest(payload: MeshWXDecoder.buildWarningsNearRequest(pfmPointIndex: pfmPointIndex))
    }

    /// Requests the full text description for a zone-based warning from the bot.
    /// The bot responds with a 0x40 text chunk; the result is stored in `weatherCache.warningDescriptions`.
    func sendWarningDescriptionRequest(for warning: MeshWXWarning) async -> WeatherRefreshResult {
        guard let key = warning.descriptionKey,
              let first = warning.zones.first else { return .notConnected }
        let payload = MeshWXDecoder.buildWarningDescriptionRequest(stateIdx: first.stateIdx, zoneNum: first.zoneNum)
        let result = await sendWXDataRequest(payload: payload)
        if case .sent = result {
            weatherCache.requestDescriptionPending(zoneKey: key)
        }
        return result
    }

    private func wireWeatherHandler(services: ServiceContainer) async {
        await services.syncCoordinator.setWeatherMessageHandler { [weak self] message in
            guard let self else { return }
            let logger = Logger(subsystem: "com.mc1", category: "MeshWX")

            // Channel messages are delivered as "NodeName: " + binary payload.
            // Strip everything up to and including the first ": " (0x3a 0x20) sequence.
            let raw = message.rawPayload
            let separator: [UInt8] = [0x3a, 0x20]
            let data: Data
            var discoveredBotName: String? = nil
            if let sepRange = raw.range(of: Data(separator)) {
                let nameData = raw[raw.startIndex..<sepRange.lowerBound]
                discoveredBotName = String(data: nameData, encoding: .utf8)
                data = Data(raw[sepRange.upperBound...])  // copy to ensure startIndex == 0
            } else {
                data = raw
            }
            logger.info("MeshWX binary payload: \(data.count) bytes (raw \(raw.count)), hex=\(data.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "))")

            let decoded = MeshWXDecoder.decode(data)

            // Skip known non-product bot broadcasts (e.g. 0x0d home location) —
            // they aren't weather data and would just show as "Decode failed" noise.
            if decoded == nil && MeshWXDecoder.isKnownNonProduct(data) { return }

            await MainActor.run {
                // Auto-discover bot name from the "NodeName: " prefix if not already configured
                if let name = discoveredBotName, !name.isEmpty, self.weatherBotName.isEmpty {
                    logger.info("MeshWX: auto-discovered weather bot name: '\(name)'")
                    self.weatherBotName = name
                }

                // Always log to the weather message log (visible in Tools > Weather)
                self.weatherCache.logMessage(rawPayload: data, decoded: decoded)

                if let decoded {
                    switch decoded {
                    case .warningPolygon(let warning):
                        logger.info("MeshWX warning decoded: \(warning.displayTitle), \(warning.vertices.count) vertices, expires in \(warning.expiryMinutes)m")
                        self.weatherCache.ingestWarning(warning)
                        self.weatherCache.persistPayload(data, type: .warning)
                    case .radarGrid(let frame):
                        logger.info("MeshWX radar decoded: region \(frame.regionID), seq \(frame.frameSeq)")
                        self.weatherCache.ingestRadarFrame(frame)
                        self.weatherCache.persistPayload(data, type: .radar(frame))
                    case .forecast(let forecast):
                        let pfmIdx = forecast.pfmPointIndex.map { "\($0)" } ?? "unknown"
                        logger.info("MeshWX forecast decoded: pfmPoint=\(pfmIdx), \(forecast.periods.count) periods")
                        self.weatherCache.ingestForecast(forecast)
                        self.weatherCache.persistPayload(data, type: .forecast)
                    case .observation(let obs):
                        logger.info("MeshWX observation decoded: \(obs.displayName) \(obs.tempF)°F \(obs.skyName)")
                        self.weatherCache.ingestObservation(obs)
                        self.weatherCache.persistPayload(data, type: .observation)
                    case .outlook(let outlook):
                        logger.info("MeshWX outlook decoded: \(outlook.days.count) days")
                        self.weatherCache.ingestOutlook(outlook)
                    case .stormReports(let reports):
                        logger.info("MeshWX storm reports decoded: \(reports.reports.count) reports")
                        self.weatherCache.ingestStormReports(reports)
                    case .rainObservations(let obs):
                        logger.info("MeshWX rain observations decoded: \(obs.cities.count) cities")
                        self.weatherCache.ingestRainObservations(obs)
                    case .taf(let taf):
                        logger.info("MeshWX TAF decoded: \(taf.icao) \(taf.skyName) \(taf.validPeriodLabel)")
                        self.weatherCache.ingestTAF(taf)
                    case .warningsNear(let warnings):
                        logger.info("MeshWX warnings-near decoded: \(warnings.entries.count) entries")
                        self.weatherCache.ingestWarningsNear(warnings)
                    case .qpfGrid(let frame):
                        logger.info("MeshWX QPF grid decoded: region \(frame.regionID)")
                        self.weatherCache.ingestQPFFrame(frame)
                    case .fireWeather(let fw):
                        logger.info("MeshWX fire weather decoded: \(fw.periods.count) periods")
                        self.weatherCache.ingestFireWeather(fw)
                    case .dailyClimate(let dc):
                        logger.info("MeshWX daily climate decoded: \(dc.cities.count) cities (\(dc.dayLabel))")
                        self.weatherCache.ingestDailyClimate(dc)
                    case .nowcast(let n):
                        logger.info("MeshWX nowcast decoded: \(n.validHours)h, urgent=\(n.isUrgent)")
                        self.weatherCache.ingestNowcast(n)
                    case .notAvailable(let na):
                        if let key = na.pendingKey {
                            self.weatherCache.markUnavailable(key, reason: na.reason)
                            logger.info("MeshWX NOT_AVAILABLE for '\(key)': \(na.reasonDescription)")
                        } else {
                            logger.info("MeshWX NOT_AVAILABLE dataType=\(na.dataType) reason=\(na.reasonDescription) (no tracked key)")
                        }
                    case .beacon(let beacon):
                        logger.info("MeshWX beacon: \(beacon.displayName) on #\(beacon.channelName) (\(beacon.capabilitySummary))")
                        self.weatherCache.ingestBeacon(beacon)
                    case .textChunk(let chunk):
                        logger.info("MeshWX text chunk: \(chunk.text.count) chars")
                        self.weatherCache.ingestTextChunk(chunk)
                    }
                } else if MeshWXDecoder.radarChunkInfo(data) != nil {
                    // Non-v4 multi-chunk radar fragment — buffering, not an error
                } else if MeshWXDecoder.isV4FECUnit(data) {
                    // v4 FEC spatial unit — buffering until the full group arrives, not an error
                } else if MeshWXDecoder.isV4WrappedRadarChunk(data) {
                    // v4-wrapped multi-chunk radar fragment — buffering, not an error
                } else if MeshWXDecoder.cobsDecode(data) == nil {
                    // COBS decode failed — message was likely truncated by mesh MTU, not an app bug
                } else {
                    let firstByte = data.first.map { String(format: "0x%02x", $0) } ?? "nil"
                    logger.warning("MeshWX decode failed for \(data.count)-byte payload (first byte: \(firstByte))")
                }
            }
        }
    }

    /// Wire debug observer that counts all channel messages for the Weather Log diagnostic tool.
    private func wireChannelMessageDebugObserver(services: ServiceContainer) async {
        await services.syncCoordinator.setChannelMessageDebugObserver { [weak self] channelName in
            await MainActor.run {
                self?.weatherCache.logChannelMessageReceived(channelName: channelName)
            }
        }
    }

    private func wireMessageBroadcasting(services: ServiceContainer) async {
        await messageEventBroadcaster.wireServices(
            services,
            onConversationsChanged: { [weak self] in
                self?.conversationsVersion += 1
                Task { @MainActor [weak self] in
                    guard let self, let services = self.services else { return }
                    let total = await self.totalUnreadCount(from: services)
                    await self.liveActivityManager.handleUnreadCountChanged(unreadCount: total)
                }
            },
            onReactionReceived: { [weak self] messageID in
                await self?.handleReactionNotification(messageID: messageID)
            }
        )
    }

    /// Wire Live Activity callbacks for RX freshness, battery, and connection lifecycle.
    private func wireLiveActivityCallbacks(services: ServiceContainer) async {
        await services.rxLogService.setPacketReceivedHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.liveActivityManager.handlePacketReceived()
                if self.liveActivityManager.hasActiveActivity {
                    await self.batteryMonitor.fetchBatteryIfOverdue(
                        services: self.services, device: self.connectedDevice
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

    private func totalUnreadCount(from services: ServiceContainer) async -> Int {
        guard let deviceID = currentDeviceID else { return 0 }
        let counts = (try? await services.dataStore.getTotalUnreadCounts(deviceID: deviceID))
            ?? (contacts: 0, channels: 0, rooms: 0)
        return counts.contacts + counts.channels + counts.rooms
    }

    // MARK: - Stale Node Cleanup

    /// Runs automatic cleanup of stale non-favorite nodes if the threshold is configured.
    /// - Parameter force: When `true`, skips the 6-hour cooldown (used when the user changes the setting).
    func performStaleNodeCleanup(force: Bool = false) {
        let threshold = UserDefaults.standard.integer(forKey: "autoDeleteStaleNodesDays")
        guard threshold > 0 else { return }

        if !force {
            let lastRunTimestamp = UserDefaults.standard.double(forKey: "lastStaleCleanupDate")
            let lastRun = lastRunTimestamp > 0 ? Date(timeIntervalSinceReferenceDate: lastRunTimestamp) : Date.distantPast
            guard Date().timeIntervalSince(lastRun) >= 3 * 3600 else {
                logger.debug("Stale node cleanup skipped — cooldown not expired")
                return
            }
        }

        Task {
            do {
                let result = try await connectionManager.removeStaleNodes(olderThanDays: threshold)
                UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate, forKey: "lastStaleCleanupDate")
                if result.total > 0 {
                    logger.info("Stale node cleanup: removed \(result.removed) of \(result.total) nodes older than \(threshold) days")
                } else {
                    logger.debug("Stale node cleanup: no stale nodes found")
                }
            } catch {
                logger.warning("Stale node cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Device Actions

    /// Start device scan/pairing
    func startDeviceScan() {
        // Hide disconnected pill when starting new connection
        connectionUI.hideDisconnectedPill()
        // Clear any previous pairing failure state
        connectionUI.failedPairingDeviceID = nil
        connectionUI.isBusy = true

        Task {
            defer { connectionUI.isBusy = false }

            do {
                // pairNewDevice() triggers onConnectionReady callback on success
                try await connectionManager.pairNewDevice()
                await wireServicesIfConnected()

                // If still in onboarding, navigate to radio preset; otherwise mark complete
                if !onboarding.hasCompletedOnboarding {
                    onboarding.onboardingPath.append(.radioPreset)
                }
            } catch AccessorySetupKitError.pickerDismissed {
                // User cancelled - no error
            } catch AccessorySetupKitError.pickerAlreadyActive {
                // Picker is already showing - ignore
            } catch let pairingError as PairingError {
                // ASK pairing succeeded but BLE connection failed (e.g., wrong PIN)
                // Store device ID for recovery UI instead of showing generic alert
                connectionUI.failedPairingDeviceID = pairingError.deviceID
                connectionUI.connectionFailedMessage = "Authentication failed. The device was added but couldn't connect — this usually means the wrong PIN was entered."
                connectionUI.showingConnectionFailedAlert = true
            } catch {
                connectionUI.connectionFailedMessage = error.localizedDescription
                connectionUI.showingConnectionFailedAlert = true
            }
        }
    }

    /// Remove a device that failed pairing (wrong PIN) and automatically retry
    func removeFailedPairingAndRetry() {
        guard let deviceID = connectionUI.failedPairingDeviceID else { return }

        Task {
            await connectionManager.removeFailedPairing(deviceID: deviceID)
            connectionUI.failedPairingDeviceID = nil
            // Set flag - View observing scenePhase will trigger startDeviceScan when active
            connectionUI.shouldShowPickerOnForeground = true
        }
    }

    /// Retry connecting to the device that just failed without removing the bond.
    /// Used for transient pairing failures where the bond is still good — radio out of range,
    /// brief BLE flap, etc. Auth-failure paths route through `removeFailedPairingAndRetry`
    /// because the bond itself needs to be torn down before retrying.
    func retryFailedPairingConnect() async {
        guard let deviceID = connectionUI.failedPairingDeviceID else { return }
        connectionUI.failedPairingDeviceID = nil
        connectionUI.isBusy = true
        defer { connectionUI.isBusy = false }

        do {
            try await connectionManager.connect(to: deviceID, forceReconnect: true)
            await wireServicesIfConnected()
        } catch BLEError.deviceConnectedToOtherApp {
            connectionUI.otherAppWarningDeviceID = deviceID
        } catch {
            // Restore the device id so the alert routes back into the transient
            // (Try Again) variant — without this, presentConnectionFailure leaves
            // failedPairingDeviceID nil and the user is stranded with only OK.
            connectionUI.failedPairingDeviceID = deviceID
            connectionUI.presentConnectionFailure(message: error.localizedDescription)
        }
    }

    /// Called by View when scenePhase becomes active and shouldShowPickerOnForeground is true
    func handleBecameActive() {
        if connectionUI.shouldShowPickerOnForeground {
            connectionUI.shouldShowPickerOnForeground = false
            startDeviceScan()
        }

        activeRecoveryFallbackTask?.cancel()
        activeRecoveryFallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            guard self.connectionState == .disconnected,
                  self.connectionManager.lastConnectedDeviceID != nil else { return }

            self.logger.info("[BLE] Active fallback: disconnected after activation, running foreground reconciliation")
            await self.handleReturnToForeground()
        }
    }

    /// Disconnect from device
    /// - Parameter reason: The reason for disconnecting (for debugging)
    func disconnect(reason: DisconnectReason = .userInitiated) async {
        await connectionManager.disconnect(reason: reason)
        await liveActivityManager.endActivity()
    }

    /// Connect to a device via WiFi/TCP
    func connectViaWiFi(host: String, port: UInt16, forceFullSync: Bool = false) async throws {
        // Hide disconnected pill when starting new connection
        connectionUI.hideDisconnectedPill()
        try await connectionManager.connectViaWiFi(host: host, port: port, forceFullSync: forceFullSync)
        await wireServicesIfConnected()
    }

    // MARK: - App Lifecycle

    private enum BLELifecycleTransition {
        case enterBackground
        case becomeActive
    }

    @discardableResult
    private func enqueueBLELifecycleTransition(_ transition: BLELifecycleTransition) -> Task<Void, Never> {
        let priorTask = bleLifecycleTransitionTask
        let manager = connectionManager

        let transitionTask = Task { @MainActor in
            await priorTask?.value

#if DEBUG
            switch transition {
            case .enterBackground:
                if let override = bleEnterBackgroundOverride {
                    await override()
                    return
                }
            case .becomeActive:
                if let override = bleBecomeActiveOverride {
                    await override()
                    return
                }
            }
#endif

            switch transition {
            case .enterBackground:
                await manager.appDidEnterBackground()
            case .becomeActive:
                await manager.appDidBecomeActive()
            }
        }

        bleLifecycleTransitionTask = transitionTask
        return transitionTask
    }

    /// Called when app enters background
    func handleEnterBackground() {
        activeRecoveryFallbackTask?.cancel()
        activeRecoveryFallbackTask = nil

        // Stop repeater sharing timer
        repeaterSharingTask?.cancel()
        repeaterSharingTask = nil

        liveActivityManager.handleEnterBackground()

        // Keep battery polling alive when the live activity is visible on the lock screen
        if !liveActivityManager.hasActiveActivity {
            batteryMonitor.stop()
        }

        // Stop room keepalives to save battery/bandwidth
        Task {
            await services?.remoteNodeService.stopAllKeepAlives()
        }

        // Queue BLE lifecycle transition so background/foreground hooks stay ordered.
        enqueueBLELifecycleTransition(.enterBackground)
    }

    /// Called when app returns to foreground
    func handleReturnToForeground() async {
        // Update badge count from database
        await services?.notificationService.updateBadgeCount()

        // Room keepalives are managed by RoomConversationView lifecycle
        // (started on view appear, stopped on disappear, restarted via scenePhase)

        // Restart decay timer and flush any buffered live activity state
        liveActivityManager.handleReturnToForeground()

        // Validate live activity is still alive (may have ended while suspended)
        await liveActivityManager.validateActivityState()

        // Check for expired ACKs
        if connectionState == .ready {
            try? await services?.messageService.checkExpiredAcks()
        }

        // Check connection health (may have died while backgrounded)
        await connectionManager.checkWiFiConnectionHealth()
        await enqueueBLELifecycleTransition(.becomeActive).value

        // Trigger resync if sync failed while connected
        await connectionManager.checkSyncHealth()

        // Check for missed battery thresholds and restart polling if connected
        if let services {
            await batteryMonitor.checkMissedBatteryThreshold(device: connectedDevice, services: services)
            batteryMonitor.startRefreshLoop(services: services, device: connectedDevice)
        }

        // Resume repeater sharing if enabled
        updateRepeaterSharing()
    }

    // MARK: - Repeater Sharing Lifecycle

    /// Start or stop the repeater sharing timer based on user preference and auth state.
    func updateRepeaterSharing() {
        let enabled = UserDefaults.standard.bool(forKey: "shareRepeatersEnabled")

        guard enabled else {
            repeaterSharingTask?.cancel()
            repeaterSharingTask = nil
            return
        }

        // Already running — don't start another
        guard repeaterSharingTask == nil else { return }

        repeaterSharingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.performRepeaterShareIfNeeded()
                do {
                    try await Task.sleep(for: .seconds(RepeaterSharingService.minimumInterval))
                } catch {
                    break  // cancelled
                }
            }
        }
    }

    /// Attempt to re-verify the contributor identity if the auth token has expired.
    /// Returns the new auth token on success, or nil if verification could not be performed.
    func autoRenewVerificationIfNeeded() async -> String? {
        let verificationService = ContributorVerificationService()

        // If token is still valid, return it
        if let token = verificationService.getAuthToken() {
            return token
        }

        // Token expired — try to re-verify if device is connected
        guard let settingsService = services?.settingsService else {
            logger.info("Auto-renew: device not connected, cannot re-verify")
            return nil
        }

        logger.info("Auto-renew: auth token expired, attempting re-verification…")

        do {
            let uploadService = SurveyUploadService()
            let contributorID = try await uploadService.getOrCreateContributorID()
            let result = try await verificationService.verify(
                settingsService: settingsService,
                contributorID: contributorID
            )

            guard result.verified else {
                logger.warning("Auto-renew: verification failed")
                return nil
            }

            if let newID = result.newContributorID {
                await uploadService.updateContributorID(newID)
            }

            if let token = result.authToken {
                verificationService.storeAuthToken(token, expires: result.authTokenExpires)
                UserDefaults.standard.set(true, forKey: "surveyContributorVerified")
                logger.info("Auto-renew: verification succeeded, new token stored")
                return token
            }

            return nil
        } catch {
            logger.error("Auto-renew: verification error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Perform a single repeater share attempt if there are changes or enough time has elapsed.
    private func performRepeaterShareIfNeeded() async {
        guard let deviceID = currentDeviceID,
              let dataStore = offlineDataStore else { return }

        // Get valid auth token, auto-renewing if expired
        guard let authToken = await autoRenewVerificationIfNeeded() else {
            logger.info("Repeater sharing: no valid auth token, skipping this cycle")
            return
        }

        do {
            let contacts = try await dataStore.fetchContacts(deviceID: deviceID)
            let repeaterInfos = RepeaterSharingService.repeaterInfos(from: contacts)

            guard !repeaterInfos.isEmpty else { return }

            let fingerprint = RepeaterSharingService.fingerprint(from: repeaterInfos)

            let shouldShare = await repeaterSharingService.shouldShare()
            let hasChanges = await repeaterSharingService.hasChanges(fingerprint: fingerprint)

            guard shouldShare || hasChanges else { return }

            let result = try await repeaterSharingService.shareRepeaters(repeaterInfos, authToken: authToken)
            await repeaterSharingService.recordShare(fingerprint: fingerprint)

            logger.info("Shared \(repeaterInfos.count) repeaters: \(result.created) created, \(result.updated) updated")
        } catch {
            logger.error("Repeater sharing failed: \(error.localizedDescription)")
        }
    }

    /// Manually trigger an immediate repeater share, returning a user-facing result string.
    func performRepeaterShareNow(completion: @escaping (String) -> Void) async {
        guard let deviceID = currentDeviceID,
              let dataStore = offlineDataStore else {
            completion("No device data available")
            return
        }

        // Auto-renew token if expired
        guard let authToken = await autoRenewVerificationIfNeeded() else {
            completion("Not verified — connect device to verify identity")
            return
        }

        do {
            let contacts = try await dataStore.fetchContacts(deviceID: deviceID)
            let repeaterInfos = RepeaterSharingService.repeaterInfos(from: contacts)

            guard !repeaterInfos.isEmpty else {
                completion("No repeaters with known locations")
                return
            }

            for info in repeaterInfos {
                logger.info("Sharing repeater: \(info.name) pk=\(info.publicKey.prefix(8))… lastHeard=\(info.lastHeard ?? "nil")")
            }

            let result = try await repeaterSharingService.shareRepeaters(repeaterInfos, authToken: authToken)
            let fingerprint = RepeaterSharingService.fingerprint(from: repeaterInfos)
            await repeaterSharingService.recordShare(fingerprint: fingerprint)

            completion("Shared \(repeaterInfos.count) repeaters (\(result.created) new, \(result.updated) updated)")
            logger.info("Manual repeater share: \(repeaterInfos.count) repeaters, \(result.created) created, \(result.updated) updated")
        } catch {
            completion("Failed: \(error.localizedDescription)")
            logger.error("Manual repeater share failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Onboarding

    func completeOnboarding() {
        onboarding.completeOnboarding()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await donateDeviceMenuTipIfOnValidTab()
        }
    }

    /// Donates the tip if on a valid tab, otherwise marks it pending.
    /// Thin coordinator that reads from both navigation and onboarding concerns.
    func donateDeviceMenuTipIfOnValidTab() async {
        if navigation.isOnValidTabForDeviceMenuTip {
            navigation.pendingDeviceMenuTipDonation = false
            await DeviceMenuTip.hasCompletedOnboarding.donate()
        } else {
            navigation.pendingDeviceMenuTipDonation = true
        }
    }

#if DEBUG
    /// Test helper: Overrides BLE lifecycle operations for deterministic ordering tests.
    func setBLELifecycleOverridesForTesting(
        enterBackground: (@MainActor () async -> Void)? = nil,
        becomeActive: (@MainActor () async -> Void)? = nil
    ) {
        bleEnterBackgroundOverride = enterBackground
        bleBecomeActiveOverride = becomeActive
    }
#endif

    // MARK: - Notification Handlers

    /// Configure notification handlers once services are available
    func configureNotificationHandlers() {
        guard let services else { return }

        // Navigation-related notification tap handlers (delegated to NavigationCoordinator)
        navigation.configureNotificationHandlers(
            notificationService: services.notificationService,
            dataStore: services.dataStore,
            connectedDevice: { [weak self] in self?.connectedDevice }
        )

        services.notificationService.onQuickReply = { [weak self] contactID, text in
            guard let self else { return }
            await self.handleQuickReply(services: services, contactID: contactID, text: text)
        }

        services.notificationService.onChannelQuickReply = { [weak self] deviceID, channelIndex, text in
            guard let self else { return }
            await self.handleChannelQuickReply(services: services, deviceID: deviceID, channelIndex: channelIndex, text: text)
        }

        services.notificationService.onMarkAsRead = { [weak self] contactID, messageID in
            guard let self else { return }
            await self.handleMarkAsRead(services: services, contactID: contactID, messageID: messageID)
        }

        services.notificationService.onChannelMarkAsRead = { [weak self] deviceID, channelIndex, messageID in
            guard let self else { return }
            await self.handleChannelMarkAsRead(services: services, deviceID: deviceID, channelIndex: channelIndex, messageID: messageID)
        }
    }

    private func handleQuickReply(services: ServiceContainer, contactID: UUID, text: String) async {
        guard let contact = try? await services.dataStore.fetchContact(id: contactID) else { return }

        if connectionState == .ready {
            do {
                _ = try await services.messageService.sendDirectMessage(text: text, to: contact)

                // Clear unread state - user replied so they've seen the chat
                try? await services.dataStore.clearUnreadCount(contactID: contactID)
                await services.notificationService.removeDeliveredNotifications(forContactID: contactID)
                await services.notificationService.updateBadgeCount()
                syncCoordinator?.notifyConversationsChanged()
                return
            } catch {
                // Fall through to draft handling
            }
        }

        services.notificationService.saveDraft(for: contactID, text: text)
        await services.notificationService.postQuickReplyFailedNotification(
            contactName: contact.displayName,
            contactID: contactID
        )
    }

    private func handleChannelQuickReply(services: ServiceContainer, deviceID: UUID, channelIndex: UInt8, text: String) async {
        // Fetch channel for display name in failure notification
        let channel = try? await services.dataStore.fetchChannel(deviceID: deviceID, index: channelIndex)
        let channelName = channel?.name ?? "Channel \(channelIndex)"

        guard connectionState == .ready else {
            await services.notificationService.postChannelQuickReplyFailedNotification(
                channelName: channelName,
                deviceID: deviceID,
                channelIndex: channelIndex
            )
            return
        }

        do {
            _ = try await services.messageService.sendChannelMessage(
                text: text,
                channelIndex: channelIndex,
                deviceID: deviceID
            )

            // Clear unread state - user replied so they've seen the channel
            try? await services.dataStore.clearChannelUnreadCount(deviceID: deviceID, index: channelIndex)
            await services.notificationService.removeDeliveredNotifications(
                forChannelIndex: channelIndex,
                deviceID: deviceID
            )
            await services.notificationService.updateBadgeCount()
            syncCoordinator?.notifyConversationsChanged()
        } catch {
            await services.notificationService.postChannelQuickReplyFailedNotification(
                channelName: channelName,
                deviceID: deviceID,
                channelIndex: channelIndex
            )
        }
    }

    private func handleMarkAsRead(services: ServiceContainer, contactID: UUID, messageID: UUID) async {
        do {
            try await services.dataStore.markMessageAsRead(id: messageID)
            try await services.dataStore.clearUnreadCount(contactID: contactID)
            services.notificationService.removeDeliveredNotification(messageID: messageID)
            await services.notificationService.updateBadgeCount()
            syncCoordinator?.notifyConversationsChanged()
        } catch {
            // Silently ignore
        }
    }

    private func handleChannelMarkAsRead(services: ServiceContainer, deviceID: UUID, channelIndex: UInt8, messageID: UUID) async {
        do {
            try await services.dataStore.markMessageAsRead(id: messageID)
            try await services.dataStore.clearChannelUnreadCount(deviceID: deviceID, index: channelIndex)
            services.notificationService.removeDeliveredNotification(messageID: messageID)
            await services.notificationService.updateBadgeCount()
            syncCoordinator?.notifyConversationsChanged()
        } catch {
            // Silently ignore
        }
    }

    /// Handle posting a notification when someone reacts to the user's message
    private func handleReactionNotification(messageID: UUID) async {
        guard let services else { return }

        // Fetch the message to check if it's outgoing
        guard let message = try? await services.dataStore.fetchMessage(id: messageID),
              message.direction == .outgoing else {
            return
        }

        // Fetch the latest reaction for this message
        guard let reactions = try? await services.dataStore.fetchReactions(for: messageID, limit: 1),
              let latestReaction = reactions.first else {
            return
        }

        // Check if this is a self-reaction (user reacting to their own message)
        if let localNodeName = connectedDevice?.nodeName,
           latestReaction.senderName == localNodeName {
            return
        }

        // Check mute status based on message type
        let isMuted: Bool
        if let contactID = message.contactID {
            let contact = try? await services.dataStore.fetchContact(id: contactID)
            isMuted = contact?.isMuted ?? false
        } else if let channelIndex = message.channelIndex {
            let channel = try? await services.dataStore.fetchChannel(deviceID: message.deviceID, index: channelIndex)
            isMuted = channel?.isMuted ?? false
        } else {
            isMuted = false
        }

        guard !isMuted else { return }

        // Truncate preview if too long
        let truncatedPreview = message.text.count > 50
            ? String(message.text.prefix(47)) + "..."
            : message.text

        // Post the notification
        await services.notificationService.postReactionNotification(
            reactorName: latestReaction.senderName,
            body: L10n.Localizable.Notifications.Reaction.body(latestReaction.emoji, truncatedPreview),
            messageID: messageID,
            contactID: message.contactID,
            channelIndex: message.channelIndex,
            deviceID: message.channelIndex != nil ? message.deviceID : nil
        )
    }
}

// MARK: - Preview Support

extension AppState {
    /// Creates an AppState for previews using an in-memory container
    @MainActor
    convenience init() {
        let schema = Schema([
            Device.self,
            Contact.self,
            Message.self,
            Channel.self,
            RemoteNodeSession.self,
            RoomMessage.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        let container = try! ModelContainer(for: schema, configurations: [config])
        self.init(modelContainer: container)
    }
}

// MARK: - Environment Key

/// Environment key for AppState with safe default for background snapshot scenarios.
/// MainActor.assumeIsolated asserts we're on the main actor, which is always true
/// for SwiftUI environment access in views.
private struct AppStateKey: EnvironmentKey {
    static var defaultValue: AppState {
        MainActor.assumeIsolated {
            AppState()
        }
    }
}

extension EnvironmentValues {
    /// AppState environment value with safe default for background snapshot scenarios.
    /// Having a default value ensures a value is always available, preventing crashes when
    /// iOS takes app switcher snapshots or launches the app in background.
    var appState: AppState {
        get { self[AppStateKey.self] }
        set { self[AppStateKey.self] = newValue }
    }
}
