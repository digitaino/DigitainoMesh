@testable import MC1
@testable import MC1Services
import Testing

@Suite("MovementHintMonitor")
struct MovementHintMonitorTests {
  private func level(
    stationary: Bool = false,
    walking: Bool = false,
    cycling: Bool = false,
    running: Bool = false,
    automotive: Bool = false,
    isLowConfidence: Bool = false
  ) -> MovementHint? {
    MovementHintMonitor.level(
      stationary: stationary,
      walking: walking,
      cycling: cycling,
      running: running,
      automotive: automotive,
      isLowConfidence: isLowConfidence
    )
  }

  // MARK: - Mapping

  @Test
  func `a stationary sample maps to stationary`() {
    #expect(level(stationary: true) == .stationary)
  }

  @Test
  func `walking and cycling map to the slow cadence`() {
    #expect(level(walking: true) == .slow)
    #expect(level(cycling: true) == .slow)
  }

  @Test
  func `running and driving map to the fast cadence`() {
    #expect(level(running: true) == .fast)
    #expect(level(automotive: true) == .fast)
  }

  @Test
  func `driving outranks a simultaneous walking flag`() {
    // CoreMotion sets several flags at once when a transition is in progress; the faster
    // classification wins so probe cadence errs on the side of keeping up.
    #expect(level(walking: true, automotive: true) == .fast)
  }

  @Test
  func `stationary outranks every other flag`() {
    #expect(level(stationary: true, walking: true, automotive: true) == .stationary)
  }

  // MARK: - Samples that must be ignored

  @Test
  func `a low-confidence sample is ignored rather than treated as stationary`() {
    #expect(level(automotive: true, isLowConfidence: true) == nil)
    #expect(level(stationary: true, isLowConfidence: true) == nil)
  }

  @Test
  func `an unclassifiable sample is ignored`() {
    // No flag set at all: CoreMotion emits these between activities, and folding them into
    // stationary would flap the level — and the radio write — every few seconds.
    #expect(level() == nil)
  }

  // MARK: - Lifecycle

  @Test
  @MainActor
  func `a fresh monitor is stationary and not running`() {
    let monitor = MovementHintMonitor()
    #expect(monitor.level == .stationary)
    #expect(monitor.isRunning == false)
  }

  @Test
  @MainActor
  func `starting reports the initial stationary reading`() {
    let monitor = MovementHintMonitor()
    var readings: [MovementHint] = []
    monitor.start { readings.append($0) }

    #expect(monitor.isRunning)
    #expect(readings == [.stationary])
  }

  @Test
  @MainActor
  func `stopping ends delivery`() {
    let monitor = MovementHintMonitor()
    var readings: [MovementHint] = []
    monitor.start { readings.append($0) }
    monitor.stop()

    #expect(monitor.isRunning == false)
    #expect(monitor.level == .stationary)
  }
}
