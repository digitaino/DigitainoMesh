import Foundation
@testable import MC1
@testable import MC1Services
import os
import Testing

/// The signal mapper's location layer (docs/SIGNAL_MAPPER_V2.md §2.2): when a cached fix is
/// re-used, when a new one is spent, and — the part that matters most — when the one being
/// served has to be marked as no longer describing where the phone is.
///
/// Every dependency is injected (`requestFix`, `movementHints`, `now`,
/// `minimumRefreshInterval`), so nothing here waits on CoreLocation, CoreMotion or the wall
/// clock.
@Suite("MapperFixCache")
struct MapperFixCacheTests {
  // MARK: - Fixtures

  /// A one-shot fix source the test drives: it counts calls and hands back whatever the
  /// test last staged, so "did we spend a GPS fix" is directly observable.
  private final class FixRequestSpy: Sendable {
    private struct State {
      var next: MapperFix?
      var callCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(next: MapperFix? = nil) {
      state.withLock { $0.next = next }
    }

    var callCount: Int {
      state.withLock { $0.callCount }
    }

    func stage(_ fix: MapperFix?) {
      state.withLock { $0.next = fix }
    }

    var request: @Sendable () async -> MapperFix? {
      { [state] in
        state.withLock { current in
          current.callCount += 1
          return current.next
        }
      }
    }
  }

  private final class MutableHints: MovementHintProvider {
    private let hint: OSAllocatedUnfairLock<MovementHint>

    init(_ initial: MovementHint = .stationary) {
      hint = OSAllocatedUnfairLock(initialState: initial)
    }

    func currentMovementHint() async -> MovementHint {
      hint.withLock { $0 }
    }

    func set(_ next: MovementHint) {
      hint.withLock { $0 = next }
    }
  }

  private func fix(
    latitude: Double = 37.7749,
    longitude: Double = -122.4194,
    accuracy: Double = 10,
    speed: Double? = nil,
    at timestamp: Date
  ) -> MapperFix {
    MapperFix(
      latitude: latitude,
      longitude: longitude,
      horizontalAccuracyMeters: accuracy,
      speedMetersPerSecond: speed,
      timestamp: timestamp
    )
  }

  private func makeCache(
    requests: FixRequestSpy,
    hints: any MovementHintProvider,
    clock: TestClockBox,
    tuning: MapperTuning = MapperTuning(fixMaxAgeSeconds: 120),
    minimumRefreshInterval: TimeInterval = 5
  ) -> MapperFixCache {
    MapperFixCache(
      requestFix: requests.request,
      movementHints: hints,
      tuning: StaticMapperTuningProvider(tuning),
      now: clock.provider,
      minimumRefreshInterval: minimumRefreshInterval
    )
  }

  /// A hand-moved clock. The cache's refresh is a detached task, so tests poll for its
  /// effect rather than sleeping a fixed amount and hoping.
  final class TestClockBox: Sendable {
    private let state: OSAllocatedUnfairLock<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_753_000_000)) {
      state = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date {
      state.withLock { $0 }
    }

    var provider: @Sendable () -> Date {
      { [state] in state.withLock { $0 } }
    }

    func advance(_ interval: TimeInterval) {
      state.withLock { $0 = $0.addingTimeInterval(interval) }
    }
  }

  @discardableResult
  private func waitFor(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
  }

  // MARK: - Cold start

  @Test
  func `The first call returns nothing and spends a fix to fill the cache`() async {
    let clock = TestClockBox()
    let requests = FixRequestSpy(next: fix(at: clock.now))
    let cache = makeCache(requests: requests, hints: MutableHints(.stationary), clock: clock)

    // Never blocks, so the very first call has nothing to hand over.
    #expect(await cache.latestFix() == nil)

    #expect(await waitFor { await cache.latestFix() != nil })
    #expect(requests.callCount >= 1)
  }

  // MARK: - Staleness

  @Test
  func `A fix past the age budget is replaced even while stationary`() async {
    let clock = TestClockBox()
    let original = fix(at: clock.now)
    let requests = FixRequestSpy(next: original)
    let cache = makeCache(requests: requests, hints: MutableHints(.stationary), clock: clock)

    #expect(await waitFor { await cache.latestFix() != nil })
    let spentOnFill = requests.callCount

    // Well inside the budget and standing still: no reason to spend anything.
    clock.advance(30)
    _ = await cache.latestFix()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(requests.callCount == spentOnFill, "a fresh fix on a stationary phone must not cost a GPS fix")

    // Past `fixMaxAge`: replaced whatever the phone is doing.
    clock.advance(120)
    let replacement = fix(at: clock.now)
    requests.stage(replacement)
    _ = await cache.latestFix()

    #expect(await waitFor { await cache.latestFix()?.timestamp == replacement.timestamp })
    #expect(requests.callCount > spentOnFill)
  }

  // MARK: - Movement

  @Test
  func `Movement spends a fresh fix even though the held one is still young`() async {
    let clock = TestClockBox()
    let original = fix(at: clock.now)
    let requests = FixRequestSpy(next: original)
    let hints = MutableHints(.stationary)
    let cache = makeCache(requests: requests, hints: hints, clock: clock)

    #expect(await waitFor { await cache.latestFix() != nil })
    let spentOnFill = requests.callCount

    clock.advance(10)
    hints.set(.fast)
    let replacement = fix(latitude: 37.8044, longitude: -122.2712, at: clock.now)
    requests.stage(replacement)
    _ = await cache.latestFix()

    #expect(await waitFor { await cache.latestFix()?.timestamp == replacement.timestamp })
    #expect(requests.callCount > spentOnFill)
  }

  @Test
  func `Movement marks the fix still being served as moved-since-capture`() async {
    // The gap the audit found: the refresh is asynchronous, so between "we moved" and "the
    // new fix landed" the *old* fix is what callers get — and nothing about its age or
    // accuracy reveals that the phone walked away from it.
    let clock = TestClockBox()
    let requests = FixRequestSpy(next: fix(at: clock.now))
    let hints = MutableHints(.stationary)
    let cache = makeCache(requests: requests, hints: hints, clock: clock)

    #expect(await waitFor { await cache.latestFix() != nil })
    #expect(await cache.latestFix()?.movedSinceCapture == false)

    // Moving, and the replacement never arrives — the worst case, and the one the mark is
    // there for.
    clock.advance(10)
    hints.set(.fast)
    requests.stage(nil)
    _ = await cache.latestFix()

    #expect(await waitFor { await cache.latestFix()?.movedSinceCapture == true })
    // Still fresh and still accurate: the mark is the only thing that says it is wrong.
    let served = await cache.latestFix()
    #expect(served?.horizontalAccuracyMeters == 10)
    #expect(clock.now.timeIntervalSince(served?.timestamp ?? .distantPast) < 120)
  }

  @Test
  func `A fix that actually lands comes back unmarked`() async {
    let clock = TestClockBox()
    let requests = FixRequestSpy(next: fix(at: clock.now))
    let hints = MutableHints(.stationary)
    let cache = makeCache(requests: requests, hints: hints, clock: clock)

    #expect(await waitFor { await cache.latestFix() != nil })

    clock.advance(10)
    hints.set(.fast)
    let replacement = fix(latitude: 37.8044, longitude: -122.2712, at: clock.now)
    requests.stage(replacement)
    _ = await cache.latestFix()

    // The mark clears by construction: the whole value is replaced, not patched.
    #expect(await waitFor {
      let served = await cache.latestFix()
      return served?.timestamp == replacement.timestamp && served?.movedSinceCapture == false
    })
  }

  @Test
  func `A stationary phone's fix is never marked`() async {
    let clock = TestClockBox()
    let requests = FixRequestSpy(next: fix(at: clock.now))
    let cache = makeCache(requests: requests, hints: MutableHints(.stationary), clock: clock)

    #expect(await waitFor { await cache.latestFix() != nil })
    for _ in 0..<5 {
      clock.advance(10)
      _ = await cache.latestFix()
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(await cache.latestFix()?.movedSinceCapture == false)
  }

  // MARK: - Declined motion permission

  @Test
  func `With the hint stuck stationary the served fix carries its speed for the engine to judge`() async throws {
    // Motion & Fitness declined: the relay reports `.stationary` forever, so nothing here
    // can ever mark the fix. What the layer *can* still do is hand over the speed
    // CoreLocation reported with the fix, which is what bounds the age downstream.
    let clock = TestClockBox()
    let moving = fix(speed: 15, at: clock.now)
    let requests = FixRequestSpy(next: moving)
    let cache = makeCache(requests: requests, hints: MutableHints(.stationary), clock: clock)

    #expect(await waitFor { await cache.latestFix() != nil })
    let served = await cache.latestFix()

    #expect(served?.movedSinceCapture == false, "no classifier, so nothing can mark it")
    #expect(served?.speedMetersPerSecond == 15)

    // And that is enough: the engine's budget rejects it long before `fixMaxAge`.
    let tuning = MapperTuning(fixMaxAgeSeconds: 120, fixMaxDisplacementMeters: 150)
    let budget = try SignalMapperCaptureEngine.toleratedAgeSeconds(
      for: #require(served), tuning: tuning
    )
    #expect(budget == 10)
  }

  // MARK: - Refresh storms

  @Test
  func `A burst of calls inside the refresh floor spends at most one fix`() async {
    // A busy channel calls this once per packet, and a denied location permission makes
    // every attempt fail — together that is a request per packet unless the floor holds.
    let clock = TestClockBox()
    let requests = FixRequestSpy(next: nil)
    let cache = makeCache(
      requests: requests,
      hints: MutableHints(.fast),
      clock: clock,
      minimumRefreshInterval: 5
    )

    for _ in 0..<50 {
      _ = await cache.latestFix()
    }
    try? await Task.sleep(for: .milliseconds(100))

    #expect(requests.callCount <= 1, "spent \(requests.callCount) fixes inside one refresh window")
  }

  @Test
  func `Past the refresh floor a new attempt is allowed`() async {
    let clock = TestClockBox()
    let requests = FixRequestSpy(next: nil)
    let cache = makeCache(
      requests: requests,
      hints: MutableHints(.fast),
      clock: clock,
      minimumRefreshInterval: 5
    )

    _ = await cache.latestFix()
    #expect(await waitFor { requests.callCount == 1 })

    clock.advance(6)
    _ = await cache.latestFix()
    #expect(await waitFor { requests.callCount == 2 })
  }

  // MARK: - Reset

  @Test
  func `Reset drops the cache so a new session cannot inherit the old one's fix`() async {
    let clock = TestClockBox()
    let requests = FixRequestSpy(next: fix(at: clock.now))
    let cache = makeCache(requests: requests, hints: MutableHints(.stationary), clock: clock)

    #expect(await waitFor { await cache.latestFix() != nil })
    await cache.reset()

    #expect(await cache.latestFix() == nil)
  }
}
