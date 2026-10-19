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

  /// A survey stretches this engine's cadence instead of stopping it. Stopping emptied
  /// the table the toolbar pill mirrors — which shrank the pill's label, and a toolbar
  /// item's tap target is its label's rect — and threw away the warm target set the
  /// survey itself starts from (Rafael, 2026-08-30).
  @Test
  func `A running survey stretches every cadence instead of stopping the engine`() throws {
    let entry = try repeater("01")
    var surveying = policy
    surveying.isSurveyActive = true

    #expect(policy.cadenceScale == 1)
    #expect(surveying.cadenceScale == 4)
    #expect(surveying.probeInterval(for: entry, isBest: true, movement: .stationary) == 180)
    #expect(surveying.probeInterval(for: entry, isBest: false, movement: .stationary) == 480)
    #expect(surveying.effectiveDiscoverProbeInterval == 120)
    // Still a cadence, not a stop: every interval stays finite and the failure ceiling
    // is the only thing that ends probing.
    #expect(surveying.probeInterval(for: entry, isBest: true, movement: .fast) != nil)
  }

  /// The backoff multiplies the movement divisor rather than replacing it — a rider is
  /// moving *and* surveying, and both facts have to survive.
  @Test
  func `Survey backoff and movement compose`() throws {
    let entry = try repeater("01")
    var surveying = policy
    surveying.isSurveyActive = true
    let stationary = surveying.probeInterval(for: entry, isBest: true, movement: .stationary)
    let moving = surveying.probeInterval(for: entry, isBest: true, movement: .slow)
    #expect(stationary == 180)
    #expect(moving == 90)
    // The case the feature actually runs in: riding. `.fast` divides by 4, so the
    // backoff's ×4 lands the interval back on the unscaled stationary figure.
    #expect(surveying.probeInterval(for: entry, isBest: true, movement: .fast) == 45)
    #expect(surveying.probeInterval(for: entry, isBest: false, movement: .fast) == 120)
  }

  /// Both paths that used to sit outside the cadence — a never-measured TX leg jumping the
  /// queue outright, and the reactive probe a fresh sighting schedules — are inside it
  /// under a survey. The survey's own discovers create exactly those rows, so leaving them
  /// exempt had this engine feeding off the traffic the backoff exists to sit beneath.
  @Test
  func `Under a survey an unknown TX leg waits its turn instead of jumping the queue`() throws {
    let unknown = try repeater("01", txState: .unknown)
    var surveying = policy
    surveying.isSurveyActive = true

    #expect(
      policy.probeUrgency(for: unknown, isBest: false, now: start, movement: .stationary)
        == -TimeInterval.infinity
    )
    // Freshly seen, never probed: still due under backoff, but as an ordinary overdue row.
    let urgency = surveying.probeUrgency(for: unknown, isBest: false, now: start, movement: .stationary)
    #expect(urgency != -TimeInterval.infinity)

    // The reactive cooldown scales too, so a just-probed unknown row is not re-probed.
    let justProbed = try repeater("02", txState: .unknown, lastProbeAt: start.addingTimeInterval(-40))
    #expect(policy.shouldProbeReactively(justProbed, now: start))
    #expect(!surveying.shouldProbeReactively(justProbed, now: start))
    #expect(surveying.effectiveReactiveFailedCooldown == 120)
    #expect(surveying.effectiveStaleThreshold == 1200)
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
