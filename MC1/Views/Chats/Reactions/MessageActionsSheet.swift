import MC1Services
import SwiftUI

struct MessageActionsSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let message: MessageDTO
  let senderResolution: NodeNameResolution
  let recentEmojis: [String]
  let onAction: (MessageAction) -> Void

  private var availability: MessageActionAvailability {
    MessageActionAvailability(message: message)
  }

  private func performAction(_ action: MessageAction) {
    if action == .delete || action == .blockSender {
      destructiveHapticTrigger += 1
    }
    onAction(action)
    dismiss()
  }

  @State private var destructiveHapticTrigger = 0
  @State private var showEmojiPicker = false
  @State private var isDetailExpanded = false
  @State private var repeats: [MessageRepeatDTO]?
  @State private var contacts: [ContactDTO] = []
  @State private var discoveredNodes: [DiscoveredNodeDTO] = []
  @State private var pathViewModel = MessagePathViewModel()

  var body: some View {
    VStack(spacing: 0) {
      ActionsPreviewHeader(
        message: message,
        senderResolution: senderResolution
      )

      Divider()

      if !dynamicTypeSize.isAccessibilitySize {
        ActionsEmojiSection(
          recentEmojis: recentEmojis,
          showEmojiPicker: $showEmojiPicker,
          onSelectEmoji: { performAction(.react($0)) }
        )
        Divider()
      }

      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
              ActionsEmojiSection(
                recentEmojis: recentEmojis,
                showEmojiPicker: $showEmojiPicker,
                onSelectEmoji: { performAction(.react($0)) }
              )
              Divider()
            }
            ActionsButtonsSection(
              availability: availability,
              onSelectAction: performAction
            )
            ActionsDetailsSection(
              message: message,
              availability: availability,
              isDetailExpanded: $isDetailExpanded,
              repeats: repeats,
              contacts: contacts,
              discoveredNodes: discoveredNodes,
              pathViewModel: pathViewModel,
              onSelectAction: performAction
            )
            ActionsDestructiveSection(
              availability: availability,
              onSelectAction: performAction
            )
          }
        }
        .onChange(of: isDetailExpanded) { _, expanded in
          if expanded {
            withAnimation(reduceMotion ? nil : .default) {
              proxy.scrollTo("expandedContent", anchor: .top)
            }
          }
        }
      }
    }
    .presentationDetents(
      (horizontalSizeClass == .regular || dynamicTypeSize.isAccessibilitySize)
        ? [.large] : [.medium, .large]
    )
    .presentationContentInteraction(.scrolls)
    .presentationDragIndicator(.visible)
    .presentationBackground(Color(.systemBackground))
    .sensoryFeedback(.warning, trigger: destructiveHapticTrigger)
    .task {
      // The path view model names hops for every destination — the path screen,
      // the repeats map and the Network View — so it loads for every message, from
      // the process store, with no radio required. It used to load only inside the
      // two local-evidence branches and only when `services` existed, which left a
      // Network-View-only message (an incoming DM) with unresolved hops forever, and a
      // disconnected radio with a spinner that never ended (review F010, F075).
      async let pathLoad: Void = pathViewModel.loadContacts(
        dataStore: appState.offlineDataStore,
        radioID: message.radioID
      )
      if availability.canShowRepeatDetails {
        // Repeats, contacts and discovered nodes share no data, so they run
        // concurrently. The store is the durable home of the repeat rows —
        // `refreshRepeats` only ever re-read them — so reading it directly drops
        // the dependency on a connected radio's service container.
        if let store = appState.offlineDataStore {
          do {
            async let fetchedRepeats = store.fetchMessageRepeats(messageID: message.id)
            async let fetchedContacts = store.fetchContacts(radioID: message.radioID)
            async let fetchedNodes = store.fetchDiscoveredNodes(radioID: message.radioID)
            contacts = try await fetchedContacts
            discoveredNodes = try await fetchedNodes
            repeats = try await fetchedRepeats
          } catch {
            contacts = []
            discoveredNodes = []
            repeats = []
          }
        } else {
          // Never paired: there is no store to read. An empty list is a terminal
          // state the rows can render; `nil` is a spinner that never ends.
          repeats = []
        }
      }
      await pathLoad
    }
  }
}

#Preview("Outgoing Message") {
  let message = Message(
    radioID: UUID(),
    contactID: UUID(),
    text: "Hello world!",
    directionRawValue: MessageDirection.outgoing.rawValue,
    statusRawValue: MessageStatus.delivered.rawValue
  )
  message.roundTripTime = 234
  message.heardRepeats = 2
  return MessageActionsSheet(
    message: MessageDTO(from: message),
    senderResolution: NodeNameResolution(displayName: "My Device", matchKind: .exact),
    recentEmojis: RecentEmojisStore.defaultEmojis,
    onAction: { print("Action: \($0)") }
  )
}

#Preview("Incoming Message") {
  let message = Message(
    radioID: UUID(),
    contactID: UUID(),
    text: "Hey, can you meet me at the coffee shop downtown later today? I have something important to discuss.",
    directionRawValue: MessageDirection.incoming.rawValue,
    statusRawValue: MessageStatus.delivered.rawValue,
    pathLength: 2
  )
  message.pathNodes = Data([0xA3, 0x7F])
  message.snr = 8.5
  return MessageActionsSheet(
    message: MessageDTO(from: message),
    senderResolution: NodeNameResolution(displayName: "Alice", matchKind: .exact),
    recentEmojis: RecentEmojisStore.defaultEmojis,
    onAction: { print("Action: \($0)") }
  )
}
