import Foundation
@testable import MC1Services
import Testing

/// Spec source: legacy `SignalBarsService.pendingPings` and the timeout branch of
/// `pingRepeater(hexID:publicKey:)`.
@Suite("SignalBarsProbeTracker")
struct SignalBarsProbeTrackerTests {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)

  @Test
  func `A reply is correlated back to the repeater its tag was sent to`() throws {
    var tracker = SignalBarsProbeTracker()
    let target = nodeID("0C13")
    tracker.register(tag: 42, target: target, now: start, timeoutMs: 5000)

    let probe = tracker.claim(tag: 42)
    let claimed = try #require(probe)
    #expect(claimed.target == target)
    #expect(claimed.sentAt == start)
    #expect(tracker.isEmpty, "a claimed probe is no longer in flight")
  }

  @Test
  func `An unknown or already claimed tag is ignored`() {
    var tracker = SignalBarsProbeTracker()
    tracker.register(tag: 42, target: nodeID("0C"), now: start, timeoutMs: 5000)
    _ = tracker.claim(tag: 42)

    let reclaimed = tracker.claim(tag: 42)
    let unknown = tracker.claim(tag: 99)
    #expect(reclaimed == nil)
    #expect(unknown == nil)
  }

  @Test
  func `A probe expires only once its deadline has passed`() {
    var tracker = SignalBarsProbeTracker()
    tracker.register(tag: 7, target: nodeID("0C"), now: start, timeoutMs: 5000)

    #expect(tracker.expired(now: start.addingTimeInterval(4.9)).isEmpty)
    #expect(tracker.count == 1)

    let lost = tracker.expired(now: start.addingTimeInterval(5))
    #expect(lost.map(\.tag) == [7])
    #expect(tracker.isEmpty, "an expired probe is removed, so a late reply cannot revive it")
  }

  @Test
  func `Expired probes come back oldest first`() {
    var tracker = SignalBarsProbeTracker()
    tracker.register(tag: 1, target: nodeID("01"), now: start, timeoutMs: 1000)
    tracker.register(
      tag: 2,
      target: nodeID("02"),
      now: start.addingTimeInterval(0.5),
      timeoutMs: 1000
    )

    #expect(tracker.expired(now: start.addingTimeInterval(10)).map(\.tag) == [1, 2])
  }

  @Test
  func `The device's suggested timeout sets the deadline`() {
    var tracker = SignalBarsProbeTracker()
    tracker.register(tag: 1, target: nodeID("01"), now: start, timeoutMs: 12000)

    #expect(tracker.expired(now: start.addingTimeInterval(11)).isEmpty)
    #expect(tracker.expired(now: start.addingTimeInterval(12)).count == 1)
  }

  @Test
  func `Retiming an outstanding probe takes the new timeout and keeps the send time`() {
    var tracker = SignalBarsProbeTracker()
    tracker.register(tag: 1, target: nodeID("01"), now: start, timeoutMs: 5000)

    tracker.retime(tag: 1, timeoutMs: 12000)

    #expect(tracker.expired(now: start.addingTimeInterval(11)).isEmpty)
    #expect(tracker.expired(now: start.addingTimeInterval(12)).map(\.sentAt) == [start])
  }

  @Test
  func `Retiming a probe that is no longer outstanding does not resurrect it`() {
    var tracker = SignalBarsProbeTracker()
    tracker.register(tag: 1, target: nodeID("01"), now: start, timeoutMs: 5000)
    _ = tracker.claim(tag: 1)

    tracker.retime(tag: 1, timeoutMs: 12000)

    #expect(
      tracker.isEmpty,
      "the reply already claimed it; re-registering would hand the next sweep an answered probe"
    )
  }

  @Test
  func `In-flight checks and cancellation match nodes across hash widths`() {
    var tracker = SignalBarsProbeTracker()
    tracker.register(tag: 1, target: nodeID("0C13"), now: start, timeoutMs: 5000)

    #expect(tracker.hasProbe(for: nodeID("0C")))
    #expect(tracker.hasProbe(for: nodeID("0C13AB")))
    #expect(!tracker.hasProbe(for: nodeID("0D")))

    tracker.cancelProbes(for: [nodeID("0C")])
    #expect(tracker.isEmpty, "pruning a repeater cancels the probes still out for it")
  }

  @Test
  func `Re-using a tag replaces the older probe`() {
    var tracker = SignalBarsProbeTracker()
    tracker.register(tag: 5, target: nodeID("01"), now: start, timeoutMs: 5000)
    tracker.register(
      tag: 5,
      target: nodeID("02"),
      now: start.addingTimeInterval(1),
      timeoutMs: 5000
    )

    #expect(tracker.count == 1)
    let claimed = tracker.claim(tag: 5)
    #expect(claimed?.target.hex == "02")
  }
}
