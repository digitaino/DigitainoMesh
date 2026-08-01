import Foundation

/// Identifies runs of consecutive duplicate messages and plans which rows the
/// timeline renders. Mesh retries necessarily carry a fresh sender timestamp
/// (a reused one would be dropped by repeater dedup rings before it traveled),
/// so content-identical copies of one logical message land as distinct stored
/// rows; this module collapses them at render time instead of discarding the
/// per-copy path and SNR data at ingest.
///
/// Pure over value inputs — no actor state, no I/O. The bake pipeline calls
/// `plan` on every full rebuild; expansion state is the caller's to hold.
public enum DuplicateMessageGrouping {
  /// A run of consecutive messages with identical text from the same sender.
  /// The leader (oldest member) is the stable key expansion state tracks,
  /// surviving representative changes as new copies extend the run.
  public struct Run: Equatable, Sendable {
    public let leaderID: UUID
    public let messages: [MessageDTO]

    public var count: Int { messages.count }
    public var memberIDs: [UUID] { messages.map(\.id) }
  }

  /// Render decisions for one baked timeline pass.
  public struct Plan: Equatable, Sendable {
    /// Messages that produce a render item, in timeline order.
    public let visibleMessages: [MessageDTO]
    /// Collapsed copies that produce no item this pass.
    public let hiddenIDs: Set<UUID>
    /// Badge count for the one badge-bearing row of each multi-message run:
    /// the newest copy when collapsed, the leader when expanded.
    public let badgeCountByID: [UUID: Int]
    /// Run leader for every member of a multi-message run, so a toggle or
    /// reveal can resolve its group from any member id.
    public let leaderIDByMemberID: [UUID: UUID]

    public static let empty = Plan(
      visibleMessages: [], hiddenIDs: [], badgeCountByID: [:], leaderIDByMemberID: [:]
    )
  }

  /// Whether `message` extends a duplicate run ending at `previous`.
  /// Identical text and direction; channel rows additionally require a
  /// matching, present sender name (DMs have only two parties, so direction
  /// alone identifies the sender).
  public static func isDuplicateOfPrevious(_ message: MessageDTO, previous: MessageDTO) -> Bool {
    guard message.text == previous.text else { return false }
    guard message.direction == previous.direction else { return false }
    if message.contactID == nil {
      return message.senderNodeName == previous.senderNodeName
        && message.senderNodeName != nil
    }
    return true
  }

  /// Splits `messages` into consecutive duplicate runs (single messages are
  /// one-element runs).
  public static func runs(in messages: [MessageDTO]) -> [Run] {
    guard let first = messages.first else { return [] }
    var runs: [Run] = []
    var currentRun: [MessageDTO] = [first]
    for message in messages.dropFirst() {
      if let previous = currentRun.last, isDuplicateOfPrevious(message, previous: previous) {
        currentRun.append(message)
      } else {
        runs.append(Run(leaderID: currentRun[0].id, messages: currentRun))
        currentRun = [message]
      }
    }
    runs.append(Run(leaderID: currentRun[0].id, messages: currentRun))
    return runs
  }

  /// Plans the render pass: collapsed runs emit only their newest copy (the
  /// one whose path chip reflects the latest arrival) carrying the run count;
  /// expanded runs emit every copy with the count on the leader, whose badge
  /// collapses the run again.
  public static func plan(messages: [MessageDTO], expandedLeaders: Set<UUID>) -> Plan {
    var visible: [MessageDTO] = []
    var hidden: Set<UUID> = []
    var badgeCounts: [UUID: Int] = [:]
    var leaderByMember: [UUID: UUID] = [:]

    for run in runs(in: messages) {
      guard run.count > 1 else {
        visible.append(run.messages[0])
        continue
      }
      for id in run.memberIDs {
        leaderByMember[id] = run.leaderID
      }
      if expandedLeaders.contains(run.leaderID) {
        visible.append(contentsOf: run.messages)
        badgeCounts[run.leaderID] = run.count
      } else {
        let representative = run.messages[run.count - 1]
        visible.append(representative)
        badgeCounts[representative.id] = run.count
        for message in run.messages.dropLast() {
          hidden.insert(message.id)
        }
      }
    }

    return Plan(
      visibleMessages: visible,
      hiddenIDs: hidden,
      badgeCountByID: badgeCounts,
      leaderIDByMemberID: leaderByMember
    )
  }
}
