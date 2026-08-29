import Foundation
@testable import MC1
@testable import MC1Services
import Testing

/// Guards the paging loop a search jump runs. Both of its failure modes are invisible until
/// they bite on device: a loop that reads a *skipped* load as progress holds the main actor
/// for the whole budget — and the load it is waiting for can only finish if the loop lets go —
/// while a jump that ignores cancellation lands its scroll on top of a newer one's.
@Suite("Chat message search navigator")
@MainActor
struct ChatMessageSearchNavigatorTests {
  /// Set by a main-actor task queued behind the paging loop; a reference box because a
  /// concurrently-executing closure cannot capture a mutable local.
  @MainActor
  private final class Sentinel {
    var ran = false
  }

  private func makeStore() throws -> PersistenceStore {
    let container = try PersistenceStore.createContainer(inMemory: true)
    return PersistenceStore(modelContainer: container)
  }

  private func makeContact(radioID: UUID) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: radioID,
      publicKey: Data((0..<ProtocolLimits.publicKeySize).map { _ in UInt8.random(in: 0...255) }),
      name: "TestContact",
      typeRawValue: ContactType.chat.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  private func makeMessage(radioID: UUID, contactID: UUID, timestamp: UInt32) -> MessageDTO {
    MessageDTO(
      id: UUID(),
      radioID: radioID,
      contactID: contactID,
      channelIndex: nil,
      text: "m\(timestamp)",
      timestamp: timestamp,
      createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
      direction: .incoming,
      status: .delivered,
      textType: .plain,
      ackCode: nil,
      pathLength: 0,
      snr: nil,
      senderKeyPrefix: nil,
      senderNodeName: nil,
      isRead: false,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0
    )
  }

  /// An opened conversation holding `messageCount` messages.
  private func makeOpenedConversation(messageCount: Int) async throws -> ChatViewModel {
    let dataStore = try makeStore()
    let radioID = UUID()
    let contact = makeContact(radioID: radioID)
    for offset in 0..<messageCount {
      try await dataStore.saveMessage(makeMessage(
        radioID: radioID,
        contactID: contact.id,
        timestamp: UInt32(1000 + offset)
      ))
    }

    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(dataStore: { dataStore }))
    viewModel.bindCoordinatorForTesting(ChatCoordinator.makeForTesting())
    #expect(
      await viewModel.primeInitialMessages(for: contact, populateMode: .replace),
      "Initial open must succeed"
    )
    return viewModel
  }

  @Test
  func `A target the conversation does not hold stops at the end of history`() async throws {
    let viewModel = try await makeOpenedConversation(messageCount: 3)
    #expect(viewModel.hasMoreMessages == false)

    let outcome = await ChatMessageSearchNavigator.loadUntilVisible(UUID(), in: viewModel)

    #expect(outcome == .notFound)
  }

  @Test
  func `A cancelled jump gives up instead of paging`() async throws {
    let viewModel = try await makeOpenedConversation(messageCount: ChatCoordinator.pageSize + 5)
    #expect(viewModel.hasMoreMessages)

    let jump = Task { await ChatMessageSearchNavigator.loadUntilVisible(UUID(), in: viewModel) }
    jump.cancel()

    #expect(await jump.value == .cancelled)
    #expect(viewModel.messages.count == ChatCoordinator.pageSize, "A cancelled jump must not page")
  }

  /// The load in flight is main-actor work too, so its continuation can only run if the retry
  /// loop hands the actor back. Without the yield nothing else on the main actor — including
  /// the load being waited for — runs until the budget expires.
  @Test
  func `A skipped load yields the main actor instead of spinning on it`() async throws {
    let viewModel = try await makeOpenedConversation(messageCount: ChatCoordinator.pageSize + 5)
    // Latch the spinner: every loadOlder from here is skipped, never a page.
    viewModel.timeline.writer?.updateRenderState { $0.with(isLoadingOlder: true) }

    let sentinel = Sentinel()
    let queuedBehindTheLoop = Task { @MainActor in sentinel.ran = true }

    let outcome = await ChatMessageSearchNavigator.loadUntilVisible(
      UUID(),
      in: viewModel,
      budget: .milliseconds(50)
    )

    #expect(outcome == .timedOut)
    #expect(sentinel.ran, "Main-actor work queued behind the loop must have run during it")
    #expect(viewModel.messages.count == ChatCoordinator.pageSize, "A skipped load must not page")
    _ = await queuedBehindTheLoop.value
  }
}
