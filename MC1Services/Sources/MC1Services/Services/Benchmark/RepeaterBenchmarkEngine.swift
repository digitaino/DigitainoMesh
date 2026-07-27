import Foundation
import MeshCore

/// Measures how well a chosen *test repeater* reaches a set of neighbouring repeaters.
///
/// A run is a sequence of trace probes along the path `test → target → test`. Because the
/// path is explicit and symmetric, one reply carries both legs of the link the user cares
/// about: the SNR the target measured for the test repeater's transmission, and the SNR the
/// test repeater measured for the target's. Repeat that a few times per target and the
/// spread of round trips says as much as the average does — which is why the whole batch is
/// kept, not just its mean.
///
/// Everything time-shaped is injected. The clock, the waits and the probe tags are all
/// closures, and the reply path is an ``ingest(_:)`` a test can call directly, so a full
/// run — sequencing, timeouts, cancellation — is driven without a radio and without waiting.
///
/// State comes out as ``RepeaterBenchmarkSnapshot`` values on ``snapshots()``; a SwiftUI
/// façade is a subscription and an assignment, matching `SignalBarsEngine`.
public actor RepeaterBenchmarkEngine {
  // MARK: - Configuration

  /// The parts of a run that come from the connected radio rather than the user.
  public struct Configuration: Sendable {
    /// Bytes per hop in a trace path: `1 << pathHashMode`, so 1, 2 or 4. This is the trace
    /// protocol's power-of-two width, *not* the linear 1/2/3-byte routing hash width.
    public var traceHashSize: Int
    /// The `path_sz` code written into the trace's flags byte.
    public var traceFlags: UInt8
    /// Name shown for this radio at both ends of a hop chain.
    public var localNodeName: String
    public var policy: RepeaterBenchmarkPolicy

    public init(
      traceHashSize: Int = 1,
      traceFlags: UInt8 = 0,
      localNodeName: String = "",
      policy: RepeaterBenchmarkPolicy = RepeaterBenchmarkPolicy()
    ) {
      self.traceHashSize = traceHashSize
      self.traceFlags = traceFlags
      self.localNodeName = localNodeName
      self.policy = policy
    }
  }

  // MARK: - Dependencies

  private let session: any BenchmarkSessionOps & SessionEventStreaming
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async -> Void
  private let makeTag: @Sendable () -> UInt32
  private let logger = PersistentLogger(subsystem: "com.mc1", category: "RepeaterBenchmark")

  // MARK: - State

  private var configuration: Configuration
  private var plan = BenchmarkPlan()
  private var results: [BenchmarkTargetResult] = []
  private var isRunning = false
  private var isCancelled = false
  private var currentTargetIndex = 0
  private var currentTraceIndex = 0
  private var completedAt: Date?

  /// Probes waiting on a reply, keyed by tag.
  private var waiters: [UInt32: CheckedContinuation<TraceInfo?, Never>] = [:]
  /// Replies that arrived before the sender got round to waiting for them.
  private var earlyReplies: [UInt32: TraceInfo] = [:]
  /// Tags whose deadline fired before the sender registered its waiter.
  private var expiredTags: Set<UInt32> = []

  private var eventTask: Task<Void, Never>?
  private var lastPublished: RepeaterBenchmarkSnapshot?
  private nonisolated let broadcaster = EventBroadcaster<RepeaterBenchmarkSnapshot>()

  // MARK: - Lifecycle

  /// - Parameters:
  ///   - session: Trace sending plus the event stream the replies arrive on.
  ///   - configuration: Radio-derived hop width, flags and cadences.
  ///   - now: The clock. Injected so nothing here calls `Date()`.
  ///   - sleep: How the engine waits between probes and for a reply.
  ///   - makeTag: Probe correlation tags, injected so a test can predict them.
  public init(
    session: any BenchmarkSessionOps & SessionEventStreaming,
    configuration: Configuration = Configuration(),
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    makeTag: @escaping @Sendable () -> UInt32 = { UInt32.random(in: 0..<UInt32.max) }
  ) {
    self.session = session
    self.configuration = configuration
    self.now = now
    self.sleep = sleep
    self.makeTag = makeTag
  }

  deinit {
    eventTask?.cancel()
  }

  /// Ends every ``snapshots()`` subscriber's loop and stops any run. Called on teardown.
  public func shutdown() {
    cancel()
    eventTask?.cancel()
    eventTask = nil
    broadcaster.finish()
  }

  // MARK: - Output

  /// A fresh stream of state snapshots. Registration is synchronous, so a snapshot published
  /// immediately afterwards is never missed.
  public nonisolated func snapshots() -> AsyncStream<RepeaterBenchmarkSnapshot> {
    broadcaster.subscribe(bufferingPolicy: .bufferingNewest(8))
  }

  /// The current state, for a façade's initial value.
  public func currentSnapshot() -> RepeaterBenchmarkSnapshot {
    makeSnapshot()
  }

  // MARK: - Configuration

  /// Applies the connected radio's trace geometry. Ignored mid-run so a settings change
  /// cannot alter the geometry of a batch half way through it.
  public func configure(
    traceHashSize: Int? = nil,
    traceFlags: UInt8? = nil,
    localNodeName: String? = nil
  ) {
    guard !isRunning else { return }
    if let traceHashSize { configuration.traceHashSize = max(1, traceHashSize) }
    if let traceFlags { configuration.traceFlags = traceFlags }
    if let localNodeName { configuration.localNodeName = localNodeName }
  }

  // MARK: - Plan

  public func currentPlan() -> BenchmarkPlan {
    plan
  }

  /// Chooses the repeater whose links are being measured.
  ///
  /// Changing it clears any target that *is* the new test repeater, and drops results from
  /// the previous run — they were measured through a different node and comparing them to
  /// the next batch would be meaningless.
  public func setTestRepeater(_ target: BenchmarkTarget?) {
    guard !isRunning, plan.testRepeater != target else { return }
    plan.testRepeater = target
    if let target {
      plan.targets.removeAll { $0.publicKey == target.publicKey }
    }
    results = []
    completedAt = nil
    publish()
  }

  public func setTargets(_ targets: [BenchmarkTarget]) {
    guard !isRunning else { return }
    plan.targets = plan.selectable(from: targets)
    publish()
  }

  public func toggleTarget(_ target: BenchmarkTarget) {
    guard !isRunning else { return }
    if let index = plan.targets.firstIndex(where: { $0.publicKey == target.publicKey }) {
      plan.targets.remove(at: index)
    } else if plan.testRepeater?.publicKey != target.publicKey {
      plan.targets.append(target)
    }
    publish()
  }

  public func setTracesPerTarget(_ count: Int) {
    guard !isRunning else { return }
    plan.tracesPerTarget = RepeaterBenchmarkPolicy.clampTracesPerTarget(count)
    publish()
  }

  /// Clears the last run's measurements without touching the plan.
  public func clearResults() {
    guard !isRunning else { return }
    results = []
    completedAt = nil
    publish()
  }

  // MARK: - Running

  /// Runs the plan: every target in turn, every probe in a target's batch in turn.
  ///
  /// Sequential on purpose. Two probes in flight at once share one radio and one channel, so
  /// their round trips measure each other rather than the links under test.
  public func run() async {
    guard !isRunning, plan.isRunnable, let testRepeater = plan.testRepeater else { return }

    isRunning = true
    isCancelled = false
    completedAt = nil
    results = plan.targets.map { BenchmarkTargetResult(target: $0) }
    currentTargetIndex = 0
    currentTraceIndex = 0
    startListening()
    publish()

    for (index, target) in plan.targets.enumerated() {
      if isCancelled { break }
      currentTargetIndex = index + 1
      currentTraceIndex = 0

      let path = probePath(testRepeater: testRepeater, target: target)
      for sequence in 1...plan.tracesPerTarget {
        if isCancelled { break }
        currentTraceIndex = sequence
        publish()

        let outcome = await probe(sequence: sequence, path: path)
        results[index].outcomes.append(outcome)
        publish()

        if sequence < plan.tracesPerTarget, !isCancelled {
          await sleep(configuration.policy.interTraceDelay)
        }
      }
      results[index].isComplete = true
      publish()
    }

    isRunning = false
    currentTargetIndex = 0
    currentTraceIndex = 0
    completedAt = now()
    stopListening()
    publish()
  }

  /// Stops a run after the probe in flight resolves. Anything already measured is kept —
  /// a partial batch is still a reading.
  public func cancel() {
    isCancelled = true
    for (_, waiter) in waiters {
      waiter.resume(returning: nil)
    }
    waiters.removeAll()
    earlyReplies.removeAll()
    expiredTags.removeAll()
    publish()
  }

  // MARK: - Probing

  /// The explicit path a probe travels: out through the test repeater to the target, then
  /// back through the test repeater. The return leg is what makes one reply carry both
  /// directions of the link.
  private func probePath(testRepeater: BenchmarkTarget, target: BenchmarkTarget) -> Data {
    let width = configuration.traceHashSize
    let testHash = testRepeater.pathHash(byteWidth: width)
    return testHash + target.pathHash(byteWidth: width) + testHash
  }

  private func probe(sequence: Int, path: Data) async -> BenchmarkTraceOutcome {
    let tag = makeTag()
    let sentAt = now()

    let timeout: Duration
    do {
      let sent = try await session.sendTrace(
        tag: tag,
        authCode: 0,
        flags: configuration.traceFlags,
        path: path
      )
      timeout = configuration.policy.replyTimeout(suggestedTimeoutMs: sent.suggestedTimeoutMs)
    } catch {
      logger.error("Benchmark probe send failed: \(error.localizedDescription)")
      return BenchmarkTraceOutcome(
        sequence: sequence,
        startedAt: sentAt,
        durationMs: 0,
        hops: [],
        failure: .sendFailed
      )
    }

    guard let reply = await awaitReply(tag: tag, timeout: timeout) else {
      logger.debug("Benchmark probe \(sequence) timed out (tag \(tag))")
      return BenchmarkTraceOutcome(
        sequence: sequence,
        startedAt: sentAt,
        durationMs: 0,
        hops: [],
        failure: .timeout
      )
    }

    let durationMs = Int((now().timeIntervalSince(sentAt) * 1000).rounded())
    return BenchmarkTraceOutcome(
      sequence: sequence,
      startedAt: sentAt,
      durationMs: max(0, durationMs),
      hops: hops(from: reply),
      failure: nil
    )
  }

  /// Waits for the reply to one probe, or `nil` when its deadline passes first.
  ///
  /// The three-way handshake between the waiter, an early reply and an early deadline is why
  /// `earlyReplies` and `expiredTags` exist: the timeout task and the event stream both run
  /// outside this call, and either can reach the actor before the continuation is installed.
  private func awaitReply(tag: UInt32, timeout: Duration) async -> TraceInfo? {
    if let early = earlyReplies.removeValue(forKey: tag) { return early }

    let deadline = Task { [weak self, sleep] in
      await sleep(timeout)
      await self?.expire(tag: tag)
    }
    defer { deadline.cancel() }

    return await withCheckedContinuation { (continuation: CheckedContinuation<TraceInfo?, Never>) in
      if let early = earlyReplies.removeValue(forKey: tag) {
        continuation.resume(returning: early)
      } else if expiredTags.remove(tag) != nil || isCancelled {
        continuation.resume(returning: nil)
      } else {
        waiters[tag] = continuation
      }
    }
  }

  private func expire(tag: UInt32) {
    if let waiter = waiters.removeValue(forKey: tag) {
      waiter.resume(returning: nil)
    } else {
      expiredTags.insert(tag)
    }
  }

  // MARK: - Event ingest

  /// Starts listening for trace replies. Only live during a run — the benchmark has no
  /// interest in traces the rest of the app sends while it is idle.
  private func startListening() {
    guard eventTask == nil else { return }
    eventTask = Task { [weak self] in
      guard let self else { return }
      let events = await self.session.events(filter: Self.eventFilter)
      for await event in events {
        if Task.isCancelled { break }
        await self.ingest(event)
      }
    }
  }

  private func stopListening() {
    eventTask?.cancel()
    eventTask = nil
  }

  static let eventFilter = EventFilter { event in
    if case .traceData = event { return true }
    return false
  }

  /// Folds one device event into the run. Exposed for tests, which script replies directly
  /// rather than through a live session.
  func ingest(_ event: MeshEvent) {
    guard case let .traceData(info) = event else { return }
    if let waiter = waiters.removeValue(forKey: info.tag) {
      waiter.resume(returning: info)
    } else {
      earlyReplies[info.tag] = info
    }
  }

  // MARK: - Hops

  /// Turns a reply's path into the hop chain a row renders.
  ///
  /// Receiver attribution, matching the Trace Path tool: each hop's SNR is what *that* node
  /// measured when the packet reached it. The endpoints are this radio — the start hop
  /// carries no measurement, the end hop carries the SNR we measured for the reply.
  private func hops(from info: TraceInfo) -> [BenchmarkHop] {
    var hops: [BenchmarkHop] = [
      BenchmarkHop(position: .start, hash: nil, name: localName, snr: 0)
    ]

    for node in info.path where node.hashBytes != nil {
      hops.append(BenchmarkHop(
        position: .intermediate,
        hash: node.hashBytes,
        name: resolvedName(for: node.hashBytes),
        snr: node.snr
      ))
    }

    hops.append(BenchmarkHop(
      position: .end,
      hash: nil,
      name: localName,
      snr: info.path.last?.snr ?? 0
    ))
    return hops
  }

  private var localName: String? {
    configuration.localNodeName.isEmpty ? nil : configuration.localNodeName
  }

  /// Names a hop from the run's own participants.
  ///
  /// A benchmark path only ever visits the test repeater and one target, both of which the
  /// plan already holds with full public keys — so resolution is a prefix match against two
  /// known nodes rather than a trip through the node directory.
  private func resolvedName(for hash: Data?) -> String? {
    guard let hash, !hash.isEmpty else { return nil }
    let participants = ([plan.testRepeater] + plan.targets).compactMap(\.self)
    return participants.first { $0.publicKey.starts(with: hash) }?.name
  }

  // MARK: - Publishing

  private func makeSnapshot() -> RepeaterBenchmarkSnapshot {
    RepeaterBenchmarkSnapshot(
      plan: plan,
      results: results,
      isRunning: isRunning,
      currentTargetIndex: currentTargetIndex,
      currentTraceIndex: currentTraceIndex,
      completedAt: completedAt
    )
  }

  private func publish() {
    let snapshot = makeSnapshot()
    guard snapshot != lastPublished else { return }
    lastPublished = snapshot
    broadcaster.yield(snapshot)
  }
}
