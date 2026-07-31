import Foundation
@testable import MC1Services
import Testing

/// Spec source: legacy `SignalBarsService.desiredPingInterval(for:)`,
/// `nextRepeaterToPing()`, the reactive-trigger branch of `handleDiscoverResponse`, and
/// the motion divisor that mirrored the firmware's `_td`.
@Suite("SignalBarsPolicy")
struct SignalBarsPolicyTests {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)
  private let policy = SignalBarsPolicy()

  private func repeater(
    _ hex: String,
    txState: RepeaterTXState = .measured(.good),
    failCount: Int = 0,
    lastProbeAt: Date? = nil,
    hasKey: Bool = true,
    rxSnr: Double = 5
  ) throws -> RepeaterSignal {
    try RepeaterSignal(
      id: #require(NodeHexID(hex)),
      rxSnr: rxSnr,
      txSnr: 5,
      txState: txState,
      lastHeard: start,
      publicKey: hasKey ? SignalBarsFixtures.publicKey([UInt8(hex.count)]) : nil,
      failCount: failCount,
      lastProbeAt: lastProbeAt
    )
  }

  // MARK: - Cadence

  @Test
  func `The best link is probed more often than the rest`() throws {
    let entry = try repeater("01")
    #expect(policy.probeInterval(for: entry, isBest: true, movement: .stationary) == 45)
    #expect(policy.probeInterval(for: entry, isBest: false, movement: .stationary) == 120)
  }

  @Test
  func `Failures back off on a 20 45 90 ladder and stop at the fail ceiling`() throws {
    let cases: [(failCount: Int, interval: TimeInterval?)] = [
      (1, 20), (2, 45), (3, 90), (4, nil), (9, nil)
    ]
    for testCase in cases {
      let entry = try repeater("01", failCount: testCase.failCount)
      #expect(
        policy.probeInterval(for: entry, isBest: true, movement: .stationary) == testCase.interval,
        "failCount \(testCase.failCount)"
      )
    }
  }

  @Test
  func `Movement shortens the cadence the way the firmware scales its own`() throws {
    let entry = try repeater("01")
    #expect(MovementHint.stationary.cadenceDivisor == 1)
    #expect(MovementHint.slow.cadenceDivisor == 2)
    #expect(MovementHint.fast.cadenceDivisor == 4)
    #expect(policy.probeInterval(for: entry, isBest: true, movement: .slow) == 22.5)
    #expect(policy.probeInterval(for: entry, isBest: true, movement: .fast) == 11.25)
  }

  // MARK: - Target selection

  @Test
  func `A repeater that has never been measured outranks every overdue one`() throws {
    let table = try [
      repeater("01", txState: .measured(.good), lastProbeAt: start.addingTimeInterval(-10000)),
      repeater("02", txState: .unknown)
    ]
    #expect(policy.nextProbeTarget(among: table, now: start, movement: .stationary)?.hexID == "02")
  }

  @Test
  func `Among due repeaters the most overdue goes first`() throws {
    let table = try [
      repeater("01", lastProbeAt: start.addingTimeInterval(-200)),
      repeater("02", lastProbeAt: start.addingTimeInterval(-600))
    ]
    #expect(policy.nextProbeTarget(among: table, now: start, movement: .stationary)?.hexID == "02")
  }

  @Test
  func `Nothing is probed when nothing is due`() throws {
    let table = try [repeater("01", lastProbeAt: start.addingTimeInterval(-5))]
    #expect(policy.nextProbeTarget(among: table, now: start, movement: .stationary) == nil)
  }

  @Test
  func `Unprobeable, in-flight and burnt-out repeaters are skipped`() throws {
    let table = try [
      repeater("01", txState: .unknown, hasKey: false),
      repeater("02", txState: .measuring, lastProbeAt: start.addingTimeInterval(-1000)),
      repeater("03", failCount: 4, lastProbeAt: start.addingTimeInterval(-10000))
    ]
    #expect(policy.nextProbeTarget(among: table, now: start, movement: .stationary) == nil)
  }

  @Test
  func `Movement makes an otherwise-not-due repeater due`() throws {
    let table = try [repeater("01", lastProbeAt: start.addingTimeInterval(-30))]
    #expect(policy.nextProbeTarget(among: table, now: start, movement: .stationary) == nil)
    #expect(policy.nextProbeTarget(among: table, now: start, movement: .fast)?.hexID == "01")
  }

  @Test
  func `Urgency answers only for a row that is due, whatever the caller's own preference`() throws {
    let due = try repeater("01", lastProbeAt: start.addingTimeInterval(-50))
    let waiting = try repeater("01", lastProbeAt: start.addingTimeInterval(-5))
    let backedOff = try repeater(
      "01",
      txState: .failed,
      failCount: 1,
      lastProbeAt: start.addingTimeInterval(-5)
    )

    #expect(policy.probeUrgency(for: due, isBest: true, now: start, movement: .stationary) == -5)
    #expect(policy.probeUrgency(for: waiting, isBest: true, now: start, movement: .stationary) == nil)
    #expect(
      policy.probeUrgency(for: backedOff, isBest: true, now: start, movement: .stationary) == nil,
      "the failure ladder holds a row back even when its caller wants it next"
    )
  }

  // MARK: - Reactive triggers

  @Test
  func `Hearing an unmeasured repeater schedules a probe, hearing a healthy one does not`() throws {
    #expect(try policy.shouldProbeReactively(repeater("01", txState: .unknown), now: start))
    #expect(try !policy.shouldProbeReactively(repeater("01", txState: .measured(.good)), now: start))
    #expect(try !policy.shouldProbeReactively(repeater("01", txState: .measuring), now: start))
  }

  @Test
  func `A failed link is re-probed only after the cooldown`() throws {
    let recent = try repeater("01", txState: .failed, lastProbeAt: start.addingTimeInterval(-10))
    let old = try repeater("01", txState: .failed, lastProbeAt: start.addingTimeInterval(-31))
    #expect(!policy.shouldProbeReactively(recent, now: start))
    #expect(policy.shouldProbeReactively(old, now: start))
  }

  @Test
  func `A repeater with no public key can never be probed reactively`() throws {
    let entry = try repeater("01", txState: .unknown, hasKey: false)
    #expect(!policy.shouldProbeReactively(entry, now: start))
  }
}
