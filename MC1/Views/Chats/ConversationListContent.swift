import MC1Services
import SwiftUI

/// Uses a `LazyVStack` because `List` can fail its batch-consistency assertion
/// when the selected conversation is deleted.
struct ConversationListContent: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private let viewModel: ChatViewModel
  private let pinnedConversations: [Conversation]
  private let otherConversations: [Conversation]
  private let selectedRoute: ChatRoute?
  private let onSelect: (ChatRoute) -> Void
  private let hasLoadedOnce: Bool
  private let searchText: String
  private let emptyStateMessage: (title: String, description: String, systemImage: String)
  private let onDeleteConversation: (Conversation) -> Void
  @Binding private var selectedFilter: ChatFilter

  /// Global message search, owned here so both layouts get it without threading another
  /// binding through two root views.
  @State private var messageSearch = MessageSearchViewModel()

  /// Leading inset for the inter-row divider, aligning it under the row text past the avatar
  /// (row horizontal padding 16 + avatar 44 + avatar-to-text spacing 12).
  private static let rowSeparatorLeadingInset: CGFloat = 72
  private static let sectionHeaderHorizontalPadding: CGFloat = 16
  private static let sectionHeaderVerticalPadding: CGFloat = 12

  init(
    viewModel: ChatViewModel,
    pinnedConversations: [Conversation],
    otherConversations: [Conversation],
    selectedFilter: Binding<ChatFilter>,
    searchText: String,
    hasLoadedOnce: Bool,
    emptyStateMessage: (title: String, description: String, systemImage: String),
    selectedRoute: ChatRoute?,
    onSelect: @escaping (ChatRoute) -> Void,
    onDeleteConversation: @escaping (Conversation) -> Void
  ) {
    self.viewModel = viewModel
    self.pinnedConversations = pinnedConversations
    self.otherConversations = otherConversations
    self.selectedRoute = selectedRoute
    self.onSelect = onSelect
    _selectedFilter = selectedFilter
    self.searchText = searchText
    self.hasLoadedOnce = hasLoadedOnce
    self.emptyStateMessage = emptyStateMessage
    self.onDeleteConversation = onDeleteConversation
  }

  var body: some View {
    Group {
      if !hasLoadedOnce {
        loadingBody
      } else {
        TimelineView(.everyMinute) { context in
          loadedBody(referenceDate: context.date)
        }
      }
    }
    // Warm the top registry-capacity conversations after load so open lands settled.
    // Keep warm work off LazyVStack rows: appear/disappear would start and cancel tasks while scrolling.
    .task(id: hasLoadedOnce) {
      guard hasLoadedOnce else { return }
      await prewarmTopConversations()
    }
    // Debounced so a query is not run per keystroke: each edit cancels the previous task,
    // and only a pause long enough to finish typing a word reaches the store.
    .task(id: searchText) {
      guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        messageSearch.clear()
        return
      }
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      await messageSearch.search(
        query: searchText,
        radioID: appState.currentRadioID,
        store: appState.offlineDataStore,
        conversationName: conversationName(for:)
      )
    }
  }

  // MARK: - Message Search

  /// Resolves a result's conversation to its display name; `nil` for a conversation the
  /// list no longer holds, which drops the group rather than offering an untappable row.
  private func conversationName(for scope: MessageSearchResult.Scope) -> String? {
    conversation(for: scope)?.displayName
  }

  private func conversation(for scope: MessageSearchResult.Scope) -> Conversation? {
    viewModel.allConversations.first { candidate in
      switch (scope, candidate) {
      case let (.direct(contactID), .direct(contact)): contact.id == contactID
      case let (.channel(index), .channel(channel)): channel.index == index
      default: false
      }
    }
  }

  /// Opens the conversation a result belongs to, handing the message id to
  /// `ChatConversationView` through the same pending-scroll channel a reaction
  /// notification uses. `ChatRoute` hashes on the conversation alone, so the target cannot
  /// ride along inside the route — and when the route is the one already selected, that
  /// channel is the only thing that moves the open conversation at all.
  private func openMessageResult(_ result: MessageSearchResult) {
    guard let conversation = conversation(for: result.conversation) else { return }
    let route = ChatRoute(conversation: conversation)
    appState.navigation.pendingScrollTarget = PendingScrollTarget(route: route, messageID: result.id)
    onSelect(route)
  }

  private var loadingBody: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        Section {} header: { filterHeader }
      }
    }
    .overlay { ProgressView() }
  }

  private func loadedBody(referenceDate: Date) -> some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        filterHeader
        if hasNoConversations {
          // While searching, an empty conversation list is not an empty screen: the message
          // results below may well be what the user was after.
          if !isSearching || messageSearchFoundNothing {
            emptyState
          }
        } else if pinnedConversations.isEmpty {
          rows(otherConversations, referenceDate: referenceDate)
        } else {
          conversationSection(
            pinnedConversations,
            title: L10n.Chats.Chats.Row.pin,
            referenceDate: referenceDate
          )
          conversationSection(
            otherConversations,
            title: L10n.Chats.Chats.title,
            referenceDate: referenceDate
          )
        }
        MessageSearchResultsSection(
          search: messageSearch,
          query: searchText,
          referenceDate: referenceDate,
          onOpen: openMessageResult
        )
      }
    }
    .swipeActionsContainerIfAvailable()
  }

  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The message half has finished searching the current query and found nothing, so the
  /// whole result is empty.
  private var messageSearchFoundNothing: Bool {
    messageSearch.groups.isEmpty && !messageSearch.isLoading
      && messageSearch.resolvedQuery == searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Filter bar as the section header; it scrolls away with the list (upstream 0a762556).
  /// `pinnedFilterHeaderBackground` documents the per-OS backing.
  private var filterHeader: some View {
    ChatFilterPicker(selection: $selectedFilter, isSearching: !searchText.isEmpty)
      .frame(maxWidth: .infinity)
      .pinnedFilterHeaderBackground(theme)
  }

  private var hasNoConversations: Bool {
    pinnedConversations.isEmpty && otherConversations.isEmpty
  }

  private var emptyState: some View {
    Group {
      if !searchText.isEmpty {
        ContentUnavailableView.search(text: searchText)
      } else {
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
    .containerRelativeFrame([.horizontal, .vertical])
  }

  @ViewBuilder
  private func conversationSection(
    _ conversations: [Conversation],
    title: String,
    referenceDate: Date
  ) -> some View {
    if !conversations.isEmpty {
      Section {
        rows(conversations, referenceDate: referenceDate)
      } header: {
        Text(title)
          .font(.headline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Self.sectionHeaderHorizontalPadding)
          .padding(.vertical, Self.sectionHeaderVerticalPadding)
          .accessibilityAddTraits(.isHeader)
      }
    }
  }

  private func rows(_ conversations: [Conversation], referenceDate: Date) -> some View {
    ForEach(Array(conversations.enumerated()), id: \.element.id) { index, conversation in
      rowView(conversation, referenceDate: referenceDate)
        .transition(.opacity)
      if index < conversations.count - 1 {
        Divider().padding(.leading, Self.rowSeparatorLeadingInset)
      }
    }
  }

  /// Primes the top conversations up to the registry's capacity, staggering
  /// fetches so populate and bake work does not land on the main actor in one burst.
  private func prewarmTopConversations() async {
    let ordered = pinnedConversations + otherConversations
    for conversation in ordered.prefix(ChatCoordinatorRegistry.defaultCapacity) {
      guard !Task.isCancelled else { return }
      warm(conversation)
      try? await Task.sleep(for: .milliseconds(30))
    }
  }

  /// Kicks off the coordinator warm for one conversation. Rooms have no
  /// coordinator; skipped.
  private func warm(_ conversation: Conversation) {
    guard let conversationType = ChatRoute(conversation: conversation).chatConversationType else { return }
    appState.prefetchConversation(
      conversationType,
      envInputs: appState.chatEnvInputs(
        for: conversationType,
        themeID: theme.id,
        isDark: colorScheme == .dark,
        isHighContrast: colorSchemeContrast == .increased,
        contentSizeCategory: AppearanceToken.contentSizeCategoryToken(dynamicTypeSize)
      )
    )
  }

  @ViewBuilder
  private func rowView(_ conversation: Conversation, referenceDate: Date) -> some View {
    let route = ChatRoute(conversation: conversation)
    ConversationSelectionRow(
      conversation: conversation,
      viewModel: viewModel,
      referenceDate: referenceDate,
      isSelected: selectedRoute == route,
      onSelect: { onSelect(route) },
      onDelete: { onDeleteConversation(conversation) }
    )
  }
}

// MARK: - Row Layout

private enum ConversationRowLayout {
  static let horizontalPadding: CGFloat = 16
  static let verticalPadding: CGFloat = 6
}

private struct ConversationRowLabel: View {
  let conversation: Conversation
  let viewModel: ChatViewModel
  let referenceDate: Date

  var body: some View {
    Group {
      switch conversation {
      case let .direct(contact):
        ConversationRow(contact: contact, viewModel: viewModel, referenceDate: referenceDate)
      case let .channel(channel):
        ChannelConversationRow(channel: channel, viewModel: viewModel, referenceDate: referenceDate)
      case let .room(session):
        RoomConversationRow(session: session, viewModel: viewModel, referenceDate: referenceDate)
      }
    }
    .padding(.horizontal, ConversationRowLayout.horizontalPadding)
    .padding(.vertical, ConversationRowLayout.verticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
  }
}

// MARK: - Extracted Rows

private struct ConversationSelectionRow: View {
  let conversation: Conversation
  let viewModel: ChatViewModel
  let referenceDate: Date
  let isSelected: Bool
  let onSelect: () -> Void
  let onDelete: () -> Void

  private var isDeleting: Bool {
    viewModel.deletingIDs.contains(conversation.id)
  }

  var body: some View {
    Button(action: onSelect) {
      ConversationRowLabel(conversation: conversation, viewModel: viewModel, referenceDate: referenceDate)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .conversationContextMenu(conversation: conversation, viewModel: viewModel, onDelete: onDelete)
    .selectedRowHighlight(isSelected: isSelected)
    .deletingRowOverlay(isDeleting: isDeleting)
    .conversationSwipeActions(conversation: conversation, viewModel: viewModel, onDelete: onDelete)
  }
}
