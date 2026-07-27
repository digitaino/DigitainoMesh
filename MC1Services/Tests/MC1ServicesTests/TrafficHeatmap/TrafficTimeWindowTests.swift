import Foundation
@testable import MC1Services
import Testing

/// Spec source: legacy `TrafficHeatmapViewModel.computeTimePeriods`.
@Suite("TrafficTimeWindow")
struct TrafficTimeWindowTests {
  private let now = TrafficFixture.now

  // MARK: - Ladder

  @Test
  func `An empty log offers nothing but the all-time window`() {
    #expect(TrafficTimeWindow.available(oldestEntry: nil, now: now) == [.all])
  }

  /// One row of the ladder table. A named type rather than a tuple: the tuple version of this
  /// table takes the type checker past its budget.
  struct LadderCase: Sendable {
    let span: TimeInterval
    let expected: [TrafficTimeWindow]
  }

  static let ladderCases: [LadderCase] = [
    LadderCase(span: 60, expected: [.minutes15, .minutes30, .all]),
    LadderCase(span: 3599, expected: [.minutes15, .minutes30, .all]),
    LadderCase(span: 3600, expected: [.minutes30, .hour1, .hours3, .all]),
    LadderCase(span: 21599, expected: [.minutes30, .hour1, .hours3, .all]),
    LadderCase(span: 21600, expected: [.hour1, .hours6, .hours12, .all]),
    LadderCase(span: 86399, expected: [.hour1, .hours6, .hours12, .all]),
    LadderCase(span: 86400, expected: [.hours6, .day1, .days3, .all]),
    LadderCase(span: 603_999, expected: [.hours6, .day1, .days3, .all]),
    LadderCase(span: 604_800, expected: [.day1, .days3, .days7, .all]),
    LadderCase(span: 2_592_000, expected: [.day1, .days3, .days7, .all]),
  ]

  @Test(arguments: ladderCases)
  func `The ladder scales to the span of the log actually on hand`(testCase: LadderCase) {
    let oldest = now.addingTimeInterval(-testCase.span)
    #expect(TrafficTimeWindow.available(oldestEntry: oldest, now: now) == testCase.expected)
  }

  @Test
  func `A log timestamped in the future falls back to the shortest ladder rather than failing`() {
    let oldest = now.addingTimeInterval(3600)
    #expect(TrafficTimeWindow.available(oldestEntry: oldest, now: now) == [.minutes15, .minutes30, .all])
  }

  @Test
  func `Every ladder ends with the all-time window`() {
    for span in [0.0, 1800, 7200, 40000, 200_000, 2_000_000] {
      let windows = TrafficTimeWindow.available(oldestEntry: now.addingTimeInterval(-span), now: now)
      #expect(windows.last == .all)
      #expect(Set(windows).count == windows.count)
    }
  }

  // MARK: - Containment

  @Test
  func `An entry exactly on the cutoff is inside the window`() throws {
    let window = TrafficTimeWindow.hour1
    let cutoff = try #require(window.cutoff(now: now))
    #expect(cutoff == now.addingTimeInterval(-3600))
    #expect(window.contains(cutoff, now: now))
    #expect(!window.contains(cutoff.addingTimeInterval(-1), now: now))
    #expect(window.contains(now, now: now))
  }

  @Test
  func `The all-time window has no cutoff and admits everything`() {
    #expect(TrafficTimeWindow.all.duration == nil)
    #expect(TrafficTimeWindow.all.cutoff(now: now) == nil)
    #expect(TrafficTimeWindow.all.contains(.distantPast, now: now))
  }
}
