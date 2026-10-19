import Foundation
@testable import MC1Services
import Testing

/// Behavior spec source: the pre-v2 duplicate collapse
/// (`ChatViewModel.isDuplicateOfPrevious` and `identifyDuplicateGroups` on the
/// `personal` branch): identical consecutive copies from one sender collapse
/// to the newest with a count; expansion emits every copy with the count on
/// the leader.
@Suite("DuplicateMessageGrouping")
struct DuplicateMessageGroupingTests {
  private let radioID = UUID()
  private let contactID = UUID()

  private func dm(
    _ text: String,
    direction: MessageDirection = .incoming,
    id: UUID = UUID()
  ) -> MessageDTO {
    .testDirectMessage(
      id: id, radioID: radioID, contactID: contactID, text: text, direction: direction
    )
  }

  private func channel(
    _ text: String,
    from sender: String?,
    direction: MessageDirection = .incoming,
    id: UUID = UUID()
  ) -> MessageDTO {
    .testChannelMessage(
      id: id, radioID: radioID, text: text, direction: direction, senderNodeName: sender
    )
  }

  // MARK: - Predicate

  @Test
  func `DM copies with identical text and direction are duplicates`() {
    let first = dm("Yes sir")
    #expect(DuplicateMessageGrouping.isDuplicateOfPrevious(dm("Yes sir"), previous: first))
  }

  @Test
  func `Different text or direction breaks the duplicate relation`() {
    let incoming = dm("Yes sir")
    #expect(!DuplicateMessageGrouping.isDuplicateOfPrevious(dm("Que cambio?"), previous: incoming))
    #expect(!DuplicateMessageGrouping.isDuplicateOfPrevious(
      dm("Yes sir", direction: .outgoing), previous: incoming
    ))
  }

  @Test
  func `Channel copies require a matching, present sender name`() {
    let fromChapin = channel("Yes sir", from: "Chapin710")
    #expect(DuplicateMessageGrouping.isDuplicateOfPrevious(
      channel("Yes sir", from: "Chapin710"), previous: fromChapin
    ))
    #expect(!DuplicateMessageGrouping.isDuplicateOfPrevious(
      channel("Yes sir", from: "Someone"), previous: fromChapin
    ))
    // Two nameless rows cannot be attributed to one sender, so they never group.
    let nameless = channel("Yes sir", from: nil)
    #expect(!DuplicateMessageGrouping.isDuplicateOfPrevious(
      channel("Yes sir", from: nil), previous: nameless
    ))
  }

  // MARK: - Run identification

  @Test
  func `Runs split on any non-duplicate boundary and lead with their oldest member`() {
    let a1 = dm("Yes sir"), a2 = dm("Yes sir"), b = dm("Que cambio?"), c1 = dm("Yes sir")
    let runs = DuplicateMessageGrouping.runs(in: [a1, a2, b, c1])
    #expect(runs.map(\.memberIDs) == [[a1.id, a2.id], [b.id], [c1.id]])
    #expect(runs[0].leaderID == a1.id)
  }

  @Test
  func `Interleaved senders never group even with identical text`() {
    let messages = [
      channel("Yes sir", from: "Chapin710"),
      channel("Yes sir", from: "Other"),
      channel("Yes sir", from: "Chapin710"),
    ]
    #expect(DuplicateMessageGrouping.runs(in: messages).allSatisfy { $0.count == 1 })
  }

  // MARK: - Collapsed plan

  @Test
  func `Collapsed run renders only its newest copy carrying the run count`() {
    let copies = [dm("Yes sir"), dm("Yes sir"), dm("Yes sir")]
    let tail = dm("Que cambio?")
    let plan = DuplicateMessageGrouping.plan(messages: copies + [tail], expandedLeaders: [])

    #expect(plan.visibleMessages.map(\.id) == [copies[2].id, tail.id])
    #expect(plan.hiddenIDs == [copies[0].id, copies[1].id])
    #expect(plan.badgeCountByID == [copies[2].id: 3])
    #expect(plan.leaderIDByMemberID[copies[1].id] == copies[0].id)
    #expect(plan.leaderIDByMemberID[tail.id] == nil)
  }

  @Test
  func `Single messages carry no badge and no run membership`() {
    let single = dm("Hello")
    let plan = DuplicateMessageGrouping.plan(messages: [single], expandedLeaders: [])
    #expect(plan.visibleMessages.map(\.id) == [single.id])
    #expect(plan.hiddenIDs.isEmpty)
    #expect(plan.badgeCountByID.isEmpty)
    #expect(plan.leaderIDByMemberID.isEmpty)
  }

  // MARK: - Expanded plan

  @Test
  func `Expanded run renders every copy with the count on its leader`() {
    let copies = [dm("Yes sir"), dm("Yes sir"), dm("Yes sir")]
    let plan = DuplicateMessageGrouping.plan(
      messages: copies, expandedLeaders: [copies[0].id]
    )
    #expect(plan.visibleMessages.map(\.id) == copies.map(\.id))
    #expect(plan.hiddenIDs.isEmpty)
    #expect(plan.badgeCountByID == [copies[0].id: 3])
  }

  @Test
  func `Expansion is per run — other runs stay collapsed`() {
    let first = [dm("Yes sir"), dm("Yes sir")]
    let second = [dm("Que cambio?"), dm("Que cambio?")]
    let plan = DuplicateMessageGrouping.plan(
      messages: first + second, expandedLeaders: [first[0].id]
    )
    #expect(plan.visibleMessages.map(\.id) == [first[0].id, first[1].id, second[1].id])
    #expect(plan.hiddenIDs == [second[0].id])
  }

  // MARK: - Run growth

  @Test
  func `A new copy extends a collapsed run and moves the badge to the newest copy`() {
    let copies = [dm("Yes sir"), dm("Yes sir")]
    let newest = dm("Yes sir")
    let before = DuplicateMessageGrouping.plan(messages: copies, expandedLeaders: [])
    let after = DuplicateMessageGrouping.plan(messages: copies + [newest], expandedLeaders: [])

    #expect(before.badgeCountByID == [copies[1].id: 2])
    #expect(after.badgeCountByID == [newest.id: 3])
    // The leader (expansion key) is unchanged by growth.
    #expect(after.leaderIDByMemberID[newest.id] == copies[0].id)
  }
}
