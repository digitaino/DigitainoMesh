import Foundation

/// Grouping signal — first-in-cluster, show timestamp, show divider.
public struct GroupingFlags: Sendable, Hashable {
  public let showTimestamp: Bool
  public let showDirectionGap: Bool
  public let showSenderName: Bool
  public let showNewMessagesDivider: Bool
  /// True for the first message of a new calendar day; drives the day separator.
  public let showDayDivider: Bool
  /// Size of the duplicate run this row fronts; 1 for rows outside any run.
  /// Greater than 1 only on the badge-bearing row (the collapsed
  /// representative, or the expanded leader).
  public let duplicateCount: Int
  /// Whether the run behind `duplicateCount` is currently expanded; drives
  /// the badge's collapse-vs-expand affordance.
  public let isDuplicateRunExpanded: Bool

  public init(
    showTimestamp: Bool,
    showDirectionGap: Bool,
    showSenderName: Bool,
    showNewMessagesDivider: Bool,
    showDayDivider: Bool = false,
    duplicateCount: Int = 1,
    isDuplicateRunExpanded: Bool = false
  ) {
    self.showTimestamp = showTimestamp
    self.showDirectionGap = showDirectionGap
    self.showSenderName = showSenderName
    self.showNewMessagesDivider = showNewMessagesDivider
    self.showDayDivider = showDayDivider
    self.duplicateCount = duplicateCount
    self.isDuplicateRunExpanded = isDuplicateRunExpanded
  }
}
