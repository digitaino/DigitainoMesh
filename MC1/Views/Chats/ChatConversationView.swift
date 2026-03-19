import CoreLocation
import SwiftUI
import UIKit  // UIPasteboard for .copy action
import MC1Services
import OSLog

private let logger = Logger(subsystem: "com.mc1", category: "ChatConversationView")

/// Unified chat conversation view supporting both DMs and Channels.
struct ChatConversationView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.linkPreviewCache) private var linkPreviewCache

    @State private var conversationType: ChatConversationType
    let parentViewModel: ChatViewModel?

    @State private var chatViewModel = ChatViewModel()

    // MARK: - Scroll State

    @State private var isAtBottom = true
    @State private var unreadCount = 0
    @State private var scrollToBottomRequest = 0
    @State private var scrollToMentionRequest = 0
    @State private var unseenMentionIDs: [UUID] = []
    @State private var scrollToTargetID: UUID?
    @State private var mentionScrollTask: Task<Void, Never>?
    @State private var scrollToDividerRequest = 0
    @State private var isDividerVisible = false

    // MARK: - Sheet State

    @State private var showingInfo = false
    @State private var selectedMessageForActions: MessageDTO?
    @State private var blockSenderContext: BlockSenderContext?
    @State private var imageViewerData: ImageViewerData?
    @State private var contactDetailContact: ContactDTO?

    // Route location picker state
    @State private var showingRouteLocationPicker = false
    @State private var pendingRouteMessage: MessageDTO?
    @State private var pendingRouteInfo: String?

    // MARK: - Other State

    @State private var recentEmojisStore = RecentEmojisStore()
    @State private var mentionSenderOrder: [String: UInt32]?
    @State private var eventCursor: Int?
    @FocusState private var isInputFocused: Bool

    // MARK: - AppStorage

    @AppStorage("showInlineImages") private var showInlineImages = true
    @AppStorage("autoPlayGIFs") private var autoPlayGIFs = true
    @AppStorage("showIncomingPath") private var showIncomingPath = false
    @AppStorage("showIncomingHopCount") private var showIncomingHopCount = false

    // MARK: - Init

    init(conversationType: ChatConversationType, parentViewModel: ChatViewModel? = nil) {
        self._conversationType = State(initialValue: conversationType)
        self.parentViewModel = parentViewModel
    }

    // MARK: - Body

    var body: some View {
        ChatConversationMessagesContent(
            conversationType: conversationType,
            viewModel: chatViewModel,
            deviceName: appState.localNodeName,
            recentEmojisStore: recentEmojisStore,
            showInlineImages: showInlineImages,
            autoPlayGIFs: autoPlayGIFs,
            showIncomingPath: showIncomingPath,
            showIncomingHopCount: showIncomingHopCount,
            isAtBottom: $isAtBottom,
            unreadCount: $unreadCount,
            scrollToBottomRequest: $scrollToBottomRequest,
            scrollToMentionRequest: $scrollToMentionRequest,
            scrollToDividerRequest: $scrollToDividerRequest,
            isDividerVisible: $isDividerVisible,
            unseenMentionIDs: unseenMentionIDs,
            scrollToTargetID: scrollToTargetID,
            newMessagesDividerMessageID: chatViewModel.newMessagesDividerMessageID,
            selectedMessageForActions: $selectedMessageForActions,
            imageViewerData: $imageViewerData,
            onMentionSeen: { await markMentionSeen(messageID: $0) },
            onScrollToMention: { scrollToNextMention() },
            onRetryMessage: { retryMessage($0) },
            onReply: { message in
                chatViewModel.composingText = buildReplyText(for: message)
                isInputFocused = true
            }
        )
        .safeAreaInset(edge: .bottom, spacing: 8) {
            ChatConversationInputBar(
                conversationType: conversationType,
                composingText: $chatViewModel.composingText,
                isFocused: $isInputFocused,
                nodeNameByteCount: appState.connectedDevice?.nodeName.utf8.count ?? 0,
                onSend: { text in
                    switch conversationType {
                    case .dm:
                        await chatViewModel.sendMessage(text: text)
                    case .channel:
                        await chatViewModel.sendChannelMessage(text: text)
                    }
                },
                onWillSend: { scrollToBottomRequest += 1 }
            )
        }
        .overlay(alignment: .bottom) {
            ChatConversationMentionOverlay(
                suggestions: mentionSuggestions,
                onSelectMention: { insertMention(for: $0) }
            )
        }
        .navigationHeader(
            title: conversationType.navigationTitle,
            subtitle: conversationType.navigationSubtitle
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Info", systemImage: "info.circle") {
                    showingInfo = true
                }
            }
        }
        // Info sheet — type-specific
        .sheet(isPresented: $showingInfo, onDismiss: {
            if case .dm = conversationType {
                Task { await refreshContact() }
            }
        }, content: {
            ChatConversationInfoSheet(
                conversationType: conversationType,
                chatViewModel: chatViewModel,
                onClearChannelMessages: {
                    guard case .channel(let channel) = conversationType else { return }
                    await chatViewModel.loadChannelMessages(for: channel)
                    if let parent = parentViewModel {
                        await parent.loadChannels(deviceID: channel.deviceID)
                        await parent.loadLastMessagePreviews()
                    }
                },
                onDeleteChannel: { dismiss() }
            )
        })
        // Message actions sheet — shared
        .sheet(item: $selectedMessageForActions) { message in
            messageActionsSheet(for: message)
                .environment(\.horizontalSizeClass, horizontalSizeClass)
        }
        // Block sender sheet — channel only
        .sheet(item: $blockSenderContext) { context in
            BlockSenderSheet(
                senderName: context.senderName,
                deviceID: context.deviceID
            ) { blockedContactIDs in
                Task {
                    await performBlock(
                        senderName: context.senderName,
                        deviceID: context.deviceID,
                        contactIDs: blockedContactIDs
                    )
                }
            }
        }
        .fullScreenCover(item: $imageViewerData) { data in
            FullScreenImageViewer(data: data)
        }
        .sheet(item: $contactDetailContact) { contact in
            NavigationStack {
                ContactDetailView(contact: contact)
            }
        }
        .sheet(isPresented: $showingRouteLocationPicker) {
            if let trueCoord = routePickerTrueLocation {
                ShareLocationPickerSheet(trueLocation: trueCoord, shareLabel: "Share Route") { chosenCoordinate in
                    guard let message = pendingRouteMessage, let routeInfo = pendingRouteInfo else { return }
                    Task {
                        guard let url = await uploadRouteToServer(message: message, routeInfo: routeInfo, chosenCoordinate: chosenCoordinate) else { return }
                        await MainActor.run {
                            if chatViewModel.composingText.contains(routeInfo) {
                                chatViewModel.composingText += "\(url.absoluteString)\n"
                            }
                        }
                    }
                    pendingRouteMessage = nil
                    pendingRouteInfo = nil
                }
            }
        }
        .onAppear {
            eventCursor = appState.messageEventBroadcaster.currentEventSequence
        }
        .task(id: appState.servicesVersion) {
            await performInitialLoad()
        }
        .onDisappear {
            performCleanup()
        }
        .onChange(of: activeMentionQuery != nil) { _, isActive in
            if isActive {
                mentionSenderOrder = chatViewModel.channelSenderOrder
            } else {
                mentionSenderOrder = nil
            }
        }
        .onChange(of: appState.messageEventBroadcaster.newMessageCount) { _, _ in
            drainEvents()
        }
        .alert(L10n.Chats.Chats.Alert.UnableToSend.title, isPresented: $chatViewModel.showRetryError) {
            Button(L10n.Chats.Chats.Common.ok, role: .cancel) { }
        } message: {
            Text(L10n.Chats.Chats.Alert.UnableToSend.message)
        }
    }

    // MARK: - Initial Load (.task)

    private func performInitialLoad() async {
        // Cancel any in-flight mention paging from a previous servicesVersion
        mentionScrollTask?.cancel()
        mentionScrollTask = nil

        // Capture pending scroll target before loading
        let pendingTarget = appState.navigation.pendingScrollToMessageID
        if pendingTarget != nil {
            appState.navigation.clearPendingScrollToMessage()
        }

        chatViewModel.configure(appState: appState, linkPreviewCache: linkPreviewCache)

        switch conversationType {
        case .dm(let contact):
            await chatViewModel.loadMessages(for: contact)
            await chatViewModel.loadConversations(deviceID: contact.deviceID)
            await chatViewModel.loadAllContacts(deviceID: contact.deviceID)
            chatViewModel.loadDraftIfExists()
            // Restore in-progress draft from navigation
            if chatViewModel.composingText.isEmpty,
               let draft = ChatViewModel.loadDraft(key: "dm-\(contact.id)") {
                chatViewModel.composingText = draft
            }

        case .channel(let channel):
            // Load contacts first so contactNameSet is populated before buildChannelSenders runs
            await chatViewModel.loadAllContacts(deviceID: channel.deviceID)
            await chatViewModel.loadChannelMessages(for: channel)
            await chatViewModel.loadConversations(deviceID: channel.deviceID)
            // Restore in-progress draft from navigation
            if chatViewModel.composingText.isEmpty,
               let draft = ChatViewModel.loadDraft(key: "ch-\(channel.id)") {
                chatViewModel.composingText = draft
            }
        }

        await loadUnseenMentions()

        // Trigger scroll to target message if pending (notification deeplink)
        if let targetID = pendingTarget {
            scrollToTargetID = targetID
            scrollToMentionRequest += 1
        }
    }

    // MARK: - Cleanup (.onDisappear)

    private func performCleanup() {
        mentionScrollTask?.cancel()
        mentionScrollTask = nil

        // Save in-progress draft so it survives navigation
        switch conversationType {
        case .dm(let contact):
            ChatViewModel.saveDraft(key: "dm-\(contact.id)", text: chatViewModel.composingText)
        case .channel(let channel):
            ChatViewModel.saveDraft(key: "ch-\(channel.id)", text: chatViewModel.composingText)
        }

        // Clear notification suppression
        switch conversationType {
        case .dm:
            appState.services?.notificationService.activeContactID = nil
        case .channel:
            appState.services?.notificationService.activeChannelIndex = nil
            appState.services?.notificationService.activeChannelDeviceID = nil
        }

        // Refresh parent conversation list when leaving
        if let parent = parentViewModel {
            Task {
                guard let deviceID = appState.connectedDevice?.id else { return }
                await parent.loadConversations(deviceID: deviceID)
                if case .channel = conversationType {
                    await parent.loadChannels(deviceID: deviceID)
                }
                await parent.loadLastMessagePreviews()
            }
        }
    }

    // MARK: - Event Draining

    private func drainEvents() {
        guard let cursor = eventCursor else { return }
        let (events, newCursor, droppedEvents) = appState.messageEventBroadcaster.events(after: cursor)
        eventCursor = newCursor
        var needsReload = droppedEvents
        var needsContactRefresh = false

        switch conversationType {
        case .dm(let contact):
            (needsReload, needsContactRefresh) = drainDMEvents(
                events, contact: contact, needsReload: needsReload
            )
        case .channel(let channel):
            needsReload = drainChannelEvents(events, channel: channel, needsReload: needsReload)
        }

        if needsReload {
            reloadMessages()
        }
        if case .dm = conversationType, needsContactRefresh || droppedEvents {
            Task { await refreshContact() }
        }
        if droppedEvents {
            Task { await loadUnseenMentions() }
        }
    }

    private func reloadMessages() {
        Task {
            switch conversationType {
            case .dm(let contact):
                await chatViewModel.loadMessages(for: contact)
            case .channel(let channel):
                await chatViewModel.loadChannelMessages(for: channel)
            }
        }
    }

    private func handleIncomingMentionIfNeeded(_ message: MessageDTO) {
        guard message.containsSelfMention else { return }
        Task {
            if isAtBottom {
                await markNewArrivalMentionSeen(messageID: message.id)
            } else {
                await loadUnseenMentions()
            }
        }
    }

    private func drainDMEvents(
        _ events: [MessageEvent], contact: ContactDTO, needsReload: Bool
    ) -> (needsReload: Bool, needsContactRefresh: Bool) {
        var needsReload = needsReload
        var needsContactRefresh = false
        for event in events {
            switch event {
            case .directMessageReceived(let message, _) where message.contactID == contact.id:
                chatViewModel.appendMessageIfNew(message)
                handleIncomingMentionIfNeeded(message)
            case .messageStatusUpdated, .messageRetrying:
                needsReload = true
            case .messageFailed(let messageID):
                if chatViewModel.messages.contains(where: { $0.id == messageID }) {
                    needsReload = true
                }
            case .routingChanged(let contactID, _) where contactID == contact.id:
                needsContactRefresh = true
            case .reactionReceived(let messageID, let summary):
                if chatViewModel.messages.contains(where: { $0.id == messageID }) {
                    chatViewModel.updateReactionSummary(for: messageID, summary: summary)
                }
            default:
                break
            }
        }
        return (needsReload, needsContactRefresh)
    }

    private func drainChannelEvents(
        _ events: [MessageEvent], channel: ChannelDTO, needsReload: Bool
    ) -> Bool {
        var needsReload = needsReload
        for event in events {
            switch event {
            case .channelMessageReceived(let message, let channelIndex)
                where channelIndex == channel.index && message.deviceID == channel.deviceID:
                chatViewModel.appendMessageIfNew(message)
                handleIncomingMentionIfNeeded(message)
            case .messageStatusUpdated:
                needsReload = true
            case .messageFailed(let messageID):
                if chatViewModel.messages.contains(where: { $0.id == messageID }) {
                    needsReload = true
                }
            case .heardRepeatRecorded(let messageID, _):
                if chatViewModel.messages.contains(where: { $0.id == messageID }) {
                    needsReload = true
                }
            case .reactionReceived(let messageID, let summary):
                if chatViewModel.messages.contains(where: { $0.id == messageID }) {
                    chatViewModel.updateReactionSummary(for: messageID, summary: summary)
                }
            default:
                break
            }
        }
        return needsReload
    }

    // MARK: - Contact Refresh (DM only)

    private func refreshContact() async {
        guard case .dm(let contact) = conversationType else { return }
        if let updated = try? await appState.services?.dataStore.fetchContact(id: contact.id) {
            conversationType = conversationType.replacingContact(updated)
            chatViewModel.currentContact = updated
        }
    }

    // MARK: - Mention Tracking

    private func loadUnseenMentions() async {
        switch conversationType {
        case .dm(let contact):
            guard let dataStore = appState.services?.dataStore else { return }
            do {
                unseenMentionIDs = try await dataStore.fetchUnseenMentionIDs(contactID: contact.id)
            } catch {
                logger.error("Failed to load unseen mentions: \(error)")
            }

        case .channel(let channel):
            guard let services = appState.services else { return }
            do {
                let allIDs = try await services.dataStore.fetchUnseenChannelMentionIDs(
                    deviceID: channel.deviceID,
                    channelIndex: channel.index
                )

                let blockedNames = await services.syncCoordinator.blockedSenderNames()
                if blockedNames.isEmpty {
                    unseenMentionIDs = allIDs
                    return
                }

                var filteredIDs: [UUID] = []
                for id in allIDs {
                    do {
                        if let message = try await services.dataStore.fetchMessage(id: id),
                           let senderName = message.senderNodeName,
                           blockedNames.contains(senderName) {
                            try await services.dataStore.markMentionSeen(messageID: id)
                            continue
                        }
                    } catch {
                        logger.error("Failed to check/filter mention \(id): \(error)")
                    }
                    filteredIDs.append(id)
                }
                unseenMentionIDs = filteredIDs
            } catch {
                logger.error("Failed to load unseen channel mentions: \(error)")
            }
        }
    }

    private func markMentionSeen(messageID: UUID) async {
        guard unseenMentionIDs.contains(messageID) else { return }
        guard await persistMentionSeen(messageID: messageID) else { return }
        unseenMentionIDs.removeAll { $0 == messageID }
    }

    private func markNewArrivalMentionSeen(messageID: UUID) async {
        _ = await persistMentionSeen(messageID: messageID)
    }

    private func persistMentionSeen(messageID: UUID) async -> Bool {
        guard let dataStore = appState.services?.dataStore else { return false }
        do {
            try await dataStore.markMentionSeen(messageID: messageID)
            switch conversationType {
            case .dm(let contact):
                try await dataStore.decrementUnreadMentionCount(contactID: contact.id)
                if let parent = parentViewModel, let deviceID = appState.connectedDevice?.id {
                    await parent.loadConversations(deviceID: deviceID)
                }
            case .channel(let channel):
                try await dataStore.decrementChannelUnreadMentionCount(channelID: channel.id)
                if let parent = parentViewModel, let deviceID = appState.connectedDevice?.id {
                    await parent.loadChannels(deviceID: deviceID)
                }
            }
            return true
        } catch {
            logger.error("Failed to mark mention seen: \(error)")
            return false
        }
    }

    // MARK: - Mention Navigation

    private func scrollToNextMention() {
        guard let targetID = unseenMentionIDs.first else { return }

        if chatViewModel.displayItems.contains(where: { $0.id == targetID }) {
            scrollToTargetID = targetID
            scrollToMentionRequest += 1
            return
        }

        mentionScrollTask?.cancel()
        mentionScrollTask = Task {
            do {
                let deadline = ContinuousClock.now + .seconds(10)
                while !chatViewModel.displayItems.contains(where: { $0.id == targetID }) {
                    guard chatViewModel.hasMoreMessages else {
                        logger.warning("Mention \(targetID) not found after exhausting history, removing")
                        if let dataStore = appState.services?.dataStore {
                            try? await dataStore.markMentionSeen(messageID: targetID)
                        }
                        unseenMentionIDs.removeAll { $0 == targetID }
                        break
                    }
                    guard unseenMentionIDs.contains(targetID) else { break }
                    guard ContinuousClock.now < deadline else {
                        logger.warning("Mention \(targetID) paging timed out")
                        break
                    }
                    if chatViewModel.isLoadingOlder {
                        try await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    await chatViewModel.loadOlderMessages()
                    try Task.checkCancellation()
                }
                if chatViewModel.displayItems.contains(where: { $0.id == targetID }) {
                    scrollToTargetID = targetID
                    scrollToMentionRequest += 1
                }
            } catch is CancellationError {
                // Expected when view disappears during paging
            } catch {
                logger.error("Failed to scroll to mention: \(error)")
            }
        }
    }

    // MARK: - Mention Suggestions

    private var activeMentionQuery: String? {
        MentionUtilities.detectActiveMention(in: chatViewModel.composingText)
    }

    private var mentionSuggestions: [ContactDTO] {
        guard let query = activeMentionQuery else { return [] }
        switch conversationType {
        case .dm:
            return MentionUtilities.filterContacts(chatViewModel.allContacts, query: query)
        case .channel:
            let combined = chatViewModel.allContacts + chatViewModel.channelSenders
            let order = mentionSenderOrder ?? chatViewModel.channelSenderOrder
            return MentionUtilities.filterContacts(combined, query: query, senderOrder: order)
        }
    }

    private func insertMention(for contact: ContactDTO) {
        guard let query = MentionUtilities.detectActiveMention(in: chatViewModel.composingText) else { return }

        let searchPattern = "@" + query
        if let range = chatViewModel.composingText.range(of: searchPattern, options: .backwards) {
            let mention = MentionUtilities.createMention(for: contact.name)
            chatViewModel.composingText.replaceSubrange(range, with: mention + " ")
        }

        // Reset keyboard to alphabetic layout (user was on symbols to type @)
        isInputFocused = false
        DispatchQueue.main.async {
            isInputFocused = true
        }
    }

    // MARK: - Message Actions Sheet

    private func messageActionsSheet(for message: MessageDTO) -> some View {
        let senderName: String = {
            if message.isOutgoing {
                return appState.localNodeName
            }
            switch conversationType {
            case .dm(let contact):
                return contact.displayName
            case .channel:
                return message.senderNodeName ?? L10n.Chats.Chats.Message.Sender.unknown
            }
        }()

        let senderContact: ContactDTO? = {
            if case .channel = conversationType {
                return resolveSenderContact(for: message)
            }
            return nil
        }()

        return MessageActionsSheet(
            message: message,
            senderName: senderName,
            recentEmojis: recentEmojisStore.recentEmojis,
            senderContact: senderContact,
            onAction: { action in
                handleMessageAction(action, for: message)
            },
            onDirectMessage: { contact in
                appState.navigation.navigateToChat(with: contact)
            },
            onViewContact: { contact in
                contactDetailContact = contact
            }
        )
    }

    // MARK: - Message Action Handling

    private func handleMessageAction(_ action: MessageAction, for message: MessageDTO) {
        switch action {
        case .react(let emoji):
            recentEmojisStore.recordUsage(emoji)
            Task { await chatViewModel.sendReaction(emoji: emoji, to: message) }
        case .reply:
            let replyText = buildReplyText(for: message)
            chatViewModel.composingText = replyText
            isInputFocused = true
        case .copy:
            UIPasteboard.general.string = message.text
        case .sendAgain:
            Task { await chatViewModel.sendAgain(message) }
        case .blockSender:
            guard case .channel(let channel) = conversationType, let name = message.senderNodeName else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                blockSenderContext = BlockSenderContext(senderName: name, deviceID: channel.deviceID)
            }
        case .replyWithRoute(let routeInfo):
            let replyText: String
            switch conversationType {
            case .dm:
                replyText = MentionUtilities.buildReplyPreview(messageText: message.text, routeInfo: routeInfo)
            case .channel:
                let mentionName = message.senderNodeName ?? L10n.Chats.Chats.Message.Sender.unknown
                replyText = MentionUtilities.buildReplyText(mentionName: mentionName, messageText: message.text, routeInfo: routeInfo)
            }
            chatViewModel.composingText = replyText
            isInputFocused = true

            // Show location picker before uploading (same privacy system as repeater maps)
            let hasLocation = (message.userLatitude != nil && message.userLongitude != nil)
                || appState.locationService.currentLocation != nil
            if hasLocation {
                pendingRouteMessage = message
                pendingRouteInfo = routeInfo
                showingRouteLocationPicker = true
            } else {
                // No location available — upload without user location
                Task {
                    guard let url = await uploadRouteToServer(message: message, routeInfo: routeInfo, chosenCoordinate: nil) else { return }
                    await MainActor.run {
                        if chatViewModel.composingText.contains(routeInfo) {
                            chatViewModel.composingText += "\(url.absoluteString)\n"
                        }
                    }
                }
            }
        case .replyWithRepeaterMap(let url, let description):
            // Standalone descriptive message — not a reply-quote
            chatViewModel.composingText = "\(description)\n\(url.absoluteString)\n"
            isInputFocused = true
        case .delete:
            Task { await chatViewModel.deleteMessage(message) }
        }
    }

    private func buildReplyText(for message: MessageDTO) -> String {
        let mentionName: String
        switch conversationType {
        case .dm(let contact):
            mentionName = contact.name
        case .channel:
            mentionName = message.senderNodeName ?? L10n.Chats.Chats.Message.Sender.unknown
        }
        return MentionUtilities.buildReplyText(mentionName: mentionName, messageText: message.text)
    }

    /// The true location for the route share location picker.
    /// Prefers the location recorded on the pending message; falls back to current GPS.
    private var routePickerTrueLocation: CLLocationCoordinate2D? {
        if let msg = pendingRouteMessage,
           let lat = msg.userLatitude, let lon = msg.userLongitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return appState.locationService.currentLocation?.coordinate
    }

    /// Resolve hop data from a message and upload to the server.
    /// Returns the share URL on success, nil on failure or no internet.
    private func uploadRouteToServer(message: MessageDTO, routeInfo: String, chosenCoordinate: CLLocationCoordinate2D?) async -> URL? {
        guard let pathNodes = message.pathNodes, !pathNodes.isEmpty else { return nil }

        let hashSize = message.pathHashSize
        let hopHashes = stride(from: 0, to: pathNodes.count, by: hashSize).map { start in
            Data(pathNodes[start..<min(start + hashSize, pathNodes.count)])
        }

        let userLocation = appState.locationService.currentLocation

        // Use the same resolution lists as the message path view:
        // repeater-typed contacts first, then discovered repeater nodes.
        // Using all contacts (unfiltered) can pick the wrong match when
        // 1-byte hex IDs collide between a repeater and a non-repeater contact.
        let repeaterContacts = chatViewModel.allContacts.filter { $0.type == .repeater }

        var discoveredNodes: [DiscoveredNodeDTO] = []
        if let deviceID = appState.connectedDevice?.id {
            let allDiscovered = (try? await appState.services?.dataStore.fetchDiscoveredNodes(deviceID: deviceID)) ?? []
            discoveredNodes = allDiscovered.filter { $0.nodeType == .repeater }
        }

        // Build RouteHop array by resolving each hop
        let hops: [RouteShareService.RouteHop] = hopHashes.map { hashBytes in
            let hexID = hashBytes.map { String(format: "%02X", $0) }.joined()

            // Try to resolve name and location — matching the message path view
            if let match = RepeaterResolver.bestMatch(for: hashBytes, in: repeaterContacts, userLocation: userLocation) {
                return RouteShareService.RouteHop(
                    hexID: hexID,
                    name: match.resolvableName,
                    latitude: match.hasLocation ? match.latitude : nil,
                    longitude: match.hasLocation ? match.longitude : nil
                )
            }
            if let match = RepeaterResolver.bestMatch(for: hashBytes, in: discoveredNodes, userLocation: userLocation) {
                return RouteShareService.RouteHop(
                    hexID: hexID,
                    name: match.resolvableName,
                    latitude: match.hasLocation ? match.latitude : nil,
                    longitude: match.hasLocation ? match.longitude : nil
                )
            }

            // Fall back to all contacts in case the hop is a non-repeater node
            if let match = RepeaterResolver.bestMatch(for: hashBytes, in: chatViewModel.allContacts, userLocation: userLocation) {
                return RouteShareService.RouteHop(
                    hexID: hexID,
                    name: match.resolvableName,
                    latitude: match.hasLocation ? match.latitude : nil,
                    longitude: match.hasLocation ? match.longitude : nil
                )
            }

            return RouteShareService.RouteHop(hexID: hexID, name: nil, latitude: nil, longitude: nil)
        }

        let hopCount = Int(message.pathLength & 0x3F)

        // Compute distance directly from the resolved hop coordinates.
        // This is more accurate than parsing the route info string because
        // the hops here were resolved with repeater-priority matching.
        let locatedCoords: [CLLocationCoordinate2D] = hops.compactMap { hop in
            guard let lat = hop.latitude, let lon = hop.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        var distanceCoords = locatedCoords
        if let userLocation {
            distanceCoords.append(userLocation.coordinate)
        }
        let totalMeters = RouteDistanceCalculator.chainDistance(between: distanceCoords)
        let hasGaps = locatedCoords.count < hops.count
        let distanceText: String? = totalMeters > 0
            ? RouteDistanceCalculator.formatTotal(totalMeters, hasGaps: hasGaps)
            : nil

        let service = RouteShareService()
        return await service.shareRoute(
            hopCount: hopCount,
            distanceText: distanceText,
            hops: hops,
            userLatitude: chosenCoordinate?.latitude,
            userLongitude: chosenCoordinate?.longitude
        )
    }

    private func retryMessage(_ message: MessageDTO) {
        Task {
            switch conversationType {
            case .dm:
                await chatViewModel.retryMessage(message)
            case .channel:
                await chatViewModel.retryChannelMessage(message)
            }
        }
    }

    // MARK: - Sender Resolution (Channel only)

    private func resolveSenderContact(for message: MessageDTO) -> ContactDTO? {
        guard !message.isOutgoing else { return nil }

        // Try key prefix match first (most reliable)
        if let prefix = message.senderKeyPrefix {
            if let contact = chatViewModel.allContacts.first(where: { contact in
                contact.publicKey.count >= prefix.count &&
                Array(contact.publicKey.prefix(prefix.count)) == Array(prefix)
            }) {
                return contact
            }
        }

        // Fall back to name match against real contacts
        if let senderName = message.senderNodeName, !senderName.isEmpty {
            return chatViewModel.allContacts.first { $0.name == senderName }
        }

        return nil
    }

    // MARK: - Blocking (Channel only)

    private func performBlock(senderName: String, deviceID: UUID, contactIDs: Set<UUID>) async {
        guard let services = appState.services else { return }

        let dto = BlockedChannelSenderDTO(name: senderName, deviceID: deviceID)
        do {
            try await services.dataStore.saveBlockedChannelSender(dto)
        } catch {
            logger.error("Failed to save blocked channel sender: \(error)")
            return
        }

        for contactID in contactIDs {
            do {
                try await services.contactService.updateContactPreferences(
                    contactID: contactID,
                    isBlocked: true
                )
            } catch {
                logger.error("Failed to block contact \(contactID): \(error)")
            }
        }

        await services.syncCoordinator.refreshBlockedContactsCache(
            deviceID: deviceID,
            dataStore: services.dataStore
        )

        if !contactIDs.isEmpty {
            await services.syncCoordinator.notifyContactsChanged()
        }

        if case .channel(let channel) = conversationType {
            await chatViewModel.loadChannelMessages(for: channel)
        }
        await services.syncCoordinator.notifyConversationsChanged()
    }
}

// MARK: - Previews

#Preview("DM") {
    NavigationStack {
        ChatConversationView(
            conversationType: .dm(ContactDTO(from: Contact(
                deviceID: UUID(),
                publicKey: Data(repeating: 0x42, count: 32),
                name: "Alice"
            )))
        )
    }
    .environment(\.appState, AppState())
}

#Preview("Channel") {
    NavigationStack {
        ChatConversationView(
            conversationType: .channel(ChannelDTO(from: Channel(
                deviceID: UUID(),
                index: 1,
                name: "General"
            )))
        )
    }
    .environment(\.appState, AppState())
}
