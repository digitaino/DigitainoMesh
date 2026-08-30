import Foundation
import MC1Services
import os

/// The session-scoped sink the capture and probe engines emit raw events into.
///
/// This is the MapperRawLog half of the boundary `MapperRawSampleRecording` declares in
/// MC1Services (docs/ACTIVE_SURVEY_M3_5.md §2.4): the engines know only the protocol, the
/// implementation lives on this side of the dependency edge, and the app wires the two
/// together. An engine with a nil recorder — the ambient, capture-off default — writes no
/// raw rows at all.
///
/// **Batching without timers.** A ride emits a few rows per second and a breadcrumb every
/// two; writing each one is a SwiftData transaction per row for hours. The recorder holds
/// events until there are ``batchSize`` of them or ``flushIntervalSeconds`` have passed
/// since the *first* buffered event, and checks that clock **lazily, on each `record`**.
/// No `Task.sleep` loop, no timer to cancel, nothing to leak when a BLE rewire abandons a
/// half-built session mid-ride — and nothing that keeps waking a phone that has stopped
/// hearing packets. The cost is that a trailing partial batch sits in memory until the
/// next event or an explicit ``flushNow()``/``finish()``, which is exactly what those are
/// for: the run lifecycle calls `finish()` on the way down.
///
/// **Errors never propagate.** `record` is on the RX path. A failed write is logged and
/// the batch is dropped, because raw logging must never be able to crash or stall a ride
/// — losing a hundred rows is a bad afternoon, losing the ride is a wasted one. What is
/// dropped is visible in ``snapshot()`` rather than silent.
public actor MapperRawSampleRecorder: MapperRawSampleRecording {
  /// What the HUD's session-detail sheet reads (§2.7): the drop counters have to be
  /// *visible*, because a cap hit or a failing store otherwise looks exactly like a quiet
  /// mesh.
  public struct Snapshot: Sendable, Equatable {
    public let runID: UUID
    /// Events accepted so far this run — the number the cap is measured against.
    public let recordedCount: Int
    /// Events held in memory, not yet written.
    public let bufferedCount: Int
    /// The sequence number the next accepted event will get. After ``finish()`` this is
    /// the run's final `seq`, which a resumed session continues from.
    public let nextSeq: Int64
    /// Events refused because the run hit its cap.
    public let droppedCount: Int
    /// Whether the cap has been reached. Sticky for the run.
    public let didHitCap: Bool
    /// How many batches failed to write. Non-zero means rows are missing from the log.
    public let flushFailureCount: Int
  }

  /// Rows per batch. Sized so an active ride flushes roughly every 20–60 s while a busy
  /// probe cycle still lands promptly.
  public static let batchSize = 100

  /// How long a partial batch may wait. Short enough that a jetsam loses seconds of ride,
  /// not minutes.
  public static let flushIntervalSeconds: TimeInterval = 5

  private let store: MapperRawLogStore
  private let runID: UUID
  private let cap: Int
  private let now: @Sendable () -> Date

  /// Logs carry counts and error *types* only — never a coordinate, a public key or a
  /// name (docs/SIGNAL_MAPPER_V2.md §3 rule 3, restated in ACTIVE_SURVEY_M3_5.md §3.5).
  /// `error.localizedDescription` is deliberately not logged: a SwiftData failure can
  /// quote the offending row's values, and this module's rows are exactly the ones that
  /// must not reach OSLog.
  private let logger = Logger(subsystem: "MapperRawLog", category: "Recorder")

  private var buffer: [MapperRawSampleEvent] = []
  private var firstBufferedAt: Date?
  private var nextSeq: Int64
  private var recordedCount = 0
  private var droppedCount = 0
  private var flushFailureCount = 0
  private var didHitCap = false

  /// - Parameters:
  ///   - store: Where batches land.
  ///   - runID: The run every row is stamped with. Fixed for the recorder's life — a new
  ///     run means a new recorder.
  ///   - startingSeq: Where this recorder's numbering continues from. Non-zero when a
  ///     session resumes after a BLE rewire: the run's `seq` space is continuous even
  ///     though the recorder that was filling it is gone.
  ///   - cap: `rawSampleCapPerSession` (default 50 000). A runaway backstop, not a
  ///     target — a real 2 h ride writes 3–8 k rows.
  ///   - now: The clock, injected so the lazy flush deadline is testable and nothing here
  ///     reads system time directly.
  public init(
    store: MapperRawLogStore,
    runID: UUID,
    startingSeq: Int64 = 0,
    cap: Int = 50000,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = store
    self.runID = runID
    nextSeq = startingSeq
    self.cap = cap
    self.now = now
  }

  // MARK: - Recording

  public func record(_ event: MapperRawSampleEvent) async {
    guard recordedCount < cap else {
      if !didHitCap {
        didHitCap = true
        logger.notice("raw sample cap reached; further rows dropped for this run")
      }
      droppedCount += 1
      return
    }

    recordedCount += 1
    buffer.append(event)
    let at = now()
    let openedAt = firstBufferedAt ?? at
    firstBufferedAt = openedAt

    if buffer.count >= Self.batchSize || at.timeIntervalSince(openedAt) >= Self.flushIntervalSeconds {
      await flush()
    }
  }

  /// Writes whatever is buffered. The escape hatch for the cases the lazy deadline cannot
  /// serve: a ride that has gone quiet, and the debug panel's flush affordance.
  public func flushNow() async {
    await flush()
  }

  /// Flushes and reports the run's final sequence number, which the session stores so a
  /// later recorder for the same run continues the numbering rather than colliding with
  /// rows already written.
  @discardableResult
  public func finish() async -> Int64 {
    await flush()
    return nextSeq
  }

  public func snapshot() -> Snapshot {
    Snapshot(
      runID: runID,
      recordedCount: recordedCount,
      bufferedCount: buffer.count,
      nextSeq: nextSeq,
      droppedCount: droppedCount,
      didHitCap: didHitCap,
      flushFailureCount: flushFailureCount
    )
  }

  // MARK: - Internals

  private func flush() async {
    guard !buffer.isEmpty else { return }

    let batch = buffer
    buffer.removeAll(keepingCapacity: true)
    firstBufferedAt = nil

    // The sequence range is claimed *before* the suspension point. `record` is
    // re-entrant — a second event can arrive and start its own flush while this one is
    // awaiting the store — and two batches handed the same `startingSeq` would produce
    // duplicate `seq` values, which is the one thing the run-local correlation key
    // (§6 F1) is not allowed to do.
    let base = nextSeq
    nextSeq += Int64(batch.count)

    do {
      try await store.insertSamples(batch, runID: runID, startingSeq: base)
    } catch {
      flushFailureCount += 1
      // The claimed range is not rewound. A gap in `seq` is an honest record of a lost
      // batch; reusing the numbers would make the log look continuous when it is not.
      logger.error(
        "dropped a raw batch of \(batch.count, privacy: .public) rows: \(String(describing: type(of: error)), privacy: .public)"
      )
    }
  }
}
