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
    private let dataStore: PersistenceStore
    private let logger = PersistentLogger(subsystem: "MC1", category: "SurveyService")

    private var deviceID: UUID?
    private var activeSessionID: UUID?

    /// Called when a new survey point is recorded (for live map updates).
    private var onPointRecorded: SurveyPointHandler?

    /// Provider that returns the current GPS fix.
    private var locationProvider: SurveyLocationProvider?

    /// Whether active probing is currently enabled. When true, incoming control (discover)
    /// and trace response packets are classified as active probe results.
    private var isProbingActive: Bool = false

    /// Maximum GPS accuracy to accept (meters). Points with worse accuracy are discarded.
    private let maxAccuracyMeters: Double = 100

    /// Maximum GPS age to accept (seconds). Stale fixes are discarded.
    /// CoreLocation's distanceFilter means updates only arrive on movement,
    /// so a stationary user's fix goes stale quickly. 30s is generous enough
    /// for wardriving while still rejecting truly outdated fixes.
    private let maxLocationAgeSeconds: TimeInterval = 30

    public init(dataStore: PersistenceStore) {
        self.dataStore = dataStore
    }

    // MARK: - Configuration

    /// Configure the service with device context.
    /// Also closes any orphaned sessions from previous app runs.
    public func configure(deviceID: UUID) async {
        self.deviceID = deviceID

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

        // Get current GPS location
        guard let fix = await locationProvider?() else {
            logger.debug("Survey: no GPS fix available, skipping packet")
            return
        }

        // Validate GPS quality
        guard fix.horizontalAccuracy <= maxAccuracyMeters else {
            logger.debug("Survey: GPS accuracy \(fix.horizontalAccuracy)m exceeds \(self.maxAccuracyMeters)m limit")
            return
        }

        // Validate GPS freshness
        let age = abs(fix.timestamp.timeIntervalSinceNow)
        guard age <= maxLocationAgeSeconds else {
            logger.debug("Survey: GPS fix age \(age)s exceeds \(self.maxLocationAgeSeconds)s limit")
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
        // For TRACE responses: trace target hashes represent ALL nodes the flood trace
        // reached (repeaters, chat nodes, sensors, etc.) — NOT heard repeaters.
        // traceResponseCount already tracks trace reach separately, so skip them here.
        // For CONTROL packets (discover responses): extract the responder's public key from the payload.
        //   Discover response packetPayload format: [0x9x:1][snr_in:1][tag:4][pubkey:8-32]
        //   where x = node type. The pubkey starts at offset 6.
        // For other packets: use pathNodes (the routing hops from the network path).
        let pathHexIDs: [String] = {
            // Note: traceTargetHashes (mesh reachability data) is tracked separately via
            // traceResponseCount. Here we extract the *forwarding repeater* from pathNodes,
            // which is present on trace responses just like any other packet.
            if entry.payloadType == .control {
                let pubkey = Self.extractDiscoverResponsePubkey(from: entry.packetPayload)
                return pubkey.map { [$0] } ?? []
            }
            let hashSize = entry.pathHashSize
            guard hashSize > 0, !entry.pathNodes.isEmpty else {
                return []
            }
            let bytes = Array(entry.pathNodes)
            let ids = stride(from: 0, to: bytes.count, by: hashSize).map { start in
                let end = min(start + hashSize, bytes.count)
                return Data(bytes[start..<end]).hexString()
            }
            return ids
        }()

        // Classify as active probe result when probing is enabled and this is a
        // probe response packet (discover response or trace response).
        let isActive = isProbingActive && (entry.payloadType == .control || entry.payloadType == .trace)

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

    // MARK: - Discover Response Parsing

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
