import Foundation
import SurveyKit

/// The signal mapper's capture core: mesh activity in, H3 cell-day aggregates out
/// (docs/SIGNAL_MAPPER_V2.md §2.1–2.3).
///
/// Purely passive. It subscribes to three streams the app already runs and never transmits
/// anything on the mesh — the whole automatic mode is "map the traffic we were going to
/// have anyway". Manual mode's probe engine (M3) folds its samples through the same
/// aggregation, which is why the fold lives here rather than in a mode-specific layer.
///
/// The three directions of §2.1, and what each is evidence of:
///
/// - **`rx`** — `RxLogService.entryStream()`. A packet reached us here: downlink coverage.
/// - **`txHeard`** — `HeardRepeatsService.events()`. A repeater rebroadcast *our own*
///   packet and we heard the echo: proof the uplink from here works, which no amount of
///   listening can establish. The SNR on the echo is what we measured of the repeater's
///   rebroadcast, so it lands as the repeater's `rxSnr`; `txSnr` stays reserved for "they
///   told us how well they heard us", which only a trace or discover response carries.
/// - **`ack`** — `MessageService.statusEvents()`. A send from here was acknowledged end to
///   end. Not a packet: an ACK carries no radio measurement, so it folds no SNR, no route
///   and no hop count — only the fact, and the round trip when firmware reported one.
///
/// An echo is deliberately counted twice, once through each of the first two streams: the
/// RX log yields it like any other packet, and the repeat correlation yields it again as a
/// TX-heard fact. They are two different claims about one radio event ("we can hear that
/// repeater from here" and "that repeater can hear us from here"), and the direction
/// counters are what keep the two legible after the fold.
///
/// Three rules shape everything below:
///
/// - **No fix, no observation.** A packet whose location cannot be established within the
///   tuning's age, accuracy and *displacement* limits is dropped, never queued and never
///   guessed. A cell tagged with a stale fix is worse than a missing cell, because it looks
///   like data. Age alone is not enough: a two-minute-old fix is excellent standing still
///   and describes a place two kilometers back on a motorway, which is why ``place()``
///   also rejects a fix the phone is known to have moved away from and scales the age
///   budget by the fix's own reported speed.
/// - **Anchors are never mapped.** Observations inside an exclusion disc
///   (``MapperAnchorPolicy``) are dropped before they fold, and rows that accumulated
///   before a cell was recognised as an anchor are purged. Dwell time, not coverage, is
///   what makes a cell dense, and the dense cells are people's homes.
/// - **Aggregate before storing.** Packets fold into an in-memory `(cell, day)` dictionary
///   and reach the store in batches, so a busy channel costs one write per flush rather
///   than one per packet.
/// - **Everything injected.** The clock, the fix provider, the tuning and the entry source
///   are all parameters, so the whole state machine runs from a test with a scripted
///   stream and a fake clock. Nothing here calls `Date()`.
public actor SignalMapperCaptureEngine {
  /// What the debug panel reads. A value type, so the panel polls it without holding the
  /// actor.
  public struct Snapshot: Sendable, Equatable {
    /// Whether the entry subscription is live.
    public var isRunning: Bool
    /// `(cell, day)` aggregates buffered in memory, not yet flushed.
    public var pendingCellCount: Int
    /// Samples folded since ``start()`` — the honest "how much did this walk capture".
    public var sampleCount: Int
    /// ``sampleCount`` split by direction.
    public var rxSampleCount: Int
    public var txHeardSampleCount: Int
    public var ackSampleCount: Int
    /// Probe results folded via ``ingestProbeResult(_:)`` — a subset of the whole, not a
    /// fourth direction: an active sample also counts as `rx` when it carries a reply.
    public var activeSampleCount: Int
    /// Rows in the store as of the last successful flush.
    public var storedCellCount: Int
    /// Packets seen but not folded, split by why.
    public var droppedNoFixCount: Int
    /// Failed the age budget — either the flat ``MapperTuning/fixMaxAgeSeconds`` or the
    /// tighter one the fix's own speed implies (``MapperTuning/fixMaxDisplacementMeters``).
    public var droppedStaleFixCount: Int
    public var droppedInaccurateFixCount: Int
    /// The fix was fresh and accurate, but the phone is known to have moved since it was
    /// taken, so it no longer describes where the phone is (§2.2).
    public var droppedMovedSinceFixCount: Int
    /// Fell inside an anchor exclusion disc (``MapperAnchorPolicy``).
    public var droppedAnchorCount: Int
    public var duplicateCount: Int
    public var lastFlushAt: Date?

    // MARK: Anchor exclusion

    /// Cells currently recognised as places the user stays.
    public var anchorCount: Int
    /// Res-9 cells the exclusion discs cover — the size of the hole in the map.
    public var excludedCellCount: Int
    /// Stored cells deleted by anchor purges since ``start()``. Non-zero means data that
    /// predated the detection has been cleared, which is the behaviour that matters most on
    /// a phone that has been capturing at home for weeks.
    public var purgedCellCount: Int
    public var lastAnchorRecomputeAt: Date?

    public init(
      isRunning: Bool = false,
      pendingCellCount: Int = 0,
      sampleCount: Int = 0,
      rxSampleCount: Int = 0,
      txHeardSampleCount: Int = 0,
      ackSampleCount: Int = 0,
      activeSampleCount: Int = 0,
      storedCellCount: Int = 0,
      droppedNoFixCount: Int = 0,
      droppedStaleFixCount: Int = 0,
      droppedInaccurateFixCount: Int = 0,
      droppedMovedSinceFixCount: Int = 0,
      droppedAnchorCount: Int = 0,
      duplicateCount: Int = 0,
      lastFlushAt: Date? = nil,
      anchorCount: Int = 0,
      excludedCellCount: Int = 0,
      purgedCellCount: Int = 0,
      lastAnchorRecomputeAt: Date? = nil
    ) {
      self.isRunning = isRunning
      self.pendingCellCount = pendingCellCount
      self.sampleCount = sampleCount
      self.rxSampleCount = rxSampleCount
      self.txHeardSampleCount = txHeardSampleCount
      self.ackSampleCount = ackSampleCount
      self.activeSampleCount = activeSampleCount
      self.storedCellCount = storedCellCount
      self.droppedNoFixCount = droppedNoFixCount
      self.droppedStaleFixCount = droppedStaleFixCount
      self.droppedInaccurateFixCount = droppedInaccurateFixCount
      self.droppedMovedSinceFixCount = droppedMovedSinceFixCount
      self.droppedAnchorCount = droppedAnchorCount
      self.duplicateCount = duplicateCount
      self.lastFlushAt = lastFlushAt
      self.anchorCount = anchorCount
      self.excludedCellCount = excludedCellCount
      self.purgedCellCount = purgedCellCount
      self.lastAnchorRecomputeAt = lastAnchorRecomputeAt
    }

    /// Every packet the engine declined to fold, for the one-line status row.
    public var droppedCount: Int {
      droppedNoFixCount + droppedStaleFixCount + droppedInaccurateFixCount
        + droppedMovedSinceFixCount + droppedAnchorCount + duplicateCount
    }
  }

  /// The in-memory aggregation key. A cell observed either side of UTC midnight is two
  /// rows, because the wire and the store are both day-bucketed (§3.4).
  private struct CellDay: Hashable {
    let cell: H3Cell
    let day: String
  }

  /// One buffered cell-day: the SurveyKit fold, plus the direction bookkeeping SurveyKit
  /// has no concept of. Kept side by side rather than pushed into `AggregatedCell` so the
  /// shared aggregation type stays the same on the app and the server.
  private struct PendingCell {
    var aggregate: AggregatedCell
    var rxCount = 0
    var txHeardCount = 0
    var ackCount = 0
    /// Observations folded while the movement hint said the phone was standing still — the
    /// dwell signal ``MapperAnchorPolicy`` reads back out of the store.
    var stationaryCount = 0
    var rttMsSum = 0.0
    var rttSampleCount = 0
    /// Round trips of *trace probes*, client-measured — a separate ledger from
    /// `rttMsSum`, which holds end-to-end delivery ACKs an order of magnitude slower.
    /// Averaging the two together would mean nothing (M3.5 review M6).
    var probeRttMsSum = 0.0
    var probeRttSampleCount = 0

    init(cell: H3Cell) {
      aggregate = AggregatedCell(cell: cell)
    }

    /// Widens the aggregate's time span for an observation that folds no packet — an ACK,
    /// which would otherwise leave an ack-only row with no first/last-seen at all.
    mutating func note(_ timestamp: Date) {
      aggregate.earliest = Swift.min(aggregate.earliest ?? timestamp, timestamp)
      aggregate.latest = Swift.max(aggregate.latest ?? timestamp, timestamp)
    }

    func observation(day: String) -> MapperCellObservationDTO {
      MapperCellObservationDTO(
        day: day,
        aggregate: aggregate,
        rxCount: rxCount,
        txHeardCount: txHeardCount,
        ackCount: ackCount,
        stationaryObservationCount: stationaryCount,
        rttMsSum: rttMsSum,
        rttSampleCount: rttSampleCount,
        probeRttMsSum: probeRttMsSum,
        probeRttSampleCount: probeRttSampleCount
      )
    }
  }

  /// Where an observation belongs, once the fix gate has agreed to place it.
  private struct Placement {
    let cell: H3Cell
    let coordinate: GeoCoordinate
    let at: Date
    /// Whether the movement hint said the phone was standing still at fold time — the dwell
    /// signal the anchor policy reads back out of the store.
    ///
    /// False when there is no hint provider at all, because "nobody is classifying motion"
    /// is not evidence of standing still and must not accumulate as dwell (see
    /// ``movementHints``). Under-counting dwell only delays an anchor; over-counting it
    /// would erase a commute.
    let isStationary: Bool
  }

  // MARK: - Dependencies

  private let source: any MapperRxEntrySource
  private let txHeardSource: (any MapperTxHeardSource)?
  private let ackSource: (any MapperAckSource)?
  private let store: any MapperCellPersisting
  private let fixProvider: any MapperFixProviding
  /// Motion classification, when something is actually doing it.
  ///
  /// Optional on purpose, and nil is **not** ``MovementHint/stationary``. With Motion &
  /// Fitness declined there is no classifier, and a relay's default reading of "stationary"
  /// is then indistinguishable from a phone genuinely standing still — which would mark
  /// every observation as dwell and eventually declare a user's whole commute an anchor.
  /// Nil means "unknown", nothing is counted as dwell, and anchor detection falls back to
  /// ``MapperTuning/anchorObservationCount``.
  private let movementHints: (any MovementHintProvider)?
  private let tuningProvider: any MapperTuningProviding
  private let anchorSeedProvider: any MapperAnchorSeedProviding
  /// Raw ride-log recorder, session-scoped: set while a recorded survey run is active,
  /// nil otherwise — ambient capture never writes raw rows. Fed *before* anchor policy
  /// and with data-quality outcomes only (docs/ACTIVE_SURVEY_M3_5.md §2.4): dropped
  /// samples are recorded with the reason, because "why a sample was rejected" is
  /// itself ride-analysis data, but disc membership is never expressible.
  private var rawRecorder: (any MapperRawSampleRecording)?
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async -> Void
  private let logger = PersistentLogger(subsystem: "com.mc1", category: "SignalMapperCapture")

  // MARK: - State

  private var pending: [CellDay: PendingCell] = [:]
  private var pendingEntryCount = 0
  private var dedup = MapperPacketDedup()
  private var state = Snapshot()
  private var anchors: MapperAnchorExclusion = .none
  private var flushesSinceAnchorRecompute = 0
  private var entryTask: Task<Void, Never>?
  private var txHeardTask: Task<Void, Never>?
  private var ackTask: Task<Void, Never>?
  private var flushTask: Task<Void, Never>?
  private var anchorTask: Task<Void, Never>?

  // MARK: - Lifecycle

  /// - Parameters:
  ///   - source: Where RX entries come from. `RxLogService` conforms; tests script one.
  ///   - txHeardSource: Where heard repeats come from. `HeardRepeatsService` conforms.
  ///     Nil captures nothing in that direction, which is what an engine wired before the
  ///     service exists should do.
  ///   - ackSource: Where delivery acknowledgements come from. `MessageService` conforms.
  ///   - store: Where flushed aggregates land.
  ///   - fixProvider: Location tagging. Defaults to "never has a fix", so an engine wired
  ///     without one captures nothing rather than capturing something wrong.
  ///   - movementHints: Motion classification, or nil when nothing is classifying. See the
  ///     stored property: nil is "unknown", not "stationary".
  ///   - tuningProvider: Live §2.5 constants.
  ///   - anchorSeedProvider: The per-install seed the exclusion discs are drawn from.
  ///     Defaults to the real store, so an engine wired without one still gets discs unique
  ///     to this install rather than a constant every copy of the app shares.
  ///   - now: The clock, injected so nothing here reads the system time.
  ///   - sleep: How the flush ticker waits. Injected for symmetry with `SignalBarsEngine`;
  ///     the default is cancellable, so ``stop()`` ends the ticker promptly.
  public init(
    source: any MapperRxEntrySource,
    txHeardSource: (any MapperTxHeardSource)? = nil,
    ackSource: (any MapperAckSource)? = nil,
    store: any MapperCellPersisting,
    fixProvider: any MapperFixProviding = NoMapperFixProvider(),
    movementHints: (any MovementHintProvider)? = nil,
    tuningProvider: any MapperTuningProviding = StaticMapperTuningProvider(),
    anchorSeedProvider: any MapperAnchorSeedProviding = MapperTuningStore(),
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.source = source
    self.txHeardSource = txHeardSource
    self.ackSource = ackSource
    self.store = store
    self.fixProvider = fixProvider
    self.movementHints = movementHints
    self.tuningProvider = tuningProvider
    self.anchorSeedProvider = anchorSeedProvider
    self.now = now
    self.sleep = sleep
  }

  deinit {
    entryTask?.cancel()
    txHeardTask?.cancel()
    ackTask?.cancel()
    flushTask?.cancel()
    anchorTask?.cancel()
  }

  /// Subscribes to the RX log and begins folding. Restarts a running engine, which resets
  /// the session counters and the dedup memory but keeps whatever is already in the store.
  public func start() {
    stopTasks()

    dedup.reset()
    pending.removeAll()
    pendingEntryCount = 0
    flushesSinceAnchorRecompute = 0
    state = Snapshot(isRunning: true, lastFlushAt: now())
    logger.info("Signal mapper capture started")

    // Anchors first, on their own task so a store read cannot delay the subscription. Until
    // it lands the exclusion is whatever the previous session left, or empty on a cold
    // start — the window is one store fetch wide, and the purge below cleans up anything
    // that folded into an excluded cell inside it.
    anchorTask = Task { [weak self] in
      await self?.recomputeAnchors()
    }

    let entries = source.entryStream()
    entryTask = Task { [weak self] in
      for await entry in entries {
        if Task.isCancelled { break }
        await self?.ingest(entry)
      }
    }

    if let repeats = txHeardSource?.events() {
      txHeardTask = Task { [weak self] in
        for await event in repeats {
          if Task.isCancelled { break }
          await self?.ingestHeardRepeat(event)
        }
      }
    }

    if let statuses = ackSource?.statusEvents() {
      ackTask = Task { [weak self] in
        for await event in statuses {
          if Task.isCancelled { break }
          await self?.ingestStatus(event)
        }
      }
    }

    flushTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let interval = await self.flushInterval
        await self.sleep(.seconds(interval))
        if Task.isCancelled { return }
        await self.flushIfDue()
      }
    }
  }

  /// Stops folding and writes out whatever is buffered, so a session's tail is not lost.
  public func stop() async {
    guard state.isRunning else { return }
    stopTasks()
    await flush()
    state.isRunning = false
    logger.info("Signal mapper capture stopped: \(self.state.sampleCount) samples, \(self.state.droppedCount) dropped")
  }

  /// Current counters, for the debug panel.
  public func snapshot() -> Snapshot {
    var current = state
    current.pendingCellCount = pending.count
    return current
  }

  /// Forces a flush now. The debug panel's "flush" affordance, and how tests observe the
  /// store without waiting on the ticker.
  public func flushNow() async {
    await flush()
  }

  /// Attaches the raw ride-log recorder (nil detaches). Session-scoped; see the stored
  /// property for the rules.
  public func setRawRecorder(_ recorder: (any MapperRawSampleRecording)?) {
    rawRecorder = recorder
  }

  // MARK: - Ingest

  private func ingest(_ entry: RxLogEntryDTO) async {
    guard state.isRunning else { return }

    // Trace packets never fold on the passive path. Their path bytes are per-hop SNR
    // readings, not hop hashes — splitting them like a route would mint repeater IDs out
    // of signal levels (the same reason `SignalBarsObservation.passiveSighting` excludes
    // them). Our own probe replies lose nothing: the probe engine folds them through
    // ``ingestProbeResult(_:)`` with the real repeater identity and both link legs.
    guard entry.payloadType != .trace else { return }

    // Dedup first: a packet we have already folded carries no new coverage information,
    // whatever the fix situation is now.
    guard dedup.admit(entry.packetHash) else {
      state.duplicateCount += 1
      return
    }

    let gate = await qualityGate()
    await recordRaw(
      MapperRawSampleEvent(
        timestamp: entry.receivedAt,
        kind: .passiveRx,
        rxSnr: entry.snr,
        rssi: entry.rssi,
        hopCount: entry.hopCount,
        routeTypeRaw: entry.routeType.rawValue,
        payloadTypeRaw: entry.payloadType.rawValue,
        repeaterHexID: Self.repeaterSightings(from: entry).last?.id
      ),
      gate: gate
    )
    guard let placed = gate.placement else { return }
    guard !anchors.contains(cell: placed.cell) else {
      state.droppedAnchorCount += 1
      return
    }

    let sample = Self.sample(from: entry, at: placed.coordinate)
    let key = CellDay(cell: placed.cell, day: MapperDayKey.key(for: entry.receivedAt))
    var slot = pending[key] ?? PendingCell(cell: placed.cell)
    CellAggregator.fold(sample, into: &slot.aggregate)
    slot.rxCount += 1
    if placed.isStationary { slot.stationaryCount += 1 }
    pending[key] = slot

    state.rxSampleCount += 1
    await recordSample(at: placed.at)
  }

  /// Folds a heard repeat: a repeater rebroadcast our own packet and we caught the echo.
  ///
  /// The repeat is *not* deduplicated here — `HeardRepeatsService` already refuses to
  /// record two repeats for one RX log entry, so every event that reaches this point is a
  /// distinct echo.
  private func ingestHeardRepeat(_ event: HeardRepeatEvent) async {
    guard state.isRunning else { return }
    let gate = await qualityGate()
    let detail = event.detail
    let echoHops = Self.sightings(
      pathNodes: detail.pathNodes,
      hashSize: detail.hashSize,
      snr: detail.snr,
      rssi: detail.rssi
    )
    await recordRaw(
      MapperRawSampleEvent(
        timestamp: detail.receivedAt,
        kind: .txHeard,
        rxSnr: detail.snr,
        rssi: detail.rssi,
        hopCount: detail.hopCount,
        repeaterHexID: echoHops.last?.id
      ),
      gate: gate
    )
    guard let placed = gate.placement else { return }
    guard !anchors.contains(cell: placed.cell) else {
      state.droppedAnchorCount += 1
      return
    }

    let sample = Self.sample(from: event, at: placed.coordinate)
    let key = CellDay(cell: placed.cell, day: MapperDayKey.key(for: event.detail.receivedAt))
    var slot = pending[key] ?? PendingCell(cell: placed.cell)
    CellAggregator.fold(sample, into: &slot.aggregate)
    slot.txHeardCount += 1
    if placed.isStationary { slot.stationaryCount += 1 }
    pending[key] = slot

    state.txHeardSampleCount += 1
    await recordSample(at: placed.at)
  }

  /// Folds a delivery acknowledgement. Only `.delivered` is an end-to-end ACK — `.sent`
  /// means the radio queued the packet, which says nothing about whether it arrived.
  ///
  /// An ACK is tagged with the fix at *resolution* time, not send time: it is evidence
  /// that a send from where the phone is standing now completed, and a phone that has
  /// moved since the send has no business claiming the old cell.
  private func ingestStatus(_ event: MessageStatusEvent) async {
    guard state.isRunning else { return }
    guard case let .statusResolved(_, status, roundTripTime) = event, status == .delivered else {
      return
    }
    let gate = await qualityGate()
    await recordRaw(
      MapperRawSampleEvent(
        timestamp: now(),
        kind: .ackResolved,
        rttMs: roundTripTime.map(Int.init)
      ),
      gate: gate
    )
    guard let placed = gate.placement else { return }
    guard !anchors.contains(cell: placed.cell) else {
      state.droppedAnchorCount += 1
      return
    }

    let key = CellDay(cell: placed.cell, day: MapperDayKey.key(for: placed.at))
    var slot = pending[key] ?? PendingCell(cell: placed.cell)
    // No `CellAggregator.fold`: an ACK is not a packet. Folding it would invent a route
    // classification and a hop count the event does not carry, and inflate the packet
    // count a cell's signal averages are drawn from.
    slot.note(placed.at)
    slot.ackCount += 1
    if placed.isStationary { slot.stationaryCount += 1 }
    if let roundTripTime {
      slot.rttMsSum += Double(roundTripTime)
      slot.rttSampleCount += 1
    }
    pending[key] = slot

    state.ackSampleCount += 1
    await recordSample(at: placed.at)
  }

  /// Folds one probe result from the manual-mode engine (M3).
  ///
  /// The same gates apply as to a passive packet — fix policy, anchor discs — because an
  /// active sample is not entitled to a laxer placement than a passive one. What differs
  /// is the content: `isActiveProbe` marks it, and the TX leg (`txSnr`, the SNR the
  /// repeater reported for our probe) is populated, which no passive fold can do.
  ///
  /// No dedup: probe replies are correlated one-to-one by trace tag or discover tag in
  /// the probe engine before they get here, and the passive path never folds trace
  /// packets (see ``ingest(_:)``), so a reply cannot arrive twice.
  public func ingestProbeResult(_ result: MapperProbeResult) async {
    guard state.isRunning else { return }

    // Fold against the send-time placement when the probe engine supplied one — at
    // ride speed a reply lands a boundary-straddling couple of seconds downrange of
    // the transmission it answers (M3.5 review M4). The current fix is only a
    // fallback. Anchor policy applies either way: a placement carries no disc verdict.
    let placed: Placement
    if let sendPlacement = result.placement {
      placed = Placement(
        cell: sendPlacement.cell,
        coordinate: GeoCoordinate(
          latitude: sendPlacement.fix.latitude,
          longitude: sendPlacement.fix.longitude
        ),
        at: sendPlacement.at,
        isStationary: sendPlacement.isStationary
      )
    } else if let fallback = await place() {
      placed = fallback
    } else {
      return
    }
    if result.placement != nil, anchors.contains(cell: placed.cell) {
      state.droppedAnchorCount += 1
      return
    }

    let sighting = result.repeaterID.map { id in
      SurveySample.RepeaterSighting(
        id: id.hex,
        rxSnr: result.rxSnr,
        txSnr: result.txSnr,
        rssi: result.rssi.map(Double.init)
      )
    }
    let sample = SurveySample(
      timestamp: result.at,
      coordinate: placed.coordinate,
      snr: result.rxSnr,
      txSnr: result.txSnr,
      rssi: result.rssi.map(Double.init),
      route: .direct,
      isActiveProbe: true,
      hopCount: result.hopCount,
      repeaters: sighting.map { [$0] } ?? []
    )

    let key = CellDay(cell: placed.cell, day: MapperDayKey.key(for: result.at))
    var slot = pending[key] ?? PendingCell(cell: placed.cell)
    CellAggregator.fold(sample, into: &slot.aggregate)
    slot.rxCount += 1
    if placed.isStationary { slot.stationaryCount += 1 }
    if let rttMs = result.rttMs {
      slot.probeRttMsSum += Double(rttMs)
      slot.probeRttSampleCount += 1
    }
    pending[key] = slot

    state.rxSampleCount += 1
    state.activeSampleCount += 1
    await recordSample(at: placed.at)
  }

  /// Places a probe transmission at the current fix (data-quality gate only) and books
  /// the attempt into the cell's `probesSent` — the denominator dead-zone rendering
  /// divides by. The aggregate booking respects anchor discs; the returned placement is
  /// handed back regardless, because the raw log and the reply fold both need it and
  /// neither may learn the disc verdict from it.
  public func placeProbeAttempt() async -> MapperProbePlacement? {
    guard state.isRunning else { return nil }
    let gate = await qualityGate()
    guard let placed = gate.placement, let fix = gate.fix else { return nil }

    if !anchors.contains(cell: placed.cell) {
      let key = CellDay(cell: placed.cell, day: MapperDayKey.key(for: placed.at))
      var slot = pending[key] ?? PendingCell(cell: placed.cell)
      slot.note(placed.at)
      slot.aggregate.probesSent += 1
      pending[key] = slot
    }

    return MapperProbePlacement(
      cell: placed.cell,
      fix: fix,
      at: placed.at,
      isStationary: placed.isStationary
    )
  }

  // MARK: - Fix gate

  /// Where an observation arriving now belongs, or nil when the fix policy (§2.2) or the
  /// anchor exclusion (§2.7) refuses to place it. The drop is counted against the reason it
  /// failed for.
  ///
  /// Four ways a fix can fail, in the order they are cheapest to test:
  ///
  /// 1. **There isn't one.** Nothing to place against.
  /// 2. **The phone moved.** The cache saw a movement hint after this fix was taken, so
  ///    whatever the fix says, the phone is somewhere else now. Age and accuracy both still
  ///    look perfect here, which is exactly why this test has to exist separately.
  /// 3. **It is too old** — either past the flat ``MapperTuning/fixMaxAgeSeconds`` or past
  ///    the shorter budget its own speed implies (see ``toleratedAgeSeconds(for:tuning:)``).
  /// 4. **It is too vague.** Accuracy worse than the tuning allows, or CoreLocation's
  ///    negative sentinel for "not a real fix".
  private func place() async -> Placement? {
    let gate = await qualityGate()
    guard let placed = gate.placement else { return nil }
    // Before the fold, not at upload: an excluded observation must never exist on disk.
    guard !anchors.contains(cell: placed.cell) else {
      state.droppedAnchorCount += 1
      return nil
    }
    return placed
  }

  /// The data-quality half of the gate — everything except anchor policy, which is an
  /// aggregate-path concern and deliberately invisible to the raw recorder
  /// (docs/ACTIVE_SURVEY_M3_5.md §3.2: a per-point in/out label is a solvable oracle
  /// for the disc geometry). Returns the fix it examined either way, so a raw row can
  /// carry the position knowledge that existed even for a rejected sample.
  private func qualityGate() async -> (placement: Placement?, fix: MapperFix?, outcome: MapperGateOutcome) {
    let tuning = tuningProvider.tuning
    guard let fix = await fixProvider.latestFix() else {
      state.droppedNoFixCount += 1
      return (nil, nil, .noFix)
    }

    guard !fix.movedSinceCapture else {
      state.droppedMovedSinceFixCount += 1
      return (nil, fix, .movedSinceCapture)
    }

    let at = now()
    guard at.timeIntervalSince(fix.timestamp) <= Self.toleratedAgeSeconds(for: fix, tuning: tuning) else {
      state.droppedStaleFixCount += 1
      return (nil, fix, .staleFix)
    }
    // A negative accuracy is CoreLocation's "this is not a real fix" sentinel, so it fails
    // the same test as an accuracy that is merely too poor.
    guard fix.horizontalAccuracyMeters >= 0,
          fix.horizontalAccuracyMeters <= tuning.fixMaxAccuracyMeters else {
      state.droppedInaccurateFixCount += 1
      return (nil, fix, .inaccurateFix)
    }

    let coordinate = GeoCoordinate(latitude: fix.latitude, longitude: fix.longitude)
    guard let cell = SurveyGrid.cell(containing: coordinate) else {
      state.droppedNoFixCount += 1
      return (nil, fix, .noFix)
    }

    let placement = await Placement(
      cell: cell,
      coordinate: coordinate,
      at: at,
      isStationary: movementHints?.currentMovementHint() == .stationary
    )
    return (placement, fix, .accepted)
  }

  /// Populates a raw event's position block from a gate result and hands it to the
  /// session recorder, when one is attached. A rejected fix still contributes what it
  /// knew — the drop reason is analysis data too.
  private func recordRaw(
    _ event: MapperRawSampleEvent,
    gate: (placement: Placement?, fix: MapperFix?, outcome: MapperGateOutcome)
  ) async {
    guard let rawRecorder else { return }
    var event = event
    if let fix = gate.fix {
      event.setFix(fix, at: event.timestamp)
    }
    event.cellRaw = gate.placement?.cell.rawValue
    event.gateOutcome = gate.outcome
    await rawRecorder.record(event)
  }

  /// How old a fix may be before it stops describing where the phone is.
  ///
  /// ``MapperTuning/fixMaxAgeSeconds`` is a bound on *time*, and the thing that actually
  /// matters is a bound on *distance*: at 15 m/s a 119-second-old fix passes the age test
  /// and points at a cell nearly two kilometers back down the road. So when the fix reports
  /// its own ground speed — which CoreLocation supplies with the fix and no permission
  /// gates — the budget shrinks to `fixMaxDisplacementMeters / speed`, and the effective
  /// limit is whichever of the two is tighter.
  ///
  /// A stationary phone (speed 0, or a platform that reported none) keeps the full age
  /// budget, which is correct: it is still in the same cell an hour later. This is the half
  /// of the movement rule that survives a declined Motion & Fitness prompt, where the
  /// hint-driven ``MapperFix/movedSinceCapture`` never fires at all.
  static func toleratedAgeSeconds(for fix: MapperFix, tuning: MapperTuning) -> TimeInterval {
    guard let speed = fix.speedMetersPerSecond, speed > 0,
          tuning.fixMaxDisplacementMeters > 0 else {
      return tuning.fixMaxAgeSeconds
    }
    return Swift.min(tuning.fixMaxAgeSeconds, tuning.fixMaxDisplacementMeters / speed)
  }

  /// Counts a folded sample and flushes if either threshold has come due.
  private func recordSample(at: Date) async {
    state.sampleCount += 1
    pendingEntryCount += 1

    let tuning = tuningProvider.tuning
    if pendingEntryCount >= tuning.flushEntryCount {
      await flush()
    } else if let last = state.lastFlushAt,
              at.timeIntervalSince(last) >= tuning.flushIntervalSeconds {
      await flush()
    }
  }

  /// Maps one RX entry onto a SurveyKit sample.
  ///
  /// `isActiveProbe` is always false — everything here is passive. `txSnr` stays nil for a
  /// related reason: it means "the repeater told us how well it heard *us*", which only a
  /// trace or discover response carries.
  static func sample(from entry: RxLogEntryDTO, at coordinate: GeoCoordinate) -> SurveySample {
    SurveySample(
      timestamp: entry.receivedAt,
      coordinate: coordinate,
      snr: entry.snr,
      txSnr: nil,
      rssi: entry.rssi.map(Double.init),
      route: entry.isFlood ? .flood : .direct,
      isActiveProbe: false,
      hopCount: entry.hopCount,
      repeaters: repeaterSightings(from: entry)
    )
  }

  /// The repeaters a packet passed through, in path order.
  ///
  /// Only the *last* hop gets the packet's SNR and RSSI: those numbers describe the link
  /// between that node and our radio, which is the only link this packet measured. Earlier
  /// hops are recorded as involved — they are real evidence the cell can reach them — but
  /// with no signal reading attached, because the hop that heard them was somebody else's.
  ///
  /// Hash handling goes through ``NodeHexID`` (MIGRATION_PLAN §2.1): no hex strings are
  /// built or compared by hand anywhere in the mapper.
  static func repeaterSightings(from entry: RxLogEntryDTO) -> [SurveySample.RepeaterSighting] {
    sightings(
      pathNodes: entry.pathNodes,
      hashSize: entry.pathHashSize,
      snr: entry.snr,
      rssi: entry.rssi
    )
  }

  /// Maps one heard repeat onto a SurveyKit sample.
  ///
  /// Everything on the echo describes the *rebroadcast* we received, so it goes in on the
  /// RX side of the ledger: the packet's SNR/RSSI are our measurement of the repeater, and
  /// the last hop on its path is the repeater that made it. What makes this an uplink fact
  /// is not the numbers but the correlation — this was our own packet coming back — and
  /// that lives in the direction counter, not in the sample.
  ///
  /// `txSnr` is emphatically not used: it is reserved for a repeater *reporting* how well
  /// it heard us, which only a trace or discover response carries (see
  /// ``SurveySample/RepeaterSighting``).
  static func sample(from event: HeardRepeatEvent, at coordinate: GeoCoordinate) -> SurveySample {
    let detail = event.detail
    return SurveySample(
      timestamp: detail.receivedAt,
      coordinate: coordinate,
      snr: detail.snr,
      txSnr: nil,
      rssi: detail.rssi.map(Double.init),
      route: event.isFlood ? .flood : .direct,
      isActiveProbe: false,
      hopCount: detail.hopCount,
      repeaters: sightings(
        pathNodes: detail.pathNodes,
        hashSize: detail.hashSize,
        snr: detail.snr,
        rssi: detail.rssi
      )
    )
  }

  private static func sightings(
    pathNodes: Data,
    hashSize: Int,
    snr: Double?,
    rssi: Int?
  ) -> [SurveySample.RepeaterSighting] {
    let hashes = TrafficHopResolver.hopHashes(pathNodes: pathNodes, hashSize: hashSize)
    let hops = hashes.compactMap(NodeHexID.init(data:))
    guard let lastIndex = hops.indices.last else { return [] }

    return hops.enumerated().map { index, hop in
      let heardDirectly = index == lastIndex
      return SurveySample.RepeaterSighting(
        id: hop.hex,
        rxSnr: heardDirectly ? snr : nil,
        txSnr: nil,
        rssi: heardDirectly ? rssi.map(Double.init) : nil
      )
    }
  }

  // MARK: - Flush

  private var flushInterval: TimeInterval {
    Swift.max(1, tuningProvider.tuning.flushIntervalSeconds)
  }

  /// The ticker's entry point: only writes when there is something to write, so an idle
  /// mesh costs nothing.
  private func flushIfDue() async {
    guard state.isRunning, !pending.isEmpty else { return }
    await flush()
  }

  private func flush() async {
    guard !pending.isEmpty else {
      state.lastFlushAt = now()
      return
    }

    let batch = pending.map { $0.value.observation(day: $0.key.day) }
    do {
      try await store.upsertMapperCellObservations(batch)
      // Cleared only on success: a failed write leaves the aggregate buffered so the next
      // flush retries it rather than silently losing a window of coverage.
      pending.removeAll(keepingCapacity: true)
      pendingEntryCount = 0
      state.lastFlushAt = now()
      state.storedCellCount = await (try? store.countMapperCellObservations()) ?? state.storedCellCount
      await recomputeAnchorsIfDue()
    } catch {
      logger.error("Signal mapper flush failed, keeping \(batch.count) cells buffered: \(error.localizedDescription)")
    }
  }

  // MARK: - Anchors

  /// Re-derives the anchor exclusion from the store, and purges anything already stored
  /// inside it.
  ///
  /// Recomputed on a cadence rather than per packet because anchors move on a scale of
  /// days: a cell crosses ``MapperTuning/anchorMinDistinctDays`` once, and asking the store
  /// to re-derive the whole picture on every fold would be pure cost for an answer that is
  /// the same as last time.
  ///
  /// The purge is the part that matters most today. A cell only becomes *detectable* as
  /// somebody's home after it has accumulated the observations that give it away, so the
  /// rows that triggered detection are on disk by the time it happens. Refusing to capture
  /// from here on would leave the evidence intact and protect nobody who was already using
  /// the feature.
  public func recomputeAnchors() async {
    let tuning = tuningProvider.tuning
    let policy = MapperAnchorPolicy(tuning: tuning, seed: anchorSeedProvider.anchorSeed)

    guard let rows = try? await store.fetchMapperCellObservations() else { return }
    let exclusion = policy.exclusion(for: rows)

    // Everything stored inside a disc goes, whether the disc is new or the row is: a row
    // that landed in an excluded cell during the window before the first recompute is
    // exactly as revealing as one that predates the anchor.
    let excludedStored = exclusion.excluded(from: rows.compactMap(\.cell))
    if !excludedStored.isEmpty {
      do {
        try await store.deleteMapperCellObservations(cellsRaw: Set(excludedStored.map(\.rawValue)))
        state.purgedCellCount += excludedStored.count
        state.storedCellCount = await (try? store.countMapperCellObservations()) ?? state.storedCellCount
        logger.info("Signal mapper purged \(excludedStored.count) cells inside anchor exclusions")
      } catch {
        logger.error("Signal mapper anchor purge failed: \(error.localizedDescription)")
      }
    }

    // Buffered cells too — they have not reached the store yet, and flushing them after
    // raising the disc that covers them would put back exactly what was just deleted.
    pending = pending.filter { !exclusion.contains(cell: $0.key.cell) }

    anchors = exclusion
    flushesSinceAnchorRecompute = 0
    state.anchorCount = exclusion.anchors.count
    state.excludedCellCount = exclusion.coveredCells().count
    state.lastAnchorRecomputeAt = now()
  }

  private func recomputeAnchorsIfDue() async {
    flushesSinceAnchorRecompute += 1
    let every = Swift.max(1, tuningProvider.tuning.anchorRecomputeFlushCount)
    guard flushesSinceAnchorRecompute >= every else { return }
    await recomputeAnchors()
  }

  private func stopTasks() {
    entryTask?.cancel()
    entryTask = nil
    txHeardTask?.cancel()
    txHeardTask = nil
    ackTask?.cancel()
    ackTask = nil
    flushTask?.cancel()
    flushTask = nil
    anchorTask?.cancel()
    anchorTask = nil
  }
}

// MARK: - Entry source

/// Where the capture engine gets RX packets.
///
/// A one-method protocol so the engine can be driven by a scripted stream in tests without
/// standing up a `MeshCoreSession`. `RxLogService` is the production conformer and needs
/// no changes to be one — its `entryStream()` is already the multicast subscription
/// `HeardRepeatsService` and the Live Activity wiring use.
public protocol MapperRxEntrySource: Sendable {
  func entryStream() -> AsyncStream<RxLogEntryDTO>
}

extension RxLogService: MapperRxEntrySource {}

// MARK: - TX-heard source

/// Where the capture engine learns that one of our own packets was rebroadcast.
///
/// `HeardRepeatsService` is the production conformer and needed only a widened event to
/// become one: it already builds the full `MessageRepeatDTO` — path, SNR, RSSI, receive
/// time — before it yields.
public protocol MapperTxHeardSource: Sendable {
  func events() -> AsyncStream<HeardRepeatEvent>
}

extension HeardRepeatsService: MapperTxHeardSource {}

// MARK: - ACK source

/// Where the capture engine learns that a send completed end to end.
///
/// The engine filters the stream down to `.statusResolved(status: .delivered)`; the
/// protocol carries the whole thing so a test can drive it exactly as `MessageService`
/// does, mixed statuses and all.
public protocol MapperAckSource: Sendable {
  func statusEvents() -> AsyncStream<MessageStatusEvent>
}

extension MessageService: MapperAckSource {}

// MARK: - Active sample sink

extension SignalMapperCaptureEngine: MapperActiveSampleSink {}
