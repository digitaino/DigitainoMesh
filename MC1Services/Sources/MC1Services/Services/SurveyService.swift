import CryptoKit
import Foundation
import MeshCore
import OSLog

/// Callback signature for when a survey point is recorded.
public typealias SurveyPointHandler = @Sendable (SignalSurveyPointDTO) async -> Void

/// Callback signature for getting the current GPS location.
public typealias SurveyLocationProvider = @Sendable () async -> SurveyLocationFix?

/// GPS fix data passed from the app's LocationService to the SurveyService actor.
public struct SurveyLocationFix: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let horizontalAccuracy: Double
    public let speed: Double?
    public let timestamp: Date

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double?,
        horizontalAccuracy: Double,
        speed: Double?,
        timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.timestamp = timestamp
    }
}

/// Service for recording signal survey data during wardriving sessions.
///
/// Hooks into RxLogService via a callback (like HeardRepeatsService) to receive
/// each incoming packet. When a survey is active, pairs the packet with the
/// user's current GPS location and persists a SignalSurveyPoint.
public actor SurveyService {
    private let session: MeshCoreSession
    private let dataStore: PersistenceStore
    private let logger = PersistentLogger(subsystem: "MC1", category: "SurveyService")

    private var deviceID: UUID?
    private var activeSessionID: UUID?

    /// Task monitoring MeshCore events for discover/trace responses.
    private var eventMonitorTask: Task<Void, Never>?

    /// Called when a new survey point is recorded (for live map updates).
    private var onPointRecorded: SurveyPointHandler?

    /// Provider that returns the current GPS fix.
    private var locationProvider: SurveyLocationProvider?

    /// Whether active probing is currently enabled. When true, incoming control (discover)
    /// and trace response packets are classified as active probe results.
    private var isProbingActive: Bool = false

    /// Local node name used to identify heard repeats of our own channel messages.
    /// A `.groupText` packet is only classified as an active probe result if the
    /// sender name (parsed from the decrypted text) matches this value.
    private var localNodeName: String?

    /// Maximum GPS accuracy to accept (meters). Points with worse accuracy are discarded.
    private let maxAccuracyMeters: Double = 100

    /// Maximum GPS age to accept (seconds). Stale fixes are discarded.
    /// CoreLocation's distanceFilter means updates only arrive on movement,
    /// so a stationary user's fix goes stale quickly. 30s is generous enough
    /// for wardriving while still rejecting truly outdated fixes.
    private let maxLocationAgeSeconds: TimeInterval = 30

    /// Relaxed GPS accuracy limit for active probe responses (meters).
    private let relaxedAccuracyMeters: Double = 200

    /// Relaxed GPS age limit for active probe responses (seconds).
    private let relaxedLocationAgeSeconds: TimeInterval = 60

    public init(session: MeshCoreSession, dataStore: PersistenceStore) {
        self.session = session
        self.dataStore = dataStore
    }

    // MARK: - Configuration

    /// Configure the service with device context.
    /// Also closes any orphaned sessions from previous app runs.
    public func configure(deviceID: UUID, localNodeName: String? = nil) async {
        self.deviceID = deviceID
        self.localNodeName = localNodeName

        // Close any sessions left open from a previous app run (crash, disconnect, etc.)
        do {
            let closed = try await dataStore.closeOrphanedSessions(deviceID: deviceID)
            if closed > 0 {
                logger.info("Closed \(closed) orphaned survey session(s)")
            }
        } catch {
            logger.error("Failed to close orphaned sessions: \(error.localizedDescription)")
        }

        // One-time backfill: retroactively classify existing survey points as active/passive
        // based on payloadType (.control and .trace are inherently active probe responses)
        if !UserDefaults.standard.bool(forKey: "surveyActiveProbeBackfillDone") {
            do {
                let updated = try await dataStore.backfillActiveProbeFlag()
                if updated > 0 {
                    logger.info("Backfilled isActiveProbe on \(updated) existing survey point(s)")
                }
                UserDefaults.standard.set(true, forKey: "surveyActiveProbeBackfillDone")
            } catch {
                logger.error("Failed to backfill active probe flag: \(error.localizedDescription)")
            }
        }

        logger.info("Configured with deviceID: \(deviceID)")
    }

    /// Sets the handler called when a survey point is recorded.
    public func setPointRecordedHandler(_ handler: SurveyPointHandler?) {
        self.onPointRecorded = handler
    }

    /// Sets the location provider callback.
    public func setLocationProvider(_ provider: @escaping SurveyLocationProvider) {
        self.locationProvider = provider
    }

    /// Sets whether active probing is enabled. When true, control (discover response)
    /// and trace response packets are classified as active probe results.
    public func setProbingActive(_ active: Bool) {
        self.isProbingActive = active
    }

    // MARK: - Event Monitoring

    /// Start monitoring MeshCore events for discover and trace responses.
    ///
    /// These events arrive on separate BLE response codes (0x8E controlData and
    /// 0x89 traceData) that RxLogService does not process. Without this, the survey
    /// never captures the bidirectional proof from active probes.
    public func startEventMonitoring() {
        eventMonitorTask?.cancel()

        eventMonitorTask = Task { [weak self] in
            guard let self else { return }
            let events = await session.events()

            for await event in events {
                guard !Task.isCancelled else { break }
                switch event {
                case .discoverResponse(let response):
                    await self.processDiscoverResponse(response)
                case .traceData(let traceInfo):
                    await self.processTraceResponse(traceInfo)
                default:
                    break
                }
            }
        }

        logger.info("Survey event monitoring started")
    }

    /// Stop monitoring MeshCore events.
    public func stopEventMonitoring() {
        eventMonitorTask?.cancel()
        eventMonitorTask = nil
    }

    // MARK: - GPS Helpers

    /// Get a validated GPS fix for survey recording.
    ///
    /// - Parameter relaxed: When true, uses wider accuracy (200m) and age (60s) limits.
    ///   Active probe responses use relaxed thresholds because they are high-value
    ///   bidirectional proof and the user is actively wardriving.
    private func getLocationForSurvey(relaxed: Bool = false) async -> SurveyLocationFix? {
        guard let fix = await locationProvider?() else {
            logger.debug("Survey: no GPS fix available")
            return nil
        }

        let accuracyLimit = relaxed ? relaxedAccuracyMeters : maxAccuracyMeters
        let ageLimit = relaxed ? relaxedLocationAgeSeconds : maxLocationAgeSeconds

        guard fix.horizontalAccuracy <= accuracyLimit else {
            logger.debug("Survey: GPS accuracy \(fix.horizontalAccuracy)m exceeds \(accuracyLimit)m limit")
            return nil
        }

        let age = abs(fix.timestamp.timeIntervalSinceNow)
        guard age <= ageLimit else {
            logger.debug("Survey: GPS fix age \(age)s exceeds \(ageLimit)s limit")
            return nil
        }

        return fix
    }

    /// Compute a SHA256-based packet hash for deduplication.
    private static func computeHash(from data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Session Management

    /// Whether a survey session is currently active.
    public var isActive: Bool { activeSessionID != nil }

    /// The active session ID, if any.
    public var currentSessionID: UUID? { activeSessionID }

    /// Start a new survey session.
    public func startSession(name: String? = nil) async throws -> SurveySessionDTO {
        guard let deviceID else {
            throw SurveyServiceError.notConfigured
        }
        guard activeSessionID == nil else {
            throw SurveyServiceError.sessionAlreadyActive
        }

        let session = try await dataStore.createSurveySession(
            deviceID: deviceID,
            name: name
        )
        activeSessionID = session.id
        logger.info("Started survey session: \(session.id)")
        return session
    }

    /// Force-clear any in-memory active session state without touching the database.
    /// Use this to recover from a stuck state (e.g. if configure already cleaned up the DB).
    public func forceReset() {
        activeSessionID = nil
    }

    /// Stop the active survey session.
    public func stopSession() async throws {
        guard let sessionID = activeSessionID else {
            throw SurveyServiceError.noActiveSession
        }

        try await dataStore.endSurveySession(id: sessionID)
        let pointCount = try await dataStore.countSurveyPoints(sessionID: sessionID)
        activeSessionID = nil
        logger.info("Ended survey session \(sessionID) with \(pointCount) points")
    }

    // MARK: - Packet Processing (called by RxLogService)

    /// Process an incoming RX log entry for signal survey recording.
    /// Called from RxLogService for each received packet.
    public func processForSurvey(_ entry: RxLogEntryDTO) async {
        guard let sessionID = activeSessionID else {
            // No active session — this is normal when survey is not running
            return
        }
        guard let deviceID = self.deviceID else {
            logger.warning("Survey: no deviceID configured")
            return
        }

        // Get current GPS location with standard quality gates
        guard let fix = await getLocationForSurvey(relaxed: false) else {
            return
        }

        // Check for duplicate packet
        do {
            let exists = try await dataStore.surveyPointExists(
                sessionID: sessionID,
                packetHash: entry.packetHash
            )
            if exists {
                logger.debug("Survey: duplicate packet hash, skipping")
                return
            }
        } catch {
            logger.error("Dedup check failed: \(error.localizedDescription)")
        }

        // Extract relay/target hex IDs.
        //
        // TRACE packets are special: the routing header's path[] array contains SNR
        // values (not hashes) — each repeater appends its SNR as it forwards.
        // The actual node hashes are in the packetPayload after offset 9.
        // So we MUST skip pathNodes for trace packets and use the payload hashes.
        //
        // CONTROL packets (discover responses): use pathNodes when available.
        //   If pathNodes are empty, fall back to extracting the responder's 2-byte
        //   public key prefix from the payload.
        //   Discover response packetPayload format: [0x9x:1][snr_in:1][tag:4][pubkey:8-32]
        //
        // Other packets: use pathNodes (the routing hops from the network path).

        let pathHexIDs: [String] = {
            // Trace packets: always extract from payload (pathNodes are SNR values, not hashes).
            // IMPORTANT: RxLogParser uses the routing header's pathLength to extract pathNodes,
            // but for trace packets the path[] array stores SNR values (1 byte each), not hashes
            // (hashSize bytes each). When hashSize > 1, the parser over-reads into the trace
            // payload by (hashSize - 1) * hopCount bytes. We must reconstruct the full trace
            // payload by prepending those stolen bytes.
            if entry.payloadType == .trace {
                return Self.extractTraceTargetHexIDs(from: entry)
            }

            // Non-trace packets: extract hex IDs from routing header pathNodes
            let hashSize = entry.pathHashSize
            if hashSize > 0, !entry.pathNodes.isEmpty {
                let bytes = Array(entry.pathNodes)
                // Validate: pathNodes byte count should equal hashSize * hopCount.
                // If mismatched (corrupt packet), only process the valid portion.
                let safeLen = min(bytes.count, hashSize * max(entry.hopCount, 1))
                let ids = stride(from: 0, to: safeLen, by: hashSize).map { start in
                    let end = min(start + hashSize, safeLen)
                    return Data(bytes[start..<end]).hexString()
                }
                return ids
            }
            // Fallback for control packets with no pathNodes
            if entry.payloadType == .control {
                let pubkey = Self.extractDiscoverResponsePubkey(from: entry.packetPayload)
                return pubkey.map { [$0] } ?? []
            }
            return []
        }()

        // Classify as active probe result when probing is enabled.
        // - .control (discover response) and .trace: always active during probing (deep scan).
        // - .groupText: only active when it's a heard repeat of OUR OWN channel message
        //   (sender name matches localNodeName). Other people's messages are passive.
        let isActive: Bool = {
            guard isProbingActive else { return false }
            if entry.payloadType == .control || entry.payloadType == .trace {
                return true
            }
            if entry.payloadType == .groupText, let nodeName = localNodeName, let text = entry.decodedText {
                if let (senderName, _) = ChannelMessageFormat.parse(text), senderName == nodeName {
                    return true
                }
            }
            return false
        }()

        // Create survey point
        let point = SignalSurveyPointDTO(
            deviceID: deviceID,
            surveySessionID: sessionID,
            timestamp: entry.receivedAt,
            latitude: fix.latitude,
            longitude: fix.longitude,
            altitude: fix.altitude,
            horizontalAccuracy: fix.horizontalAccuracy,
            speed: fix.speed,
            snr: entry.snr,
            rssi: entry.rssi,
            routeType: entry.routeType,
            payloadType: entry.payloadType,
            pathLength: entry.pathLength,
            packetHash: entry.packetHash,
            fromContactName: entry.fromContactName,
            pathNodeHexIDs: pathHexIDs,
            isActiveProbe: isActive
        )

        // Persist
        do {
            try await dataStore.saveSurveyPoint(point)
        } catch {
            logger.error("Failed to save survey point: \(error)")
            return
        }

        logger.debug("Survey: saved point (SNR: \(point.snr?.description ?? "nil"), relays: \(pathHexIDs.count))")

        // Notify handler (for live map update)
        if let handler = onPointRecorded {
            await handler(point)
        }
    }

    // MARK: - Direct Event Handlers (0x8E discover, 0x89 trace)

    /// Process a discover response event directly from MeshCore's event stream.
    ///
    /// These arrive on BLE response code 0x8E (controlData) which RxLogService
    /// does not process. This is the primary path for capturing bidirectional
    /// proof from active discovery probes.
    private func processDiscoverResponse(_ response: DiscoverResponse) async {
        guard let sessionID = activeSessionID else { return }
        guard let deviceID = self.deviceID else { return }

        // Use relaxed GPS thresholds — active probe responses are high-value data
        guard let fix = await getLocationForSurvey(relaxed: true) else { return }

        // Compute dedup hash from tag + pubkey prefix
        let hashInput = response.tag + response.publicKey.prefix(4)
        let packetHash = Self.computeHash(from: hashInput)

        do {
            if try await dataStore.surveyPointExists(sessionID: sessionID, packetHash: packetHash) {
                return
            }
        } catch {
            logger.error("Dedup check failed: \(error.localizedDescription)")
        }

        // Extract 2-byte pubkey hex ID (matches existing discover response parsing)
        let pubkeyHexID = response.publicKey.prefix(2)
            .map { String(format: "%02X", $0) }.joined()

        let point = SignalSurveyPointDTO(
            deviceID: deviceID,
            surveySessionID: sessionID,
            latitude: fix.latitude,
            longitude: fix.longitude,
            altitude: fix.altitude,
            horizontalAccuracy: fix.horizontalAccuracy,
            speed: fix.speed,
            snr: response.snr,
            txSnr: response.snrIn,
            rssi: response.rssi,
            routeType: .flood,
            payloadType: .control,
            pathLength: response.pathLength,
            packetHash: packetHash,
            pathNodeHexIDs: [pubkeyHexID],
            isActiveProbe: isProbingActive
        )

        do {
            try await dataStore.saveSurveyPoint(point)
        } catch {
            logger.error("Failed to save discover survey point: \(error)")
            return
        }

        logger.debug("Survey: saved discover response (SNR: \(response.snr), node: \(pubkeyHexID))")

        if let handler = onPointRecorded {
            await handler(point)
        }
    }

    /// Process a trace response event directly from MeshCore's event stream.
    ///
    /// These arrive on BLE response code 0x89 (traceData) which RxLogService
    /// does not process. Trace responses carry hop-by-hop path information
    /// proving mesh reach from the user's location.
    private func processTraceResponse(_ traceInfo: TraceInfo) async {
        guard let sessionID = activeSessionID else { return }
        guard let deviceID = self.deviceID else { return }

        guard let fix = await getLocationForSurvey(relaxed: true) else { return }

        // Compute dedup hash from tag + authCode
        var hashInput = Data()
        withUnsafeBytes(of: traceInfo.tag.littleEndian) { hashInput.append(contentsOf: $0) }
        withUnsafeBytes(of: traceInfo.authCode.littleEndian) { hashInput.append(contentsOf: $0) }
        let packetHash = Self.computeHash(from: hashInput)

        do {
            if try await dataStore.surveyPointExists(sessionID: sessionID, packetHash: packetHash) {
                return
            }
        } catch {
            logger.error("Dedup check failed: \(error.localizedDescription)")
        }

        // Extract hex IDs from trace path nodes (2-byte prefix each)
        let pathHexIDs: [String] = traceInfo.path.compactMap { node in
            guard let hashBytes = node.hashBytes, hashBytes.count >= 2 else { return nil }
            return hashBytes.prefix(2).map { String(format: "%02X", $0) }.joined()
        }

        // Use the last node's SNR (destination node, farthest reach) as RX SNR.
        // For traces with >1 hop, the last node's SNR is how that node heard us (TX SNR).
        let destinationSNR = traceInfo.path.last?.snr
        // First node's SNR is our local reception quality (RX from the nearest repeater).
        let localSNR = traceInfo.path.first?.snr
        // For single-hop traces: destinationSNR == localSNR, so txSnr is the remote side.
        // For multi-hop: last node SNR is the remote repeater's reception → txSnr.
        let txSnr = traceInfo.path.count > 1 ? destinationSNR : nil

        let point = SignalSurveyPointDTO(
            deviceID: deviceID,
            surveySessionID: sessionID,
            latitude: fix.latitude,
            longitude: fix.longitude,
            altitude: fix.altitude,
            horizontalAccuracy: fix.horizontalAccuracy,
            speed: fix.speed,
            snr: localSNR ?? destinationSNR,
            txSnr: txSnr,
            routeType: .flood,
            payloadType: .trace,
            pathLength: traceInfo.pathLength,
            packetHash: packetHash,
            pathNodeHexIDs: pathHexIDs,
            isActiveProbe: isProbingActive
        )

        do {
            try await dataStore.saveSurveyPoint(point)
        } catch {
            logger.error("Failed to save trace survey point: \(error)")
            return
        }

        logger.debug("Survey: saved trace response (hops: \(traceInfo.path.count), nodes: \(pathHexIDs))")

        if let handler = onPointRecorded {
            await handler(point)
        }
    }

    // MARK: - Discover Response Parsing (legacy RxLogData path)

    /// Extract the responder's public key hex from a control packet's payload.
    ///
    /// Discover response payload format (from firmware `onControlDataRecv`):
    /// `[payloadType:1][snr_in:1][tag:4][pubkey:8-32]`
    /// where `payloadType` upper nibble `0x90` = DISCOVER_RESP, lower nibble = node type
    /// (ADV_TYPE_REPEATER = 2).
    ///
    /// - Returns: Uppercase hex string of the first 2 bytes of the public key (e.g. "80A3"),
    ///   or nil if not a discover response from a repeater.
    private static func extractDiscoverResponsePubkey(from payload: Data) -> String? {
        // Minimum: 1 (type) + 1 (snr_in) + 4 (tag) + 2 (at least 2 bytes pubkey) = 8
        guard payload.count >= 8 else { return nil }
        let typeByte = payload[payload.startIndex]
        // Check upper nibble for DISCOVER_RESP (0x90)
        guard typeByte & 0xF0 == 0x90 else { return nil }
        // Check lower nibble for ADV_TYPE_REPEATER (2) — ignore sensors, rooms, etc.
        guard typeByte & 0x0F == 2 else { return nil }
        // Public key starts at offset 6; take first 2 bytes for better disambiguation
        let start = payload.startIndex + 6
        let pubkeyBytes = payload[start..<start+2]
        return pubkeyBytes.map { String(format: "%02X", $0) }.joined()
    }

    /// Extract repeater hex ID from a trace packet's RxLogEntry.
    ///
    /// Trace on-air payload format: `[tag:4][auth:4][flags:1][pubkey...]`
    /// The bytes after offset 9 are the responding node's **public key** (up to 32 bytes),
    /// NOT a list of separate node hashes. We extract the first 2 bytes as a hex prefix
    /// to match the discover response format (which also uses a 2-byte pubkey prefix).
    ///
    /// **Complication**: `RxLogParser` uses the routing header's `pathLength` byte to
    /// determine how many bytes to extract as `pathNodes`. But for trace packets, the
    /// path[] array stores SNR values (1 byte per hop), not hashes (hashSize bytes per hop).
    /// When hashSize > 1, the parser over-reads by `(hashSize - 1) * hopCount` bytes,
    /// consuming the start of the trace payload. We reconstruct the full trace payload
    /// by prepending those stolen bytes from `pathNodes`.
    ///
    /// - Returns: Array with a single uppercase hex string (2-byte pubkey prefix, e.g. "805D"),
    ///   or empty if the trace payload is too short.
    static func extractTraceTargetHexIDs(from entry: RxLogEntryDTO) -> [String] {
        let hashSize = entry.pathHashSize  // from routing header
        let hopCount = entry.hopCount
        let overConsumed = (hashSize > 1 && hopCount > 0) ? (hashSize - 1) * hopCount : 0

        // Reconstruct the full trace payload by prepending bytes stolen from pathNodes
        var tracePayload: Data
        if overConsumed > 0, entry.pathNodes.count >= hopCount + overConsumed {
            let stolenBytes = entry.pathNodes.suffix(overConsumed)
            tracePayload = Data(stolenBytes) + entry.packetPayload
        } else {
            tracePayload = entry.packetPayload
        }

        // Minimum: tag(4) + auth(4) + flags(1) + pubkey(2) = 11 bytes
        guard tracePayload.count >= 11 else { return [] }

        // Extract first 2 bytes of the public key as the repeater hex ID.
        // This matches the discover response format which also uses a 2-byte pubkey prefix.
        let pubkeyStart = tracePayload.startIndex + 9
        let pubkeyPrefix = tracePayload[pubkeyStart..<pubkeyStart + 2]
        let hexID = pubkeyPrefix.map { String(format: "%02X", $0) }.joined()

        return [hexID]
    }
}

// MARK: - Errors

public enum SurveyServiceError: Error, LocalizedError, Sendable {
    case notConfigured
    case sessionAlreadyActive
    case noActiveSession

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Survey service is not configured with a device."
        case .sessionAlreadyActive: "A survey session is already active."
        case .noActiveSession: "No survey session is active."
        }
    }
}
