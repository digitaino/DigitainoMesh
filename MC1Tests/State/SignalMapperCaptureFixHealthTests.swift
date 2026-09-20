import Foundation
@testable import MC1
import MC1Services
import Testing

/// The fix-health verdict the ride strip's chip and the cell card's empty-state reason both
/// hang off.
///
/// It shipped with no coverage and a rule — "this window dropped something and placed
/// nothing" — that a perfectly healthy ride satisfies several times a minute, because the
/// window is however long it was between two probe-engine snapshots and passive RX is
/// bursty. These pin the two properties that matter: a refusal has to persist before it is
/// announced, and anything placed clears it at once.
@Suite("SignalMapperRideSession capture fix health")
@MainActor
struct SignalMapperCaptureFixHealthTests {
  private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func session() -> SignalMapperRideSession {
    SignalMapperRideSession(runID: UUID(), startedAt: Self.start, focusTargets: [], recorder: nil)
  }

  /// The engine's counters are cumulative, so a fixture is the running total, not a delta.
  private func snapshot(
    samples: Int = 0,
    noFix: Int = 0,
    stale: Int = 0,
    inaccurate: Int = 0
  ) -> SignalMapperCaptureEngine.Snapshot {
    SignalMapperCaptureEngine.Snapshot(
      sampleCount: samples,
      droppedNoFixCount: noFix,
      droppedStaleFixCount: stale,
      droppedInaccurateFixCount: inaccurate
    )
  }

  @Test
  func `the first window is only a baseline and decides nothing`() {
    let session = session()
    session.noteCaptureSnapshot(snapshot(samples: 40, stale: 9), at: Self.start)

    #expect(session.captureFixHealth.droppedCount == 0)
    #expect(session.captureFixHealth.isRejectingFixes == false)
  }

  @Test
  func `one refusing window does not raise the alarm`() {
    let session = session()
    session.noteCaptureSnapshot(snapshot(samples: 10), at: Self.start)
    session.noteCaptureSnapshot(snapshot(samples: 10, stale: 1), at: Self.start.addingTimeInterval(2))

    #expect(session.captureFixHealth.droppedCount == 1)
    #expect(session.captureFixHealth.isRejectingFixes == false)
  }

  @Test
  func `a refusal sustained past the threshold is announced`() {
    let session = session()
    session.noteCaptureSnapshot(snapshot(samples: 10), at: Self.start)
    var stale = 0
    for step in 1...6 {
      stale += 1
      session.noteCaptureSnapshot(
        snapshot(samples: 10, stale: stale),
        at: Self.start.addingTimeInterval(Double(step) * 2)
      )
    }

    #expect(session.captureFixHealth.isRejectingFixes)
    #expect(session.captureFixHealth.isQualityRejection)
  }

  @Test
  func `a single placed observation clears a run that had already fired`() {
    let session = session()
    session.noteCaptureSnapshot(snapshot(samples: 10), at: Self.start)
    for step in 1...6 {
      session.noteCaptureSnapshot(
        snapshot(samples: 10, stale: step),
        at: Self.start.addingTimeInterval(Double(step) * 2)
      )
    }
    #expect(session.captureFixHealth.isRejectingFixes)

    session.noteCaptureSnapshot(snapshot(samples: 11, stale: 6), at: Self.start.addingTimeInterval(14))

    #expect(session.captureFixHealth.isRejectingFixes == false)
    #expect(session.captureFixHealth.isQualityRejection == false)
  }

  /// A quiet radio is not evidence about the fix in either direction, so it must neither
  /// extend a run nor end one. Without this the alarm would fire on any ride that went
  /// twelve seconds without hearing anything after one bad fix.
  @Test
  func `windows where nothing arrived neither extend nor clear the run`() {
    let session = session()
    session.noteCaptureSnapshot(snapshot(samples: 10), at: Self.start)
    session.noteCaptureSnapshot(snapshot(samples: 10, stale: 1), at: Self.start.addingTimeInterval(2))
    // Twenty seconds of silence — well past the threshold, with nothing heard in it.
    for step in 2...11 {
      session.noteCaptureSnapshot(
        snapshot(samples: 10, stale: 1),
        at: Self.start.addingTimeInterval(Double(step) * 2)
      )
    }

    #expect(session.captureFixHealth.isRejectingFixes == false)
  }

  /// "No fix at all" and "a fix refused for being too vague" are two problems with two
  /// answers, and the strip prints a different chip for each. The distinction is a property
  /// of the run, not of the last window in it.
  @Test
  func `a run of missing fixes is a rejection but not a quality rejection`() {
    let session = session()
    session.noteCaptureSnapshot(snapshot(samples: 10), at: Self.start)
    for step in 1...6 {
      session.noteCaptureSnapshot(
        snapshot(samples: 10, noFix: step),
        at: Self.start.addingTimeInterval(Double(step) * 2)
      )
    }

    #expect(session.captureFixHealth.isRejectingFixes)
    #expect(session.captureFixHealth.isQualityRejection == false)
  }

  /// One bad fix early in a run still describes the run: the chip must not switch its
  /// wording to "no fix" halfway through because the latest window happened to be that.
  @Test
  func `a quality refusal anywhere in the run keeps the run a quality refusal`() {
    let session = session()
    session.noteCaptureSnapshot(snapshot(samples: 10), at: Self.start)
    session.noteCaptureSnapshot(snapshot(samples: 10, stale: 1), at: Self.start.addingTimeInterval(2))
    for step in 2...6 {
      session.noteCaptureSnapshot(
        snapshot(samples: 10, noFix: step - 1, stale: 1),
        at: Self.start.addingTimeInterval(Double(step) * 2)
      )
    }

    #expect(session.captureFixHealth.isRejectingFixes)
    #expect(session.captureFixHealth.isQualityRejection)
  }

  /// A BLE rewire hands the ride a fresh engine whose counters start at zero. The baseline
  /// re-seeds, and the alarm from the old generation must not survive it as a fact about
  /// the new one.
  @Test
  func `an engine rebuild re-seeds the baseline and drops the run`() {
    let session = session()
    session.noteCaptureSnapshot(snapshot(samples: 10), at: Self.start)
    for step in 1...6 {
      session.noteCaptureSnapshot(
        snapshot(samples: 10, stale: step),
        at: Self.start.addingTimeInterval(Double(step) * 2)
      )
    }
    #expect(session.captureFixHealth.isRejectingFixes)

    session.noteCaptureSnapshot(snapshot(), at: Self.start.addingTimeInterval(14))

    #expect(session.captureFixHealth.isRejectingFixes == false)
    #expect(session.captureFixHealth.droppedCount == 0)
  }
}
