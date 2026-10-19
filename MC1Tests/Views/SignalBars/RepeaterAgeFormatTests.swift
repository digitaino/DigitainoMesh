import Foundation
@testable import MC1
import Testing

/// Guards the repeater table's compact age readout. The column is 44pt wide; a format change
/// that reintroduces multi-unit or spelled-out strings would silently bring the truncation
/// ("2 min, 4…") back.
@Suite("Repeater age format")
struct RepeaterAgeFormatTests {
  private let locale = Locale(identifier: "en_US")

  private func format(secondsAgo: TimeInterval) -> String {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    return RepeaterAgeFormat.compact(from: now.addingTimeInterval(-secondsAgo), to: now, locale: locale)
  }

  @Test
  func `Ages under a minute read in seconds`() {
    #expect(format(secondsAgo: 0) == "0s")
    #expect(format(secondsAgo: 45) == "45s")
    #expect(format(secondsAgo: 59) == "59s")
  }

  @Test
  func `Ages under an hour read as one minutes value`() {
    #expect(format(secondsAgo: 60) == "1m")
    // The sub-minute tail is dropped, not spelled out — this is the truncation fix.
    #expect(format(secondsAgo: 166) == "2m")
    #expect(format(secondsAgo: 59 * 60) == "59m")
  }

  @Test
  func `Ages under a day read as one hours value`() {
    #expect(format(secondsAgo: 3600) == "1h")
    #expect(format(secondsAgo: 5 * 3600 + 1800) == "5h")
  }

  @Test
  func `Older ages read as one days value`() {
    #expect(format(secondsAgo: 86400) == "1d")
    #expect(format(secondsAgo: 3 * 86400) == "3d")
  }

  @Test
  func `A future timestamp clamps to zero instead of counting up`() {
    #expect(format(secondsAgo: -30) == "0s")
  }
}
