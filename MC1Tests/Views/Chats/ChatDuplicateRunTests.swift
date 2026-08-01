import Foundation
@testable import MC1
@testable import MC1Services
import Testing

/// Timeline-level wiring for duplicate-run collapse: identical consecutive
/// copies (mesh retries carrying fresh timestamps) bake to one row with a
/// count, the badge toggle re-emits or re-hides the copies, a live duplicate
/// admission folds into its run, and the divider / search-reveal paths keep a
/// hidden copy reachable.
@Suite("Duplicate-run collapse wiring")
@MainActor
struct ChatDuplicateRunTests {
  private static let radioID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
  private static let contactID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
  private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeViewModel() -> (ChatViewModel, ChatCoordinator) {
    let viewModel = ChatViewModel()
    let coordinator = ChatCoordinator.makeForTesting()
    viewModel.bindCoordinatorForTesting(coordinator)
    return (viewModel, coordinator)
  }

  /// Incoming DM copy; each call mints a distinct id and a distinct timestamp,
  /// matching how mesh retries actually land (same text, fresh timestamp).
  private func makeCopy(
    _ text: String = "Yes sir",
    offset: TimeInterval = 0,
    id: UUID = UUID()
  ) -> MessageDTO {
    let date = Self.referenceDate.addingTimeInterval(offset)
    return MessageDTO(
      id: id,
      radioID: Self.radioID,
      contactID: Self.contactID,
      channelIndex: nil,
      text: text,
      timestamp: UInt32(date.timeIntervalSince1970),
      createdAt: date,
      direction: .incoming,
      status: .delivered,
      textType: .plain,
      ackCode: nil,
      pathLength: 2,
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

  // MARK: - Collapsed bake

  @Test
  func `Identical consecutive copies bake to one row carrying the run count`() async throws {
    let (viewModel, coordinator) = makeViewModel()
    let copies = [makeCopy(offset: 0), makeCopy(offset: 10), makeCopy(offset: 20)]
    let distinct = makeCopy("Que cambio?", offset: 30)
    coordinator.replaceAllForTesting(copies + [distinct])
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value

    #expect(viewModel.items.map(\.id) == [copies[2].id, distinct.id])
    let badge = try #require(viewModel.items.first)
    #expect(badge.grouping.duplicateCount == 3)
    #expect(!badge.grouping.isDuplicateRunExpanded)
    #expect(viewModel.items.last?.grouping.duplicateCount == 1)
  }

  // MARK: - Toggle

  @Test
  func `Badge toggle expands every copy and collapses them again`() async throws {
    let (viewModel, coordinator) = makeViewModel()
    let copies = [makeCopy(offset: 0), makeCopy(offset: 10), makeCopy(offset: 20)]
    coordinator.replaceAllForTesting(copies)
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value

    viewModel.toggleDuplicateRun(containing: copies[2].id)
    await coordinator.buildItemsTask?.value

    #expect(viewModel.items.map(\.id) == copies.map(\.id))
    let leader = try #require(viewModel.items.first)
    #expect(leader.grouping.duplicateCount == 3)
    #expect(leader.grouping.isDuplicateRunExpanded)
    #expect(viewModel.items[1].grouping.duplicateCount == 1)

    // Any member reaches the same run; collapsing from a middle copy works.
    viewModel.toggleDuplicateRun(containing: copies[1].id)
    await coordinator.buildItemsTask?.value

    #expect(viewModel.items.map(\.id) == [copies[2].id])
    #expect(viewModel.items.first?.grouping.duplicateCount == 3)
  }

  // MARK: - Live admission

  @Test
  func `An admitted duplicate folds into its collapsed run instead of adding a row`() async throws {
    let (viewModel, coordinator) = makeViewModel()
    let first = makeCopy(offset: 0)
    coordinator.replaceAllForTesting([first])
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value
    #expect(viewModel.items.count == 1)

    let retry = makeCopy(offset: 10)
    viewModel.appendMessageIfNew(retry)
    await coordinator.buildItemsTask?.value

    #expect(viewModel.messages.count == 2)
    #expect(viewModel.items.map(\.id) == [retry.id])
    #expect(viewModel.items.first?.grouping.duplicateCount == 2)
  }

  @Test
  func `A non-duplicate admission appends its own row`() async throws {
    let (viewModel, coordinator) = makeViewModel()
    let first = makeCopy(offset: 0)
    coordinator.replaceAllForTesting([first])
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value

    viewModel.appendMessageIfNew(makeCopy("Que cambio?", offset: 10))
    #expect(viewModel.items.count == 2)
    #expect(viewModel.items.allSatisfy { $0.grouping.duplicateCount == 1 })
  }

  @Test
  func `A duplicate admitted onto an expanded run keeps the run expanded`() async throws {
    let (viewModel, coordinator) = makeViewModel()
    let copies = [makeCopy(offset: 0), makeCopy(offset: 10)]
    coordinator.replaceAllForTesting(copies)
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value
    viewModel.toggleDuplicateRun(containing: copies[1].id)
    await coordinator.buildItemsTask?.value

    let retry = makeCopy(offset: 20)
    viewModel.appendMessageIfNew(retry)
    await coordinator.buildItemsTask?.value

    #expect(viewModel.items.map(\.id) == copies.map(\.id) + [retry.id])
    #expect(viewModel.items.first?.grouping.duplicateCount == 3)
  }

  // MARK: - Divider auto-expand

  @Test
  func `A run holding the New Messages divider bakes expanded`() async throws {
    let (viewModel, coordinator) = makeViewModel()
    let copies = [makeCopy(offset: 0), makeCopy(offset: 10), makeCopy(offset: 20)]
    coordinator.replaceAllForTesting(copies)
    // Divider on a copy that collapse would hide.
    viewModel.bake.newMessagesDividerMessageID = copies[1].id
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value

    #expect(viewModel.items.map(\.id) == copies.map(\.id))
    let divided = try #require(viewModel.items.first { $0.id == copies[1].id })
    #expect(divided.grouping.showNewMessagesDivider)
  }

  // MARK: - Reveal for search jumps

  @Test
  func `Reveal expands the run hiding a message and reports visible rows truthfully`() async throws {
    let (viewModel, coordinator) = makeViewModel()
    let copies = [makeCopy(offset: 0), makeCopy(offset: 10)]
    coordinator.replaceAllForTesting(copies)
    viewModel.buildItems()
    await coordinator.buildItemsTask?.value
    #expect(viewModel.itemIndexByID[copies[0].id] == nil)

    #expect(viewModel.revealHiddenDuplicate(copies[0].id))
    await coordinator.buildItemsTask?.value
    #expect(viewModel.itemIndexByID[copies[0].id] != nil)

    // Already visible: no expansion, no rebake.
    #expect(!viewModel.revealHiddenDuplicate(copies[0].id))
    #expect(!viewModel.revealHiddenDuplicate(copies[1].id))
  }
}
