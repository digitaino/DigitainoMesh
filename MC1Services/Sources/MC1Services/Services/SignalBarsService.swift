import Foundation
import os

/// Tracks live repeater signal data for the toolbar signal bars indicator.
///
/// Uses a firmware-style round-robin ping engine: one repeater is pinged at a time
/// with adaptive intervals, failure backoff, reactive triggers, and stale pruning.
///
/// Lifecycle: ``start(deviceID:pathHashMode:)`` on connect, ``stop()`` on disconnect.
@Observable
@MainActor
public final class SignalBarsService {

    // MARK: - Types

    /// Per-repeater signal state displayed in the detail sheet.
    public struct RepeaterSignal: Identifiable, Equatable {
        public let id: String                    // hex ID (e.g. "07A3")
        public var name: String?                 // resolved contact name
        public var rxSnr: Double?                // how well we hear them
        public var rxQuality: SNRQuality         // computed from rxSnr
        public var txSnr: Double?                // how well they hear us
        public var txState: TXState              // measurement state
        public var rssi: Int?
        public var rttMs: Int?                   // round-trip time from last ping
        public var lastHeard: Date
        public var publicKey: Data?              // for sending traces
        // Round-robin tracking
        public var failCount: Int = 0            // consecutive ping failures
        public var lastPingTime: Date?           // when last pinged
    }

    /// TX measurement state for a repeater.
    public enum TXState: Equatable, Sendable {
        case unknown        // never pinged (shows "?")
        case measuring      // ping in flight (shows spinner)
        case measured(SNRQuality) // shows bars
        case failed         // ping timed out (shows "X")
    }

    /// How this service sources signal data.
    public enum Mode: Sendable {
        /// Stock firmware: the app runs its own ping/discover engine.
        case engine
        /// Digitaino custom firmware: the device owns the engine; the app mirrors its
        /// table via `SYNC_ID_SIGNAL_BARS` and sends no traces/pings of its own.
        case viewer
    }

    // MARK: - Constants

    private enum Constants {
        static let minPingSpacing: Duration = .seconds(1)
        static let viewerPollInterval: Duration = .seconds(5)      // viewer mode: poll the device's table
        static let bestRepeaterInterval: TimeInterval = 45         // primary link — keep fresh
        static let otherRepeaterInterval: TimeInterval = 120       // secondary — periodic check
        static let failRetryInterval1: TimeInterval = 20           // failCount == 1: quick retry
        static let failRetryInterval2: TimeInterval = 45           // failCount == 2
        static let failRetryInterval3: TimeInterval = 90           // failCount == 3
        static let maxFailCount: Int = 4                           // stop pinging at 4+
        static let staleThreshold: TimeInterval = 300              // 5 minutes
        static let reactiveTriggerDelay: Duration = .seconds(2)
        static let reactiveFailedCooldown: TimeInterval = 30       // min gap before reactive re-ping of failed repeater
        static let discoverProbeInterval: Duration = .seconds(30)
        static let maxTrackedRepeaters: Int = 8                    // match firmware SIGNAL_MAX
    }

    // MARK: - Published State

    /// All tracked repeaters, sorted by signal quality (TX-weighted, best first).
    public private(set) var repeaters: [RepeaterSignal] = []

    /// Best repeater (first in sorted list) — drives toolbar indicator.
    public var bestRepeater: RepeaterSignal? { repeaters.first }

    /// Whether a manual refresh (ping-all) is in progress.
    public private(set) var isRefreshing: Bool = false

    /// Incremented on every RX packet event — drives arrow flash animation in UI.
    public private(set) var rxFlashTick: UInt = 0

    /// Incremented on every TX send event — drives arrow flash animation in UI.
    public private(set) var txFlashTick: UInt = 0

    // MARK: - Private

    private let logger = Logger(subsystem: "com.mc1", category: "SignalBars")

    private var deviceID: UUID?
    private var pathHashMode: UInt8 = 0

    /// How this service sources data: `.engine` (app pings, stock firmware) or
    /// `.viewer` (mirror Digitaino custom firmware's table, no app-side pinging).
    public private(set) var mode: Mode = .engine

    /// Viewer-mode handler: fetch the device's serialized signal-bars blob.
    private var fetchSignalBarsHandler: (() async throws -> Data)?
    /// Viewer-mode handler: trigger a device-side refresh/ping — `(action, targetID)`.
    private var signalTriggerHandler: ((UInt8, UInt8) async throws -> Void)?

    /// Phone motion level (0=stationary, 1=slow, 2=fast) for engine-mode cadence
    /// scaling, mirroring the firmware's `_td`. Viewer mode ignores this (the device
    /// owns cadence; AppState routes the hint to it via `setSync(.motionHint)`).
    private var motionLevel: UInt8 = 0
    private var motionDivisor: Int { motionLevel == 0 ? 1 : (motionLevel == 1 ? 2 : 4) }

    /// Callback to send a trace via BinaryProtocolService.
    /// Parameters: tag, flags, path → SendTraceResult
    private var sendTraceHandler: ((UInt32, UInt8, Data) async throws -> SendTraceResult)?

    /// Callback to send a node discover request (filter=0x04 for repeaters).
    private var sendDiscoverHandler: (() async throws -> Void)?

    /// Notification observation tasks.
    private var discoverObserver: Task<Void, Never>?
    private var rxLogTraceObserver: Task<Void, Never>?
    private var rxLogPacketObserver: Task<Void, Never>?
    private var roundRobinTask: Task<Void, Never>?
    private var reactivePingTask: Task<Void, Never>?
    private var discoverProbeTask: Task<Void, Never>?
    private var viewerPollTask: Task<Void, Never>?

    /// In-flight ping tracking: tag → (repeaterHexID, startTime).
    private var pendingPings: [UInt32: (hexID: String, startTime: ContinuousClock.Instant)] = [:]

    /// Hex IDs awaiting a reactive ping (prevents duplicate triggers).
    private var reactivePingTargets: Set<String> = []

    /// Timeout for pings in milliseconds (updated from device responses).
    private var suggestedTimeoutMs: Int = 5000

    // MARK: - Watched Repeater

    /// Hex ID of a repeater the user is actively watching for range testing.
    /// When set, `onWatchedRepeaterHeard` fires each time a packet arrives from this repeater.
    public var watchedRepeaterHexID: String?

    /// Callback fired on the main actor when a packet from the watched repeater is received.
    /// Parameters: hexID, rxSnr, rxQuality, txSnr (if available).
    public var onWatchedRepeaterHeard: ((String, Double, SNRQuality, Double?) -> Void)?

    // MARK: - Lifecycle

    public init() {}

    /// Start tracking repeater signals.
    /// - Parameters:
    ///   - deviceID: Current connected device ID.
    ///   - pathHashMode: Device's path hash mode (0, 1, or 2).
    public func start(deviceID: UUID, pathHashMode: UInt8, mode: Mode = .engine) {
        self.deviceID = deviceID
        self.pathHashMode = pathHashMode
        self.mode = mode

        switch mode {
        case .viewer:
            // Custom firmware owns the engine — mirror its table, transmit nothing.
            startViewerPolling()
            logger.info("SignalBarsService started in VIEWER mode for device \(deviceID.uuidString.prefix(8))")
        case .engine:
            subscribeToDiscoverResponses()
            subscribeToRxLogTraces()
            subscribeToRxLogPackets()
            startRoundRobin()
            logger.info("SignalBarsService started in ENGINE mode for device \(deviceID.uuidString.prefix(8))")
        }
    }

    /// Stop tracking and clear state.
    public func stop() {
        discoverObserver?.cancel()
        discoverObserver = nil
        rxLogTraceObserver?.cancel()
        rxLogTraceObserver = nil
        rxLogPacketObserver?.cancel()
        rxLogPacketObserver = nil
        roundRobinTask?.cancel()
        roundRobinTask = nil
        reactivePingTask?.cancel()
        reactivePingTask = nil
        discoverProbeTask?.cancel()
        discoverProbeTask = nil
        viewerPollTask?.cancel()
        viewerPollTask = nil

        repeaters = []
        pendingPings = [:]
        reactivePingTargets = []
        isRefreshing = false
        deviceID = nil
        sendDiscoverHandler = nil
        fetchSignalBarsHandler = nil
        signalTriggerHandler = nil
        mode = .engine
        onWatchedRepeaterHeard = nil

        logger.info("SignalBarsService stopped")
    }

    /// Set the trace-sending handler (wired from AppState).
    public func setSendTraceHandler(
        _ handler: @escaping (UInt32, UInt8, Data) async throws -> SendTraceResult
    ) {
        self.sendTraceHandler = handler
    }

    /// Set the discover-probe handler (wired from AppState).
    /// Called periodically to send node discover requests for repeaters.
    public func setSendDiscoverHandler(_ handler: @escaping () async throws -> Void) {
        self.sendDiscoverHandler = handler
        // Start periodic probing now that we have the handler
        startDiscoverProbing()
    }

    // MARK: - Viewer Mode (mirror custom firmware's table)

    /// Wire the viewer-mode handlers (Digitaino custom firmware present).
    /// - Parameters:
    ///   - fetch: returns the device's serialized signal-bars blob (`getSync(.signalBars)`).
    ///   - trigger: requests a device-side refresh/ping (`setSync(.signalBars, [action, targetID])`).
    public func setViewerHandlers(
        fetch: @escaping () async throws -> Data,
        trigger: @escaping (UInt8, UInt8) async throws -> Void
    ) {
        self.fetchSignalBarsHandler = fetch
        self.signalTriggerHandler = trigger
    }

    /// Engine mode: set the current phone motion level (0/1/2) to scale ping cadence.
    /// No-op effect in viewer mode (AppState routes the hint to the device instead).
    public func setMotionLevel(_ level: UInt8) {
        motionLevel = min(level, 2)
    }

    /// Update the device's path hash mode when the user changes it at runtime.
    /// Controls how many bytes (mode + 1 → 1/2/3) of the public key form a repeater's
    /// display/match ID, so the list reflects the configured path hash size.
    public func setPathHashMode(_ mode: UInt8) {
        pathHashMode = mode
    }

    private func startViewerPolling() {
        viewerPollTask?.cancel()
        viewerPollTask = Task { [weak self] in
            // Brief delay so the connection settles and handlers get wired.
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                guard let self else { break }
                await self.pollSignalBars()
                try? await Task.sleep(for: Constants.viewerPollInterval)
            }
        }
    }

    private func pollSignalBars() async {
        guard let fetch = fetchSignalBarsHandler else { return }
        do {
            let data = try await fetch()
            guard let blob = SignalBarsBlob(decoding: data) else { return }
            applyBlob(blob)
        } catch {
            logger.debug("viewer poll failed: \(error.localizedDescription)")
        }
    }

    /// Replace `repeaters` with the device's table (best repeater first), preserving
    /// any locally-known name / public key / RSSI for matching entries.
    private func applyBlob(_ blob: SignalBarsBlob) {
        let now = Date()
        let mapped: [RepeaterSignal] = blob.entries.map { e in
            let existing = repeaters.first {
                $0.id == e.hexID || $0.id.hasPrefix(e.hexID) || e.hexID.hasPrefix($0.id)
            }
            let txState: TXState
            if e.hasTx {
                txState = .measured(SNRQuality(snr: e.txSnr))
            } else if e.txFailed {
                txState = .failed
            } else {
                txState = .unknown
            }
            return RepeaterSignal(
                id: e.hexID,
                name: existing?.name,
                rxSnr: e.rxSnr,
                rxQuality: SNRQuality(snr: e.rxSnr),
                txSnr: e.txSnr,
                txState: txState,
                rssi: existing?.rssi,
                rttMs: e.rttMs == 0 ? nil : Int(e.rttMs),
                lastHeard: now.addingTimeInterval(-Double(e.ageSeconds)),
                publicKey: existing?.publicKey,
                failCount: 0,
                lastPingTime: existing?.lastPingTime
            )
        }
        // The firmware emits the table already in canonical order (best first), matching
        // the OLED Signals page — render it verbatim rather than re-sorting by recency.
        repeaters = mapped
        rxFlashTick &+= 1

        // Keep the watched-repeater range-test working in viewer mode (poll-driven).
        if let watched = watchedRepeaterHexID,
           let e = blob.entries.first(where: { $0.hexID.hasPrefix(watched) || watched.hasPrefix($0.hexID) }) {
            onWatchedRepeaterHeard?(e.hexID, e.rxSnr ?? 0, SNRQuality(snr: e.rxSnr), e.txSnr)
        }
    }

    /// Start a discovery probe to find repeaters. Viewer mode asks the device to run
    /// its discovery scan (action 2) and the device's auto-ping then measures TX; engine
    /// mode runs the app's own discover + ping-all.
    public func startProbe() async {
        switch mode {
        case .viewer:
            guard let trigger = signalTriggerHandler else { return }
            isRefreshing = true
            txFlashTick &+= 1
            try? await trigger(2, 0)                  // action 2 = discovery probe
            try? await Task.sleep(for: .seconds(4))   // let the scan + auto-ping run
            await pollSignalBars()
            isRefreshing = false
        case .engine:
            await refreshAll()                        // already does discover + ping-all
        }
    }

    /// Refresh signal data. `targetHexID == nil` refreshes all repeaters; otherwise
    /// pings just that one. Works in both modes — viewer asks the device (one RF ping
    /// originated by the radio), engine pings directly.
    public func requestRefresh(targetHexID: String? = nil) async {
        switch mode {
        case .viewer:
            guard let trigger = signalTriggerHandler else { return }
            let action: UInt8 = (targetHexID != nil) ? 1 : 0
            // Firmware matches on the 1-byte key = first byte of the hash, so send just that.
            let target: UInt8 = targetHexID.flatMap { UInt8($0.prefix(2), radix: 16) } ?? 0
            if let hexID = targetHexID {
                updateRepeater(hexID: hexID) { $0.txState = .measuring }
            }
            txFlashTick &+= 1
            try? await trigger(action, target)
            // Re-poll shortly to surface the device's fresh measurement.
            try? await Task.sleep(for: .seconds(2))
            await pollSignalBars()
        case .engine:
            if let hexID = targetHexID {
                guard let target = repeaters.first(where: { $0.id == hexID }),
                      let pubKey = target.publicKey else { return }
                updateRepeater(hexID: hexID) {
                    $0.txState = .measuring
                    $0.lastPingTime = Date()
                }
                await pingRepeater(hexID: hexID, publicKey: pubKey)
            } else {
                await refreshAll()
            }
        }
    }

    // MARK: - Active Measurement

    /// Manual refresh: discover + sequential ping-all with 1s spacing.
    /// Resets fail/check counts so all repeaters get re-measured.
    public func refreshAll() async {
        // Viewer mode: the device owns pinging — ask it to refresh instead.
        if mode == .viewer { await requestRefresh(); return }
        guard !isRefreshing else { return }
        guard sendTraceHandler != nil else {
            logger.warning("refreshAll: no sendTrace handler wired")
            return
        }

        isRefreshing = true

        // Reset tracking for all repeaters
        for i in repeaters.indices {
            repeaters[i].failCount = 0
            repeaters[i].txState = .measuring
        }

        // 1. Send discover probe to refresh public keys
        await sendDiscoverProbe()
        try? await Task.sleep(for: .milliseconds(3000))

        // 2. Ping each repeater sequentially with 1s spacing
        let targets = repeaters.filter { $0.publicKey != nil }
        logger.info("Manual refresh: pinging \(targets.count) repeater(s) sequentially")

        for target in targets {
            guard !Task.isCancelled else { break }
            guard let pubKey = target.publicKey else { continue }
            let hexID = target.id

            updateRepeater(hexID: hexID) {
                $0.txState = .measuring
                $0.lastPingTime = Date()
            }
            await pingRepeater(hexID: hexID, publicKey: pubKey)

            // 1s spacing between pings
            try? await Task.sleep(for: Constants.minPingSpacing)
        }

        // Mark any still-measuring as failed
        for i in repeaters.indices {
            if case .measuring = repeaters[i].txState {
                repeaters[i].txState = .failed
                repeaters[i].failCount += 1
            }
        }

        isRefreshing = false
    }

    /// Ping a single repeater by sending a trace and waiting for a response.
    private func pingRepeater(hexID: String, publicKey: Data) async {
        guard let sendTrace = sendTraceHandler else { return }

        let tag = UInt32.random(in: 0 ..< UInt32.max)
        let traceHashSize = 1 << Int(pathHashMode)
        let pathData = Data(publicKey.prefix(traceHashSize))

        let startTime = ContinuousClock.now
        pendingPings[tag] = (hexID: hexID, startTime: startTime)

        do {
            let result = try await sendTrace(tag, pathHashMode, pathData)
            txFlashTick &+= 1
            suggestedTimeoutMs = result.suggestedTimeoutMs

            // Wait for response or timeout
            try await Task.sleep(for: .milliseconds(result.suggestedTimeoutMs))

            // If still pending after timeout, it's a failure
            if pendingPings.removeValue(forKey: tag) != nil {
                updateRepeater(hexID: hexID) {
                    $0.txState = .failed
                    $0.failCount += 1
                }
                logger.debug("Ping timeout for repeater \(hexID) (failCount: \(self.repeaters.first { $0.id == hexID }?.failCount ?? -1))")
            }
        } catch is CancellationError {
            pendingPings.removeValue(forKey: tag)
        } catch {
            pendingPings.removeValue(forKey: tag)
            updateRepeater(hexID: hexID) {
                $0.txState = .failed
                $0.failCount += 1
            }
            logger.error("Ping failed for \(hexID): \(error.localizedDescription)")
        }
    }

    // MARK: - Round-Robin Engine

    /// Start the always-on round-robin ping engine.
    /// Runs continuously, pinging one repeater at a time with adaptive intervals.
    private func startRoundRobin() {
        roundRobinTask?.cancel()
        roundRobinTask = Task { [weak self] in
            // Wait for handlers to be wired and initial discover to populate repeaters
            try? await Task.sleep(for: .seconds(5))

            while !Task.isCancelled {
                guard let self else { break }

                // 1. Prune stale repeaters
                self.pruneStaleRepeaters()

                // 2. Find next repeater to ping
                if let target = self.nextRepeaterToPing(),
                   let publicKey = target.publicKey {
                    let hexID = target.id

                    // Mark as measuring
                    self.updateRepeater(hexID: hexID) {
                        $0.txState = .measuring
                        $0.lastPingTime = Date()
                    }

                    // Ping it
                    await self.pingRepeater(hexID: hexID, publicKey: publicKey)

                    // Enforce minimum 1s spacing between pings
                    try? await Task.sleep(for: Constants.minPingSpacing)
                } else {
                    // Nothing to ping right now, sleep briefly and re-check
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    /// Calculate the desired ping interval for a repeater.
    private func desiredPingInterval(for repeater: RepeaterSignal) -> TimeInterval? {
        guard repeater.failCount < Constants.maxFailCount else { return nil }

        let base: TimeInterval
        if repeater.failCount > 0 {
            switch repeater.failCount {
            case 1:  base = Constants.failRetryInterval1
            case 2:  base = Constants.failRetryInterval2
            default: base = Constants.failRetryInterval3
            }
        } else {
            let isBest = (bestRepeater?.id == repeater.id)
            base = isBest ? Constants.bestRepeaterInterval : Constants.otherRepeaterInterval
        }
        // Motion hint shortens intervals when moving (÷1/2/4), mirroring firmware's _td.
        return base / Double(motionDivisor)
    }

    /// Select the next repeater that needs pinging, or nil if none are due.
    private func nextRepeaterToPing() -> RepeaterSignal? {
        // Skip during manual refresh — refreshAll handles its own pinging
        guard !isRefreshing else { return nil }

        let now = Date()
        var bestCandidate: (repeater: RepeaterSignal, urgency: TimeInterval)?

        for repeater in repeaters {
            // Skip repeaters without public keys (can't ping them)
            guard repeater.publicKey != nil else { continue }

            // Get desired interval; nil means "stop pinging this one"
            guard let interval = desiredPingInterval(for: repeater) else { continue }

            // TX unknown always gets priority (never been pinged)
            if case .unknown = repeater.txState {
                let urgency: TimeInterval = -.infinity // highest priority
                if bestCandidate == nil || urgency < bestCandidate!.urgency {
                    bestCandidate = (repeater, urgency)
                }
                continue
            }

            // Check if enough time has passed since last ping
            let lastPing = repeater.lastPingTime ?? .distantPast
            let elapsed = now.timeIntervalSince(lastPing)
            let overdue = elapsed - interval

            if overdue >= 0 {
                // This repeater is due; more overdue = higher priority (larger overdue = more negative urgency)
                let urgency = -overdue
                if bestCandidate == nil || urgency < bestCandidate!.urgency {
                    bestCandidate = (repeater, urgency)
                }
            }
        }

        return bestCandidate?.repeater
    }

    // MARK: - Notification Subscriptions

    private func subscribeToDiscoverResponses() {
        discoverObserver?.cancel()
        logger.debug("subscribeToDiscoverResponses: subscribing, deviceID=\(self.deviceID?.uuidString.prefix(8) ?? "nil")")
        discoverObserver = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .discoverResponseReceived) {
                guard !Task.isCancelled else { break }
                guard let self else {
                    self?.logger.warning("subscribeToDiscoverResponses: self is nil, breaking")
                    break
                }

                guard let userInfo = notification.userInfo else {
                    self.logger.warning("subscribeToDiscoverResponses: notification has no userInfo")
                    continue
                }

                let hexID = userInfo["hexID"] as? String
                let rxSnr = userInfo["rxSnr"] as? Double
                let notifDeviceID = userInfo["deviceID"] as? UUID

                self.logger.debug("subscribeToDiscoverResponses: got notification hexID=\(hexID ?? "nil") rxSnr=\(rxSnr.map { String($0) } ?? "nil") notifDeviceID=\(notifDeviceID?.uuidString.prefix(8) ?? "nil") myDeviceID=\(self.deviceID?.uuidString.prefix(8) ?? "nil")")

                guard let hexID, let rxSnr, let notifDeviceID,
                      notifDeviceID == self.deviceID else {
                    self.logger.debug("subscribeToDiscoverResponses: skipping — guard failed (deviceID match: \(notifDeviceID == self.deviceID))")
                    continue
                }

                let txSnr = userInfo["txSnr"] as? Double
                let rssi = userInfo["rssi"] as? Int
                let publicKey = userInfo["publicKey"] as? Data

                self.logger.info("subscribeToDiscoverResponses: processing hexID=\(hexID) rxSnr=\(rxSnr) rssi=\(rssi.map { String($0) } ?? "nil")")

                self.handleDiscoverResponse(
                    hexID: hexID,
                    rxSnr: rxSnr,
                    txSnr: txSnr,
                    rssi: rssi,
                    publicKey: publicKey
                )
                self.rxFlashTick &+= 1

                self.logger.info("subscribeToDiscoverResponses: after handle, repeaters count=\(self.repeaters.count), bestRepeater=\(self.bestRepeater?.id ?? "nil")")
            }
        }
    }

    private func subscribeToRxLogTraces() {
        rxLogTraceObserver?.cancel()
        rxLogTraceObserver = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .rxLogTraceReceived) {
                guard !Task.isCancelled else { break }
                guard let self else { break }

                guard let userInfo = notification.userInfo,
                      let tag = userInfo["tag"] as? UInt32,
                      let notifDeviceID = userInfo["deviceID"] as? UUID,
                      notifDeviceID == self.deviceID else { continue }

                let localSnr = userInfo["localSnr"] as? Double
                let remoteSnr = userInfo["remoteSnr"] as? Double

                self.handleTraceResponse(tag: tag, localSnr: localSnr, remoteSnr: remoteSnr)
            }
        }
    }

    /// Listen for any relayed packet to passively track repeater signal quality.
    private func subscribeToRxLogPackets() {
        rxLogPacketObserver?.cancel()
        rxLogPacketObserver = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .rxLogPacketReceived) {
                guard !Task.isCancelled else { break }
                guard let self else { break }

                guard let userInfo = notification.userInfo,
                      let hexID = userInfo["hexID"] as? String,
                      let rxSnr = userInfo["rxSnr"] as? Double,
                      let notifDeviceID = userInfo["deviceID"] as? UUID,
                      notifDeviceID == self.deviceID else { continue }

                let rssi = userInfo["rssi"] as? Int

                self.logger.debug("rxLogPacket: repeater \(hexID) rxSnr=\(rxSnr) rssi=\(rssi.map { String($0) } ?? "nil")")

                // Update or insert repeater with RX-only data (no TX or publicKey from passive packets)
                self.handleDiscoverResponse(
                    hexID: hexID,
                    rxSnr: rxSnr,
                    txSnr: nil,
                    rssi: rssi,
                    publicKey: nil
                )
                self.rxFlashTick &+= 1
            }
        }
    }

    // MARK: - Event Handlers

    private func handleDiscoverResponse(
        hexID rawHexID: String,
        rxSnr: Double,
        txSnr: Double?,
        rssi: Int?,
        publicKey: Data?
    ) {
        // Discover responses carry the full public key, but the wire-level hexID is
        // only the first byte. Re-derive the display/match ID at the configured path
        // hash size (mode + 1 → 1/2/3 bytes) so the list honors the device's path hash
        // mode. Passive packets pass publicKey == nil and already arrive at the right
        // size — keep theirs.
        let hexID: String
        if let publicKey, !publicKey.isEmpty {
            let size = min(3, max(1, Int(pathHashMode) + 1))
            hexID = publicKey.prefix(size).map { String(format: "%02X", $0) }.joined()
        } else {
            hexID = rawHexID
        }

        let rxQuality = SNRQuality(snr: rxSnr)

        // Find existing repeater by exact match or prefix match.
        // e.g. "0C" from passive packets and "0C13" from discover responses
        // are the same repeater — merge into the longer ID.
        let idx = findRepeaterIndex(for: hexID)

        // Firmware-matching 75/25 RX smoothing for an already-tracked repeater
        // (raw value on first sight). Keeps the app's RX bars as steady as the OLED's.
        var effRx = rxSnr
        var effQuality = rxQuality
        if let idx, let old = repeaters[idx].rxSnr {
            effRx = (old * 3 + rxSnr) / 4
            effQuality = SNRQuality(snr: effRx)
        }

        if let idx {
            // Upgrade the ID to the longer variant if the new one is longer
            if hexID.count > repeaters[idx].id.count {
                repeaters[idx] = RepeaterSignal(
                    id: hexID,
                    name: repeaters[idx].name,
                    rxSnr: effRx,
                    rxQuality: effQuality,
                    txSnr: txSnr ?? repeaters[idx].txSnr,
                    txState: txSnr.map({ .measured(SNRQuality(snr: $0)) }) ?? repeaters[idx].txState,
                    rssi: rssi ?? repeaters[idx].rssi,
                    rttMs: repeaters[idx].rttMs,
                    lastHeard: Date(),
                    publicKey: publicKey ?? repeaters[idx].publicKey,
                    failCount: repeaters[idx].failCount,
                    lastPingTime: repeaters[idx].lastPingTime
                )
            } else {
                repeaters[idx].rxSnr = effRx
                repeaters[idx].rxQuality = effQuality
                repeaters[idx].lastHeard = Date()
                if let rssi { repeaters[idx].rssi = rssi }
                if let publicKey { repeaters[idx].publicKey = publicKey }
                if let txSnr {
                    repeaters[idx].txSnr = txSnr
                    repeaters[idx].txState = .measured(SNRQuality(snr: txSnr))
                }
            }
        } else {
            // Enforce max tracked repeaters limit. Match firmware: evict the oldest
            // (least-recently-heard) entry to make room for a newly-heard repeater.
            if repeaters.count >= Constants.maxTrackedRepeaters {
                if let oldestIdx = repeaters.indices.min(by: {
                    repeaters[$0].lastHeard < repeaters[$1].lastHeard
                }) {
                    let removed = repeaters.remove(at: oldestIdx)
                    logger.info("Evicted oldest repeater \(removed.id) to make room for \(hexID)")
                }
            }

            let txState: TXState
            if let txSnr {
                txState = .measured(SNRQuality(snr: txSnr))
            } else {
                txState = .unknown
            }
            repeaters.append(RepeaterSignal(
                id: hexID,
                name: nil,
                rxSnr: rxSnr,
                rxQuality: rxQuality,
                txSnr: txSnr,
                txState: txState,
                rssi: rssi,
                rttMs: nil,
                lastHeard: Date(),
                publicKey: publicKey
            ))
        }

        sortRepeaters()

        // Notify watched repeater listener
        if let watched = watchedRepeaterHexID,
           (hexID.hasPrefix(watched) || watched.hasPrefix(hexID)) {
            onWatchedRepeaterHeard?(hexID, rxSnr, rxQuality, txSnr)
        }

        // Reactive trigger: when we hear a repeater with no/stale TX measurement,
        // schedule a ping after 2s to get (or refresh) bidirectional signal data
        let idx2 = findRepeaterIndex(for: hexID)
        let shouldReactivePing: Bool
        if let idx2 {
            switch repeaters[idx2].txState {
            case .unknown:
                shouldReactivePing = true
            case .failed:
                // Re-ping if enough time has passed — receiving a packet suggests link may be back
                let lastPing = repeaters[idx2].lastPingTime ?? .distantPast
                shouldReactivePing = Date().timeIntervalSince(lastPing) > Constants.reactiveFailedCooldown
            default:
                shouldReactivePing = false
            }
        } else {
            shouldReactivePing = false
        }
        if let idx2 = idx2,
           shouldReactivePing,
           repeaters[idx2].publicKey != nil,
           !reactivePingTargets.contains(repeaters[idx2].id) {
            let targetID = repeaters[idx2].id
            reactivePingTargets.insert(targetID)
            logger.debug("Reactive trigger: will ping \(targetID) in 2s")

            reactivePingTask?.cancel()
            reactivePingTask = Task { [weak self] in
                try? await Task.sleep(for: Constants.reactiveTriggerDelay)
                guard !Task.isCancelled, let self else { return }
                self.reactivePingTargets.remove(targetID)
                guard let target = self.repeaters.first(where: { $0.id == targetID }),
                      let pubKey = target.publicKey,
                      case .unknown = target.txState else { return }
                self.updateRepeater(hexID: targetID) {
                    $0.txState = .measuring
                    $0.lastPingTime = Date()
                }
                await self.pingRepeater(hexID: targetID, publicKey: pubKey)
            }
        }
    }

    /// Find an existing repeater by exact match or prefix match.
    /// Returns the index if this hexID matches or is a prefix/extension of an existing entry.
    private func findRepeaterIndex(for hexID: String) -> Int? {
        // Exact match first
        if let idx = repeaters.firstIndex(where: { $0.id == hexID }) {
            return idx
        }
        // Check if incoming is a prefix of existing (e.g. "0C" matches "0C13")
        if let idx = repeaters.firstIndex(where: { $0.id.hasPrefix(hexID) }) {
            return idx
        }
        // Check if existing is a prefix of incoming (e.g. existing "0C", incoming "0C13")
        if let idx = repeaters.firstIndex(where: { hexID.hasPrefix($0.id) }) {
            return idx
        }
        return nil
    }

    private func handleTraceResponse(tag: UInt32, localSnr: Double?, remoteSnr: Double?) {
        guard let ping = pendingPings.removeValue(forKey: tag) else {
            return
        }

        let elapsed = ContinuousClock.now - ping.startTime
        let latencyMs = Int(elapsed / .milliseconds(1))

        updateRepeater(hexID: ping.hexID) { repeater in
            repeater.rttMs = latencyMs
            if let localSnr {
                // 75/25 RX smoothing (matches firmware onPingResponse).
                let smoothed = repeater.rxSnr.map { ($0 * 3 + localSnr) / 4 } ?? localSnr
                repeater.rxSnr = smoothed
                repeater.rxQuality = SNRQuality(snr: smoothed)
            }
            repeater.lastHeard = Date()
            if let remoteSnr {
                repeater.txSnr = remoteSnr
                repeater.txState = .measured(SNRQuality(snr: remoteSnr))
                repeater.failCount = 0
            } else {
                // Reply without a remote SNR — we can't measure how they hear us.
                // Don't fake TX as RX (firmware never substitutes); mark it unmeasured
                // and let backoff prevent immediate re-pinging.
                repeater.txState = .failed
                repeater.failCount += 1
            }
        }
        sortRepeaters()
    }

    // MARK: - Periodic Discover Probing

    /// Start periodic discover probes to find repeaters.
    /// Sends an initial probe immediately, then repeats every 30 seconds.
    /// Also piggybacks stale repeater pruning on each cycle.
    private func startDiscoverProbing() {
        discoverProbeTask?.cancel()
        guard sendDiscoverHandler != nil else { return }

        discoverProbeTask = Task { [weak self] in
            // Initial probe immediately
            guard let self else { return }
            await self.sendDiscoverProbe()

            // Periodic probes
            while !Task.isCancelled {
                try? await Task.sleep(for: Constants.discoverProbeInterval)
                guard !Task.isCancelled else { break }
                self.pruneStaleRepeaters()
                await self.sendDiscoverProbe()
            }
        }

        logger.info("Periodic discover probing started (every 30s)")
    }

    /// Send a single discover probe for repeaters.
    private func sendDiscoverProbe() async {
        guard let handler = sendDiscoverHandler else { return }
        do {
            try await handler()
            txFlashTick &+= 1
            logger.debug("Discover probe sent")
        } catch {
            logger.error("Discover probe failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Stale Pruning

    /// Remove repeaters not heard in 5 minutes.
    private func pruneStaleRepeaters() {
        let cutoff = Date().addingTimeInterval(-Constants.staleThreshold)
        let staleIDs = repeaters.filter { $0.lastHeard < cutoff }.map(\.id)
        guard !staleIDs.isEmpty else { return }

        repeaters.removeAll { $0.lastHeard < cutoff }
        // Clean up any pending pings for pruned repeaters
        pendingPings = pendingPings.filter { _, value in
            !staleIDs.contains(where: { value.hexID.hasPrefix($0) || $0.hasPrefix(value.hexID) })
        }
        // Clean up reactive ping targets
        reactivePingTargets.subtract(staleIDs)
        logger.info("Pruned \(staleIDs.count) stale repeater(s): \(staleIDs.joined(separator: ", "))")
    }

    // MARK: - Helpers

    private func updateRepeater(hexID: String, mutate: (inout RepeaterSignal) -> Void) {
        guard let idx = findRepeaterIndex(for: hexID) else { return }
        mutate(&repeaters[idx])
    }

    private func sortRepeaters() {
        let previousBest = repeaters.first?.id
        repeaters.sort { lhs, rhs in
            let lhsTier = sortTier(for: lhs)
            let rhsTier = sortTier(for: rhs)
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            return sortScore(for: lhs) > sortScore(for: rhs)
        }
        if let newBest = repeaters.first,
           newBest.id != previousBest,
           !isRefreshing {
            logger.info("Best repeater changed to \(newBest.id) — prioritizing next ping")
            updateRepeater(hexID: newBest.id) {
                $0.lastPingTime = nil
            }
        }
    }

    /// Sort tier: 0 = bidirectional (measured TX), 1 = measuring, 2 = unknown/failed
    private func sortTier(for r: RepeaterSignal) -> Int {
        switch r.txState {
        case .measured: return 0
        case .measuring: return 1
        case .unknown, .failed: return 2
        }
    }

    /// Sort score within a tier — the unified best-link score shared with the firmware:
    /// 0.6·TX + 0.4·RX with a weak-leg guard (see ``SignalBarsBlob/score(rxSnr:txSnr:)``).
    private func sortScore(for r: RepeaterSignal) -> Double {
        if case .measured = r.txState, let tx = r.txSnr {
            return SignalBarsBlob.score(rxSnr: r.rxSnr, txSnr: tx)
        }
        return SignalBarsBlob.score(rxSnr: r.rxSnr, txSnr: nil)
    }

    /// Update a repeater's display name from the contacts database.
    public func updateRepeaterName(hexID: String, name: String?) {
        updateRepeater(hexID: hexID) { $0.name = name }
    }
}

// MARK: - Send Trace Result

/// Result from sending a trace, carrying the suggested timeout.
public struct SendTraceResult: Sendable {
    public let suggestedTimeoutMs: Int

    public init(suggestedTimeoutMs: Int) {
        self.suggestedTimeoutMs = suggestedTimeoutMs
    }
}
