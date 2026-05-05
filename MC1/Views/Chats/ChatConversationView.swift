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
    @State private var sendDMContext: SendDMContext?
    @State private var imageViewerData: ImageViewerData?
    @State private var contactDetailContact: ContactDTO?

    // Route location picker state
    @State private var showingRouteLocationPicker = false
    @State private var pendingRouteMessage: MessageDTO?
    @State private var pendingRouteInfo: String?



    // MARK: - Search State

    @State private var conversationSearchText = ""
    @State private var isSearchActive = false
    @State private var searchScrollTask: Task<Void, Never>?
    @State private var highlightedMessageID: UUID?
    @State private var highlightDismissTask: Task<Void, Never>?

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
    @AppStorage("replyWithQuote") private var replyWithQuote = false

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
            highlightedMessageID: highlightedMessageID,
            newMessagesDividerMessageID: chatViewModel.newMessagesDividerMessageID,
            selectedMessageForActions: $selectedMessageForActions,
            imageViewerData: $imageViewerData,
            onMentionSeen: { await markMentionSeen(messageID: $0) },
            onScrollToMention: { scrollToNextMention() },
            onRetryMessage: { retryMessage($0) },
            onSendAgain: { message in
                Task { await chatViewModel.sendAgain(message) }
            },
            onSendAgainEscalated: { message in
                Task { await chatViewModel.sendAgainEscalated(message) }
            },
            onReply: { message in
                let mentionName: String
                switch conversationType {
                case .dm(let contact):
                    mentionName = contact.name
                case .channel:
                    mentionName = message.senderNodeName ?? L10n.Chats.Chats.Message.Sender.unknown
                }
                if replyWithQuote {
                    chatViewModel.composingText = MentionUtilities.buildReplyText(mentionName: mentionName, messageText: message.text)
                } else {
                    chatViewModel.composingText = MentionUtilities.createMention(for: mentionName) + " "
                }
                isInputFocused = true
            }
        )
        .safeAreaInset(edge: .bottom, spacing: 8) {
            ChatConversationInputBar(
                conversationType: conversationType,
                composingText: $chatViewModel.composingText,
                isFocused: $isInputFocused,
                nodeNameByteCount: appState.connectedDevice?.nodeName.utf8.count ?? 0,
                onSend: { text, powerOverride in
                    switch conversationType {
                    case .dm:
                        await chatViewModel.sendMessage(text: text, powerOverrideDbm: powerOverride)
                    case .channel:
                        await chatViewModel.sendChannelMessage(text: text, powerOverrideDbm: powerOverride)
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
            ToolbarItem(placement: .topBarTrailing) {
                SignalBarsToolbarItem()
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
        .sheet(item: $sendDMContext) { context in
            SendDMSheet(
                senderName: context.senderName,
                deviceID: context.deviceID,
                onSelect: { contact in
                    appState.navigation.navigateToChat(with: contact)
                }
            )
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
        .searchable(
            text: $conversationSearchText,
            isPresented: $isSearchActive,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search messages"
        )
        .onChange(of: conversationSearchText) { _, newValue in
            chatViewModel.searchWithinConversation(query: newValue)
        }
        .onChange(of: isSearchActive) { _, active in
            if !active {
                chatViewModel.clearConversationSearch()
            }
        }
        .onChange(of: chatViewModel.conversationSearch.currentMatchID) { _, matchID in
            guard let matchID else { return }
            scrollToSearchMatch(targetID: matchID)
        }
        .toolbar {
            if isSearchActive && chatViewModel.conversationSearch.totalMatches > 0 {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        chatViewModel.searchPreviousMatch()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(!chatViewModel.conversationSearch.canGoPrevious)

                    Text(chatViewModel.conversationSearch.currentMatchDisplay)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)

                    Button {
                        chatViewModel.searchNextMatch()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(!chatViewModel.conversationSearch.canGoNext)
                }
            }
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

        // Trigger scroll to target message if pending (notification deeplink or search result tap)
        if let targetID = pendingTarget {
            scrollToSearchMatch(targetID: targetID)
        }
    }

    // MARK: - Cleanup (.onDisappear)

    private func performCleanup() {
        mentionScrollTask?.cancel()
        mentionScrollTask = nil
        searchScrollTask?.cancel()
        searchScrollTask = nil
        highlightDismissTask?.cancel()
        highlightDismissTask = nil
        chatViewModel.clearConversationSearch()

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
            case .heardRepeatRecorded(let messageID, let count):
                if chatViewModel.messages.contains(where: { $0.id == messageID }) {
                    chatViewModel.updateHeardRepeats(for: messageID, count: count)
                    if count > 0 {
                        appState.adaptivePowerService.onRepeatsHeard()
                    }
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

    // MARK: - Search Navigation

    private func scrollToSearchMatch(targetID: UUID) {
        searchScrollTask?.cancel()
        searchScrollTask = Task {
            do {
                // Page through older messages until the target is loaded
                let deadline = ContinuousClock.now + .seconds(10)
                while !chatViewModel.displayItems.contains(where: { $0.id == targetID }) {
                    guard chatViewModel.hasMoreMessages else { break }
                    guard ContinuousClock.now < deadline else {
                        logger.warning("Search match \(targetID) paging timed out")
                        break
                    }
                    if chatViewModel.isLoadingOlder {
                        try await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    await chatViewModel.loadOlderMessages()
                    try Task.checkCancellation()
                }

                guard chatViewModel.displayItems.contains(where: { $0.id == targetID }) else {
                    return
                }

                // Small yield to ensure SwiftUI has processed the displayItems update
                // through updateUIViewController before issuing the scroll command.
                try await Task.sleep(for: .milliseconds(50))
                try Task.checkCancellation()

                scrollToTargetID = targetID
                scrollToMentionRequest += 1
                flashHighlight(messageID: targetID)
            } catch is CancellationError {
                // Expected when view disappears during paging
            } catch {
                logger.error("Failed to scroll to search match: \(error)")
            }
        }
    }

    /// Briefly highlight a message to draw attention after scroll completes.
    private func flashHighlight(messageID: UUID) {
        highlightDismissTask?.cancel()
        highlightedMessageID = messageID
        highlightDismissTask = Task {
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }
            highlightedMessageID = nil
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
            let mentionName: String
            switch conversationType {
            case .dm(let contact):
                mentionName = contact.name
            case .channel:
                mentionName = message.senderNodeName ?? L10n.Chats.Chats.Message.Sender.unknown
            }
            if replyWithQuote {
                chatViewModel.composingText = MentionUtilities.buildReplyText(mentionName: mentionName, messageText: message.text)
            } else {
                chatViewModel.composingText = MentionUtilities.createMention(for: mentionName) + " "
            }
            isInputFocused = true
        case .copy:
            UIPasteboard.general.string = message.text
        case .sendAgain:
            Task { await chatViewModel.sendAgain(message) }
        case .sendDM:
            guard case .channel(let channel) = conversationType, let name = message.senderNodeName else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                sendDMContext = SendDMContext(senderName: name, deviceID: channel.deviceID)
            }
        case .blockSender:
            guard case .channel(let channel) = conversationType, let name = message.senderNodeName else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                blockSenderContext = BlockSenderContext(senderName: name, deviceID: channel.deviceID)
            }
        case .replyWithRoute(let routeInfo, let shareFormat):
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

            if shareFormat == .textOnly {
                // Text-only: no upload, no location picker — just the route description
                break
            }

            // Web link: show location picker before uploading (same privacy system as repeater maps)
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
            if let url {
                // Web link: include URL with description
                chatViewModel.composingText = "\(description)\n\(url.absoluteString)\n"
            } else {
                // Text-only: just the description
                chatViewModel.composingText = "\(description)\n"
            }
            isInputFocused = true
        case .delete:
            Task { await chatViewModel.deleteMessage(message) }
        }
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

        // Use the same merged-pool + bidirectional anchor resolution as the
        // message path view to ensure the shared route matches what the user
        // sees on the iOS client.
        let repeaterContacts = chatViewModel.allContacts.filter { $0.type == .repeater }

        var discoveredNodes: [DiscoveredNodeDTO] = []
        if let deviceID = appState.connectedDevice?.id {
            let allDiscovered = (try? await appState.services?.dataStore.fetchDiscoveredNodes(deviceID: deviceID)) ?? []
            discoveredNodes = allDiscovered.filter { $0.nodeType == .repeater }
        }

        // Merged pool of all repeater-type nodes for unified resolution
        let allNodes: [AnyResolvable] =
            repeaterContacts.map { AnyResolvable($0) } +
            discoveredNodes.map { AnyResolvable($0) }

        // Determine sender location as forward anchor
        let senderAnchor: CLLocation? = {
            guard let senderKey = message.senderKeyPrefix,
                  let sender = chatViewModel.allContacts.first(where: { $0.publicKeyPrefix == senderKey }),
                  sender.hasLocation else { return nil }
            return CLLocation(latitude: sender.latitude, longitude: sender.longitude)
        }()

        // Forward pass: sender → receiver
        var forwardMatches: [AnyResolvable?] = []
        var forwardAnchor = senderAnchor
        var forwardHadAnchor: [Bool] = []
        for hash in hopHashes {
            let had = forwardAnchor != nil
            let match = RepeaterResolver.bestMatch(for: hash, in: allNodes, userLocation: userLocation, anchorLocation: forwardAnchor)
            forwardMatches.append(match)
            forwardHadAnchor.append(had)
            if let m = match, m.hasLocation {
                forwardAnchor = CLLocation(latitude: m.latitude, longitude: m.longitude)
            }
        }

        // Backward pass: receiver → sender
        var backwardMatches: [AnyResolvable?] = []
        var backwardAnchor = userLocation
        var backwardHadAnchor: [Bool] = []
        for hash in hopHashes.reversed() {
            let had = backwardAnchor != nil
            let match = RepeaterResolver.bestMatch(for: hash, in: allNodes, userLocation: userLocation, anchorLocation: backwardAnchor)
            backwardMatches.append(match)
            backwardHadAnchor.append(had)
            if let m = match, m.hasLocation {
                backwardAnchor = CLLocation(latitude: m.latitude, longitude: m.longitude)
            }
        }
        backwardMatches.reverse()
        backwardHadAnchor.reverse()

        // Load user overrides for ambiguous hops (set via disambiguation sheet)
        let overrides = MessagePathViewModel.overrides(for: message.id)

        // Merge: pick the result from the closer end for each hop
        let hops: [RouteShareService.RouteHop] = hopHashes.enumerated().map { i, hashBytes in
            let hexID = hashBytes.map { String(format: "%02X", $0) }.joined()

            // User override takes priority over algorithmic resolution
            if let overrideName = overrides[hexID],
               let overrideMatch = allNodes.first(where: { $0.resolvableName == overrideName }) {
                return RouteShareService.RouteHop(
                    hexID: hexID,
                    name: overrideMatch.resolvableName,
                    latitude: overrideMatch.hasLocation ? overrideMatch.latitude : nil,
                    longitude: overrideMatch.hasLocation ? overrideMatch.longitude : nil
                )
            }

            let useBackward: Bool
            if forwardHadAnchor[i] && backwardHadAnchor[i] {
                useBackward = (hopHashes.count - 1 - i) < i
            } else {
                useBackward = backwardHadAnchor[i] && !forwardHadAnchor[i]
            }

            let match = useBackward ? backwardMatches[i] : forwardMatches[i]

            if let match {
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

        // Compute distance from the resolved hop coordinates
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
            userLongitude: chosenCoordinate?.longitude,
            userName: appState.connectedDevice?.nodeName
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
