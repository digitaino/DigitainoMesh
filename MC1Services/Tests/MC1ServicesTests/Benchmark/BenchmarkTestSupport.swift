import Foundation
@testable import MC1Services
import MeshCore
import os

// MARK: - Targets

/// A benchmark target whose public key begins with `prefix`.
func benchmarkTarget(_ name: String, prefix: [UInt8]) -> BenchmarkTarget {
  var key = Data(prefix)
  key.append(contentsOf: [UInt8](repeating: 0xEE, count: 32 - prefix.count))
  return BenchmarkTarget(publicKey: key, name: name)
}

// MARK: - Tags

/// Probe tags handed out in a predictable order so a test can answer the right probe.
final class TagSequence: Sendable {
  private let next = OSAllocatedUnfairLock(initialState: UInt32(1))

  var provider: @Sendable () -> UInt32 {
    { [next] in
      next.withLock { value in
        defer { value += 1 }
        return value
      }
    }
  }
}

// MARK: - Sleeper

/// A stand-in for the engine's waits.
///
/// Short waits (the inter-probe gap) pass straight through so a run does not take real time;
/// long waits (a probe's reply deadline) park until the test releases them, which is what
/// makes "reply arrives" and "reply never arrives" two deterministic paths rather than a
/// race. Cancellation releases a parked wait, so the engine cancelling a deadline after a
/// reply lands leaves no continuation behind.
actor GatedSleeper {
  private var gates: [UUID: CheckedContinuation<Void, Never>] = [:]
  private(set) var recorded: [Duration] = []
  private let threshold: Duration

  init(threshold: Duration = .seconds(1)) {
    self.threshold = threshold
  }

  nonisolated var provider: @Sendable (Duration) async -> Void {
    { [weak self] duration in await self?.perform(duration) }
  }

  /// Releases every parked wait, making the deadlines they represent fire.
  func releaseAll() {
    let parked = gates
    gates.removeAll()
    for (_, continuation) in parked {
      continuation.resume()
    }
  }

  private func perform(_ duration: Duration) async {
    recorded.append(duration)
    guard duration >= threshold else { return }
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        if Task.isCancelled {
          continuation.resume()
        } else {
          gates[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.release(id) }
    }
  }

  private func release(_ id: UUID) {
    gates.removeValue(forKey: id)?.resume()
  }
}

// MARK: - Session

/// A scriptable stand-in for the radio: records every probe and lets the test push replies
/// into the engine's subscription.
actor MockBenchmarkSession: BenchmarkSessionOps, SessionEventStreaming {
  private(set) var traces: [(tag: UInt32?, flags: UInt8, path: Data?)] = []

  var traceError: (any Error)?
  var sentInfo = MessageSentInfo(route: 0, expectedAck: Data(), suggestedTimeoutMs: 5000)
  /// Runs while the send is still in flight, which is how a test lands a reply before the
  /// probe has installed its waiter.
  private var onSend: (@Sendable (UInt32?) async -> Void)?

  var traceCount: Int {
    traces.count
  }

  func setTraceError(_ error: (any Error)?) {
    traceError = error
  }

  func setSentInfo(_ info: MessageSentInfo) {
    sentInfo = info
  }

  func setOnSend(_ hook: (@Sendable (UInt32?) async -> Void)?) {
    onSend = hook
  }

  func sendTrace(
    tag: UInt32?,
    authCode _: UInt32?,
    flags: UInt8,
    path: Data?
  ) async throws -> MessageSentInfo {
    traces.append((tag, flags, path))
    if let traceError { throw traceError }
    await onSend?(tag)
    return sentInfo
  }

  // MARK: SessionEventStreaming

  private var continuations: [UUID: AsyncStream<MeshEvent>.Continuation] = [:]

  nonisolated var connectionState: AsyncStream<ConnectionState> {
    AsyncStream { $0.finish() }
  }

  func events() async -> AsyncStream<MeshEvent> {
    makeStream()
  }

  func events(filter _: EventFilter) async -> AsyncStream<MeshEvent> {
    makeStream()
  }

  func waitForEvent(filter _: EventFilter, timeout _: TimeInterval?) async -> MeshEvent? {
    nil
  }

  private func makeStream() -> AsyncStream<MeshEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<MeshEvent>.makeStream()
    continuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeStream(id) }
    }
    return stream
  }

  private func removeStream(_ id: UUID) {
    continuations[id] = nil
  }

  func emit(_ event: MeshEvent) {
    for (_, continuation) in continuations {
      continuation.yield(event)
    }
  }
}

// MARK: - Fixtures

enum BenchmarkFixtures {
  /// A trace reply for the standard `test → target → test` path, carrying the SNR each hop
  /// measured: index 0 is the test repeater hearing us, 1 the target hearing the test
  /// repeater (TX), 2 the test repeater hearing the target on the way back (RX).
  static func reply(
    tag: UInt32,
    hops: [(hash: UInt8, snr: Double)]
  ) -> TraceInfo {
    TraceInfo(
      tag: tag,
      authCode: 0,
      flags: 0,
      pathLength: UInt8(hops.count),
      path: hops.map { TraceNode(hashBytes: Data([$0.hash]), snr: $0.snr) }
    )
  }

  /// One probe outcome, for scoring tables that need no engine at all.
  static func outcome(
    sequence: Int = 1,
    durationMs: Int,
    intermediateSNRs: [Double],
    failure: BenchmarkTraceOutcome.Failure? = nil
  ) -> BenchmarkTraceOutcome {
    var hops: [BenchmarkHop] = [BenchmarkHop(position: .start, hash: nil, name: nil, snr: 0)]
    hops += intermediateSNRs.map {
      BenchmarkHop(position: .intermediate, hash: Data([0x01]), name: nil, snr: $0)
    }
    hops.append(BenchmarkHop(position: .end, hash: nil, name: nil, snr: 0))
    return BenchmarkTraceOutcome(
      sequence: sequence,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      durationMs: failure == nil ? durationMs : 0,
      hops: failure == nil ? hops : [],
      failure: failure
    )
  }

  /// A saved benchmark path with one run per `(rtt, snrs)` pair. A `nil` `runStamp` writes the
  /// pre-stamp name format, which is what history holds for runs saved before stamps existed.
  static func savedPath(
    note: String,
    runStamp: String? = nil,
    testRepeater: String = "Tower",
    target: String,
    createdDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
    runs: [(rtt: Int, snrs: [Double], success: Bool)]
  ) -> SavedTracePathDTO {
    SavedTracePathDTO(
      id: UUID(),
      radioID: UUID(),
      name: BenchmarkNaming.pathName(
        note: note,
        runStamp: runStamp,
        testRepeater: testRepeater,
        target: target
      ),
      pathBytes: Data([0x01, 0x02, 0x01]),
      hashSize: 1,
      createdDate: createdDate,
      runs: runs.enumerated().map { index, run in
        TracePathRunDTO(
          id: UUID(),
          date: createdDate.addingTimeInterval(Double(index)),
          success: run.success,
          roundTripMs: run.rtt,
          hopsSNR: run.snrs
        )
      }
    )
  }
}

struct BenchmarkTestError: Error {}

// MARK: - Failing store

/// A trace-path store that accepts paths and refuses every run append, for the case where a
/// save must not leave a runless path behind.
actor FailingAppendTracePathStore: TracePathPersisting {
  private(set) var paths: [UUID: SavedTracePathDTO] = [:]

  func fetchSavedTracePaths(radioID: UUID) async throws -> [SavedTracePathDTO] {
    paths.values.filter { $0.radioID == radioID }
  }

  func fetchSavedTracePath(id: UUID) async throws -> SavedTracePathDTO? {
    paths[id]
  }

  func createSavedTracePath(
    radioID: UUID,
    name: String,
    pathBytes: Data,
    hashSize: Int,
    initialRun: TracePathRunDTO?
  ) async throws -> SavedTracePathDTO {
    let path = SavedTracePathDTO(
      id: UUID(),
      radioID: radioID,
      name: name,
      pathBytes: pathBytes,
      hashSize: hashSize,
      createdDate: Date(timeIntervalSince1970: 1_700_000_000),
      runs: initialRun.map { [$0] } ?? []
    )
    paths[path.id] = path
    return path
  }

  func updateSavedTracePathName(id _: UUID, name _: String) async throws {}

  func deleteSavedTracePath(id: UUID) async throws {
    paths.removeValue(forKey: id)
  }

  func appendTracePathRun(pathID _: UUID, run _: TracePathRunDTO) async throws {
    throw BenchmarkTestError()
  }
}

/// Waits for an actor-isolated condition, for the tests that let the engine run its own loop.
func waitForBenchmarkCondition(
  timeout: Duration = .seconds(2),
  _ message: String = "condition not met",
  _ condition: @Sendable () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  struct ConditionTimeout: Error, CustomStringConvertible {
    let description: String
  }
  guard await condition() else { throw ConditionTimeout(description: message) }
}
