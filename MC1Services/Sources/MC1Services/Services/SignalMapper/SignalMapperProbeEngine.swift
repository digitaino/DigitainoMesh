import Foundation
import MeshCore
import SurveyKit

/// Manual survey mode: deliberate, budgeted probing of the mesh from wherever the user
/// walks — or rides (docs/SIGNAL_MAPPER_V2.md §2.4 "M3"; docs/ACTIVE_SURVEY_M3_5.md).
///
/// Where the capture engine listens, this one asks. A session sends two kinds of probe,
/// both strictly non-flood:
///
/// - **Zero-hop discover** (`sendNodeDiscoverRequest`, repeaters-only filter) — nearby
///   repeaters announce themselves with full public keys and report the SNR they measured
///   for our request. One packet, answered only by direct neighbours.
/// - **Directed trace** to a known repeater — a source-routed ping of the direct link.
///   The reply carries the SNR the repeater measured for our probe (the TX leg no amount
///   of listening can observe) and our own measurement of the reply.
///
/// **Never flood.** §2.4 allowed one flood discover per unknown cell; that exception was
/// removed 2026-08-26 (Rafael) — the engine transmits nothing flood-routed, ever, so the
/// policy's flood quota is pinned to zero rather than tuned.
///
/// Two schedulers share the radio, with **separate budgets** so neither can starve the
/// other (M3.5 review C1/C2 — the original single-bucket design let three focus targets
/// drain the novelty supply to zero for an entire ride):
///
/// - **Novelty probing** is SurveyKit's `SamplingPolicy`, unchanged: token bucket with a
///   reserve only spot check may spend, per-cell sample quotas, speed-adaptive tier.
///   Focus probes never touch this policy — not its bucket and not its cadence state,
///   because `manualProbe` resets `lastProbeAt` and a 15 s focus cadence would hold the
///   stationary-retry gate closed forever.
/// - **Focus probing** traces each locked-on target on its own cadence from its own
///   small bucket. The cadence ladders on loss streak: base while the link is healthy,
///   fast (×0.4) while probes are dropping — resolution exactly where the coverage edge
///   is — and slow (×3) once the target is well and truly gone, so a dead link is a
///   heartbeat, not a hammer. A lost probe was never heard by the repeater, so the
///   fast rung costs the mesh nothing beyond our own airtime.
///
/// **Send-time placement** (review M4): a probe is attributed to where it was
/// *transmitted*, not where its reply arrived — at 7 m/s a reply lands two
/// boundary-straddling seconds downrange. The sink places the attempt when the packet
/// leaves; replies and losses fold against that stored placement.
///
/// **Trace correlation is staged** (review M9/M10): a reply arrives as up to two events —
/// `.traceData` (per-hop uplink SNR array, plus our own downlink reading in its final
/// hash-less node) and the RX-log view of the same packet (adds RSSI). Either alone is
/// enough to fold; the tracker claim happens exactly once, when the first half arrives,
/// and the staged pair settles when both halves are in or the staging window lapses.
/// `.traceData` is also the robustness leg — a radio that does not push the RX log
/// still folds complete results.
///
/// Results fold through the capture engine (``MapperActiveSampleSink``), so an active
/// sample passes the very same fix gate, anchor exclusion and aggregation as a passive
/// packet. Raw ride-log events for probe traffic are emitted here (the engine knows the
/// kind, the per-hop array and the focus flag); passive raw events are the capture
/// engine's job — emitting both here would double-log every packet.
public actor SignalMapperProbeEngine {
  /// Live per-target state for a locked-on repeater — what the ride HUD renders.
  public struct FocusTargetState: Sendable, Equatable, Identifiable {
    public let id: NodeHexID
    public let publicKey: Data
    /// Our reading of them, from replies or passive sightings — the downlink leg.
    public var lastRxSnr: Double?
    /// Their reading of us, from trace/discover replies — the uplink leg.
    public var lastTxSnr: Double?
    public var lastRssi: Int?
    public var lastRttMs: Int?
    /// Any evidence at all — reply or passive sighting.
    public var lastHeardAt: Date?
    /// A correlated probe reply specifically.
    public var lastReplyAt: Date?
    public var lastProbeAt: Date?
    public var probesSent: Int = 0
    public var repliesHeard: Int = 0
    /// Consecutive probes lost. Drives the cadence ladder and the HUD's red state.
    public var lossStreak: Int = 0

    public init(id: NodeHexID, publicKey: Data) {
      self.id = id
      self.publicKey = publicKey
    }
  }

  /// What the session HUD and the completion sheet read.
  public struct SessionSnapshot: Sendable, Equatable {
    public var isRunning: Bool
    public var startedAt: Date?
    /// Probe cycles executed (each is one discover and/or one trace).
    public var probesSent: Int
    public var tracesSent: Int
    public var discoversSent: Int
    /// Trace replies correlated back to a probe of ours.
    public var traceRepliesHeard: Int
    /// Discover responses heard (each also refreshes the target table).
    public var discoverResponsesHeard: Int
    /// Probes whose deadline passed with the radio link healthy — genuine dead-zone
    /// evidence, not an error.
    public var probesLost: Int
    /// Probes written off because the session or radio went away (BLE teardown, stop).
    /// Kept apart from ``probesLost`` so a reconnect blip cannot paint phantom dead
    /// zones on a road where the link was fine (M3.5 review 2a).
    public var probesAbandoned: Int
    /// Distinct tier-cells that triggered a probe this session.
    public var cellsProbed: Int
    /// Repeaters currently known well enough to trace (full public key in hand).
    public var targetCount: Int
    /// Tokens left in the novelty TX budget, for the HUD's budget gauge.
    public var budgetAvailable: Double
    public var budgetCapacity: Double
    /// Tokens left in the focus budget (1 token = 1 trace).
    public var focusBudgetAvailable: Double
    public var tier: SamplingTier
    /// Ticks the engine skipped because no usable fix was available.
    public var skippedNoFixCount: Int
    /// Live lock-on state, in the order the targets were selected.
    public var focusStates: [FocusTargetState]

    public init(
      isRunning: Bool = false,
      startedAt: Date? = nil,
      probesSent: Int = 0,
      tracesSent: Int = 0,
      discoversSent: Int = 0,
      traceRepliesHeard: Int = 0,
      discoverResponsesHeard: Int = 0,
      probesLost: Int = 0,
      probesAbandoned: Int = 0,
      cellsProbed: Int = 0,
      targetCount: Int = 0,
      budgetAvailable: Double = 0,
      budgetCapacity: Double = 0,
      focusBudgetAvailable: Double = 0,
      tier: SamplingTier = .fine,
      skippedNoFixCount: Int = 0,
      focusStates: [FocusTargetState] = []
    ) {
      self.isRunning = isRunning
      self.startedAt = startedAt
      self.probesSent = probesSent
      self.tracesSent = tracesSent
      self.discoversSent = discoversSent
      self.traceRepliesHeard = traceRepliesHeard
      self.discoverResponsesHeard = discoverResponsesHeard
      self.probesLost = probesLost
      self.probesAbandoned = probesAbandoned
      self.cellsProbed = cellsProbed
      self.targetCount = targetCount
      self.budgetAvailable = budgetAvailable
      self.budgetCapacity = budgetCapacity
      self.focusBudgetAvailable = focusBudgetAvailable
      self.tier = tier
      self.skippedNoFixCount = skippedNoFixCount
      self.focusStates = focusStates
    }
  }

  // MARK: - Dependencies

  /// The same narrow radio surface signal bars probes through — reused, not duplicated
  /// (MIGRATION_PLAN §3: the mapper wraps the B1 engine's probe plumbing).
  private let session: any SignalBarsSessionOps & SessionEventStreaming
  /// Where probe results fold. The capture engine conforms; its fix gate and anchor
  /// exclusion apply to active samples exactly as to passive ones.
  private let sink: any MapperActiveSampleSink
  /// Warm-start repeater targets, typically the signal-bars table. Discover responses
  /// during the session keep extending the set beyond it.
  private let warmTargets: (any MapperProbeTargetSource)?
  /// Recent coverage, read once per session to skip cells that are already mapped.
  private let store: (any MapperCellPersisting)?
  private let fixProvider: any MapperFixProviding
  private let tuningProvider: any MapperTuningProviding
  /// Raw ride-log recorder for probe traffic; nil outside recorded sessions.
  private var rawRecorder: (any MapperRawSampleRecording)?
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async -> Void
  private let logger = PersistentLogger(subsystem: "com.mc1", category: "SignalMapperProbe")

  // MARK: - State

  private var policy: SamplingPolicy?
  private var pathHashMode: UInt8 = 0
  private var tracker = SignalBarsProbeTracker()

  /// What the engine planned for each outstanding tag: the send-time placement every
  /// reply and loss is attributed to, plus the novelty credit. Discover tags keep their
  /// entry after the first response (several neighbours answer one broadcast); trace
  /// tags are removed when their probe settles. Stale entries are TTL-swept.
  private struct PlannedProbe {
    var placement: MapperProbePlacement?
    var creditCell: H3Cell?
    var creditConsumed = false
    var createdAt: Date
  }

  private var planned: [UInt32: PlannedProbe] = [:]

  /// A trace reply mid-assembly: the tracker entry is already claimed (exactly once —
  /// the expiry sweep can no longer touch it), and the two event halves join here.
  private struct StagedReply {
    var probe: SignalBarsProbeTracker.Probe
    var firstHalfAt: Date
    var wasFocused: Bool
    var localSnr: Double?
    var remoteSnrRxLog: Double?
    var rssi: Int?
    var hopCount: Int?
    var trace: TraceInfo?
  }

  private var staged: [UInt32: StagedReply] = [:]
  /// Trace tags belonging to focus probes (the shared tracker type stays untouched).
  private var focusTags: Set<UInt32> = []

  /// Repeaters probeable right now: full public key in hand, freshest sighting last.
  private var targets: [NodeHexID: MapperProbeTarget] = [:]
  /// When each target was last traced — round-robin and focus cadence read this. A side
  /// dictionary, deliberately not a `MapperProbeTarget` field: discover responses
  /// replace target values wholesale and would wipe it (review M8).
  private var lastTraceAt: [NodeHexID: Date] = [:]

  /// Lock-on: ordered focus selection, its live state, and its dedicated budget.
  private var focusOrder: [NodeHexID] = []
  private var focusStates: [NodeHexID: FocusTargetState] = [:]
  private var focusBucket: TokenBucket?

  private var probedTierCells: Set<H3Cell> = []
  private var state = SessionSnapshot()
  private var probeTimeoutMs = 5000
  private var eventTask: Task<Void, Never>?
  private var loopTask: Task<Void, Never>?
  private var snapshotContinuations: [UUID: AsyncStream<SessionSnapshot>.Continuation] = [:]

  /// The events a session consumes. `.traceData` is the authoritative trace reply (per-hop
  /// uplink SNR, correct at every hash width, pushed even by radios that never push an RX
  /// log); the RX-log view of the same packet adds RSSI; discover responses arrive only as
  /// their own event.
  static let eventFilter = EventFilter { event in
    switch event {
    case .rxLogData, .discoverResponse, .traceData: true
    default: false
    }
  }

  public init(
    session: any SignalBarsSessionOps & SessionEventStreaming,
    sink: any MapperActiveSampleSink,
    warmTargets: (any MapperProbeTargetSource)? = nil,
    store: (any MapperCellPersisting)? = nil,
    fixProvider: any MapperFixProviding = NoMapperFixProvider(),
    tuningProvider: any MapperTuningProviding = StaticMapperTuningProvider(),
    rawRecorder: (any MapperRawSampleRecording)? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.session = session
    self.sink = sink
    self.warmTargets = warmTargets
    self.store = store
    self.fixProvider = fixProvider
    self.tuningProvider = tuningProvider
    self.rawRecorder = rawRecorder
    self.now = now
    self.sleep = sleep
  }

  deinit {
    eventTask?.cancel()
    loopTask?.cancel()
    for continuation in snapshotContinuations.values {
      continuation.finish()
    }
  }

  // MARK: - Session lifecycle

  /// Begins a survey session. Restarting a running session resets its counters and
  /// budget, which is what a user tapping "start" expects a fresh session to mean.
  /// (A BLE rewire mid-ride does *not* come through here — the app builds a fresh
  /// engine and carries the run's cumulative counters itself; see AppState.)
  ///
  /// - Parameter pathHashMode: The device's configured path hash width mode (0/1/2 →
  ///   1/2/3-byte hashes), the same value trace paths are addressed with everywhere else.
  public func startSession(pathHashMode: UInt8) async {
    stopTasks()

    let tuning = tuningProvider.tuning
    let at = now()
    self.pathHashMode = pathHashMode
    policy = SamplingPolicy(config: Self.policyConfig(from: tuning), at: at.timeIntervalSinceReferenceDate)
    tracker.cancelAll()
    planned.removeAll()
    staged.removeAll()
    focusTags.removeAll()
    probedTierCells.removeAll()
    targets.removeAll()
    lastTraceAt.removeAll()
    state = SessionSnapshot(
      isRunning: true,
      startedAt: at,
      budgetCapacity: Self.policyConfig(from: tuning).bucketCapacity,
      tier: policy?.currentTier ?? .fine
    )
    rebuildFocusBucket(at: at)

    await warmStartTargets()
    await skipFreshCells(tuning: tuning, at: at)

    let events = await session.events(filter: Self.eventFilter)
    eventTask = Task { [weak self] in
      for await event in events {
        if Task.isCancelled { break }
        await self?.ingest(event)
      }
    }

    loopTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.sleep(Self.loopInterval)
        if Task.isCancelled { return }
        await self.tick()
      }
    }

    logger.info("Signal mapper survey session started")
  }

  /// Ends the session and returns its final counters for the completion sheet.
  ///
  /// Outstanding and half-staged probes are **abandoned**, not lost: their replies would
  /// arrive with nobody listening, which says nothing about coverage. Teardown must never
  /// manufacture dead-zone evidence.
  @discardableResult
  public func stopSession() async -> SessionSnapshot {
    guard state.isRunning else { return state }
    stopTasks()
    let at = now()
    for probe in tracker.probes.values {
      await recordAbandoned(probe, at: at)
    }
    for reply in staged.values {
      await recordAbandoned(reply.probe, at: at)
    }
    state.probesAbandoned += tracker.probes.count + staged.count
    tracker.cancelAll()
    staged.removeAll()
    planned.removeAll()
    focusTags.removeAll()
    state.isRunning = false
    logger.info(
      "Signal mapper survey session ended: \(self.state.probesSent) probes, \(self.state.traceRepliesHeard + self.state.discoverResponsesHeard) replies"
    )
    yieldSnapshot()
    for continuation in snapshotContinuations.values {
      continuation.finish()
    }
    snapshotContinuations.removeAll()
    return state
  }

  /// One-tap spot check: a single probe cycle for the cell the user is standing in,
  /// through the same budget — it may spend the reserve automatic cycles cannot touch,
  /// and nothing else (§2.4: "no separate code path").
  public func spotCheck() async {
    guard state.isRunning, var policy else { return }
    guard let fix = await usableFix() else {
      state.skippedNoFixCount += 1
      return
    }
    let at = now()
    let plan = policy.manualProbe(
      coordinate: GeoCoordinate(latitude: fix.latitude, longitude: fix.longitude),
      at: at.timeIntervalSinceReferenceDate
    )
    self.policy = policy
    guard let plan else { return }
    await execute(plan, at: at)
  }

  // MARK: - Lock-on

  /// Replaces the focus selection. Focus targets are traced on their own cadence and
  /// budget for as long as they stay selected; deselected targets keep their entries in
  /// the general table. Passing more than ``maxFocusTargets`` keeps the first ones.
  public func setFocusTargets(_ selection: [MapperProbeTarget]) {
    let capped = Array(selection.prefix(Self.maxFocusTargets))
    focusOrder = capped.map(\.id)
    var newStates: [NodeHexID: FocusTargetState] = [:]
    for target in capped {
      targets[target.id] = targets[target.id] ?? target
      newStates[target.id] = focusStates[target.id] ?? FocusTargetState(id: target.id, publicKey: target.publicKey)
    }
    focusStates = newStates
    rebuildFocusBucket(at: now())
    yieldSnapshot()
  }

  /// Pins the sampling tier (nil returns to automatic speed-based selection). A range
  /// ride pins `.fine`: at 15–30 km/h the automatic tier flaps across its hysteresis
  /// band and sampling density becomes a function of traffic lights.
  public func setTierOverride(_ tier: SamplingTier?) {
    policy?.tierOverride = tier
  }

  /// Attaches the raw ride-log recorder (nil detaches). Session-scoped: the app sets it
  /// when a recorded run begins and clears it when the run ends.
  public func setRawRecorder(_ recorder: (any MapperRawSampleRecording)?) {
    rawRecorder = recorder
  }

  /// Current counters, refreshed with the live budget reading.
  public func snapshot() -> SessionSnapshot {
    var current = state
    let at = now()
    if var policy {
      current.budgetAvailable = policy.budgetAvailable(at: at.timeIntervalSinceReferenceDate)
      current.tier = policy.currentTier
      self.policy = policy
    }
    if var bucket = focusBucket {
      current.focusBudgetAvailable = bucket.available(at: at.timeIntervalSinceReferenceDate)
      focusBucket = bucket
    }
    current.targetCount = targets.count
    current.cellsProbed = probedTierCells.count
    current.focusStates = focusOrder.compactMap { focusStates[$0] }
    return current
  }

  /// A live snapshot stream for the ride HUD. Yields on every loop tick (the budget
  /// refills with time, not events) and on every fold; finishes when the session stops.
  /// Each caller gets its own stream — a rewired HUD re-subscribes to the new engine.
  public func snapshots() -> AsyncStream<SessionSnapshot> {
    let id = UUID()
    return AsyncStream { continuation in
      snapshotContinuations[id] = continuation
      continuation.yield(snapshot())
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeSnapshotContinuation(id) }
      }
    }
  }

  private func removeSnapshotContinuation(_ id: UUID) {
    snapshotContinuations.removeValue(forKey: id)
  }

  private func yieldSnapshot() {
    guard !snapshotContinuations.isEmpty else { return }
    let current = snapshot()
    for continuation in snapshotContinuations.values {
      continuation.yield(current)
    }
  }

  // MARK: - Probe cycle

  /// One pass of the session loop: settle staged replies, sweep timeouts, run the focus
  /// scheduler, then ask the policy whether the current position warrants a novelty
  /// probe. Internal so tests can step the engine with a parked loop.
  func tick() async {
    guard state.isRunning else { return }
    let at = now()
    // Order matters (review M10): staged replies settle before the sweep so a reply
    // that beat its deadline by less than a tick cannot be counted lost.
    await settleStagedReplies(at: at, force: false)
    await sweepExpired(at: at)
    sweepStalePlans(at: at)
    await runFocusScheduler(at: at)

    guard var policy else { return }
    guard let fix = await usableFix() else {
      state.skippedNoFixCount += 1
      yieldSnapshot()
      return
    }
    let plan = policy.locationUpdate(
      coordinate: GeoCoordinate(latitude: fix.latitude, longitude: fix.longitude),
      speed: fix.speedMetersPerSecond,
      at: at.timeIntervalSinceReferenceDate
    )
    state.tier = policy.currentTier
    self.policy = policy
    if let plan {
      await execute(plan, at: at)
    }
    yieldSnapshot()
  }

  /// Sends one novelty probe cycle: a zero-hop discover, and a directed trace to the
  /// stalest-probed known repeater (round-robin — focus targets have their own cadence
  /// and are excluded here). Either half alone is still a useful cycle.
  private func execute(_ plan: SamplingPolicy.ProbePlan, at: Date) async {
    state.probesSent += 1
    probedTierCells.insert(plan.tierCell)

    let placement = await sink.placeProbeAttempt()
    await sendDiscover(creditCell: plan.baseCell, placement: placement, at: at)
    if let target = nextRoundRobinTarget() {
      await sendTrace(to: target, creditCell: plan.baseCell, placement: placement, isFocus: false, at: at)
    }
  }

  private func sendDiscover(creditCell: H3Cell?, placement: MapperProbePlacement?, at: Date) async {
    do {
      let tag = try await session.sendNodeDiscoverRequest(
        filter: SignalBarsPolicy().discoverFilter,
        prefixOnly: true,
        tag: nil,
        since: nil
      )
      planned[tag] = PlannedProbe(placement: placement, creditCell: creditCell, createdAt: at)
      state.discoversSent += 1
      await recordAttempt(target: nil, placement: placement, isFocus: false, at: at)
    } catch {
      logger.error("Survey discover failed: \(error.localizedDescription)")
    }
  }

  private func sendTrace(
    to target: MapperProbeTarget,
    creditCell: H3Cell?,
    placement: MapperProbePlacement?,
    isFocus: Bool,
    at: Date
  ) async {
    let tag = UInt32.random(in: 0..<UInt32.max)
    let path = SignalBarsObservation.probePath(forPublicKey: target.publicKey, pathHashMode: pathHashMode)

    tracker.register(tag: tag, target: target.id, now: at, timeoutMs: probeTimeoutMs)
    planned[tag] = PlannedProbe(placement: placement, creditCell: creditCell, createdAt: at)
    if isFocus { focusTags.insert(tag) }
    lastTraceAt[target.id] = at

    do {
      let sent = try await session.sendTrace(tag: tag, authCode: nil, flags: pathHashMode, path: path)
      probeTimeoutMs = Int(sent.suggestedTimeoutMs)
      tracker.retime(tag: tag, timeoutMs: probeTimeoutMs)
      state.tracesSent += 1
      if isFocus {
        focusStates[target.id]?.probesSent += 1
        focusStates[target.id]?.lastProbeAt = at
      }
      await recordAttempt(target: target, placement: placement, isFocus: isFocus, at: at)
    } catch {
      _ = tracker.claim(tag: tag)
      planned.removeValue(forKey: tag)
      focusTags.remove(tag)
      logger.error("Survey trace to \(target.id.hex) failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Focus scheduler

  /// The lock-on cadence: each focus target is traced when its ladder interval has
  /// elapsed and the focus bucket has a token. The bucket is sized with headroom for the
  /// ladder's fast rung, but a rung the budget refuses simply waits a tick.
  private func runFocusScheduler(at: Date) async {
    guard !focusOrder.isEmpty, state.isRunning else { return }
    let baseInterval = max(4, tuningProvider.tuning.focusProbeIntervalSeconds)

    for id in focusOrder {
      guard let target = targets[id], let focus = focusStates[id] else { continue }
      // One probe in flight per target: a second trace before the first resolves
      // would make loss attribution ambiguous.
      guard !tracker.hasProbe(for: id) else { continue }
      let interval = Self.ladderInterval(base: baseInterval, lossStreak: focus.lossStreak)
      let last = lastTraceAt[id] ?? .distantPast
      guard at.timeIntervalSince(last) >= interval else { continue }
      guard var bucket = focusBucket else { continue }
      let allowed = bucket.tryConsume(Self.focusProbeCost, at: at.timeIntervalSinceReferenceDate)
      focusBucket = bucket
      guard allowed else { continue }

      let placement = await sink.placeProbeAttempt()
      await sendTrace(to: target, creditCell: nil, placement: placement, isFocus: true, at: at)
    }
  }

  /// The loss-streak cadence ladder (M3.5 review 2e). Healthy → base; dropping probes →
  /// fast, because "the link died *here*" deserves 57 m resolution, not 105 m; gone →
  /// slow heartbeat that still catches recovery.
  static func ladderInterval(base: TimeInterval, lossStreak: Int) -> TimeInterval {
    switch lossStreak {
    case 0: base
    case 1...4: base * 0.4
    default: base * 3
    }
  }

  private func rebuildFocusBucket(at: Date) {
    guard !focusOrder.isEmpty else {
      focusBucket = nil
      return
    }
    let interval = max(4, tuningProvider.tuning.focusProbeIntervalSeconds)
    let count = Double(focusOrder.count)
    // 1.5× sustained headroom covers one target on the ladder's fast rung while the
    // others stay on base; capacity absorbs the transition burst.
    focusBucket = TokenBucket(
      capacity: count * Self.focusProbeCost * 3,
      refillPerSecond: count * Self.focusProbeCost * 1.5 / interval,
      at: at.timeIntervalSinceReferenceDate
    )
  }

  /// The novelty trace target: stalest-probed first, so every known repeater gets its
  /// turn instead of the freshest-heard one absorbing the whole session. Focus targets
  /// are excluded — they have their own cadence.
  private func nextRoundRobinTarget() -> MapperProbeTarget? {
    targets.values
      .filter { !focusOrder.contains($0.id) }
      .min { lhs, rhs in
        let lhsAt = lastTraceAt[lhs.id] ?? .distantPast
        let rhsAt = lastTraceAt[rhs.id] ?? .distantPast
        if lhsAt != rhsAt { return lhsAt < rhsAt }
        return (lhs.lastHeard ?? .distantPast) > (rhs.lastHeard ?? .distantPast)
      }
  }

  // MARK: - Sweeps

  private func sweepExpired(at: Date) async {
    let lost = tracker.expired(now: at)
    guard !lost.isEmpty else { return }
    state.probesLost += lost.count
    for probe in lost {
      let plan = planned.removeValue(forKey: probe.tag)
      let wasFocused = focusTags.remove(probe.tag) != nil
      if wasFocused {
        focusStates[probe.target]?.lossStreak += 1
      }
      var event = MapperRawSampleEvent(
        timestamp: at,
        kind: .probeLost,
        repeaterHexID: probe.target.hex,
        repeaterPublicKey: targets[probe.target]?.publicKey,
        wasFocused: wasFocused
      )
      applyPlacement(plan?.placement, to: &event)
      await rawRecorder?.record(event)
    }
    yieldSnapshot()
  }

  /// Discover plans linger so every responder can fold against the send-time placement,
  /// but a tag nobody answered must not accumulate forever.
  private func sweepStalePlans(at: Date) {
    let ttl: TimeInterval = 60
    planned = planned.filter { _, plan in
      at.timeIntervalSince(plan.createdAt) < ttl
    }
  }

  // MARK: - Event ingest

  /// Folds one device event. Exposed for tests, which script events directly.
  func ingest(_ event: MeshEvent) async {
    switch event {
    case let .discoverResponse(response):
      await ingestDiscoverResponse(response)
    case let .traceData(trace):
      await ingestTraceData(trace)
    case let .rxLogData(log):
      if let reply = SignalBarsObservation.probeReply(from: log) {
        await ingestProbeReply(reply, log: log)
      } else if let sighting = SignalBarsObservation.passiveSighting(from: log) {
        noteFocusSighting(sighting)
      }
    default:
      break
    }
  }

  /// A repeater answered a discover: both link legs in one packet, plus the full public
  /// key that makes it traceable for the rest of the session.
  private func ingestDiscoverResponse(_ response: DiscoverResponse) async {
    guard state.isRunning else { return }
    guard let id = SignalBarsObservation.hashID(forPublicKey: response.publicKey, pathHashMode: pathHashMode) else {
      return
    }
    let at = now()
    targets[id] = MapperProbeTarget(id: id, publicKey: response.publicKey, lastHeard: at)
    state.discoverResponsesHeard += 1

    if var focus = focusStates[id] {
      focus.lastRxSnr = response.snr
      focus.lastTxSnr = response.snrIn
      focus.lastRssi = response.rssi
      focus.lastHeardAt = at
      focusStates[id] = focus
    }

    // The response echoes the request's tag as four little-endian bytes.
    let tag = response.tag.readUInt32LE(at: 0)
    let plan = consumeCredit(forTag: tag)
    let wasFocused = focusOrder.contains(id)
    await sink.ingestProbeResult(MapperProbeResult(
      repeaterID: id,
      rxSnr: response.snr,
      txSnr: response.snrIn,
      rssi: response.rssi,
      hopCount: 1,
      rttMs: nil,
      at: at,
      placement: plan?.placement
    ))
    recordSample(in: plan?.creditCell)

    var event = MapperRawSampleEvent(
      timestamp: at,
      kind: .probeDiscoverResponse,
      rxSnr: response.snr,
      txSnr: response.snrIn,
      rssi: response.rssi,
      hopCount: 1,
      repeaterHexID: id.hex,
      repeaterPublicKey: response.publicKey,
      wasFocused: wasFocused
    )
    applyPlacement(plan?.placement, to: &event)
    await rawRecorder?.record(event)
    yieldSnapshot()
  }

  /// The authoritative half of a trace reply: per-hop uplink SNR at every hash width,
  /// plus our own downlink reading in the final hash-less node.
  private func ingestTraceData(_ trace: TraceInfo) async {
    guard state.isRunning else { return }
    let at = now()
    if var reply = staged[trace.tag] {
      reply.trace = trace
      staged[trace.tag] = reply
      await settleStagedReplies(at: at, force: false)
      return
    }
    guard let probe = tracker.claim(tag: trace.tag) else { return }
    staged[trace.tag] = StagedReply(
      probe: probe,
      firstHalfAt: at,
      wasFocused: focusTags.contains(trace.tag),
      trace: trace
    )
    await settleStagedReplies(at: at, force: false)
  }

  /// The RX-log half of a trace reply: adds RSSI and our unquantized receive SNR.
  private func ingestProbeReply(_ reply: RepeaterProbeReply, log: ParsedRxLogData) async {
    guard state.isRunning else { return }
    let at = now()
    let hopCount = decodePathLen(log.pathLength).map { Swift.max(1, $0.hopCount) } ?? 1
    if var pending = staged[reply.tag] {
      pending.localSnr = reply.localSnr
      pending.remoteSnrRxLog = reply.remoteSnr
      pending.rssi = log.rssi
      pending.hopCount = hopCount
      staged[reply.tag] = pending
      await settleStagedReplies(at: at, force: false)
      return
    }
    guard let probe = tracker.claim(tag: reply.tag) else { return }
    staged[reply.tag] = StagedReply(
      probe: probe,
      firstHalfAt: at,
      wasFocused: focusTags.contains(reply.tag),
      localSnr: reply.localSnr,
      remoteSnrRxLog: reply.remoteSnr,
      rssi: log.rssi,
      hopCount: hopCount
    )
    await settleStagedReplies(at: at, force: false)
  }

  /// Folds staged replies that are complete (both halves) or out of staging time.
  /// The window is deliberately much shorter than the probe deadline — a stage that
  /// outlived the deadline would race the expiry sweep (review M10).
  private func settleStagedReplies(at: Date, force: Bool) async {
    for (tag, reply) in staged {
      let complete = reply.trace != nil && reply.localSnr != nil
      let expired = at.timeIntervalSince(reply.firstHalfAt) >= Self.stagingWindow
      guard complete || expired || force else { continue }
      staged.removeValue(forKey: tag)
      focusTags.remove(tag)
      await fold(reply, tag: tag, at: at)
    }
  }

  private func fold(_ reply: StagedReply, tag: UInt32, at: Date) async {
    state.traceRepliesHeard += 1
    let plan = planned.removeValue(forKey: tag)

    // Uplink: the trace event's target hop is authoritative at every hash width. The
    // RX-log last-byte fallback is only trustworthy at 1-byte hashes (mode 0), where a
    // path entry and an SNR byte are the same width.
    let hopNodes = reply.trace?.path.filter { $0.hashBytes != nil } ?? []
    let txSnr = hopNodes.last?.snr
      ?? (pathHashMode == 0 ? reply.remoteSnrRxLog : nil)
    // Downlink: prefer our radio's unquantized RX-log reading; the trace's final
    // hash-less node carries the same measurement quantized to 0.25 dB.
    let rxSnr = reply.localSnr ?? reply.trace?.path.last(where: { $0.hashBytes == nil })?.snr
    let rttMs = Int((reply.firstHalfAt.timeIntervalSince(reply.probe.sentAt) * 1000).rounded())
    let perHop = reply.trace.map { $0.path.map(\.snr) }

    if reply.wasFocused, var focus = focusStates[reply.probe.target] {
      focus.lastRxSnr = rxSnr ?? focus.lastRxSnr
      focus.lastTxSnr = txSnr ?? focus.lastTxSnr
      focus.lastRssi = reply.rssi ?? focus.lastRssi
      focus.lastRttMs = rttMs
      focus.lastHeardAt = at
      focus.lastReplyAt = at
      focus.repliesHeard += 1
      focus.lossStreak = 0
      focusStates[reply.probe.target] = focus
    }

    await sink.ingestProbeResult(MapperProbeResult(
      repeaterID: reply.probe.target,
      rxSnr: rxSnr,
      txSnr: txSnr,
      rssi: reply.rssi,
      hopCount: reply.hopCount ?? Swift.max(1, hopNodes.count),
      rttMs: rttMs,
      at: at,
      placement: plan?.placement
    ))
    recordSample(in: plan?.creditCell)

    var event = MapperRawSampleEvent(
      timestamp: at,
      kind: .probeTraceReply,
      rxSnr: rxSnr,
      txSnr: txSnr,
      rssi: reply.rssi,
      hopCount: reply.hopCount ?? Swift.max(1, hopNodes.count),
      rttMs: rttMs,
      perHopSnrs: perHop,
      repeaterHexID: reply.probe.target.hex,
      repeaterPublicKey: targets[reply.probe.target]?.publicKey,
      wasFocused: reply.wasFocused
    )
    applyPlacement(plan?.placement, to: &event)
    await rawRecorder?.record(event)
    yieldSnapshot()
  }

  /// A passively heard packet relayed by a focus target refreshes its downlink state —
  /// hearing them costs nothing. Matching is by node identity at whatever hash width the
  /// packet carried.
  private func noteFocusSighting(_ sighting: RepeaterSighting) {
    guard state.isRunning else { return }
    for id in focusOrder where id.identifiesSameNode(as: sighting.id) {
      guard var focus = focusStates[id] else { continue }
      focus.lastRxSnr = sighting.rxSnr
      focus.lastRssi = sighting.rssi ?? focus.lastRssi
      focus.lastHeardAt = now()
      focusStates[id] = focus
    }
  }

  // MARK: - Bookkeeping

  /// Consumes a tag's novelty credit exactly once, returning the plan either way so
  /// every discover responder folds against the same send-time placement. Responders
  /// after the first see a nil credit cell — one broadcast earns one credit.
  private func consumeCredit(forTag tag: UInt32) -> PlannedProbe? {
    guard var plan = planned[tag] else { return nil }
    if plan.creditConsumed {
      var repeatPlan = plan
      repeatPlan.creditCell = nil
      return repeatPlan
    }
    let first = plan
    plan.creditConsumed = true
    planned[tag] = plan
    return first
  }

  private func recordSample(in cell: H3Cell?) {
    guard let cell, var policy else { return }
    policy.recordSample(in: cell)
    self.policy = policy
  }

  private func recordAttempt(
    target: MapperProbeTarget?,
    placement: MapperProbePlacement?,
    isFocus: Bool,
    at: Date
  ) async {
    var event = MapperRawSampleEvent(
      timestamp: at,
      kind: .probeAttempt,
      repeaterHexID: target?.id.hex,
      repeaterPublicKey: target?.publicKey,
      wasFocused: isFocus
    )
    applyPlacement(placement, to: &event)
    await rawRecorder?.record(event)
  }

  private func recordAbandoned(_ probe: SignalBarsProbeTracker.Probe, at: Date) async {
    let plan = planned[probe.tag]
    var event = MapperRawSampleEvent(
      timestamp: at,
      kind: .probeAbandoned,
      repeaterHexID: probe.target.hex,
      repeaterPublicKey: targets[probe.target]?.publicKey,
      wasFocused: focusTags.contains(probe.tag)
    )
    applyPlacement(plan?.placement, to: &event)
    await rawRecorder?.record(event)
  }

  private func applyPlacement(_ placement: MapperProbePlacement?, to event: inout MapperRawSampleEvent) {
    guard let placement else { return }
    event.setFix(placement.fix, at: placement.at)
    event.cellRaw = placement.cell.rawValue
    event.gateOutcome = .accepted
  }

  // MARK: - Session setup

  /// Seeds the target table from whatever already knows the neighbourhood — the
  /// signal-bars table in practice — so the first trace does not have to wait for the
  /// first discover response.
  private func warmStartTargets() async {
    guard let warmTargets else { return }
    for target in await warmTargets.probeTargets() {
      targets[target.id] = target
    }
    state.targetCount = targets.count
  }

  /// Marks cells with fresh local coverage as fully covered, so the session spends its
  /// budget on the blank parts of the map (§2.4). Saturating — `recordSample` would
  /// count 1-of-N under per-cell quotas and leave warm cells novel (review M3). Off by
  /// default since M3.5: a week-old res-9 row marks its 920 m and 2.4 km tier parents
  /// covered, which blanks the near field of a range ride.
  private func skipFreshCells(tuning: MapperTuning, at: Date) async {
    guard let store, tuning.communityFreshnessDays > 0, var policy else { return }
    let fromDay = MapperDayKey.key(for: at.addingTimeInterval(-Double(tuning.communityFreshnessDays) * 86400))
    let toDay = MapperDayKey.key(for: at)
    guard let rows = try? await store.fetchMapperCellObservations(fromDay: fromDay, toDay: toDay) else {
      return
    }
    for cell in rows.compactMap(\.cell) {
      policy.markCovered(cell)
    }
    self.policy = policy
  }

  /// A fix the probe loop may plan against: present, not known-moved-away-from, and
  /// inside the flat age budget. The full gate — displacement scaling, accuracy, anchor
  /// discs — runs where it matters, in the capture engine as each attempt is placed.
  private func usableFix() async -> MapperFix? {
    guard let fix = await fixProvider.latestFix() else { return nil }
    guard !fix.movedSinceCapture else { return nil }
    guard now().timeIntervalSince(fix.timestamp) <= tuningProvider.tuning.fixMaxAgeSeconds else {
      return nil
    }
    return fix
  }

  // MARK: - Policy mapping

  /// How the mapper's tuning constants become a `SamplingPolicy` configuration.
  ///
  /// The bucket is sized in *tokens*, one probe cycle costing `probeCost`: capacity
  /// covers the tuning's burst *plus* the manual reserve, because automatic probes may
  /// never dip into the reserve — a capacity of exactly burst × cost would leave the
  /// last burst slot permanently unspendable. The refill rate reproduces the tuning's
  /// sustained cadence. The flood quota is pinned to zero — see the type doc; this is a
  /// decision, not a tunable.
  static func policyConfig(from tuning: MapperTuning) -> SamplingPolicy.Config {
    var config = SamplingPolicy.Config()
    config.bucketCapacity =
      Double(Swift.max(1, tuning.probeBurst)) * config.probeCost + config.manualReserve
    config.bucketRefillPerSecond =
      tuning.probeIntervalSeconds > 0 ? config.probeCost / tuning.probeIntervalSeconds : 0
    config.minProbeInterval = Swift.max(1, tuning.probeIntervalSeconds / 2)
    config.floodsPerTierCell = 0
    config.samplesPerCell = Swift.max(1, tuning.samplesPerCellPerSession)
    // 60 s (SurveyKit's walking default) makes per-cell quotas unreachable at ride
    // speed — a res-9 cell only holds a 7 m/s rider for ~34 s.
    config.stationaryRetryInterval = 15
    return config
  }

  /// How often the loop re-evaluates position against the policy. Fine-grained enough to
  /// catch a walking-pace cell crossing; the policy's own cadence and budget do the real
  /// rate limiting.
  static let loopInterval: Duration = .seconds(2)

  /// How long a first reply half waits for its partner event before folding alone.
  /// Strictly shorter than any probe deadline, so a staged reply can never race the
  /// expiry sweep.
  static let stagingWindow: TimeInterval = 1.0

  /// A focus trace costs one token — it is a lone trace, half the discover+trace pair
  /// `SamplingPolicy.Config.probeCost` describes.
  static let focusProbeCost: Double = 1

  /// Lock-on selection cap: three targets at the base cadence is ~9 forced replies/min
  /// across the neighbourhood, inside the app's own signal-bars discipline.
  public static let maxFocusTargets = 3

  private func stopTasks() {
    eventTask?.cancel()
    eventTask = nil
    loopTask?.cancel()
    loopTask = nil
  }
}

// MARK: - Probe targets

/// A repeater a survey session can direct a trace at: identity at the device's hash
/// width, plus the full public key a source-routed probe is addressed with.
public struct MapperProbeTarget: Sendable, Equatable {
  public let id: NodeHexID
  public let publicKey: Data
  /// When the repeater was last heard, freshest-first target selection's key.
  public let lastHeard: Date?

  public init(id: NodeHexID, publicKey: Data, lastHeard: Date?) {
    self.id = id
    self.publicKey = publicKey
    self.lastHeard = lastHeard
  }
}

/// Where a session's initial targets come from. The signal-bars engine conforms — its
/// table already ranks the neighbourhood's repeaters and holds public keys for the ones
/// discover responses have identified.
public protocol MapperProbeTargetSource: Sendable {
  func probeTargets() async -> [MapperProbeTarget]
}

extension SignalBarsEngine: MapperProbeTargetSource {
  public func probeTargets() async -> [MapperProbeTarget] {
    currentSnapshot().repeaters.compactMap { repeater in
      guard let publicKey = repeater.publicKey else { return nil }
      return MapperProbeTarget(id: repeater.id, publicKey: publicKey, lastHeard: repeater.lastHeard)
    }
  }
}

// MARK: - Active sample sink

/// Where and when a probe transmission left the radio: the send-time fix, its base
/// cell, and the stationary hint that accompanied it. Replies and losses are attributed
/// here, never to wherever the phone drifted by the time they resolved.
public struct MapperProbePlacement: Sendable, Equatable {
  public let cell: H3Cell
  public let fix: MapperFix
  public let at: Date
  public let isStationary: Bool

  public init(cell: H3Cell, fix: MapperFix, at: Date, isStationary: Bool) {
    self.cell = cell
    self.fix = fix
    self.at = at
    self.isStationary = isStationary
  }
}

/// One probe result, ready to fold: what a repeater and our radio measured of the two
/// link legs from the cell the probe was sent from.
///
/// Carries the repeater at ``NodeHexID`` width, never a full public key — the stored
/// observation is only entitled to what a packet's path would reveal
/// (`SurveySample.RepeaterSighting`). The raw ride log, which is allowed the full key,
/// is fed by the probe engine directly and never through this type.
public struct MapperProbeResult: Sendable, Equatable {
  /// The repeater that answered, at the device's path-hash width.
  public let repeaterID: NodeHexID?
  /// The SNR we measured for the reply — the RX leg.
  public let rxSnr: Double?
  /// The SNR the repeater reported for our probe — the TX leg, the measurement passive
  /// capture can never make.
  public let txSnr: Double?
  public let rssi: Int?
  public let hopCount: Int?
  /// Client-measured round trip of the trace, ms. Nil for discover responses. Folded
  /// into the cell's *probe* RTT columns — never the ACK RTT pair, which measures
  /// end-to-end deliveries an order of magnitude slower.
  public let rttMs: Int?
  public let at: Date
  /// The send-time placement of the probe this result answers, when the gate could
  /// place it. A nil placement folds against the current fix as a fallback.
  public let placement: MapperProbePlacement?

  public init(
    repeaterID: NodeHexID?,
    rxSnr: Double?,
    txSnr: Double?,
    rssi: Int?,
    hopCount: Int?,
    rttMs: Int? = nil,
    at: Date,
    placement: MapperProbePlacement? = nil
  ) {
    self.repeaterID = repeaterID
    self.rxSnr = rxSnr
    self.txSnr = txSnr
    self.rssi = rssi
    self.hopCount = hopCount
    self.rttMs = rttMs
    self.at = at
    self.placement = placement
  }
}

/// Where probe results fold. ``SignalMapperCaptureEngine`` is the production conformer:
/// active samples pass its fix gate and anchor exclusion exactly as passive packets do,
/// and land in the same `(cell, day)` rows with their `activePacketCount` and TX-leg
/// aggregates set.
public protocol MapperActiveSampleSink: Actor {
  func ingestProbeResult(_ result: MapperProbeResult) async
  /// Places a probe transmission at the current fix, running the data-quality gate.
  /// Returns nil when no usable fix exists (the attempt still transmits — it just can't
  /// be attributed). The aggregate `probesSent` counter increments only where anchor
  /// policy also allows, but the returned placement itself carries no anchor verdict.
  func placeProbeAttempt() async -> MapperProbePlacement?
}
