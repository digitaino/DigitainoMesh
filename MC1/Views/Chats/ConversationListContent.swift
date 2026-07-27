import MC1Services
import SwiftUI

/// The conversation list rendered as a `ScrollView` + `LazyVStack` rather than a `List`.
/// `List` is backed by `UpdateCoalescingCollectionView`, whose batch-consistency assertion
/// is violated when the selected row is deleted; a `LazyVStack` has no collection view, so
/// that crash cannot occur. Row actions live in a `.contextMenu`.
struct ConversationListContent: View {
  enum ListMode {
    case selection(Binding<ChatRoute?>)
    case navigation(onNavigate: (ChatRoute) -> Void, onRequestRoomAuth: (RemoteNodeSessionDTO) -> Void)
  }

  @Environment(\.appTheme) private var theme
  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private let viewModel: ChatViewModel
  private let favoriteConversations: [Conversation]
  private let otherConversations: [Conversation]
  private let mode: ListMode
  private let hasLoadedOnce: Bool
  private let emptyStateMessage: (title: String, description: String, systemImage: String)
  private let onDeleteConversation: (Conversation) -> Void
  @Binding private var selectedFilter: ChatFilter

  /// The live search-field text. Conversation rows are already filtered by it upstream;
  /// this copy drives the message-search half of the results.
  private let searchText: String

  /// Global message search, owned here so both layouts get it without threading another
  /// binding through two root views.
  @State private var messageSearch = MessageSearchViewModel()

  /// Leading inset for the inter-row divider, aligning it under the row text past the avatar
  /// (row horizontal padding 16 + avatar 44 + avatar-to-text spacing 12).
  private static let rowSeparatorLeadingInset: CGFloat = 72

  init(
    viewModel: ChatViewModel,
    favoriteConversations: [Conversation],
    otherConversations: [Conversation],
    selectedFilter: Binding<ChatFilter>,
    hasLoadedOnce: Bool,
    emptyStateMessage: (title: String, description: String, systemImage: String),
    searchText: String,
    selection: Binding<ChatRoute?>,
    onDeleteConversation: @escaping (Conversation) -> Void
  ) {
    self.viewModel = viewModel
    self.favoriteConversations = favoriteConversations
    self.otherConversations = otherConversations
    _selectedFilter = selectedFilter
    self.hasLoadedOnce = hasLoadedOnce
    self.emptyStateMessage = emptyStateMessage
    self.searchText = searchText
    mode = .selection(selection)
    self.onDeleteConversation = onDeleteConversation
  }

  init(
    viewModel: ChatViewModel,
    favoriteConversations: [Conversation],
    otherConversations: [Conversation],
    selectedFilter: Binding<ChatFilter>,
    hasLoadedOnce: Bool,
    emptyStateMessage: (title: String, description: String, systemImage: String),
    searchText: String,
    onNavigate: @escaping (ChatRoute) -> Void,
    onRequestRoomAuth: @escaping (RemoteNodeSessionDTO) -> Void,
    onDeleteConversation: @escaping (Conversation) -> Void
  ) {
    self.viewModel = viewModel
    self.favoriteConversations = favoriteConversations
    self.otherConversations = otherConversations
    _selectedFilter = selectedFilter
    self.hasLoadedOnce = hasLoadedOnce
    self.emptyStateMessage = emptyStateMessage
    self.searchText = searchText
    mode = .navigation(onNavigate: onNavigate, onRequestRoomAuth: onRequestRoomAuth)
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
  /// ride along inside the route.
  private func openMessageResult(_ result: MessageSearchResult) {
    guard let conversation = conversation(for: result.conversation) else { return }
    appState.navigation.pendingScrollToMessageID = result.id
    let route = ChatRoute(conversation: conversation)
    switch mode {
    case let .selection(selection):
      selection.wrappedValue = route
    case let .navigation(onNavigate, _):
      onNavigate(route)
    }
  }

  private var loadingBody: some View {
    ScrollView {
      LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
        Section {} header: { pinnedFilterHeader }
      }
    }
    .overlay { ProgressView() }
  }

  private func loadedBody(referenceDate: Date) -> some View {
    ScrollView {
      LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
        Section {
          // While searching, an empty conversation list is not an empty screen: the
          // message results below may well be what the user was after.
          if hasNoConversations, !isSearching {
            emptyState
          } else {
            rows(referenceDate: referenceDate)
          }
          MessageSearchResultsSection(
            search: messageSearch,
            query: searchText,
            referenceDate: referenceDate,
            onOpen: openMessageResult
          )
        } header: {
          pinnedFilterHeader
        }
      }
    }
  }

  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Filter bar as the pinned section header; `pinnedFilterHeaderBackground` documents the
  /// per-OS backing.
  private var pinnedFilterHeader: some View {
    ChatFilterPicker(selection: $selectedFilter)
      .frame(maxWidth: .infinity)
      .pinnedFilterHeaderBackground(theme)
  }

  private var hasNoConversations: Bool {
    favoriteConversations.isEmpty && otherConversations.isEmpty
  }

  private var emptyState: some View {
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
    .containerRelativeFrame([.horizontal, .vertical])
  }

  /// One unified section, favorites first by concatenation, with an inset divider between rows.
  private func rows(referenceDate: Date) -> some View {
    let ordered = favoriteConversations + otherConversations
    return ForEach(Array(ordered.enumerated()), id: \.element.id) { index, conversation in
      rowView(conversation, referenceDate: referenceDate)
        .transition(.opacity)
      if index < ordered.count - 1 {
        Divider().padding(.leading, Self.rowSeparatorLeadingInset)
      }
    }
  }

  /// Warms the top conversations on first load, up to the registry's LRU
  /// capacity. Staggered so the per-conversation fetch and item build don't land
  /// on the main actor in one burst; `prefetchConversation` no-ops for any that
  /// are already warm.
  private func prewarmTopConversations() async {
    let ordered = favoriteConversations + otherConversations
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
    switch mode {
    case let .selection(selection):
      ConversationSelectionRow(
        conversation: conversation,
        viewModel: viewModel,
        referenceDate: referenceDate,
        isSelected: selection.wrappedValue == ChatRoute(conversation: conversation),
        onSelect: { selection.wrappedValue = ChatRoute(conversation: conversation) },
        onDelete: { onDeleteConversation(conversation) }
      )
    case let .navigation(onNavigate, onRequestRoomAuth):
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
}

// MARK: - Row Layout

private enum ConversationRowLayout {
  static let horizontalPadding: CGFloat = 16
  static let verticalPadding: CGFloat = 6
}

/// Renders a conversation's row body, shared by the selection and navigation rows.
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
        RoomConversationRow(session: session, referenceDate: referenceDate)
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
    .selectedRowHighlight(isSelected: isSelected)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .deletingRowOverlay(isDeleting: isDeleting)
    .conversationContextMenu(conversation: conversation, viewModel: viewModel, onDelete: onDelete)
  }
}

private struct ConversationNavigationRow: View {
  let conversation: Conversation
  let viewModel: ChatViewModel
  let referenceDate: Date
  let onNavigate: (ChatRoute) -> Void
  let onRequestRoomAuth: (RemoteNodeSessionDTO) -> Void
  let onDelete: () -> Void

  private var isDeleting: Bool {
    viewModel.deletingIDs.contains(conversation.id)
  }

  var body: some View {
    Button(action: tap) {
      ConversationRowLabel(conversation: conversation, viewModel: viewModel, referenceDate: referenceDate)
    }
    .buttonStyle(.plain)
    .deletingRowOverlay(isDeleting: isDeleting)
    .conversationContextMenu(conversation: conversation, viewModel: viewModel, onDelete: onDelete)
  }

  private func tap() {
    let route = ChatRoute(conversation: conversation)
    if case let .room(session) = conversation, !session.isConnected {
      onRequestRoomAuth(session)
    } else {
      onNavigate(route)
    }
  }
}
