import Foundation
import MeshCore

// MARK: - Message Service Actor

/// Actor-isolated service for sending messages with retry logic and ACK tracking.
///
/// `MessageService` manages all message operations including:
/// - Sending direct messages to contacts with single-attempt or automatic retry
/// - Sending channel broadcast messages
/// - Tracking pending message acknowledgements (ACKs)
/// - Handling delivery confirmations and failures
/// - Automatic retry with flood routing fallback
///
/// # Example Usage
///
/// ```swift
/// // Send a message with automatic retry
/// let message = try await messageService.sendMessageWithRetry(
///     text: "Hello!",
///     to: contact
/// ) { messageDTO in
///     // Message saved, update UI immediately
///     await updateUI(with: messageDTO)
/// }
/// ```
///
/// # ACK Tracking
///
/// After sending a message, the service tracks pending ACKs and automatically:
/// - Marks messages as delivered when ACK is received
/// - Marks messages as failed when timeout expires
/// - Tracks repeat acknowledgements for network analysis
///
/// Call `startEventMonitoring()` to begin processing ACKs from the session.
public actor MessageService {

    // MARK: - Properties

    let logger = PersistentLogger(subsystem: "com.mc1", category: "MessageService")

    let session: MeshCoreSession
    let dataStore: PersistenceStore
    let config: MessageServiceConfig

    /// Contact service for path management (optional - retry with reset requires this)
    private var contactService: ContactService?

    /// In-flight messages awaiting ACK, keyed by messageID.
    ///
    /// One entry per message. Each entry carries the full set of expected-ACK
    /// CRCs accumulated across retry attempts, so a late ACK from any attempt
    /// can still mark the message delivered.
    var pendingAcks: [UUID: PendingAck] = [:]

    /// ACK confirmation callback (ackCode, roundTripTime).
    ///
    /// `roundTripTime` is `nil` when firmware did not supply a `round_trip`
    /// value on the `PUSH_CODE_SEND_CONFIRMED` push (older firmware, truncated
    /// payloads). Callers must handle the nil case rather than substitute a
    /// fabricated value.
    private var ackConfirmationHandler: (@Sendable (UInt32, UInt32?) -> Void)?

    /// Message failure callback (messageID)
    var messageFailedHandler: (@Sendable (UUID) async -> Void)?

    /// Event broadcaster for retry status updates (messageID, attempt, maxAttempts)
    var retryStatusHandler: (@Sendable (UUID, Int, Int) async -> Void)?

    /// Handler for routing change events (contactID, isFlood)
    var routingChangedHandler: (@Sendable (UUID, Bool) async -> Void)?

    /// Provider for the phone's current GPS coordinates (latitude, longitude).
    /// Set by the app layer so outgoing messages can record the user's location at send time.
    private var userLocationProvider: (@Sendable () async -> (latitude: Double, longitude: Double)?)?

    /// Handler called after a message is saved, passing the message ID.
    /// The app layer uses this to request a fresh GPS fix in the background
    /// and patch the message's coordinates if the cached location was stale.
    private var locationPatchHandler: (@Sendable (UUID) async -> Void)?

    /// Task for periodic ACK expiry checking
    var ackCheckTask: Task<Void, Never>?

    /// Task for listening to session events
    private var eventListenerTask: Task<Void, Never>?

    /// Interval between ACK expiry checks (in seconds)
    var checkInterval: TimeInterval = 5.0

    /// Tracks message IDs currently being retried to prevent concurrent retry attempts
    var inFlightRetries: Set<UUID> = []

    // MARK: - Initialization

    /// Creates a new message service.
    ///
    /// - Parameters:
    ///   - session: The MeshCore session for sending messages
    ///   - dataStore: The persistence store for saving messages
    ///   - config: Configuration for retry and routing behavior (defaults to `.default`)
    public init(
        session: MeshCoreSession,
        dataStore: PersistenceStore,
        config: MessageServiceConfig = .default
    ) {
        self.session = session
        self.dataStore = dataStore
        self.config = config
    }

    /// Sets the contact service for path management during retry.
    ///
    /// The contact service is used to reset contact paths when switching to flood routing.
    ///
    /// - Parameter service: The contact service to use
    public func setContactService(_ service: ContactService) {
        self.contactService = service
    }

    /// Sets the provider for the phone's current GPS coordinates.
    /// Called by the app layer so outgoing messages can store where the user was at send time.
    public func setUserLocationProvider(
        _ provider: @escaping @Sendable () async -> (latitude: Double, longitude: Double)?
    ) {
        userLocationProvider = provider
    }

    /// Sets the handler called after a message is saved to patch its GPS coordinates.
    public func setLocationPatchHandler(
        _ handler: @escaping @Sendable (UUID) async -> Void
    ) {
        locationPatchHandler = handler
    }

    /// Returns the current user location from the provider, if set.
    func currentUserLocation() async -> (latitude: Double, longitude: Double)? {
        await userLocationProvider?()
    }

    /// Triggers the location patch handler for a saved message.
    func requestLocationPatch(messageID: UUID) {
        guard let handler = locationPatchHandler else { return }
        Task { await handler(messageID) }
    }

    /// Whether a contact service has been wired via `setContactService`.
    var hasContactServiceWired: Bool { contactService != nil }

    // MARK: - Event Listening

    /// Starts the session ACK event listener.
    ///
    /// Subscribes to `.anyAcknowledgement` events on the session and routes
    /// each one through `handleAcknowledgement`. Call after the connection is
    /// established; without this the listener never runs and pending DMs stay
    /// `.sent` even when ACKs arrive.
    ///
    /// # Lifecycle scope
    ///
    /// This method's counterpart is `stopEventMonitoring()`. It does **not**
    /// start the periodic ACK expiry checker — that's `startAckExpiryChecking()`,
    /// which has its own `stopAckExpiryChecking()` / `stopAndFailAllPending()`
    /// counterparts. `ServiceContainer` pairs both lifecycles together; direct
    /// callers must do the same.
    public func startEventMonitoring() {
        eventListenerTask?.cancel()

        eventListenerTask = Task { [weak self] in
            guard let self else { return }

            for await event in await session.events(filter: .anyAcknowledgement) {
                guard !Task.isCancelled else { break }

                if case .acknowledgement(let code, let tripTime) = event {
                    await handleAcknowledgement(code: code, tripTime: tripTime)
                }
            }
        }
    }

    /// Stops the session ACK event listener.
    ///
    /// Cancels `eventListenerTask` only. Does **not** cancel the periodic ACK
    /// expiry checker — for that, call `stopAckExpiryChecking()` (just stop
    /// the checker) or `stopAndFailAllPending()` (stop the checker and fail
    /// every in-flight DM, used during disconnect teardown).
    public func stopEventMonitoring() {
        eventListenerTask?.cancel()
        eventListenerTask = nil
    }

    // MARK: - ACK Handling

    /// Processes an acknowledgement from the session event stream.
    ///
    /// Finds the in-flight message whose accumulated `ackCodes` contains this
    /// CRC, marks it delivered, writes the delivery status + round-trip time
    /// to the database, and removes the entry. This is the sole DB writer for
    /// delivered status on the late-ACK path.
    func handleAcknowledgement(code: Data, tripTime: UInt32?) async {
        guard let (messageID, tracking) = pendingAcks.first(where: {
            $0.value.ackCodes.contains(code) && !$0.value.isDelivered
        }) else {
            return
        }

        pendingAcks[messageID]?.isDelivered = true

        // Persist `tripTime` only when firmware supplied it. Date()-based
        // fallbacks against `tracking.sentAt` would be wrong in either
        // direction once retries reset the timestamp, so we prefer a nil
        // `roundTripTime` over a fabricated value.
        let ackCodeUInt32 = code.ackCodeUInt32

        do {
            try await dataStore.updateMessageAck(
                id: messageID,
                ackCode: ackCodeUInt32,
                status: .delivered,
                roundTripTime: tripTime
            )
        } catch {
            logger.error("Failed to write delivered status: \(error.localizedDescription)")
        }

        do {
            try await dataStore.updateContactLastMessage(contactID: tracking.contactID, date: Date())
        } catch {
            logger.error("Failed to update contact lastMessageDate: \(error.localizedDescription)")
        }

        pendingAcks.removeValue(forKey: messageID)

        ackConfirmationHandler?(ackCodeUInt32, tripTime)

        logger.info("ACK received")
    }

    /// Sets a callback to be invoked when an ACK is received.
    ///
    /// - Parameter handler: Callback receiving (ackCode, roundTripTimeMs)
    public func setAckConfirmationHandler(_ handler: @escaping @Sendable (UInt32, UInt32?) -> Void) {
        ackConfirmationHandler = handler
    }

    /// Sets a callback to be invoked when a message fails after all retries.
    ///
    /// - Parameter handler: Callback receiving the failed message ID
    public func setMessageFailedHandler(_ handler: @escaping @Sendable (UUID) async -> Void) {
        messageFailedHandler = handler
    }

    /// Sets a callback to be invoked during retry attempts.
    ///
    /// Use this to update UI with retry progress.
    ///
    /// - Parameter handler: Callback receiving (messageID, currentAttempt, maxAttempts)
    public func setRetryStatusHandler(_ handler: @escaping @Sendable (UUID, Int, Int) async -> Void) {
        retryStatusHandler = handler
    }

    /// Sets a callback to be invoked when routing mode changes during retry.
    ///
    /// - Parameter handler: Callback receiving (contactID, isFloodRouting)
    public func setRoutingChangedHandler(_ handler: @escaping @Sendable (UUID, Bool) async -> Void) {
        routingChangedHandler = handler
    }
}
