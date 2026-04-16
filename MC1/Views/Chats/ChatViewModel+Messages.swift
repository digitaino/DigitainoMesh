import SwiftUI
import MC1Services

extension ChatViewModel {

    // MARK: - Notification Level

    /// Sets notification level for a conversation with optimistic UI update
    func setNotificationLevel(_ conversation: Conversation, level: NotificationLevel) async {
        guard appState?.connectionState == .ready else { return }
        let originalLevel = conversation.notificationLevel

        // Optimistic UI update
        updateConversationNotificationLevel(conversation, level: level)

        do {
            switch conversation {
            case .direct(let contact):
                // Contacts still use boolean muted
                try await dataStore?.setContactMuted(contact.id, isMuted: level == .muted)
            case .channel(let channel):
                try await dataStore?.setChannelNotificationLevel(channel.id, level: level)
            case .room(let session):
                try await dataStore?.setSessionNotificationLevel(session.id, level: level)
            }
            await notificationService?.updateBadgeCount()
        } catch {
            // Rollback on failure
            updateConversationNotificationLevel(conversation, level: originalLevel)
            logger.error("Failed to set notification level: \(error)")
        }
    }

    /// Toggles between muted and all (for swipe action)
    func toggleMute(_ conversation: Conversation) async {
        let newLevel: NotificationLevel = conversation.isMuted ? .all : .muted
        await setNotificationLevel(conversation, level: newLevel)
    }

    /// Updates the notification level in the local conversations array
    private func updateConversationNotificationLevel(_ conversation: Conversation, level: NotificationLevel) {
        invalidateConversationCache()
        switch conversation {
        case .direct(let contact):
            if let index = conversations.firstIndex(where: { $0.id == contact.id }) {
                conversations[index] = conversations[index].with(isMuted: level == .muted)
            }
        case .channel(let channel):
            if let index = channels.firstIndex(where: { $0.id == channel.id }) {
                channels[index] = channels[index].with(notificationLevel: level)
            }
        case .room(let session):
            if let index = roomSessions.firstIndex(where: { $0.id == session.id }) {
                roomSessions[index] = roomSessions[index].with(notificationLevel: level)
            }
        }
    }

    // MARK: - Favorite

    /// Sets favorite state for a conversation with optimistic UI update
    func setFavorite(_ conversation: Conversation, isFavorite: Bool) async {
        guard appState?.connectionState == .ready else { return }
        guard conversation.isFavorite != isFavorite else { return }

        // Reuse existing toggle logic
        await toggleFavorite(conversation)
    }

    /// Toggles favorite state for a conversation.
    ///
    /// For direct messages (contacts), this pushes the change to the device and waits
    /// for confirmation before updating the UI. For channels and rooms (app-only),
    /// this uses optimistic updates.
    ///
    /// - Parameters:
    ///   - conversation: The conversation to toggle
    ///   - disableAnimation: When true, disables SwiftUI List animations to prevent
    ///     conflicts with swipe action dismissal animations
    func toggleFavorite(_ conversation: Conversation, disableAnimation: Bool = false) async {
        guard appState?.connectionState == .ready else { return }
        let originalState = conversation.isFavorite
        let newState = !originalState

        switch conversation {
        case .direct(let contact):
            // Contacts sync with device - wait for confirmation
            togglingFavoriteID = contact.id
            defer { togglingFavoriteID = nil }

            do {
                try await contactService?.setContactFavorite(contact.id, isFavorite: newState)
                // Device confirmed - update local UI
                applyFavoriteUpdate(conversation, isFavorite: newState, disableAnimation: disableAnimation)
            } catch {
                logger.error("Failed to toggle contact favorite: \(error)")
            }

        case .channel(let channel):
            // Channels are app-only - optimistic update
            applyFavoriteUpdate(conversation, isFavorite: newState, disableAnimation: disableAnimation)

            do {
                try await dataStore?.setChannelFavorite(channel.id, isFavorite: newState)
            } catch {
                // Rollback on failure
                applyFavoriteUpdate(conversation, isFavorite: originalState, disableAnimation: disableAnimation)
                logger.error("Failed to toggle channel favorite: \(error)")
            }

        case .room(let session):
            // Rooms are app-only - optimistic update
            applyFavoriteUpdate(conversation, isFavorite: newState, disableAnimation: disableAnimation)

            do {
                try await dataStore?.setSessionFavorite(session.id, isFavorite: newState)
            } catch {
                // Rollback on failure
                applyFavoriteUpdate(conversation, isFavorite: originalState, disableAnimation: disableAnimation)
                logger.error("Failed to toggle room favorite: \(error)")
            }
        }
    }

    private func applyFavoriteUpdate(_ conversation: Conversation, isFavorite: Bool, disableAnimation: Bool) {
        if disableAnimation {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                updateConversationFavoriteState(conversation, isFavorite: isFavorite)
            }
        } else {
            updateConversationFavoriteState(conversation, isFavorite: isFavorite)
        }
    }

    /// Updates the favorite state in the local conversations array
    private func updateConversationFavoriteState(_ conversation: Conversation, isFavorite: Bool) {
        invalidateConversationCache()
        switch conversation {
        case .direct(let contact):
            if let index = conversations.firstIndex(where: { $0.id == contact.id }) {
                conversations[index] = conversations[index].with(isFavorite: isFavorite)
            }
        case .channel(let channel):
            if let index = channels.firstIndex(where: { $0.id == channel.id }) {
                channels[index] = channels[index].with(isFavorite: isFavorite)
            }
        case .room(let session):
            if let index = roomSessions.firstIndex(where: { $0.id == session.id }) {
                roomSessions[index] = roomSessions[index].with(isFavorite: isFavorite)
            }
        }
    }

    // MARK: - Conversation List

    /// Removes a conversation from local arrays for optimistic UI update.
    func removeConversation(_ conversation: Conversation) {
        invalidateConversationCache()
        switch conversation {
        case .direct(let contact):
            conversations = conversations.filter { $0.id != contact.id }
        case .channel(let channel):
            channels = channels.filter { $0.id != channel.id }
        case .room(let session):
            roomSessions = roomSessions.filter { $0.id != session.id }
        }
    }

    /// Load conversations for a device
    func loadConversations(deviceID: UUID) async {
        guard let dataStore else { return }

        isLoading = true
        errorMessage = nil

        do {
            conversations = try await dataStore.fetchConversations(deviceID: deviceID)
            invalidateConversationCache()
        } catch {
            errorMessage = error.localizedDescription
        }

        hasLoadedOnce = true
        isLoading = false
    }

    /// Load all contacts for mention autocomplete
    func loadAllContacts(deviceID: UUID) async {
        guard let dataStore else { return }

        do {
            allContacts = try await dataStore.fetchContacts(deviceID: deviceID)
            contactNameSet = Set(allContacts.map(\.name))
        } catch {
            logger.warning("Failed to load contacts for mentions: \(error.localizedDescription)")
        }
    }

    /// Load channels for a device
    func loadChannels(deviceID: UUID) async {
        guard let dataStore else { return }

        do {
            channels = try await dataStore.fetchChannels(deviceID: deviceID)
            invalidateConversationCache()
        } catch {
            // Silently handle - channels are optional
        }
    }

    /// Load all conversations (contacts + channels + rooms) for unified display.
    /// Fetches into local variables first, then applies all mutations in a single
    /// synchronous block so SwiftUI sees one consistent state update.
    func loadAllConversations(deviceID: UUID) async {
        guard let dataStore else { return }

        isLoading = true
        errorMessage = nil

        // Fetch into locals — no @Observable mutations between awaits.
        var fetchedConversations: [ContactDTO]?
        var fetchedChannels: [ChannelDTO]?
        var fetchedRoomSessions: [RemoteNodeSessionDTO]?

        do {
            fetchedConversations = try await dataStore.fetchConversations(deviceID: deviceID)
        } catch {
            errorMessage = error.localizedDescription
        }

        do {
            fetchedChannels = try await dataStore.fetchChannels(deviceID: deviceID)
        } catch {
            // Silently handle — channels are optional
        }

        do {
            let sessions = try await dataStore.fetchRemoteNodeSessions(deviceID: deviceID)
            fetchedRoomSessions = sessions.filter { $0.isRoom }
        } catch {
            // Silently handle — rooms are optional
        }

        // Apply all changes in a single synchronous block so SwiftUI sees one
        // consistent state instead of three intermediate partial states.
        if let fetchedConversations { conversations = fetchedConversations }
        if let fetchedChannels { channels = fetchedChannels }
        if let fetchedRoomSessions { roomSessions = fetchedRoomSessions }
        invalidateConversationCache()

        hasLoadedOnce = true
        isLoading = false

        await loadLastMessagePreviews()
    }

    // MARK: - Messages

    /// Load messages for a contact
    func loadMessages(for contact: ContactDTO) async {
        guard let dataStore else { return }

        // Clear preview state only when switching to a different conversation
        if currentContact?.id != contact.id {
            clearPreviewState()
            expandedDuplicateGroups.removeAll()
            newMessagesDividerMessageID = nil
            dividerComputed = false
        }

        currentContact = contact

        // Track active conversation for notification suppression
        notificationService?.activeContactID = contact.id

        isLoading = true
        errorMessage = nil

        // Reset pagination state for new conversation
        hasMoreMessages = true
        isLoadingOlder = false
        totalFetchedCount = 0

        do {
            var fetchedMessages = try await dataStore.fetchMessages(contactID: contact.id, limit: pageSize, offset: 0)
            let unfilteredCount = fetchedMessages.count
            totalFetchedCount = unfilteredCount

            // Compute divider position before filtering, using unfiltered array
            computeDividerPosition(from: fetchedMessages, unreadCount: contact.unreadCount)

            // Hide sent reaction messages (unless failed)
            fetchedMessages = filterOutgoingReactionMessages(fetchedMessages, isDM: true)

            messages = fetchedMessages
            hasMoreMessages = unfilteredCount == pageSize

            buildDisplayItems()

            // Index loaded messages for reaction matching and process any pending reactions
            if let reactionService = appState?.services?.reactionService {
                for message in fetchedMessages {
                    let pendingMatches = await reactionService.indexDMMessage(
                        id: message.id,
                        contactID: contact.id,
                        text: message.text,
                        timestamp: message.reactionTimestamp
                    )

                    // Process any pending reactions that now have their target
                    for pending in pendingMatches {
                        let exists = try? await dataStore.reactionExists(
                            messageID: message.id,
                            senderName: pending.senderName,
                            emoji: pending.parsed.emoji
                        )

                        if exists != true {
                            let reactionDTO = ReactionDTO(
                                messageID: message.id,
                                emoji: pending.parsed.emoji,
                                senderName: pending.senderName,
                                messageHash: pending.parsed.messageHash,
                                rawText: pending.rawText,
                                contactID: contact.id,
                                deviceID: contact.deviceID
                            )
                            if let result = await reactionService.persistReactionAndUpdateSummary(
                                reactionDTO,
                                using: dataStore
                            ) {
                                updateReactionSummary(for: result.messageID, summary: result.summary)
                            }
                        }
                    }
                }
            }

            // Clear unread count and mention badge, then notify UI to refresh chat list
            try await dataStore.clearUnreadCount(contactID: contact.id)
            try await dataStore.clearUnreadMentionCount(contactID: contact.id)
            syncCoordinator?.notifyConversationsChanged()

            // Update app badge
            await notificationService?.updateBadgeCount()
        } catch {
            errorMessage = error.localizedDescription
        }

        hasLoadedOnce = true
        isLoading = false
    }

    /// Optimistically append a message if not already present.
    /// Called synchronously before async reload to ensure ChatTableView
    /// sees the new count immediately for unread tracking.
    func appendMessageIfNew(_ message: MessageDTO) {
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        let previous = messages.last
        messages.append(message)
        messagesByID[message.id] = message
        totalFetchedCount += 1

        // Check if this message extends a duplicate group with the previous message
        if let previous, Self.isDuplicateOfPrevious(message: message, previous: previous) {
            // Rebuild to recompute groups (the previous representative must update its count)
            buildDisplayItems()
        } else {
            // Non-duplicate: fast O(1) append path
            let flags = Self.computeDisplayFlags(for: message, previous: previous)
            let sharedRoute: SharedRoute? = message.isOutgoing ? nil : SharedRouteParser.parse(message.text)
            cachedSharedRoutes[message.id] = sharedRoute
            let hexPath: HexPath? = (sharedRoute == nil && !message.isOutgoing) ? HexPathParser.detectInMessage(message.text) : nil
            let newItem = MessageDisplayItem(
                messageID: message.id,
                date: message.date,
                showTimestamp: flags.showTimestamp,
                showDirectionGap: flags.showDirectionGap,
                showSenderName: flags.showSenderName,
                showNewMessagesDivider: false,
                detectedURL: nil,
                isImageURL: false,
                isOutgoing: message.isOutgoing,
                status: message.status,
                containsSelfMention: message.containsSelfMention,
                mentionSeen: message.mentionSeen,
                heardRepeats: message.heardRepeats,
                retryAttempt: message.retryAttempt,
                maxRetryAttempts: message.maxRetryAttempts,
                reactionSummary: message.reactionSummary,
                detectedSharedRoute: sharedRoute,
                detectedHexPath: hexPath,
                previewState: .idle,
                loadedPreview: nil,
                isSearchMatch: false,
                duplicateCount: 1,
                duplicateGroupIDs: []
            )
            displayItems.append(newItem)
            displayItemIndexByID[message.id] = displayItems.count - 1

            // Async URL detection for this message only
            let messageID = message.id
            let text = message.text
            Task {
                await updateURLForDisplayItem(messageID: messageID, text: text)
            }
        }

        // Add sender to channelSenders if new and update sender order (for channel messages)
        if let senderName = message.senderNodeName,
           let deviceID = currentChannel?.deviceID {
            addChannelSenderIfNew(senderName, deviceID: deviceID, timestamp: message.timestamp)
        }
    }

    /// Update URL detection for a single display item by message ID.
    /// Uses O(1) dictionary lookup to handle concurrent array modifications.
    private func updateURLForDisplayItem(messageID: UUID, text: String) async {
        let detectedURL = await Task.detached(priority: .userInitiated) {
            LinkPreviewService.extractFirstURL(from: text)
        }.value

        cachedURLs[messageID] = detectedURL

        guard let index = displayItemIndexByID[messageID] else { return }
        let item = displayItems[index]
        displayItems[index] = MessageDisplayItem(
            messageID: item.messageID,
            date: item.date,
            showTimestamp: item.showTimestamp,
            showDirectionGap: item.showDirectionGap,
            showSenderName: item.showSenderName,
            showNewMessagesDivider: item.showNewMessagesDivider,
            detectedURL: detectedURL,
            isImageURL: detectedURL.map { ImageURLDetector.isImageURL($0) } ?? false,
            isOutgoing: item.isOutgoing,
            status: item.status,
            containsSelfMention: item.containsSelfMention,
            mentionSeen: item.mentionSeen,
            heardRepeats: item.heardRepeats,
            retryAttempt: item.retryAttempt,
            maxRetryAttempts: item.maxRetryAttempts,
            reactionSummary: item.reactionSummary,
            detectedSharedRoute: item.detectedSharedRoute,
            detectedHexPath: item.detectedHexPath,
            previewState: previewStates[messageID] ?? .idle,
            loadedPreview: loadedPreviews[messageID],
            isSearchMatch: item.isSearchMatch,
            duplicateCount: item.duplicateCount,
            duplicateGroupIDs: item.duplicateGroupIDs
        )
    }

    /// Load any saved draft for the current contact
    /// Drafts are consumed (removed) after loading to prevent re-display
    /// If no draft exists, this method does nothing
    func loadDraftIfExists() {
        guard let contact = currentContact,
              let notificationService,
              let draft = notificationService.consumeDraft(for: contact.id) else {
            return
        }
        composingText = draft
    }

    /// Send a message to the current contact
    /// This is non-blocking - message is created and shown immediately, sent in background
    func sendMessage(text: String, powerOverrideDbm: Int8? = nil) async {
        guard let contact = currentContact,
              let messageService,
              !text.isEmpty else {
            return
        }

        errorMessage = nil

        do {
            // Create message immediately and show it
            let message = try await messageService.createPendingMessage(text: text, to: contact)
            appendMessageIfNew(message)

            // Queue for sending with optional power override
            sendQueue.append(QueuedMessage(messageID: message.id, contactID: contact.id, overrideRadioDbm: powerOverrideDbm))

            // Start processor if not already running
            if !isProcessingQueue {
                queueProcessorTask = Task { await processQueue() }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refresh messages for current contact
    func refreshMessages() async {
        guard let contact = currentContact else { return }
        await loadMessages(for: contact)
    }

    // MARK: - Pagination

    /// Load older messages when user scrolls near the top
    func loadOlderMessages() async {
        // Guard against duplicate fetches and end of history
        guard !isLoadingOlder, hasMoreMessages else { return }
        guard let dataStore else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        // Snapshot conversation context before any await — actor reentrancy
        // means currentContact/currentChannel can change during suspensions
        let contact = currentContact
        let channel = currentChannel

        do {
            let currentOffset = totalFetchedCount
            var olderMessages: [MessageDTO]

            if let contact {
                olderMessages = try await dataStore.fetchMessages(
                    contactID: contact.id,
                    limit: pageSize,
                    offset: currentOffset
                )
            } else if let channel {
                olderMessages = try await dataStore.fetchMessages(
                    deviceID: channel.deviceID,
                    channelIndex: channel.index,
                    limit: pageSize,
                    offset: currentOffset
                )
            } else {
                return
            }

            // Use unfiltered count to determine if more messages exist
            let unfilteredCount = olderMessages.count
            totalFetchedCount += unfilteredCount
            if unfilteredCount < pageSize {
                hasMoreMessages = false
            }

            // Filter blocked senders for channel messages
            if channel != nil, let syncCoordinator {
                let blockedNames = await syncCoordinator.blockedSenderNames()
                if !blockedNames.isEmpty {
                    olderMessages = olderMessages.filter { message in
                        guard let senderName = message.senderNodeName else { return true }
                        return !blockedNames.contains(senderName)
                    }
                }
            }

            // Hide sent reaction messages (unless failed)
            let isDM = contact != nil
            olderMessages = filterOutgoingReactionMessages(olderMessages, isDM: isDM)

            // Filter out messages already in array (race condition: appendMessageIfNew can add
            // a message while this fetch is in-flight, causing duplicates)
            let existingIDs = Set(messages.map(\.id))
            olderMessages = olderMessages.filter { !existingIDs.contains($0.id) }

            // Prepend older messages (they're chronologically earlier)
            messages.insert(contentsOf: olderMessages, at: 0)

            // Re-run same-sender reordering across the page boundary to handle
            // clusters that were split between the existing and newly loaded pages
            messages = MessageDTO.reorderSameSenderClusters(messages)

            // Clear expanded groups — group leader IDs may change after prepend
            expandedDuplicateGroups.removeAll()

            // Update lookup dictionary
            for message in olderMessages {
                messagesByID[message.id] = message
            }

            // Rebuild display items with new messages
            buildDisplayItems()

            // Index older channel messages for reaction matching and process pending reactions
            if let channel,
               let reactionService = appState?.services?.reactionService {
                let localNodeName = appState?.connectedDevice?.nodeName
                let deviceID = appState?.connectedDevice?.id ?? UUID()
                for message in olderMessages {
                    let senderName: String?
                    if message.isOutgoing {
                        senderName = localNodeName
                    } else {
                        senderName = message.senderNodeName
                    }
                    if let senderName {
                        let pendingMatches = await reactionService.indexMessage(
                            id: message.id,
                            channelIndex: channel.index,
                            senderName: senderName,
                            text: message.text,
                            timestamp: message.timestamp
                        )

                        // Process any pending reactions that now have their target
                        for pending in pendingMatches {
                            let exists = try? await dataStore.reactionExists(
                                messageID: message.id,
                                senderName: pending.senderNodeName,
                                emoji: pending.parsed.emoji
                            )

                            if exists != true {
                                let reactionDTO = ReactionDTO(
                                    messageID: message.id,
                                    emoji: pending.parsed.emoji,
                                    senderName: pending.senderNodeName,
                                    messageHash: pending.parsed.messageHash,
                                    rawText: pending.rawText,
                                    channelIndex: pending.channelIndex,
                                    deviceID: deviceID
                                )
                                if let result = await reactionService.persistReactionAndUpdateSummary(
                                    reactionDTO,
                                    using: dataStore
                                ) {
                                    updateReactionSummary(for: result.messageID, summary: result.summary)
                                }
                            }
                        }
                    }
                }
            }

            // Index older DM messages for reaction matching and process pending reactions
            if let contact,
               let reactionService = appState?.services?.reactionService {
                for message in olderMessages {
                    let pendingMatches = await reactionService.indexDMMessage(
                        id: message.id,
                        contactID: contact.id,
                        text: message.text,
                        timestamp: message.reactionTimestamp
                    )

                    // Process any pending reactions that now have their target
                    for pending in pendingMatches {
                        let exists = try? await dataStore.reactionExists(
                            messageID: message.id,
                            senderName: pending.senderName,
                            emoji: pending.parsed.emoji
                        )

                        if exists != true {
                            let reactionDTO = ReactionDTO(
                                messageID: message.id,
                                emoji: pending.parsed.emoji,
                                senderName: pending.senderName,
                                messageHash: pending.parsed.messageHash,
                                rawText: pending.rawText,
                                contactID: contact.id,
                                deviceID: contact.deviceID
                            )
                            if let result = await reactionService.persistReactionAndUpdateSummary(
                                reactionDTO,
                                using: dataStore
                            ) {
                                updateReactionSummary(for: result.messageID, summary: result.summary)
                            }
                        }
                    }
                }
            }

        } catch {
            errorMessage = L10n.Chats.Chats.Errors.loadOlderMessagesFailed
            logger.error("Failed to load older messages: \(error)")
        }
    }

    // MARK: - Message Previews

    /// Get the last message preview for a contact
    func lastMessagePreview(for contact: ContactDTO) -> String? {
        // Check cache first
        if let cached = lastMessageCache[contact.id] {
            return cached.text
        }
        return nil
    }

    /// Load last message previews for all conversations.
    /// Uses batch fetch methods to minimize actor hops (2 hops instead of N).
    func loadLastMessagePreviews() async {
        guard let dataStore else { return }

        // Batch fetch contact message previews (single actor hop)
        if !conversations.isEmpty {
            do {
                let contactMessages = try await dataStore.fetchLastMessages(contactIDs: conversations.map(\.id), limit: 10)
                for contact in conversations {
                    guard let messages = contactMessages[contact.id] else { continue }

                    // Find the last non-reaction message (skip outgoing reactions unless failed)
                    let lastMessage = messages.last { message in
                        guard message.direction == .outgoing,
                              ReactionParser.parseDM(message.text) != nil else {
                            return true
                        }
                        return message.status == .failed
                    }

                    if let lastMessage {
                        lastMessageCache[contact.id] = lastMessage
                    }
                }
            } catch {
                logger.warning("Failed to load contact message previews: \(error)")
            }
        }

        // Batch fetch channel message previews (single actor hop)
        if !channels.isEmpty {
            let blockedNames = await syncCoordinator?.blockedSenderNames() ?? []
            do {
                let channelParams = channels.map { (deviceID: $0.deviceID, channelIndex: $0.index, id: $0.id) }
                let channelMessages = try await dataStore.fetchLastChannelMessages(channels: channelParams, limit: 20)
                for channel in channels {
                    guard let messages = channelMessages[channel.id] else { continue }

                    // Filter out messages from blocked senders and outgoing reactions
                    let lastMessage = messages.last { message in
                        if let senderName = message.senderNodeName,
                           blockedNames.contains(senderName) {
                            return false
                        }
                        if message.direction == .outgoing,
                           ReactionParser.parse(message.text) != nil,
                           message.status != .failed {
                            return false
                        }
                        return true
                    }

                    if let lastMessage {
                        lastMessageCache[channel.id] = lastMessage
                    } else {
                        lastMessageCache.removeValue(forKey: channel.id)
                    }
                }
            } catch {
                logger.warning("Failed to load channel message previews: \(error)")
            }
        }
    }

    /// Get the last message preview for a channel
    func lastMessagePreview(for channel: ChannelDTO) -> String? {
        if let cached = lastMessageCache[channel.id] {
            return cached.text
        }
        return nil
    }

    // MARK: - Message Actions

    /// Retry sending a failed message with flood routing enabled.
    /// If adaptive power is enabled, escalates TX power before retry.
    func retryMessage(_ message: MessageDTO) async {
        logger.info("retryMessage called for message: \(message.id)")
        clearNoRepeatsRetry()

        guard let messageService else {
            logger.warning("retryMessage: messageService is nil")
            return
        }

        guard let contact = currentContact else {
            logger.warning("retryMessage: currentContact is nil")
            return
        }

        logger.info("retryMessage: starting retry for contact \(contact.displayName)")

        // Escalate power if adaptive power is enabled (no repeats heard → bump up)
        if let powerService = appState?.adaptivePowerService, powerService.isEnabled {
            powerService.onNoRepeatsHeard()
            await powerService.escalate()
        }

        errorMessage = nil

        // Update status to pending and reload immediately for instant "Sending" feedback
        try? await dataStore?.updateMessageStatus(id: message.id, status: .pending)
        await loadMessages(for: contact)

        do {
            // Retry the existing message (preserves message identity)
            logger.info("retryMessage: calling retryDirectMessage with messageID")
            let result = try await messageService.retryDirectMessage(messageID: message.id, to: contact)
            logger.info("retryMessage: completed with status \(String(describing: result.status))")

            // Reload messages to show updated status
            await loadMessages(for: contact)
        } catch {
            logger.error("retryMessage: error - \(error)")
            errorMessage = error.localizedDescription
            showRetryError = true
            // Reload to show the failed status
            await loadMessages(for: contact)
        }
    }

    /// Resend a channel message in place, or copy text for direct messages.
    /// Used for "Send Again" context menu action.
    /// If adaptive power is enabled, escalates TX power before resend.
    func sendAgain(_ message: MessageDTO) async {
        // Escalate power if adaptive power is enabled (user tapped send again → bump up)
        if let powerService = appState?.adaptivePowerService, powerService.isEnabled {
            powerService.onNoRepeatsHeard()
            await powerService.escalate()
        }

        if message.channelIndex != nil {
            // Channel messages: resend in place (increments send count)
            guard let messageService else { return }
            do {
                try await messageService.resendChannelMessage(messageID: message.id)
                // Reload to show updated send count
                if let channel = currentChannel {
                    await loadChannelMessages(for: channel)
                }
            } catch {
                logger.error("Failed to resend message: \(error)")
            }
        } else {
            // Direct messages: send the failed message text directly
            await sendMessage(text: message.text)
        }
    }

    /// Delete a single message
    func deleteMessage(_ message: MessageDTO) async {
        guard appState?.connectionState == .ready else { return }
        guard let dataStore else { return }

        do {
            try await dataStore.deleteMessage(id: message.id)

            // Remove from all local collections
            messages.removeAll { $0.id == message.id }
            messagesByID.removeValue(forKey: message.id)

            // Clean up expansion state if this was a group leader
            expandedDuplicateGroups.remove(message.id)

            // Rebuild display items to recompute duplicate groups
            buildDisplayItems()

            // Clean up preview state for deleted message
            cleanupPreviewState(for: message.id)

            // Update last message date if needed
            if let currentContact {
                if let lastMessage = messages.last {
                    try await dataStore.updateContactLastMessage(
                        contactID: currentContact.id,
                        date: lastMessage.date
                    )
                } else {
                    try await dataStore.updateContactLastMessage(
                        contactID: currentContact.id,
                        date: Date.distantPast
                    )
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delete all messages for a direct conversation
    func deleteDirectConversation(for contact: ContactDTO) async throws {
        guard appState?.connectionState == .ready else { return }
        guard let dataStore else { return }

        try await dataStore.deleteMessagesForContact(contactID: contact.id)
        try await dataStore.clearUnreadCount(contactID: contact.id)
        try await dataStore.updateContactLastMessage(contactID: contact.id, date: nil)
        await notificationService?.updateBadgeCount()
    }

    // MARK: - Duplicate Grouping

    /// A run of consecutive messages with identical text from the same sender.
    struct DuplicateGroup {
        let leaderID: UUID          // First message ID (stable key for expansion tracking)
        let messages: [MessageDTO]
        var count: Int { messages.count }
        var allIDs: [UUID] { messages.map(\.id) }
    }

    /// Identifies runs of consecutive duplicate messages in the array.
    private func identifyDuplicateGroups(in messages: [MessageDTO]) -> [DuplicateGroup] {
        guard let first = messages.first else { return [] }

        var groups: [DuplicateGroup] = []
        var currentRun: [MessageDTO] = [first]

        for i in 1..<messages.count {
            let message = messages[i]
            let prev = messages[i - 1]

            if Self.isDuplicateOfPrevious(message: message, previous: prev) {
                currentRun.append(message)
            } else {
                groups.append(DuplicateGroup(leaderID: currentRun[0].id, messages: currentRun))
                currentRun = [message]
            }
        }
        groups.append(DuplicateGroup(leaderID: currentRun[0].id, messages: currentRun))

        return groups
    }

    // MARK: - Display Items

    /// Build a single display item from a message with pre-computed flags.
    private func buildSingleDisplayItem(
        message: MessageDTO,
        flags: ChatViewModel.DisplayFlags,
        duplicateCount: Int,
        duplicateGroupIDs: [UUID],
        uncachedMessageIDs: inout [(UUID, String)]
    ) -> MessageDisplayItem {
        // Use cached URL if available, otherwise nil (async detection below)
        let url: URL?
        if let cached = cachedURLs[message.id] {
            url = cached
        } else if previewStates[message.id] != nil || loadedPreviews[message.id] != nil {
            url = nil
        } else {
            url = nil
            uncachedMessageIDs.append((message.id, message.text))
        }

        // Shared route detection (synchronous regex, cached per message ID)
        let sharedRoute: SharedRoute?
        if let cached = cachedSharedRoutes[message.id] {
            sharedRoute = cached
        } else if !message.isOutgoing {
            let parsed = SharedRouteParser.parse(message.text)
            cachedSharedRoutes[message.id] = parsed
            sharedRoute = parsed
        } else {
            cachedSharedRoutes[message.id] = nil as SharedRoute?
            sharedRoute = nil
        }

        // Detect hex path chains only when no formal shared route was found
        let hexPath: HexPath? = (sharedRoute == nil && !message.isOutgoing) ? HexPathParser.detectInMessage(message.text) : nil

        return MessageDisplayItem(
            messageID: message.id,
            date: message.date,
            showTimestamp: flags.showTimestamp,
            showDirectionGap: flags.showDirectionGap,
            showSenderName: flags.showSenderName,
            showNewMessagesDivider: message.id == newMessagesDividerMessageID,
            detectedURL: url,
            isImageURL: url.map { ImageURLDetector.isImageURL($0) } ?? false,
            isOutgoing: message.isOutgoing,
            status: message.status,
            containsSelfMention: message.containsSelfMention,
            mentionSeen: message.mentionSeen,
            heardRepeats: message.heardRepeats,
            retryAttempt: message.retryAttempt,
            maxRetryAttempts: message.maxRetryAttempts,
            reactionSummary: message.reactionSummary,
            detectedSharedRoute: sharedRoute,
            detectedHexPath: hexPath,
            previewState: previewStates[message.id] ?? .idle,
            loadedPreview: loadedPreviews[message.id],
            isSearchMatch: message.id == conversationSearch.currentMatchID,
            duplicateCount: duplicateCount,
            duplicateGroupIDs: duplicateGroupIDs
        )
    }

    /// Build display items with pre-computed properties.
    /// Consecutive duplicate messages from the same sender are collapsed into a
    /// single representative display item unless the group is explicitly expanded.
    func buildDisplayItems() {
        messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        // Phase 1: Identify duplicate groups
        let groups = identifyDuplicateGroups(in: messages)

        // Phase 2: Auto-expand groups containing the new-messages divider or search match
        for group in groups where group.count > 1 {
            if let dividerID = newMessagesDividerMessageID, group.allIDs.contains(dividerID) {
                expandedDuplicateGroups.insert(group.leaderID)
            }
            if let matchID = conversationSearch.currentMatchID, group.allIDs.contains(matchID) {
                expandedDuplicateGroups.insert(group.leaderID)
            }
        }

        // Phase 3: Build display items respecting expansion state
        var items: [MessageDisplayItem] = []
        var uncachedMessageIDs: [(UUID, String)] = []
        var previousMessage: MessageDTO?

        for group in groups {
            let isExpanded = expandedDuplicateGroups.contains(group.leaderID)

            if group.count == 1 {
                // Single message — no grouping needed
                let message = group.messages[0]
                let flags = Self.computeDisplayFlags(for: message, previous: previousMessage)
                let item = buildSingleDisplayItem(
                    message: message,
                    flags: flags,
                    duplicateCount: 1,
                    duplicateGroupIDs: [],
                    uncachedMessageIDs: &uncachedMessageIDs
                )
                items.append(item)
                previousMessage = message
            } else if isExpanded {
                // Expanded group — emit all messages, leader gets group info
                let groupIDs = group.allIDs
                for (i, message) in group.messages.enumerated() {
                    let flags = Self.computeDisplayFlags(for: message, previous: previousMessage)
                    let item = buildSingleDisplayItem(
                        message: message,
                        flags: flags,
                        duplicateCount: i == 0 ? group.count : 1,
                        duplicateGroupIDs: i == 0 ? groupIDs : [],
                        uncachedMessageIDs: &uncachedMessageIDs
                    )
                    items.append(item)
                    previousMessage = message
                }
            } else {
                // Collapsed group — emit only the last (newest) message as representative
                let representative = group.messages.last!
                let flags = Self.computeDisplayFlags(for: representative, previous: previousMessage)
                let item = buildSingleDisplayItem(
                    message: representative,
                    flags: flags,
                    duplicateCount: group.count,
                    duplicateGroupIDs: group.allIDs,
                    uncachedMessageIDs: &uncachedMessageIDs
                )
                items.append(item)
                previousMessage = representative
            }
        }

        displayItems = items

        // Build O(1) index lookup
        displayItemIndexByID = Dictionary(uniqueKeysWithValues: displayItems.enumerated().map { ($0.element.messageID, $0.offset) })

        // Async URL detection for messages without cached results
        if !uncachedMessageIDs.isEmpty {
            let messagesToDetect = uncachedMessageIDs
            urlDetectionTask?.cancel()
            urlDetectionTask = Task {
                for (messageID, text) in messagesToDetect {
                    guard !Task.isCancelled else { return }
                    await updateURLForDisplayItem(messageID: messageID, text: text)
                }
            }
        }

        // Pre-decode legacy preview images off the main thread
        decodeLegacyPreviewImages()
    }

    /// Get full message DTO for a display item.
    /// Logs a warning if lookup fails (indicates data inconsistency).
    func message(for displayItem: MessageDisplayItem) -> MessageDTO? {
        guard let message = messagesByID[displayItem.messageID] else {
            logger.warning("Message lookup failed for displayItem id=\(displayItem.messageID)")
            return nil
        }
        return message
    }

    // MARK: - Message Queue

    /// Add a message to the send queue (for testing)
    func enqueueMessage(_ messageID: UUID, contactID: UUID) {
        sendQueue.append(QueuedMessage(messageID: messageID, contactID: contactID))
    }

    /// Process the queue (exposed for testing)
    func processQueueForTesting() async {
        await processQueue()
    }

    /// Process queued messages serially
    private func processQueue() async {
        guard let messageService,
              let dataStore else { return }

        isProcessingQueue = true
        defer { isProcessingQueue = false }

        // Snapshot before suspensions — currentContact can change if user switches conversations
        let contact = currentContact
        var lastDeviceID: UUID?

        // Process messages with re-check after reload to catch any that arrived during reload
        repeat {
            while !sendQueue.isEmpty {
                let queued = sendQueue.removeFirst()

                // Apply power for THIS message — override or adaptive
                let appliedDbm = await applyPowerForMessage(overrideDbm: queued.overrideRadioDbm)

                if appliedDbm == nil, appState?.adaptivePowerService.isEnabled == true {
                    errorMessage = "TX power could not be verified — sending at current radio level"
                }

                // Record TX power on the message
                if let dbm = appliedDbm {
                    try? await dataStore.updateMessageTxPower(id: queued.messageID, txPowerDbm: dbm)
                }

                // Fetch the target contact by ID - it may differ from currentContact
                guard let contact = try? await dataStore.fetchContact(id: queued.contactID) else {
                    // Contact was deleted, skip this message
                    logger.info("Skipping queued message - contact \(queued.contactID) was deleted")
                    continue
                }

                lastDeviceID = contact.deviceID

                do {
                    _ = try await messageService.retryDirectMessage(
                        messageID: queued.messageID,
                        to: contact
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }

                // Restore adaptive power after a one-shot override.
                // Wait for the RF transmission to complete before restoring —
                // the send command returns after BLE queuing, not after RF TX.
                if queued.overrideRadioDbm != nil {
                    try? await Task.sleep(for: .seconds(3))
                    await applyPowerForMessage(overrideDbm: nil)
                }
            }

            // Reload after queue drains - syncs statuses and conversation list
            if let contact {
                await loadMessages(for: contact)
            }
            if let deviceID = lastDeviceID {
                await loadConversations(deviceID: deviceID)
            }
        } while !sendQueue.isEmpty
    }

    // MARK: - Global Message Search

    /// Results from a global message search across all conversations
    struct GlobalSearchResults {
        var resultsByConversation: [(conversation: Conversation, results: [MessageSearchResult])] = []
        var totalCount: Int = 0
        var isSearching: Bool = false
    }

    /// Search messages across all conversations, grouped by conversation.
    func searchMessagesGlobally(query: String, deviceID: UUID) {
        globalSearchTask?.cancel()

        guard !query.isEmpty else {
            cancelGlobalSearch()
            return
        }

        globalSearchResults.isSearching = true

        globalSearchTask = Task {
            // Debounce 300ms
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }

            guard let dataStore else {
                globalSearchResults.isSearching = false
                return
            }

            do {
                let results = try await dataStore.searchMessages(
                    deviceID: deviceID,
                    searchText: query,
                    limit: 50,
                    offset: 0
                )
                let totalCount = try await dataStore.searchMessagesCount(
                    deviceID: deviceID,
                    searchText: query
                )

                guard !Task.isCancelled else { return }

                // Group results by conversation
                let grouped = groupResultsByConversation(results)
                globalSearchResults = GlobalSearchResults(
                    resultsByConversation: grouped,
                    totalCount: totalCount,
                    isSearching: false
                )
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Global message search failed: \(error.localizedDescription)")
                globalSearchResults.isSearching = false
            }
        }
    }

    /// Cancel any in-progress global search and clear results.
    func cancelGlobalSearch() {
        globalSearchTask?.cancel()
        globalSearchTask = nil
        globalSearchResults = GlobalSearchResults()
    }

    /// Groups search results by conversation, resolving contactID/channelIndex
    /// against loaded conversations and channels.
    private func groupResultsByConversation(_ results: [MessageSearchResult]) -> [(conversation: Conversation, results: [MessageSearchResult])] {
        var grouped: [UUID: (conversation: Conversation, results: [MessageSearchResult])] = [:]

        for result in results {
            let conversationKey: UUID
            let conversation: Conversation?

            if let contactID = result.contactID {
                conversationKey = contactID
                if let contact = conversations.first(where: { $0.id == contactID }) {
                    conversation = .direct(contact)
                } else {
                    conversation = nil
                }
            } else if let channelIndex = result.channelIndex {
                if let channel = channels.first(where: { $0.index == channelIndex && $0.deviceID == result.deviceID }) {
                    conversationKey = channel.id
                    conversation = .channel(channel)
                } else {
                    continue
                }
            } else {
                continue
            }

            guard let conversation else { continue }

            if grouped[conversationKey] != nil {
                grouped[conversationKey]?.results.append(result)
            } else {
                grouped[conversationKey] = (conversation: conversation, results: [result])
            }
        }

        // Sort groups by most recent result in each group
        return grouped.values.sorted { lhs, rhs in
            let lhsDate = lhs.results.first?.createdAt ?? .distantPast
            let rhsDate = rhs.results.first?.createdAt ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    // MARK: - Within-Conversation Search

    /// State for searching within the current conversation
    struct ConversationSearchState {
        var matchingIDs: [UUID] = []
        var currentMatchIndex: Int = -1
        var query: String = ""
        var isSearching: Bool = false

        var totalMatches: Int { matchingIDs.count }
        var currentMatchDisplay: String {
            guard totalMatches > 0, currentMatchIndex >= 0 else { return "" }
            return "\(currentMatchIndex + 1) of \(totalMatches)"
        }
        var currentMatchID: UUID? {
            guard currentMatchIndex >= 0, currentMatchIndex < matchingIDs.count else { return nil }
            return matchingIDs[currentMatchIndex]
        }
        var canGoNext: Bool { currentMatchIndex < matchingIDs.count - 1 }
        var canGoPrevious: Bool { currentMatchIndex > 0 }
    }

    /// Search within the current conversation.
    func searchWithinConversation(query: String) {
        conversationSearchTask?.cancel()

        guard !query.isEmpty else {
            clearConversationSearch()
            return
        }

        conversationSearch.query = query
        conversationSearch.isSearching = true

        conversationSearchTask = Task {
            // Debounce 300ms
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }

            guard let dataStore else {
                conversationSearch.isSearching = false
                return
            }

            do {
                let matchIDs: [UUID]
                if let contact = currentContact {
                    matchIDs = try await dataStore.searchMessageIDs(
                        contactID: contact.id,
                        searchText: query,
                        limit: 500
                    )
                } else if let channel = currentChannel {
                    matchIDs = try await dataStore.searchMessageIDs(
                        deviceID: channel.deviceID,
                        channelIndex: channel.index,
                        searchText: query,
                        limit: 500
                    )
                } else {
                    conversationSearch.isSearching = false
                    return
                }

                guard !Task.isCancelled else { return }

                conversationSearch.matchingIDs = matchIDs
                conversationSearch.isSearching = false

                // Start at the newest match (last in chronological order)
                if !matchIDs.isEmpty {
                    conversationSearch.currentMatchIndex = matchIDs.count - 1
                } else {
                    conversationSearch.currentMatchIndex = -1
                }
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Conversation search failed: \(error.localizedDescription)")
                conversationSearch.isSearching = false
            }
        }
    }

    /// Navigate to the next match (older).
    func searchPreviousMatch() {
        guard conversationSearch.canGoPrevious else { return }
        conversationSearch.currentMatchIndex -= 1
    }

    /// Navigate to the previous match (newer).
    func searchNextMatch() {
        guard conversationSearch.canGoNext else { return }
        conversationSearch.currentMatchIndex += 1
    }

    /// Clear within-conversation search state.
    func clearConversationSearch() {
        conversationSearchTask?.cancel()
        conversationSearchTask = nil
        conversationSearch = ConversationSearchState()
    }
}
