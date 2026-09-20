import Foundation
@testable import MC1
import MC1Services
import Testing

/// The I/O half of the automatic observer-count lookup — the part
/// `PacketScopeObserverCountsTests` cannot reach, because it is about the order in
/// which one pass touches the database and the bubble, and about the diagnostic
/// line that says what the eye badge actually knows.
@Suite("ChatViewModel observer-count pass")
@MainActor
struct ChatViewModelObserverCountPassTests {
  private let hash = "286dcbdeab84b458"

  // MARK: - The reload race

  @Test
  func `the pass writes the row before it touches the bubble`() async {
    // Every echo fires `.heardRepeatRecorded`, which enqueues a reload: an async
    // re-fetch that replaces this row's in-memory DTO with the database's. With the
    // in-memory write first, a reload landing in the gap put the older count and
    // check time straight back on the bubble — the badge reverting and then, a
    // cadence later, jumping again, which is what Rafael keeps seeing. The row has
    // to be written first so the worst a reload can fetch is this pass's answer.
    let viewModel = makeBoundViewModel()
    let message = makeSentChannelMessage(count: 3, checkedSecondsAgo: 30)
    viewModel.appendMessageIfNew(message)

    let recorder = PassRecorder()
    let report = await viewModel.runObserverCountPass(
      using: StubPacketScopeService(byHash: [hash: observations(observerCount: 8)]),
      persist: { id, count, checkedAt in
        recorder.persisted.append(PassRecorder.Write(id: id, count: count, checkedAt: checkedAt))
        recorder.messageAtPersist = viewModel.messages.first { $0.id == id }
      }
    )

    #expect(report.outcome == .completed)
    #expect(recorder.persisted.map(\.count) == [8])
    #expect(
      recorder.messageAtPersist?.packetObserverCount == 3,
      "the bubble must still hold the old count while the row is being written"
    )
    #expect(recorder.messageAtPersist?.packetObserversCheckedAt == message.packetObserversCheckedAt)
    #expect(viewModel.messages.first?.packetObserverCount == 8)
  }

  @Test
  func `a count that has not moved is not written to the row at all`() async {
    // The pass runs every four seconds inside the burst window; a database write on
    // each of them to say the number is unchanged would be a write loop.
    let viewModel = makeBoundViewModel()
    viewModel.appendMessageIfNew(makeSentChannelMessage(count: 8, checkedSecondsAgo: 30))

    let recorder = PassRecorder()
    let report = await viewModel.runObserverCountPass(
      using: StubPacketScopeService(byHash: [hash: observations(observerCount: 8)]),
      persist: { id, count, checkedAt in
        recorder.persisted.append(PassRecorder.Write(id: id, count: count, checkedAt: checkedAt))
      }
    )

    #expect(report.outcome == .completed)
    #expect(recorder.persisted.isEmpty)
    #expect(viewModel.messages.first?.packetObserverCount == 8)
  }

  // MARK: - What the log carries

  @Test
  func `a pass with nothing to ask about says so`() async {
    // The evidence for the next report: "candidates=0" distinguishes a loop that is
    // running and finding nothing from a loop that is not running at all.
    let viewModel = makeBoundViewModel()
    viewModel.appendMessageIfNew(makeSentChannelMessage(hash: nil))

    let report = await viewModel.runObserverCountPass(
      using: StubPacketScopeService(byHash: [:])
    )

    #expect(report.outcome == .idle)
    #expect(report.detail == "candidates=0")
  }

  @Test
  func `a completed pass logs the hash and the move it made`() async {
    let viewModel = makeBoundViewModel()
    viewModel.appendMessageIfNew(makeSentChannelMessage(count: 3, checkedSecondsAgo: 30))

    let report = await viewModel.runObserverCountPass(
      using: StubPacketScopeService(byHash: [hash: observations(observerCount: 8)])
    )

    #expect(report.detail.contains("candidates=1"))
    #expect(report.detail.contains(hash), "the hash is the only way to line a log up with a packet")
    #expect(report.detail.contains("3→8→8"))
  }

  @Test
  func `a never-looked-up count does not log as a zero`() async {
    let viewModel = makeBoundViewModel()
    viewModel.appendMessageIfNew(makeSentChannelMessage(count: nil, checkedSecondsAgo: nil))

    let report = await viewModel.runObserverCountPass(
      using: StubPacketScopeService(byHash: [hash: observations(observerCount: 2)])
    )

    #expect(report.detail.contains("none→2→2"))
  }

  // MARK: - The diagnostic line in the actions sheet

  @Test
  func `the diagnostic names each of the three states the badge can be in`() {
    let now = Date(timeIntervalSince1970: 1_788_400_000)
    let noHash = MessageObserverDiagnostic.text(
      for: makeSentChannelMessage(hash: nil),
      now: now
    )
    let notChecked = MessageObserverDiagnostic.text(
      for: makeSentChannelMessage(count: nil, checkedSecondsAgo: nil),
      now: now
    )
    let checked = MessageObserverDiagnostic.text(
      for: makeSentChannelMessage(count: 4, checkedSecondsAgo: 12, now: now),
      now: now
    )

    #expect(noHash == L10n.Chats.Chats.Message.Observers.diagnosticNoHash)
    #expect(notChecked == L10n.Chats.Chats.Message.Observers.diagnosticNotChecked)
    #expect(checked.contains("4"), "the count is the point of the line")
    #expect(checked != noHash)
    #expect(checked != notChecked)
  }

  @Test
  func `a checked message with no count still shows as checked`() {
    // The hot-window zero the pass declines to believe: the check happened, the
    // number is still unknown, and the badge shows the same ellipsis.
    let now = Date(timeIntervalSince1970: 1_788_400_000)
    let text = MessageObserverDiagnostic.text(
      for: makeSentChannelMessage(count: nil, checkedSecondsAgo: 4, now: now),
      now: now
    )

    #expect(text.contains("…"))
    #expect(text != L10n.Chats.Chats.Message.Observers.diagnosticNotChecked)
  }

  // MARK: - Helpers

  private func makeBoundViewModel() -> ChatViewModel {
    let viewModel = ChatViewModel()
    viewModel.bindCoordinatorForTesting(ChatCoordinator.makeForTesting())
    return viewModel
  }

  /// An outgoing channel message aged 60 s — inside the burst window, so it is a
  /// candidate whenever its last check is more than four seconds old.
  private func makeSentChannelMessage(
    hash: String? = "286dcbdeab84b458",
    count: Int? = nil,
    checkedSecondsAgo: TimeInterval? = nil,
    now: Date = Date()
  ) -> MessageDTO {
    let sentAt = now.addingTimeInterval(-60)
    return MessageDTO(
      id: UUID(),
      radioID: UUID(),
      contactID: nil,
      channelIndex: 3,
      text: "hello mesh",
      timestamp: UInt32(sentAt.timeIntervalSince1970),
      createdAt: sentAt,
      direction: .outgoing,
      status: .sent,
      textType: .plain,
      ackCode: nil,
      pathLength: 0,
      snr: nil,
      senderKeyPrefix: nil,
      senderNodeName: nil,
      isRead: true,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0,
      packetContentHash: hash,
      packetObserverCount: count,
      packetObserversCheckedAt: checkedSecondsAgo.map { now.addingTimeInterval(-$0) }
    )
  }

  /// `observerCount` distinct observers, each reporting the packet twice, so the
  /// fold to distinct ids is exercised rather than assumed.
  private func observations(observerCount: Int) -> [PacketScopeObservation] {
    (0..<observerCount).flatMap { index in
      (0..<2).map { repetition in
        PacketScopeObservation(
          id: index * 2 + repetition,
          observerID: "obs-\(index)",
          observerName: "Observer \(index)",
          observerIATA: nil,
          snr: nil,
          rssi: nil,
          pathHops: [],
          resolvedPath: [],
          timestamp: nil
        )
      }
    }
  }
}

// MARK: - Stubs

/// Records what the pass persisted and, crucially, what the bubble held at the
/// moment it did — the ordering is invisible from outside `PersistenceStore`,
/// which is an actor.
@MainActor
private final class PassRecorder {
  struct Write {
    let id: UUID
    let count: Int
    let checkedAt: Date
  }

  var persisted: [Write] = []
  var messageAtPersist: MessageDTO?
}

private struct StubPacketScopeService: PacketScopeServicing {
  let byHash: [String: [PacketScopeObservation]]

  func observations(for hashes: [String]) async throws -> [String: [PacketScopeObservation]] {
    byHash.filter { hashes.contains($0.key) }
  }

  func observers() async throws -> [PacketScopeObserver] {
    []
  }
}
