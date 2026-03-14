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

    /// Maximum GPS accuracy to accept (meters). Points with worse accuracy are discarded.
    private let maxAccuracyMeters: Double = 100

    /// Maximum GPS age to accept (seconds). Stale fixes are discarded.
    private let maxLocationAgeSeconds: TimeInterval = 10

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
        guard let sessionID = activeSessionID else { return }
        guard let deviceID = self.deviceID else { return }

        // Get current GPS location
        guard let fix = await locationProvider?() else {
            return
        }

        // Validate GPS quality
        guard fix.horizontalAccuracy <= maxAccuracyMeters else {
            return
        }

        // Validate GPS freshness
        let age = abs(fix.timestamp.timeIntervalSinceNow)
        guard age <= maxLocationAgeSeconds else {
            return
        }

        // Check for duplicate packet
        do {
            let exists = try await dataStore.surveyPointExists(
                sessionID: sessionID,
                packetHash: entry.packetHash
            )
            if exists { return }
        } catch {
            logger.error("Dedup check failed: \(error.localizedDescription)")
        }

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
            packetHash: entry.packetHash
        )

        // Persist
        do {
            try await dataStore.saveSurveyPoint(point)
        } catch {
            logger.error("Failed to save survey point: \(error.localizedDescription)")
            return
        }

        // Notify handler (for live map update)
        if let handler = onPointRecorded {
            await handler(point)
        }
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
