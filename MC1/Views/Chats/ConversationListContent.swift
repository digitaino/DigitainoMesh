import SwiftUI
import MC1Services

struct ConversationListContent: View {
    enum ListMode {
        case selection(Binding<ChatRoute?>)
        case navigation(onNavigate: (ChatRoute) -> Void, onRequestRoomAuth: (RemoteNodeSessionDTO) -> Void)
    }

    private let viewModel: ChatViewModel
    private let favoriteConversations: [Conversation]
    private let otherConversations: [Conversation]
    private let searchText: String
    private let messageSearchResults: ChatViewModel.GlobalSearchResults
    private let mode: ListMode
    private let hasLoadedOnce: Bool
    private let emptyStateMessage: (title: String, description: String, systemImage: String)
    private let onDeleteConversation: (Conversation) -> Void
    private let onSearchResultTap: (MessageSearchResult) -> Void
    @Binding private var selectedFilter: ChatFilter

    init(
        viewModel: ChatViewModel,
        favoriteConversations: [Conversation],
        otherConversations: [Conversation],
        searchText: String = "",
        messageSearchResults: ChatViewModel.GlobalSearchResults = .init(),
        selectedFilter: Binding<ChatFilter>,
        hasLoadedOnce: Bool,
        emptyStateMessage: (title: String, description: String, systemImage: String),
        selection: Binding<ChatRoute?>,
        onDeleteConversation: @escaping (Conversation) -> Void,
        onSearchResultTap: @escaping (MessageSearchResult) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.favoriteConversations = favoriteConversations
        self.otherConversations = otherConversations
        self.searchText = searchText
        self.messageSearchResults = messageSearchResults
        self._selectedFilter = selectedFilter
        self.hasLoadedOnce = hasLoadedOnce
        self.emptyStateMessage = emptyStateMessage
        self.mode = .selection(selection)
        self.onDeleteConversation = onDeleteConversation
        self.onSearchResultTap = onSearchResultTap
    }

    init(
        viewModel: ChatViewModel,
        favoriteConversations: [Conversation],
        otherConversations: [Conversation],
        searchText: String = "",
        messageSearchResults: ChatViewModel.GlobalSearchResults = .init(),
        selectedFilter: Binding<ChatFilter>,
        hasLoadedOnce: Bool,
        emptyStateMessage: (title: String, description: String, systemImage: String),
        onNavigate: @escaping (ChatRoute) -> Void,
        onRequestRoomAuth: @escaping (RemoteNodeSessionDTO) -> Void,
        onDeleteConversation: @escaping (Conversation) -> Void,
        onSearchResultTap: @escaping (MessageSearchResult) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.favoriteConversations = favoriteConversations
        self.otherConversations = otherConversations
        self.searchText = searchText
        self.messageSearchResults = messageSearchResults
        self._selectedFilter = selectedFilter
        self.hasLoadedOnce = hasLoadedOnce
        self.emptyStateMessage = emptyStateMessage
        self.mode = .navigation(onNavigate: onNavigate, onRequestRoomAuth: onRequestRoomAuth)
        self.onDeleteConversation = onDeleteConversation
        self.onSearchResultTap = onSearchResultTap
    }

    var body: some View {
        if !hasLoadedOnce {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.everyMinute) { context in
                listContent(referenceDate: context.date)
                    .overlay {
                        if favoriteConversations.isEmpty && otherConversations.isEmpty && !hasMessageSearchResults && !messageSearchResults.isSearching {
                            ContentUnavailableView {
                                Label(emptyStateMessage.title, systemImage: emptyStateMessage.systemImage)
                            } description: {
                                Text(emptyStateMessage.description)
                            } actions: {
                                if selectedFilter != .all {
                                    Button(L10n.Chats.Chats.Filter.clear) {
                                        selectedFilter = .all
                                    }
                                }
                            }
                        }
                    }
            }
        }
    }

    private var hasMessageSearchResults: Bool {
        !searchText.isEmpty && !messageSearchResults.resultsByConversation.isEmpty
    }

    @ViewBuilder
    private func messageSearchResultsSection() -> some View {
        if hasMessageSearchResults {
            Section {
                ForEach(Array(messageSearchResults.resultsByConversation.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.conversation.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)

                        let isChannel: Bool = {
                            if case .channel = group.conversation { return true }
                            return false
                        }()

                        ForEach(group.results.prefix(3)) { result in
                            Button {
                                onSearchResultTap(result)
                            } label: {
                                MessageSearchSnippetRow(
                                    result: result,
                                    searchText: searchText,
                                    isChannel: isChannel
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        if group.results.count > 3 {
                            Text("\(group.results.count - 3) more")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("Messages")
                    if messageSearchResults.isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else if messageSearchResults.totalCount > 0 {
                        Text("(\(messageSearchResults.totalCount))")
                            .foregroundColor(.secondary)
                    }
                }
            }
        } else if !searchText.isEmpty && messageSearchResults.isSearching {
            Section("Messages") {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching…")
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func listContent(referenceDate: Date) -> some View {
        switch mode {
        case .selection(let selection):
            List(selection: selection) {
                ConversationFilterSection(selection: $selectedFilter)

                Section {
                    ForEach(favoriteConversations) { conversation in
                        ConversationSelectionRow(
                            conversation: conversation,
                            viewModel: viewModel,
                            referenceDate: referenceDate,
                            onDelete: { onDeleteConversation(conversation) }
                        )
                    }
                }
                .accessibilityLabel(L10n.Chats.Chats.Section.favorites)
                .accessibilityHidden(favoriteConversations.isEmpty)

                Section {
                    ForEach(otherConversations) { conversation in
                        ConversationSelectionRow(
                            conversation: conversation,
                            viewModel: viewModel,
                            referenceDate: referenceDate,
                            onDelete: { onDeleteConversation(conversation) }
                        )
                    }
                }
                .accessibilityLabel(L10n.Chats.Chats.Section.conversations)
                .accessibilityHidden(otherConversations.isEmpty)

                messageSearchResultsSection()
            }
            .listStyle(.plain)

        case .navigation(let onNavigate, let onRequestRoomAuth):
            List {
                ConversationFilterSection(selection: $selectedFilter)

                Section {
                    ForEach(favoriteConversations) { conversation in
                        ConversationNavigationRow(
                            conversation: conversation,
                            viewModel: viewModel,
                            referenceDate: referenceDate,
                            onNavigate: onNavigate,
                            onRequestRoomAuth: onRequestRoomAuth,
                            onDelete: { onDeleteConversation(conversation) }
                        )
                    }
                }
                .accessibilityLabel(L10n.Chats.Chats.Section.favorites)
                .accessibilityHidden(favoriteConversations.isEmpty)

                Section {
                    ForEach(otherConversations) { conversation in
                        ConversationNavigationRow(
                            conversation: conversation,
                            viewModel: viewModel,
                            referenceDate: referenceDate,
                            onNavigate: onNavigate,
                            onRequestRoomAuth: onRequestRoomAuth,
                            onDelete: { onDeleteConversation(conversation) }
                        )
                    }
                }
                .accessibilityLabel(L10n.Chats.Chats.Section.conversations)
                .accessibilityHidden(otherConversations.isEmpty)

                messageSearchResultsSection()
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Extracted Views

private struct ConversationFilterSection: View {
    @Binding var selection: ChatFilter

    var body: some View {
        Section {
            ChatFilterPicker(selection: $selection)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listSectionSeparator(.hidden)
    }
}

private struct ConversationSelectionRow: View {
    let conversation: Conversation
    let viewModel: ChatViewModel
    let referenceDate: Date
    let onDelete: () -> Void

    var body: some View {
        let route = ChatRoute(conversation: conversation)
        switch conversation {
        case .direct(let contact):
            ConversationRow(contact: contact, viewModel: viewModel, referenceDate: referenceDate)
                .tag(route)
                .conversationSwipeActions(conversation: conversation, viewModel: viewModel, onDelete: onDelete)

        case .channel(let channel):
            ChannelConversationRow(channel: channel, viewModel: viewModel, referenceDate: referenceDate)
                .tag(route)
                .conversationSwipeActions(conversation: conversation, viewModel: viewModel, onDelete: onDelete)

        case .room(let session):
            RoomConversationRow(session: session, referenceDate: referenceDate)
                .tag(route)
                .conversationSwipeActions(conversation: conversation, viewModel: viewModel, onDelete: onDelete)
        }
    }
}

private struct ConversationNavigationRow: View {
    let conversation: Conversation
    let viewModel: ChatViewModel
    let referenceDate: Date
    let onNavigate: (ChatRoute) -> Void
    let onRequestRoomAuth: (RemoteNodeSessionDTO) -> Void
    let onDelete: () -> Void

    var body: some View {
        let route = ChatRoute(conversation: conversation)
        switch conversation {
        case .direct(let contact):
            NavigationLink(value: route) {
                ConversationRow(contact: contact, viewModel: viewModel, referenceDate: referenceDate)
            }
            .conversationSwipeActions(conversation: conversation, viewModel: viewModel, onDelete: onDelete)

        case .channel(let channel):
            NavigationLink(value: route) {
                ChannelConversationRow(channel: channel, viewModel: viewModel, referenceDate: referenceDate)
            }
            .conversationSwipeActions(conversation: conversation, viewModel: viewModel, onDelete: onDelete)

        case .room(let session):
            Button {
                if session.isConnected {
                    onNavigate(route)
                } else {
                    onRequestRoomAuth(session)
                }
            } label: {
                RoomConversationRow(session: session, referenceDate: referenceDate)
            }
            .buttonStyle(.plain)
            .conversationSwipeActions(conversation: conversation, viewModel: viewModel, onDelete: onDelete)
        }
    }
}
