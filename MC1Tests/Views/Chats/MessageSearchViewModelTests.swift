import Foundation
@testable import MC1
@testable import MC1Services
import Testing

/// Guards what the chats-list message-search header claims.
///
/// The count it used to print came from a second store query — an unindexable full scan on the
/// one persistence actor, run per settled keystroke — and compared that raw total against a row
/// count taken *after* grouping had dropped results no conversation claims, so the two numbers
/// described different sets.
@Suite("Message search view model")
@MainActor
struct MessageSearchViewModelTests {
  /// Serves a fixed page and records whether the total was ever asked for.
  private actor StubStore: MessageSearching {
    private let results: [MessageSearchResult]
    private(set) var countQueries = 0

    init(results: [MessageSearchResult]) {
      self.results = results
    }

    func searchMessages(radioID: UUID, query: String, limit: Int, offset: Int) -> [MessageSearchResult] {
      Array(results.dropFirst(offset).prefix(limit))
    }

    func searchMessagesCount(radioID: UUID, query: String) -> Int {
      countQueries += 1
      return results.count
    }

    func searchMessageIDs(contactID: UUID, query: String, limit: Int) -> [UUID] { [] }

    func searchMessageIDs(radioID: UUID, channelIndex: UInt8, query: String, limit: Int) -> [UUID] { [] }
  }

  private func makeResult(contactID: UUID, text: String = "antenna") -> MessageSearchResult {
    MessageSearchResult(
      id: UUID(),
      text: text,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      sortDate: Date(timeIntervalSince1970: 1_700_000_000),
      contactID: contactID,
      channelIndex: nil,
      radioID: UUID(),
      senderNodeName: nil,
      directionRawValue: MessageDirection.incoming.rawValue
    )
  }

  private func search(
    _ viewModel: MessageSearchViewModel,
    store: StubStore,
    named: @escaping (MessageSearchResult.Scope) -> String? = { _ in "Alice" }
  ) async {
    await viewModel.search(query: "antenna", radioID: UUID(), store: store, conversationName: named)
  }

  @Test
  func `A short page is the whole result set and asks the store for no total`() async {
    let contactID = UUID()
    let store = StubStore(results: (0..<3).map { _ in makeResult(contactID: contactID) })
    let viewModel = MessageSearchViewModel()

    await search(viewModel, store: store)

    #expect(viewModel.loadedCount == 3)
    #expect(viewModel.hasMoreThanLoaded == false, "A short page has nothing behind it to caption")
    #expect(await store.countQueries == 0)
  }

  @Test
  func `A full page is captioned as a first slice, still without a total`() async {
    let contactID = UUID()
    let store = StubStore(
      results: (0..<(MessageSearchLimits.globalPageSize + 20)).map { _ in makeResult(contactID: contactID) }
    )
    let viewModel = MessageSearchViewModel()

    await search(viewModel, store: store)

    #expect(viewModel.loadedCount == MessageSearchLimits.globalPageSize)
    #expect(viewModel.hasMoreThanLoaded)
    #expect(await store.countQueries == 0)
  }

  /// Grouping drops results whose conversation the list no longer knows, so `loadedCount` is
  /// the only number that describes what is on screen.
  @Test
  func `Results the chat list cannot name are not counted as shown`() async {
    let named = UUID()
    let unknown = UUID()
    let store = StubStore(results: [makeResult(contactID: named), makeResult(contactID: unknown)])
    let viewModel = MessageSearchViewModel()

    await search(viewModel, store: store) { scope in
      scope == .direct(contactID: named) ? "Alice" : nil
    }

    #expect(viewModel.loadedCount == 1)
    #expect(viewModel.hasMoreThanLoaded == false)
  }
}
