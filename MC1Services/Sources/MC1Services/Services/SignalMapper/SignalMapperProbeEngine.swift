import Foundation
import MeshCore
import SurveyKit

/// Manual survey mode: deliberate, budgeted probing of the mesh from wherever the user
/// walks (docs/SIGNAL_MAPPER_V2.md §2.4, §7 "M3").
///
/// Where the capture engine listens, this one asks. A session sends two kinds of probe,
/// both strictly non-flood:
///
/// - **Zero-hop discover** (`sendNodeDiscoverRequest`, repeaters-only filter) — nearby
///   repeaters announce themselves with full public keys and report the SNR they measured
///   for our request. One packet, answered only by direct neighbours.
/// - **Directed trace** to a known repeater — a source-routed ping of the direct link.
///   The reply carries the SNR the repeater measured for our probe (the TX leg no amount
///   of listening can observe) and, on arrival, our own measurement of the reply.
///
/// **Never flood.** §2.4 allowed one flood discover per unknown cell; that exception was
/// removed 2026-08-26 (Rafael) — the engine transmits nothing flood-routed, ever, so the
/// policy's flood quota is pinned to zero rather than tuned.
///
/// Probe *discipline* is SurveyKit's `SamplingPolicy`, unchanged from the survey-v2
/// engine that proved it (a highway drive stays under 3 probes/min):
///
/// - a token bucket is the hard TX ceiling, refilled at the tuning's sustained rate,
///   with a reserve only the user's own spot check may spend;
/// - novelty gating probes a tier-cell once — passive capture keeps recording for free;
/// - the sampling tier coarsens with speed, so cell crossings trigger at a sane rate
///   in a car as on foot;
/// - cells that already hold fresh local coverage are marked sampled at session start,
///   so the network cost of surveying shrinks as the map fills in (§2.4). Community
///   freshness joins the same test in M2.
///
/// Probes are **skipped, never queued**: a plan the budget refuses simply does not
/// happen, and the next cell crossing tries again.
///
/// Results fold through the capture engine (``MapperActiveSampleSink``), so an active
/// sample passes the very same fix gate, anchor exclusion and aggregation as a passive
/// packet — manual mode produces the same value, just faster (§1, "one capture core,
/// two thin modes").
public actor SignalMapperProbeEngine {
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
    /// Probes whose deadline passed with no reply — dead-zone evidence, not an error.
    public var probesLost: Int
    /// Distinct tier-cells that triggered a probe this session.
    public var cellsProbed: Int
    /// Repeaters currently known well enough to trace (full public key in hand).
    public var targetCount: Int
    /// Tokens left in the TX budget, for the HUD's budget gauge.
    public var budgetAvailable: Double
    public var budgetCapacity: Double
    public var tier: SamplingTier
    /// Ticks the engine skipped because no usable fix was available.
    public var skippedNoFixCount: Int

    public init(
      isRunning: Bool = false,
      startedAt: Date? = nil,
      probesSent: Int = 0,
      tracesSent: Int = 0,
      discoversSent: Int = 0,
      traceRepliesHeard: Int = 0,
      discoverResponsesHeard: Int = 0,
      probesLost: Int = 0,
      cellsProbed: Int = 0,
      targetCount: Int = 0,
      budgetAvailable: Double = 0,
      budgetCapacity: Double = 0,
      tier: SamplingTier = .fine,
      skippedNoFixCount: Int = 0
    ) {
      self.isRunning = isRunning
      self.startedAt = startedAt
      self.probesSent = probesSent
      self.tracesSent = tracesSent
      self.discoversSent = discoversSent
      self.traceRepliesHeard = traceRepliesHeard
      self.discoverResponsesHeard = discoverResponsesHeard
      self.probesLost = probesLost
      self.cellsProbed = cellsProbed
      self.targetCount = targetCount
      self.budgetAvailable = budgetAvailable
      self.budgetCapacity = budgetCapacity
      self.tier = tier
      self.skippedNoFixCount = skippedNoFixCount
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
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async -> Void
  private let logger = PersistentLogger(subsystem: "com.mc1", category: "SignalMapperProbe")

  // MARK: - State

  private var policy: SamplingPolicy?
  private var pathHashMode: UInt8 = 0
  private var tracker = SignalBarsProbeTracker()
  /// The base cell each outstanding probe was planned for, by trace tag — where the
  /// reply's novelty credit lands.
  private var probeCells: [UInt32: H3Cell] = [:]
  /// Repeaters probeable right now: full public key in hand, freshest sighting last.
  private var targets: [NodeHexID: MapperProbeTarget] = [:]
  private var probedTierCells: Set<H3Cell> = []
  private var state = SessionSnapshot()
  private var probeTimeoutMs = 5000
  private var eventTask: Task<Void, Never>?
  private var loopTask: Task<Void, Never>?

  /// The events a session consumes: trace replies ride the RX log (the only view that
  /// carries our own receive SNR for the reply), discover responses arrive as their own
  /// event and never reach the RX log at all.
  static let eventFilter = EventFilter { event in
    switch event {
    case .rxLogData, .discoverResponse: true
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
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.session = session
    self.sink = sink
    self.warmTargets = warmTargets
    self.store = store
    self.fixProvider = fixProvider
    self.tuningProvider = tuningProvider
    self.now = now
    self.sleep = sleep
  }

  deinit {
    eventTask?.cancel()
    loopTask?.cancel()
  }

  // MARK: - Session lifecycle

  /// Begins a survey session. Restarting a running session resets its counters and
  /// budget, which is what a user tapping "start" expects a fresh session to mean.
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
    probeCells.removeAll()
    probedTierCells.removeAll()
    targets.removeAll()
    state = SessionSnapshot(
      isRunning: true,
      startedAt: at,
      budgetCapacity: Self.policyConfig(from: tuning).bucketCapacity,
      tier: policy?.currentTier ?? .fine
    )

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
  @discardableResult
  public func stopSession() async -> SessionSnapshot {
    guard state.isRunning else { return state }
    stopTasks()
    // Outstanding probes are written off rather than waited for: their replies would
    // arrive with nobody listening, and the count is honest about what the session heard.
    state.probesLost += tracker.probes.count
    tracker.cancelAll()
    probeCells.removeAll()
    state.isRunning = false
    logger.info(
      "Signal mapper survey session ended: \(self.state.probesSent) probes, \(self.state.traceRepliesHeard + self.state.discoverResponsesHeard) replies"
    )
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

  /// Current counters, refreshed with the live budget reading.
  public func snapshot() -> SessionSnapshot {
    var current = state
    if var policy {
      current.budgetAvailable = policy.budgetAvailable(at: now().timeIntervalSinceReferenceDate)
      current.tier = policy.currentTier
      self.policy = policy
    }
    current.targetCount = targets.count
    current.cellsProbed = probedTierCells.count
    return current
  }

  // MARK: - Probe cycle

  /// One pass of the session loop: sweep timeouts, then ask the policy whether the
  /// current position warrants a probe. Internal so tests can step the engine with a
  /// parked loop, the same way `SignalBarsEngine.ingest` is scripted directly.
  func tick() async {
    guard state.isRunning else { return }
    sweepExpired()

    guard var policy else { return }
    guard let fix = await usableFix() else {
      state.skippedNoFixCount += 1
      return
    }
    let at = now()
    let plan = policy.locationUpdate(
      coordinate: GeoCoordinate(latitude: fix.latitude, longitude: fix.longitude),
      speed: fix.speedMetersPerSecond,
      at: at.timeIntervalSinceReferenceDate
    )
    state.tier = policy.currentTier
    self.policy = policy
    guard let plan else { return }
    await execute(plan, at: at)
  }

  /// Sends one probe cycle: a zero-hop discover, and a directed trace to the freshest
  /// known repeater. Either half alone is still a useful cycle — a first visit has no
  /// targets yet and leans on discover to find some.
  private func execute(_ plan: SamplingPolicy.ProbePlan, at: Date) async {
    state.probesSent += 1
    probedTierCells.insert(plan.tierCell)

    await sendDiscover(for: plan)
    if let target = freshestTarget() {
      await sendTrace(to: target, for: plan, at: at)
    }
  }

  private func sendDiscover(for plan: SamplingPolicy.ProbePlan) async {
    do {
      let tag = try await session.sendNodeDiscoverRequest(
        filter: SignalBarsPolicy().discoverFilter,
        prefixOnly: true,
        tag: nil,
        since: nil
      )
      probeCells[tag] = plan.baseCell
      state.discoversSent += 1
    } catch {
      logger.error("Survey discover failed: \(error.localizedDescription)")
    }
  }

  private func sendTrace(to target: MapperProbeTarget, for plan: SamplingPolicy.ProbePlan, at: Date) async {
    let tag = UInt32.random(in: 0..<UInt32.max)
    let path = SignalBarsObservation.probePath(forPublicKey: target.publicKey, pathHashMode: pathHashMode)

    tracker.register(tag: tag, target: target.id, now: at, timeoutMs: probeTimeoutMs)
    probeCells[tag] = plan.baseCell

    do {
      let sent = try await session.sendTrace(tag: tag, authCode: nil, flags: pathHashMode, path: path)
      probeTimeoutMs = Int(sent.suggestedTimeoutMs)
      tracker.retime(tag: tag, timeoutMs: probeTimeoutMs)
      state.tracesSent += 1
    } catch {
      _ = tracker.claim(tag: tag)
      probeCells.removeValue(forKey: tag)
      logger.error("Survey trace to \(target.id.hex) failed: \(error.localizedDescription)")
    }
  }

  /// The target a trace is worth spending on: the one heard most recently, because a
  /// repeater that answered moments ago is the one most likely in range of *this* cell.
  private func freshestTarget() -> MapperProbeTarget? {
    targets.values.max { lhs, rhs in
      (lhs.lastHeard ?? .distantPast) < (rhs.lastHeard ?? .distantPast)
    }
  }

  private func sweepExpired() {
    let lost = tracker.expired(now: now())
    guard !lost.isEmpty else { return }
    state.probesLost += lost.count
    for probe in lost {
      probeCells.removeValue(forKey: probe.tag)
    }
  }

  // MARK: - Event ingest

  /// Folds one device event. Exposed for tests, which script events directly.
  func ingest(_ event: MeshEvent) async {
    switch event {
    case let .discoverResponse(response):
      await ingestDiscoverResponse(response)
    case let .rxLogData(log):
      guard let reply = SignalBarsObservation.probeReply(from: log) else { return }
      await ingestProbeReply(reply, log: log)
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

    // The response echoes the request's tag as four little-endian bytes.
    let credited = creditCell(forTag: response.tag.readUInt32LE(at: 0))
    await sink.ingestProbeResult(MapperProbeResult(
      repeaterID: id,
      rxSnr: response.snr,
      txSnr: response.snrIn,
      rssi: response.rssi,
      hopCount: 1,
      at: at
    ))
    recordSample(in: credited)
  }

  /// A trace reply came back: our probe's tag, the SNR we measured for the reply, and —
  /// when the reply carries it — the SNR the repeater measured for our probe.
  private func ingestProbeReply(_ reply: RepeaterProbeReply, log: ParsedRxLogData) async {
    guard state.isRunning else { return }
    guard let probe = tracker.claim(tag: reply.tag) else { return }
    state.traceRepliesHeard += 1

    let credited = creditCell(forTag: reply.tag)
    await sink.ingestProbeResult(MapperProbeResult(
      repeaterID: probe.target,
      rxSnr: reply.localSnr,
      txSnr: reply.remoteSnr,
      rssi: log.rssi,
      hopCount: decodePathLen(log.pathLength).map { Swift.max(1, $0.hopCount) } ?? 1,
      at: now()
    ))
    recordSample(in: credited)
  }

  /// The cell a reply's novelty credit belongs to — the one its probe was planned for,
  /// falling back to nothing when the tag is not ours.
  private func creditCell(forTag tag: UInt32) -> H3Cell? {
    probeCells.removeValue(forKey: tag)
  }

  private func recordSample(in cell: H3Cell?) {
    guard let cell, var policy else { return }
    policy.recordSample(in: cell)
    self.policy = policy
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

  /// Marks cells with fresh local coverage as already sampled, so the session spends its
  /// budget on the blank parts of the map (§2.4). "Fresh" reads the same day window at
  /// exact-day precision — local data never leaves the device, so no coarsening applies.
  private func skipFreshCells(tuning: MapperTuning, at: Date) async {
    guard let store, tuning.communityFreshnessDays > 0, var policy else { return }
    let fromDay = MapperDayKey.key(for: at.addingTimeInterval(-Double(tuning.communityFreshnessDays) * 86400))
    let toDay = MapperDayKey.key(for: at)
    guard let rows = try? await store.fetchMapperCellObservations(fromDay: fromDay, toDay: toDay) else {
      return
    }
    for cell in rows.compactMap(\.cell) {
      policy.recordSample(in: cell)
    }
    self.policy = policy
  }

  /// A fix the probe loop may plan against: present, not known-moved-away-from, and
  /// inside the flat age budget. The full gate — displacement scaling, accuracy, anchor
  /// discs — runs where it matters, in the capture engine as each result folds.
  private func usableFix() async -> MapperFix? {
    guard let fix = await fixProvider.latestFix() else { return nil }
    guard !fix.movedSinceCapture else { return nil }
    guard now().timeIntervalSince(fix.timestamp) <= tuningProvider.tuning.fixMaxAgeSeconds else {
      return nil
    }
    return fix
  }

  // MARK: - Policy mapping

  /// How the mapper's §2.5 constants become a `SamplingPolicy` configuration.
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
    return config
  }

  /// How often the loop re-evaluates position against the policy. Fine-grained enough to
  /// catch a walking-pace cell crossing; the policy's own cadence and budget do the real
  /// rate limiting.
  static let loopInterval: Duration = .seconds(2)

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

/// One probe result, ready to fold: what a repeater and our radio measured of the two
/// link legs from the cell the user is standing in.
///
/// Carries the repeater at ``NodeHexID`` width, never a full public key — the stored
/// observation is only entitled to what a packet's path would reveal
/// (`SurveySample.RepeaterSighting`).
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
  public let at: Date

  public init(
    repeaterID: NodeHexID?,
    rxSnr: Double?,
    txSnr: Double?,
    rssi: Int?,
    hopCount: Int?,
    at: Date
  ) {
    self.repeaterID = repeaterID
    self.rxSnr = rxSnr
    self.txSnr = txSnr
    self.rssi = rssi
    self.hopCount = hopCount
    self.at = at
  }
}

/// Where probe results fold. ``SignalMapperCaptureEngine`` is the production conformer:
/// active samples pass its fix gate and anchor exclusion exactly as passive packets do,
/// and land in the same `(cell, day)` rows with their `activePacketCount` and TX-leg
/// aggregates set.
public protocol MapperActiveSampleSink: Actor {
  func ingestProbeResult(_ result: MapperProbeResult) async
}
