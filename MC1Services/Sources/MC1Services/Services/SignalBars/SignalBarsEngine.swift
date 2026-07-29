import Foundation
import MeshCore

/// Tracks how well this radio and the repeaters around it hear each other.
///
/// The engine owns one table of repeaters and keeps it current in one of two ways:
///
/// - **Viewer mode** (Digitaino custom firmware): the device runs the measurement engine
///   and the app mirrors its table, read from the signal-bars sync slot on connect and
///   refreshed by push (`syncValue`) or by poll. The app transmits nothing on its own; it
///   only asks the device to measure, so the OLED and the app always agree.
/// - **Engine mode** (stock firmware): the app *is* the engine. It broadcasts discover
///   requests to find repeaters, hears them passively in the RX log, probes them with
///   traces to learn how they hear us, and applies the same smoothing, scoring, backoff and
///   eviction rules the firmware uses.
///
/// Everything the engine depends on is injected and every rule that involves time takes an
/// explicit `now`, so the whole state machine can be driven from a test with a fake clock
/// and a scripted event stream. Hash comparison and name resolution go through
/// ``NodeHexID`` and ``NodeIdentityResolving`` — the engine contains no ad-hoc hex string
/// matching.
///
/// State comes out as ``SignalBarsSnapshot`` values on ``snapshots()``; a SwiftUI façade is
/// a subscription and an assignment.
public actor SignalBarsEngine {
  // MARK: - Configuration

  /// Everything about a run that the caller chooses.
  public struct Configuration: Sendable {
    /// Where the table comes from.
    public var mode: SignalBarsMode
    /// The device's path hash mode (0/1/2 → 1/2/3-byte hashes). Controls both the width of
    /// the IDs the table tracks and the number of key bytes a probe is addressed with.
    public var pathHashMode: UInt8
    /// Cadences and thresholds.
    public var policy: SignalBarsPolicy

    public init(
      mode: SignalBarsMode = .engine,
      pathHashMode: UInt8 = 0,
      policy: SignalBarsPolicy = SignalBarsPolicy()
    ) {
      self.mode = mode
      self.pathHashMode = pathHashMode
      self.policy = policy
    }
  }

  // MARK: - Dependencies

  private let session: any SignalBarsSessionOps & SessionEventStreaming
  private let directory: (any SignalBarsNodeDirectory)?
  private let resolver: any NodeIdentityResolving
  private let movementHints: any MovementHintProvider
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async -> Void
  private let logger = PersistentLogger(subsystem: "com.mc1", category: "SignalBarsEngine")

  // MARK: - State

  private var mode: SignalBarsMode
  private var pathHashMode: UInt8
  private var policy: SignalBarsPolicy
  private var table: SignalBarsTable
  private var tracker = SignalBarsProbeTracker()
  private var watched: WatchedRepeaterState?
  private var isRefreshing = false
  private var rxFlashTick: UInt = 0
  private var txFlashTick: UInt = 0
  /// Repeaters that were heard while unmeasured, and when their reactive probe comes due.
  private var reactiveProbeDueAt: [NodeHexID: Date] = [:]
  private var lastDiscoverProbeAt: Date?
  private var lastNameResolveAt: Date?
  /// The last device table applied, so an unchanged poll result publishes nothing.
  private var lastAppliedBlob: SignalBarsBlob?
  /// Probe timeout, replaced by whatever the device suggests when a probe is sent.
  private var probeTimeoutMs: Int
  private var lastPublished: SignalBarsSnapshot?
  private var eventTask: Task<Void, Never>?
  private var driverTask: Task<Void, Never>?
  private nonisolated let broadcaster = EventBroadcaster<SignalBarsSnapshot>()

  // MARK: - Lifecycle

  /// - Parameters:
  ///   - session: The narrow set of radio operations the engine needs, plus the event
  ///     stream it listens on.
  ///   - directory: Candidate nodes for name resolution. `nil` leaves names unresolved.
  ///   - resolver: Hash → node resolution. Defaults to the app's standard resolver.
  ///   - movementHints: Phone motion, which shortens probe cadence when moving. Defaults to
  ///     "always stationary"; the CoreMotion-backed provider lives in the app target.
  ///   - configuration: Mode, path hash mode and policy.
  ///   - now: The clock. Injected so nothing in the engine calls `Date()`.
  ///   - sleep: How the engine waits between cycles. Injected so tests run instantly.
  public init(
    session: any SignalBarsSessionOps & SessionEventStreaming,
    directory: (any SignalBarsNodeDirectory)? = nil,
    resolver: any NodeIdentityResolving = NodeIdentityResolver(),
    movementHints: any MovementHintProvider = StationaryMovementHintProvider(),
    configuration: Configuration = Configuration(),
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.session = session
    self.directory = directory
    self.resolver = resolver
    self.movementHints = movementHints
    self.now = now
    self.sleep = sleep
    mode = configuration.mode
    pathHashMode = configuration.pathHashMode
    policy = configuration.policy
    table = SignalBarsTable(policy: configuration.policy)
    probeTimeoutMs = configuration.policy.defaultProbeTimeoutMs
  }

  /// Begins tracking: subscribes to device events and starts the mode's own loop.
  ///
  /// In viewer mode the device's table is read once up front so the UI has something
  /// immediately, then kept current by push and poll. In engine mode the discover/probe
  /// round-robin starts. Calling this again restarts both.
  public func start(mode: SignalBarsMode? = nil, pathHashMode: UInt8? = nil) {
    if let mode { self.mode = mode }
    if let pathHashMode { self.pathHashMode = pathHashMode }
    logger.info("Starting in \(String(describing: self.mode)) mode, pathHashMode=\(self.pathHashMode)")

    eventTask?.cancel()
    eventTask = Task { [weak self] in
      guard let self else { return }
      let events = await self.session.events(filter: SignalBarsObservation.eventFilter)
      for await event in events {
        if Task.isCancelled { break }
        await self.ingest(event)
      }
    }

    driverTask?.cancel()
    driverTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { break }
        let wait = await self.runCycle()
        await self.sleepQuietly(wait)
      }
    }
  }

  /// Stops tracking and drops all state. Subscribers stay subscribed and receive the empty
  /// snapshot, so a façade that outlives a connection resets rather than freezes.
  public func stop() {
    eventTask?.cancel()
    eventTask = nil
    driverTask?.cancel()
    driverTask = nil

    table = SignalBarsTable(policy: policy)
    tracker.cancelAll()
    reactiveProbeDueAt.removeAll()
    lastDiscoverProbeAt = nil
    lastNameResolveAt = nil
    lastAppliedBlob = nil
    isRefreshing = false
    watched = nil
    probeTimeoutMs = policy.defaultProbeTimeoutMs
    publish()
    logger.info("Stopped")
  }

  /// Ends every ``snapshots()`` subscriber's loop. Called on container teardown.
  public nonisolated func finishSnapshots() {
    broadcaster.finish()
  }

  deinit {
    eventTask?.cancel()
    driverTask?.cancel()
  }

  // MARK: - Output

  /// A fresh stream of state snapshots. Registration is synchronous, so a snapshot
  /// published immediately afterwards is never missed.
  public nonisolated func snapshots() -> AsyncStream<SignalBarsSnapshot> {
    broadcaster.subscribe(bufferingPolicy: .bufferingNewest(8))
  }

  /// The current state, for a façade's initial value.
  public func currentSnapshot() -> SignalBarsSnapshot {
    makeSnapshot()
  }

  // MARK: - Settings

  /// Updates the device's path hash mode when the user changes it at runtime.
  public func setPathHashMode(_ mode: UInt8) {
    pathHashMode = mode
  }

  /// Sets the age past which rows are hidden from the display list, or `nil` to show
  /// everything. This is a display filter only — the device's table is untouched.
  public func setStaleHideThreshold(_ threshold: TimeInterval?) {
    policy.staleHideThreshold = threshold
    table.policy = policy
    publish()
  }

  /// Watches a repeater for range testing, or clears the watch with `nil`.
  ///
  /// Matching uses the bidirectional prefix rule, so a watch set on a 1-byte hash still
  /// fires for the same node heard at a wider one.
  public func watchRepeater(_ id: NodeHexID?) {
    watched = id.map { WatchedRepeaterState(id: $0) }
    publish()
  }

  /// Hides one repeater from the display list until the radio hears it again.
  ///
  /// Local-only: in viewer mode the device's table and OLED are untouched, so the entry
  /// reappears on its own the moment a fresher sighting arrives.
  public func dismissRepeater(_ id: NodeHexID) {
    table.dismiss(id, now: now())
    publish()
  }

  /// Hides every currently-stale row in one action.
  public func clearStaleRepeaters() {
    table.clearStale(now: now())
    publish()
  }

  // MARK: - User-initiated measurement

  /// Finds repeaters and measures them.
  ///
  /// Viewer mode asks the device to run its discovery scan and lets its auto-ping measure
  /// what it finds; engine mode runs the app's own discover + ping-all.
  public func startProbe() async {
    switch mode {
    case .viewer:
      guard !isRefreshing else { return }
      isRefreshing = true
      publish()
      await trigger(.discoveryProbe)
      await sleepQuietly(policy.discoveryScanSettleDelay)
      await pollDeviceTable()
      isRefreshing = false
      publish()
    case .engine:
      await refreshAll()
    }
  }

  /// Re-measures one repeater, or all of them when `target` is `nil`.
  ///
  /// Works in both modes: viewer asks the device (one RF ping, originated by the radio),
  /// engine probes directly.
  public func requestRefresh(target: NodeHexID? = nil) async {
    switch mode {
    case .viewer:
      if let target {
        table.markProbeSent(target, now: now())
      }
      await trigger(.refresh(target: target))
      await sleepQuietly(policy.deviceProbeSettleDelay)
      await pollDeviceTable()
    case .engine:
      guard let target else {
        await refreshAll()
        return
      }
      guard let repeater = table[target], repeater.publicKey != nil else { return }
      await sendProbe(to: repeater)
    }
  }

  /// Manual full refresh: discover, then probe every repeater in turn with the policy's
  /// minimum spacing. Failure counts are reset first so every link gets another chance.
  public func refreshAll() async {
    if mode == .viewer {
      await requestRefresh()
      return
    }
    guard !isRefreshing else { return }
    isRefreshing = true
    table.beginFullRefresh()
    publish()

    await sendDiscoverProbe()
    await sleepQuietly(policy.discoverSettleDelay)

    for repeater in table.repeaters where repeater.publicKey != nil {
      guard !Task.isCancelled else { break }
      await sendProbe(to: repeater)
      await sleepQuietly(policy.minProbeSpacing)
    }

    // Give the last probes their timeout, then write off whatever never answered.
    await sleepQuietly(.milliseconds(probeTimeoutMs))
    expireProbes(now: now())
    table.failOutstandingMeasurements()
    isRefreshing = false
    publish()
  }

  // MARK: - Event ingest

  /// Folds one device event into the table. Exposed for tests, which script events
  /// directly rather than through a live session.
  func ingest(_ event: MeshEvent) async {
    switch event {
    case let .syncValue(id, blob) where id == .signalBars:
      await apply(blobData: blob)

    case let .discoverResponse(response) where mode == .engine:
      guard let sighting = SignalBarsObservation.sighting(
        from: response,
        pathHashMode: pathHashMode
      ) else { return }
      await observe(sighting)

    case let .rxLogData(log) where mode == .engine:
      if let reply = SignalBarsObservation.probeReply(from: log) {
        handleProbeReply(reply)
      } else if let sighting = SignalBarsObservation.passiveSighting(from: log) {
        await observe(sighting)
      }

    default:
      // Viewer mode mirrors the device verbatim: sightings the app could derive itself are
      // deliberately ignored so the two tables never disagree.
      break
    }
  }

  private func observe(_ sighting: RepeaterSighting) async {
    let at = now()
    let change = table.ingest(sighting, now: at)
    rxFlashTick &+= 1

    if change.bestChanged, !isRefreshing, let best = table.best {
      // A new best link is worth measuring now rather than at its next slot.
      table.prioritizeNextProbe(for: best.id)
    }

    noteWatchedSighting(
      id: change.id,
      rxSnr: sighting.rxSnr,
      txSnr: sighting.txSnr ?? table[change.id]?.txSnr,
      at: at
    )

    if let repeater = table[change.id],
       policy.shouldProbeReactively(repeater, now: at),
       !tracker.hasProbe(for: repeater.id),
       reactiveProbeDueAt[repeater.id] == nil {
      reactiveProbeDueAt[repeater.id] = at.addingTimeInterval(policy.reactiveTriggerDelay)
    }

    await resolveNames(now: at)
    publish()
  }

  private func handleProbeReply(_ reply: RepeaterProbeReply) {
    guard let probe = tracker.claim(tag: reply.tag) else { return }
    let at = now()
    let rttMs = Int((at.timeIntervalSince(probe.sentAt) * 1000).rounded())
    let bestChanged = table.applyProbeReply(reply, to: probe.target, rttMs: rttMs, now: at)
    rxFlashTick &+= 1
    if bestChanged, !isRefreshing, let best = table.best {
      table.prioritizeNextProbe(for: best.id)
    }
    noteWatchedSighting(
      id: probe.target,
      rxSnr: reply.localSnr,
      txSnr: reply.remoteSnr,
      at: at
    )
    publish()
  }

  /// Applies a device table, whether it arrived by push or by poll.
  ///
  /// An identical table is still merged (it is idempotent) but publishes nothing and
  /// bumps no counters, so the poll loop cannot make the UI flash every five seconds.
  private func apply(blobData: Data) async {
    guard let blob = SignalBarsBlob(decoding: blobData) else {
      logger.error("Ignoring undecodable signal-bars blob (\(blobData.count) bytes)")
      return
    }
    let at = now()
    let isUnchanged = blob == lastAppliedBlob
    lastAppliedBlob = blob
    table.apply(blob, now: at)

    if !isUnchanged {
      rxFlashTick &+= 1
      if let watched, let entry = blob.entries.first(where: { entry in
        NodeHexID(entry.hexID).map { $0.identifiesSameNode(as: watched.id) } ?? false
      }) {
        noteWatchedSighting(
          id: NodeHexID(entry.hexID) ?? watched.id,
          rxSnr: entry.rxSnr ?? 0,
          txSnr: entry.txSnr,
          at: at
        )
      }
    }

    await resolveNames(now: at)
    publish()
  }

  private func noteWatchedSighting(id: NodeHexID, rxSnr: Double?, txSnr: Double?, at: Date) {
    guard var watched, watched.id.identifiesSameNode(as: id) else { return }
    watched.heardCount += 1
    watched.lastHeardAt = at
    watched.rxSnr = rxSnr
    watched.txSnr = txSnr ?? watched.txSnr
    self.watched = watched
  }

  // MARK: - Cycles

  /// One pass of the mode's loop. Returns how long to wait before the next one.
  /// Exposed for tests, which step the engine instead of letting it run free.
  @discardableResult
  func runCycle() async -> Duration {
    let at = now()
    expireProbes(now: at)

    switch mode {
    case .viewer:
      await pollDeviceTable()
      publish()
      return policy.viewerPollInterval

    case .engine:
      let removed = table.pruneStale(now: at)
      if !removed.isEmpty {
        tracker.cancelProbes(for: removed)
        for id in removed {
          reactiveProbeDueAt.removeValue(forKey: id)
        }
        logger.info("Pruned \(removed.count) stale repeater(s)")
      }

      if lastDiscoverProbeAt.map({ at.timeIntervalSince($0) >= policy.discoverProbeInterval }) ?? true {
        await sendDiscoverProbe()
      }

      await resolveNames(now: at)

      guard !isRefreshing, let target = await nextProbeTarget(now: at) else {
        publish()
        return policy.idleCycleInterval
      }
      await sendProbe(to: target)
      return policy.minProbeSpacing
    }
  }

  /// Writes off probes whose deadline passed. Exposed for tests, which move the clock
  /// forward and call this rather than waiting out a real timeout.
  func expireProbes(now at: Date) {
    let lost = tracker.expired(now: at)
    guard !lost.isEmpty else { return }
    for probe in lost {
      table.markProbeFailed(probe.target)
      logger.debug("Probe timeout for \(probe.target.hex)")
    }
    publish()
  }

  /// Reads the device's table. Viewer mode's initial fetch and its poll fallback both go
  /// through here; pushes take the same path via ``ingest(_:)``.
  func pollDeviceTable() async {
    do {
      let data = try await session.getSync(.signalBars)
      await apply(blobData: data)
    } catch {
      logger.debug("Signal-bars fetch failed: \(error.localizedDescription)")
    }
  }

  private func nextProbeTarget(now at: Date) async -> RepeaterSignal? {
    // Reactive triggers first: a repeater we just heard but have never measured is the
    // biggest gap in the table, and the delay it was scheduled with has now elapsed.
    let due = reactiveProbeDueAt
      .filter { $0.value <= at }
      .sorted { $0.value < $1.value }
    for (id, _) in due {
      reactiveProbeDueAt.removeValue(forKey: id)
      guard let repeater = table[id],
            repeater.publicKey != nil,
            policy.shouldProbeReactively(repeater, now: at),
            !tracker.hasProbe(for: repeater.id) else { continue }
      return repeater
    }

    let movement = await movementHints.currentMovementHint()
    return policy.nextProbeTarget(among: table.repeaters, now: at, movement: movement)
  }

  // MARK: - Transmission

  /// Sends a trace probe and registers it for correlation. The reply — or the deadline —
  /// resolves it later; nothing here waits.
  private func sendProbe(to repeater: RepeaterSignal) async {
    guard let publicKey = repeater.publicKey else { return }
    let tag = UInt32.random(in: 0..<UInt32.max)
    let path = SignalBarsObservation.probePath(forPublicKey: publicKey, pathHashMode: pathHashMode)
    let sentAt = now()

    table.markProbeSent(repeater.id, now: sentAt)
    tracker.register(tag: tag, target: repeater.id, now: sentAt, timeoutMs: probeTimeoutMs)
    publish()

    do {
      let sent = try await session.sendTrace(
        tag: tag,
        authCode: nil,
        flags: pathHashMode,
        path: path
      )
      probeTimeoutMs = Int(sent.suggestedTimeoutMs)
      // Re-register with the device's own timeout, keeping the original send time.
      tracker.register(
        tag: tag,
        target: repeater.id,
        now: sentAt,
        timeoutMs: Int(sent.suggestedTimeoutMs)
      )
      txFlashTick &+= 1
    } catch {
      _ = tracker.claim(tag: tag)
      table.markProbeFailed(repeater.id)
      logger.error("Probe to \(repeater.id.hex) failed: \(error.localizedDescription)")
    }
    publish()
  }

  private func sendDiscoverProbe() async {
    lastDiscoverProbeAt = now()
    do {
      _ = try await session.sendNodeDiscoverRequest(
        filter: policy.discoverFilter,
        prefixOnly: true,
        tag: nil,
        since: nil
      )
      txFlashTick &+= 1
    } catch {
      logger.error("Discover probe failed: \(error.localizedDescription)")
    }
  }

  /// Writes a ``SignalBarsTrigger`` to the device's signal-bars slot.
  private func trigger(_ trigger: SignalBarsTrigger) async {
    txFlashTick &+= 1
    publish()
    do {
      try await session.setSync(.signalBars, payload: trigger.payload)
    } catch {
      logger.error("Signal-bars trigger \(trigger.action.rawValue) failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Names

  /// Resolves display names for entries that have none, throttled so a busy mesh does not
  /// re-read the node directory on every packet.
  private func resolveNames(now at: Date) async {
    guard let directory else { return }
    guard table.repeaters.contains(where: { $0.name == nil }) else { return }
    if let last = lastNameResolveAt, at.timeIntervalSince(last) < policy.nameResolveThrottle {
      return
    }
    lastNameResolveAt = at

    let candidates = await directory.resolvableNodes()
    guard !candidates.isEmpty else { return }
    for repeater in table.repeaters where repeater.name == nil {
      // A row that holds the full public key (discover responses store it) is exactly
      // identified — name it from the key and never fall back to hash guessing, which
      // ranks by advert recency and can pick a different node on a prefix collision.
      if let publicKey = repeater.publicKey,
         let exact = candidates.first(where: { $0.publicKey == publicKey }) {
        table.setName(exact.resolvableName, for: repeater.id)
        continue
      }
      guard let match = resolver.bestMatch(for: repeater.id, among: candidates, now: at) else {
        continue
      }
      table.setName(match.resolvableName, for: repeater.id)
    }
  }

  /// The node pool changed (contact added, renamed, removed): every resolved name is a
  /// candidate for being wrong now, so drop them all and re-resolve immediately rather
  /// than letting stale names ride until the row happens to be recreated.
  public func nodePoolDidChange() async {
    table.clearNames()
    lastNameResolveAt = nil
    await resolveNames(now: now())
    publish()
  }

  // MARK: - Publishing

  private func makeSnapshot() -> SignalBarsSnapshot {
    let at = now()
    return SignalBarsSnapshot(
      mode: mode,
      repeaters: table.repeaters,
      displayRepeaters: table.displayed(now: at),
      isRefreshing: isRefreshing,
      hasStaleRepeaters: table.hasStale(now: at),
      watched: watched,
      rxFlashTick: rxFlashTick,
      txFlashTick: txFlashTick
    )
  }

  private func publish() {
    let snapshot = makeSnapshot()
    guard snapshot != lastPublished else { return }
    lastPublished = snapshot
    broadcaster.yield(snapshot)
  }

  private func sleepQuietly(_ duration: Duration) async {
    await sleep(duration)
  }
}
