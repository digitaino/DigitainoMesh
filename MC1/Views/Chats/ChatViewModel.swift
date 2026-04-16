import SwiftUI
import UIKit
import MC1Services
import OSLog

/// ViewModel for chat operations
@Observable
@MainActor
final class ChatViewModel {

    // MARK: - Draft Storage

    /// In-memory draft storage that survives view destruction during navigation.
    /// Keyed by conversation identifier (e.g. "dm-{contactID}" or "ch-{channelID}").
    private static var drafts: [String: String] = [:]

    static func saveDraft(key: String, text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts.removeValue(forKey: key)
        } else {
            drafts[key] = text
        }
    }

    static func loadDraft(key: String) -> String? {
        drafts.removeValue(forKey: key)
    }

    // MARK: - Properties

    let logger = Logger(subsystem: "com.mc1", category: "ChatViewModel")

    /// Current conversations (contacts with messages)
    var conversations: [ContactDTO] = []

    /// All contacts for mention autocomplete (includes contacts without messages)
    var allContacts: [ContactDTO] = []

    /// Synthetic contacts for channel senders not in contacts
    var channelSenders: [ContactDTO] = []

    /// O(1) lookup for channel sender names
    var channelSenderNames: Set<String> = []

    /// Sender name → latest message timestamp (for mention sort order)
    var channelSenderOrder: [String: UInt32] = [:]

    /// O(1) lookup for contact names
    var contactNameSet: Set<String> = []

    /// Current channels with messages
    var channels: [ChannelDTO] = []

    /// Current room sessions
    var roomSessions: [RemoteNodeSessionDTO] = []

    /// Combined conversations (contacts + channels + rooms) - favorites first
    var allConversations: [Conversation] {
        favoriteConversations + nonFavoriteConversations
    }

    /// Favorite conversations sorted by last message date
    var favoriteConversations: [Conversation] {
        rebuildConversationCacheIfNeeded()
        touchObservationDependencies()
        return cachedFavoriteConversations
    }

    /// Non-favorite conversations sorted by last message date
    var nonFavoriteConversations: [Conversation] {
        rebuildConversationCacheIfNeeded()
        touchObservationDependencies()
        return cachedNonFavoriteConversations
    }

    // MARK: - Conversation Cache

    @ObservationIgnored private var cachedFavoriteConversations: [Conversation] = []
    @ObservationIgnored private var cachedNonFavoriteConversations: [Conversation] = []
    @ObservationIgnored private var conversationCacheValid = false
    @ObservationIgnored var urlDetectionTask: Task<Void, Never>?
    // Stored for lifecycle tracking; queue drains independently of conversation
    @ObservationIgnored var queueProcessorTask: Task<Void, Never>?
    @ObservationIgnored var channelQueueTask: Task<Void, Never>?

    /// Fallback date for conversations with no messages, used to sort them to the end.
    private static let noMessageSentinel = Date.distantPast

    /// Invalidates the conversation cache, forcing rebuild on next access
    func invalidateConversationCache() {
        conversationCacheValid = false
    }

    /// Touch source arrays to maintain observation dependencies even when cache is valid.
    /// Without this, SwiftUI won't track changes after initial render because
    /// @ObservationIgnored cache properties don't register dependencies.
    private func touchObservationDependencies() {
        _ = conversations.count
        _ = channels.count
        _ = roomSessions.count
    }

    private func rebuildConversationCacheIfNeeded() {
        guard !conversationCacheValid else { return }

        let contactConversations = conversations
            .filter { $0.type != .repeater && !$0.isBlocked }
            .map { Conversation.direct($0) }
        let wxCommandChannel = appState?.wxCommandChannelName ?? ""
        let channelConversations = channels
            .filter { !$0.name.isEmpty || $0.hasSecret }
            .filter { !SyncCoordinator.isWeatherSystemChannel($0.name, commandChannelName: wxCommandChannel) }
            .map { Conversation.channel($0) }
        let roomConversations = roomSessions.map { Conversation.room($0) }
        let all = contactConversations + channelConversations + roomConversations

        cachedFavoriteConversations = sortedByLastMessage(all.filter { $0.isFavorite })
        cachedNonFavoriteConversations = sortedByLastMessage(all.filter { !$0.isFavorite })

        conversationCacheValid = true
    }

    /// Sorts conversations by last message date, most recent first.
    /// Weather discovery channels are pinned to the bottom so they don't float up on new messages.
    private func sortedByLastMessage(_ items: [Conversation]) -> [Conversation] {
        items.sorted { a, b in
            let aIsDiscovery = a.isWeatherDiscoveryChannel
            let bIsDiscovery = b.isWeatherDiscoveryChannel
            if aIsDiscovery != bIsDiscovery { return bIsDiscovery }
            return (a.lastMessageDate ?? Self.noMessageSentinel) > (b.lastMessageDate ?? Self.noMessageSentinel)
        }
    }

    /// Messages for the current conversation
    var messages: [MessageDTO] = []

    /// Pre-computed display items for efficient cell rendering
    var displayItems: [MessageDisplayItem] = []

    /// O(1) message lookup by ID (used by views to get full DTO when needed)
    var messagesByID: [UUID: MessageDTO] = [:]

    /// O(1) display item index lookup by message ID
    var displayItemIndexByID: [UUID: Int] = [:]

    /// Current contact being chatted with
    var currentContact: ContactDTO?

    /// Current channel being viewed
    var currentChannel: ChannelDTO?

    /// Loading state
    var isLoading = false

    /// Whether data has been loaded at least once (prevents empty state flash)
    var hasLoadedOnce = false

    /// Error message if any
    var errorMessage: String?

    /// Whether to show retry error alert
    var showRetryError = false

    /// Message text being composed
    var composingText = ""

    /// Queue of message IDs waiting to be sent
    var sendQueue: [QueuedMessage] = []

    /// Whether the queue processor is running
    var isProcessingQueue = false

    /// Queue of channel messages waiting to be sent
    @ObservationIgnored var channelSendQueue: [QueuedChannelMessage] = []

    /// Whether the channel queue processor is running
    @ObservationIgnored var isProcessingChannelQueue = false

    /// Whether a channel message retry is in progress
    @ObservationIgnored var isRetryingChannelMessage = false

    /// Number of messages in the send queue (for testing)
    var sendQueueCount: Int { sendQueue.count }

    /// Last message previews cache
    var lastMessageCache: [UUID: MessageDTO] = [:]

    /// Preview state per message (keyed by message ID)
    var previewStates: [UUID: PreviewLoadState] = [:]

    /// Loaded preview data per message (keyed by message ID)
    var loadedPreviews: [UUID: LinkPreviewDataDTO] = [:]

    /// In-flight preview fetch tasks (prevents duplicate fetches)
    var previewFetchTasks: [UUID: Task<Void, Never>] = [:]

    /// Raw image data per message (keyed by message ID)
    var loadedImageData: [UUID: Data] = [:]

    /// Pre-decoded UIImage per message (avoids decoding in view body)
    var decodedImages: [UUID: UIImage] = [:]

    /// Pre-decoded link preview assets (single dictionary to batch Observable notifications)
    var decodedPreviewAssets: [UUID: DecodedPreviewAssets] = [:]

    /// Tracks in-flight legacy preview decode tasks to prevent duplicates
    var legacyPreviewDecodeInFlight: Set<UUID> = []

    /// Whether each image message is a GIF (computed once during decode)
    var imageIsGIF: [UUID: Bool] = [:]

    /// In-flight image fetch tasks
    var imageFetchTasks: [UUID: Task<Void, Never>] = [:]

    /// In-flight reaction sends (prevents duplicate reactions on rapid taps)
    /// Key format: "{messageID}-{emoji}"
    var inFlightReactions: Set<String> = []

    /// Cached URL detection results to avoid re-running NSDataDetector on rebuilds
    var cachedURLs: [UUID: URL?] = [:]

    /// Message ID eligible for the "no repeats heard" retry card, or `nil` if none.
    var noRepeatsRetryMessageID: UUID?

    /// Task that schedules the no-repeats retry card appearance after a delay.
    @ObservationIgnored var noRepeatsRetryTask: Task<Void, Never>?

    /// Set of message IDs whose duplicate groups are currently expanded.
    /// Keyed by the first message ID in each group.
    var expandedDuplicateGroups: Set<UUID> = []

    /// Cached shared route detection results per message ID
    @ObservationIgnored var cachedSharedRoutes: [UUID: SharedRoute?] = [:]

    /// Cached formatted text per message (avoids rebuilding AttributedString on every render)
    @ObservationIgnored var formattedTexts: [UUID: AttributedString] = [:]

    /// Returns cached formatted text for a message, building and caching on first access
    func formattedText(
        for messageID: UUID,
        text: String,
        isOutgoing: Bool,
        currentUserName: String?,
        isHighContrast: Bool
    ) -> AttributedString {
        if let cached = formattedTexts[messageID] { return cached }
        let result = MessageText.buildFormattedText(
            text: text,
            isOutgoing: isOutgoing,
            currentUserName: currentUserName,
            isHighContrast: isHighContrast
        )
        formattedTexts[messageID] = result
        return result
    }

    // MARK: - Pagination State

    /// Whether currently fetching older messages (exposed for UI binding)
    var isLoadingOlder = false

    /// Whether more messages exist beyond what's loaded
    var hasMoreMessages = true

    /// Number of messages to fetch per page
    let pageSize = 50

    /// Total messages fetched from database (unfiltered, for accurate offset calculation)
    var totalFetchedCount = 0

    /// Message ID that should show the "New Messages" divider above it
    var newMessagesDividerMessageID: UUID?

    /// Whether the divider position has been computed for the current conversation
    var dividerComputed = false

    /// Minimum unread count before showing the "New Messages" divider
    private let newMessagesDividerMinUnreadCount = 10

    /// Computes the divider message ID from a fetched (unfiltered) message array.
    /// Must be called before filtering. Sets `dividerComputed = true`.
    func computeDividerPosition(from messages: [MessageDTO], unreadCount: Int) {
        guard !dividerComputed, unreadCount > newMessagesDividerMinUnreadCount else { return }
        let dividerIndex = max(0, messages.count - unreadCount)
        if dividerIndex < messages.count {
            newMessagesDividerMessageID = messages[dividerIndex].id
        }
        dividerComputed = true
    }

    // MARK: - Dependencies

    var dataStore: DataStore?
    var linkPreviewCache: (any LinkPreviewCaching)?
    var messageService: MessageService?
    var notificationService: NotificationService?
    private var channelService: ChannelService?
    private var roomServerService: RoomServerService?
    var contactService: ContactService?
    var syncCoordinator: SyncCoordinator?
    weak var appState: AppState?

    /// Contact ID currently having its favorite status toggled (for loading UI)
    var togglingFavoriteID: UUID?

    // MARK: - Search State

    /// Current global search results
    var globalSearchResults = GlobalSearchResults()

    /// In-flight global search task
    @ObservationIgnored var globalSearchTask: Task<Void, Never>?

    /// Current within-conversation search state
    var conversationSearch = ConversationSearchState()

    /// In-flight within-conversation search task
    @ObservationIgnored var conversationSearchTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {}

    /// Configure with services from AppState (with link preview cache for message views)
    func configure(appState: AppState, linkPreviewCache: any LinkPreviewCaching) {
        self.appState = appState
        self.dataStore = appState.offlineDataStore
        self.messageService = appState.services?.messageService
        self.notificationService = appState.services?.notificationService
        self.channelService = appState.services?.channelService
        self.roomServerService = appState.services?.roomServerService
        self.contactService = appState.services?.contactService
        self.syncCoordinator = appState.syncCoordinator
        self.linkPreviewCache = linkPreviewCache
    }

    /// Configure with services from AppState (for conversation list views that don't show previews)
    func configure(appState: AppState) {
        self.appState = appState
        self.dataStore = appState.offlineDataStore
        self.messageService = appState.services?.messageService
        self.notificationService = appState.services?.notificationService
        self.channelService = appState.services?.channelService
        self.roomServerService = appState.services?.roomServerService
        self.contactService = appState.services?.contactService
        self.syncCoordinator = appState.syncCoordinator
    }

    /// Configure with services (for testing)
    func configure(dataStore: DataStore, messageService: MessageService, linkPreviewCache: any LinkPreviewCaching) {
        self.dataStore = dataStore
        self.messageService = messageService
        self.linkPreviewCache = linkPreviewCache
    }

    // MARK: - Timestamp Helpers

    /// Time gap (in seconds) that breaks message grouping for timestamps and sender names.
    static let messageGroupingGapSeconds = 300

    /// Pre-computed display flags for a single message
    struct DisplayFlags {
        let showTimestamp: Bool
        let showDirectionGap: Bool
        let showSenderName: Bool
    }

    /// Computes all display flags in a single pass to avoid redundant message lookups.
    /// Used by buildDisplayItems() for O(n) performance instead of O(3n).
    static func computeDisplayFlags(for message: MessageDTO, previous: MessageDTO?) -> DisplayFlags {
        guard let previous else {
            // First message: show timestamp, no direction gap, show sender name
            return DisplayFlags(showTimestamp: true, showDirectionGap: false, showSenderName: true)
        }

        // Time gap calculation based on receive time (consistent with sort order)
        let timeGap = abs(Int(message.createdAt.timeIntervalSince(previous.createdAt)))

        // Timestamp: gap > 5 minutes
        let showTimestamp = timeGap > messageGroupingGapSeconds

        // Direction gap: direction changed from previous
        let showDirectionGap = message.direction != previous.direction

        // Sender name grouping (channel messages only)
        let showSenderName: Bool
        if message.contactID != nil || message.isOutgoing {
            // Direct messages or outgoing: always true (UI ignores for direct messages anyway)
            showSenderName = true
        } else if previous.isOutgoing || timeGap > messageGroupingGapSeconds {
            // Direction change or time gap breaks group
            showSenderName = true
        } else if let currentName = message.senderNodeName, let previousName = previous.senderNodeName {
            // Same sender continues group
            showSenderName = currentName != previousName
        } else {
            // Malformed message: show name to be safe
            showSenderName = true
        }

        return DisplayFlags(showTimestamp: showTimestamp, showDirectionGap: showDirectionGap, showSenderName: showSenderName)
    }

    // MARK: - Duplicate Message Collapsing

    /// Toggle expansion of a duplicate message group, then rebuild display items.
    func toggleDuplicateGroupExpansion(groupLeaderID: UUID) {
        if expandedDuplicateGroups.contains(groupLeaderID) {
            expandedDuplicateGroups.remove(groupLeaderID)
        } else {
            expandedDuplicateGroups.insert(groupLeaderID)
        }
        buildDisplayItems()
    }

    /// Determines if two consecutive messages are duplicates (same sender, same text).
    static func isDuplicateOfPrevious(message: MessageDTO, previous: MessageDTO) -> Bool {
        guard message.text == previous.text else { return false }
        guard message.direction == previous.direction else { return false }

        // For channel messages: sender node name must match
        if message.contactID == nil {
            return message.senderNodeName == previous.senderNodeName
                && message.senderNodeName != nil
        }

        // For DMs: direction match is sufficient (only two parties)
        return true
    }

    // MARK: - No Repeats Retry Card

    /// Schedule the "no repeats heard" retry card for a sent message.
    /// Shows after a delay if no repeats have been recorded by then.
    func scheduleNoRepeatsRetry(for messageID: UUID) {
        noRepeatsRetryTask?.cancel()
        noRepeatsRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            // Only show if the message has no repeats and is done sending
            // (sent/delivered — not pending, sending, retrying, or failed)
            if let msg = messages.first(where: { $0.id == messageID }),
               msg.heardRepeats == 0,
               msg.isOutgoing,
               msg.status == .sent || msg.status == .delivered {
                logger.info("No repeats after timeout for message \(messageID), showing retry card")
                noRepeatsRetryMessageID = messageID
            }
        }
    }

    /// Clear the retry card (e.g., when repeats arrive or message is resent).
    func clearNoRepeatsRetry() {
        noRepeatsRetryTask?.cancel()
        noRepeatsRetryTask = nil
        noRepeatsRetryMessageID = nil
    }

    // MARK: - TX Power for Queued Messages

    /// Apply the correct TX power before sending a queued message.
    /// If the message has a one-shot override, applies that dBm directly.
    /// Otherwise, applies the adaptive power service's current level.
    /// Returns the dBm value that was applied (for recording on the message).
    @discardableResult
    func applyPowerForMessage(overrideDbm: Int8?) async -> Int8? {
        guard let power = appState?.adaptivePowerService,
              power.isEnabled,
              let handler = power.setTxPowerHandler else { return nil }

        let dbm: Int8
        if let override = overrideDbm {
            dbm = override
            logger.info("Applying one-shot TX power: \(dbm)dBm")
        } else {
            dbm = power.currentRadioDbm
        }

        let maxRetries = 3
        for attempt in 1...maxRetries {
            do {
                let confirmed = try await handler(dbm)
                if attempt > 1 {
                    logger.info("TX power verified on attempt \(attempt): \(dbm)dBm → device confirmed \(confirmed)dBm")
                } else {
                    logger.info("Verified TX power: \(dbm)dBm → device confirmed \(confirmed)dBm")
                }
                return confirmed
            } catch {
                logger.warning("TX power attempt \(attempt)/\(maxRetries) failed: \(error.localizedDescription)")
                if attempt < maxRetries {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
        logger.error("TX power verification failed after \(maxRetries) attempts for \(dbm)dBm")
        return nil
    }
}

// MARK: - Environment Key

extension EnvironmentValues {
    @Entry var chatViewModel: ChatViewModel? = nil
}
