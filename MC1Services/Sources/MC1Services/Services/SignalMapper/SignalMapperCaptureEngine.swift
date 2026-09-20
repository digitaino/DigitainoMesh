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
  /// Send instants of probe transmissions already counted as answered. Survives flushes;
  /// see ``noteAnsweredProbe(at:)``.
  private var answeredProbeSends: Set<Date> = []
  private static let answeredProbeLedgerLimit = 512
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
    answeredProbeSends.removeAll()
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
        pathHashes: Self.pathHashes(pathNodes: entry.pathNodes, hashSize: entry.pathHashSize),
        // §9: the bytes as received, so scope can ingest them and a later tool can
        // re-decode. Foreign payloads are ciphertext here and stay that way.
        rawHex: entry.rawPayload,
        // Nil for a direct-routed packet — the row keeps the path it carried and credits
        // nobody, which is the whole of the §1 attribution rule at the row level.
        repeaterHexID: Self.repeaterSightings(from: entry).last?.id
      ),
      gate: gate
    )
    guard let placed = gate.accepted else { return }
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
      rssi: detail.rssi,
      isFlood: event.isFlood,
      isEcho: true
    )
    await recordRaw(
      MapperRawSampleEvent(
        timestamp: detail.receivedAt,
        kind: .txHeard,
        rxSnr: detail.snr,
        rssi: detail.rssi,
        hopCount: detail.hopCount,
        // The echo's path is both legs of the three-hops case: first hop heard us, last
        // hop is the one we heard. `MessageRepeatDTO` keeps no packet bytes, so there is
        // no `rawHex` to record here.
        pathHashes: Self.pathHashes(pathNodes: detail.pathNodes, hashSize: detail.hashSize),
        repeaterHexID: echoHops.last?.id
      ),
      gate: gate
    )
    guard let placed = gate.accepted else { return }
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
    guard let placed = gate.accepted else { return }
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
    //
    // Only an *accepted* send placement folds. Since 2026-09-04 the probe engine is also
    // handed doubtful placements so its raw rows can carry a cell; those are the aggregate
    // path's version of "no placement", and fall through to the current-fix fallback
    // exactly as a missing one always did.
    let sendPlacement = result.placement.flatMap { $0.outcome == .accepted ? $0 : nil }
    let placed: Placement
    if let sendPlacement {
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
    if sendPlacement != nil, anchors.contains(cell: placed.cell) {
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
    // One discover is answered by every repeater in range, and all of those replies
    // carry the same send-time placement: the cell learns that *one* probe was answered,
    // not six (field report, 2026-08-30). The ledger lives on the engine rather than the
    // pending slot because a flush between two replies to the same probe would otherwise
    // book the transmission twice.
    if let sendPlacement, noteAnsweredProbe(at: sendPlacement.at) {
      slot.aggregate.probesAnswered += 1
    }
    if let rttMs = result.rttMs {
      slot.probeRttMsSum += Double(rttMs)
      slot.probeRttSampleCount += 1
    }
    pending[key] = slot

    state.rxSampleCount += 1
    state.activeSampleCount += 1
    await recordSample(at: placed.at)
  }

  /// Records that the probe transmitted at `sendTime` has been answered, returning true
  /// the first time only.
  ///
  /// Bounded: a long ride sends thousands of probes and the ledger only has to outlive
  /// the window in which replies to one transmission can straddle a store flush, which is
  /// seconds. The oldest half goes when it fills.
  private func noteAnsweredProbe(at sendTime: Date) -> Bool {
    guard answeredProbeSends.insert(sendTime).inserted else { return false }
    if answeredProbeSends.count > Self.answeredProbeLedgerLimit {
      let keep = answeredProbeSends.sorted().suffix(Self.answeredProbeLedgerLimit / 2)
      answeredProbeSends = Set(keep)
    }
    return true
  }

  /// Places a probe transmission at the current fix (data-quality gate only) and books
  /// the attempt into the cell's `probesSent` — the denominator dead-zone rendering
  /// divides by. The aggregate booking respects anchor discs; the returned placement is
  /// handed back regardless, because the raw log and the reply fold both need it and
  /// neither may learn the disc verdict from it.
  ///
  /// A merely doubtful fix (poor accuracy, or older than its own speed allows) is placed
  /// and returned, carrying its ``MapperGateOutcome`` so no reader can mistake it for an
  /// accepted one — the probe engine planned this transmission on the same fix, and a
  /// reply that cannot be placed is a reply that vanishes. The `probesSent` booking above
  /// stays behind the strict gate: the dead-zone denominator must not inherit doubt.
  public func placeProbeAttempt() async -> MapperProbePlacement? {
    guard state.isRunning else { return nil }
    let gate = await qualityGate()
    guard let placed = gate.position, let fix = gate.fix else { return nil }

    if gate.outcome == .accepted, !anchors.contains(cell: placed.cell) {
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
      isStationary: placed.isStationary,
      outcome: gate.outcome
    )
  }

  // MARK: - Fix gate

  /// One fix, graded, with the drops already counted.
  ///
  /// Two placements rather than one, because a fix can be real without being trustworthy:
  ///
  /// - ``position`` is where the fix says we are whenever ``MapperFixGate`` could place it
  ///   at all. A raw row carries this, alongside the outcome that says how sure it is.
  /// - ``accepted`` is the same placement, but only when the strict tests passed too. It is
  ///   the *only* one the `(cell, day)` aggregates, the anchor discs and the dead-zone
  ///   `probesSent` denominator ever see.
  ///
  /// Splitting them is the 2026-09-04 owner decision: a doubtful fix used to place nothing
  /// at all, which lost the reply for ever, and losing the row is the one outcome no later
  /// consumer can undo (the observation table already carries accuracy and fix age for
  /// exactly this filtering — SIGNAL_MAPPER_V3 §2).
  private struct FixGate {
    var position: Placement?
    var fix: MapperFix?
    var outcome: MapperGateOutcome

    var accepted: Placement? {
      outcome == .accepted ? position : nil
    }
  }

  /// Where an observation arriving now belongs *for the aggregate path*, or nil when the fix
  /// policy (§2.2) or the anchor exclusion (§2.7) refuses to place it. The drop is counted
  /// against the reason it failed for.
  private func place() async -> Placement? {
    let gate = await qualityGate()
    guard let placed = gate.accepted else { return nil }
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
  ///
  /// The tests themselves live in ``MapperFixGate`` so the probe engine plans transmissions
  /// on the identical definition; what stays here is the actor's own bookkeeping — the drop
  /// counters and the movement hint the placement carries.
  private func qualityGate() async -> FixGate {
    let at = now()
    let latest = await fixProvider.latestFix()
    let verdict = MapperFixGate.evaluate(fix: latest, at: at, tuning: tuningProvider.tuning)
    switch verdict.outcome {
    case .accepted: break
    case .noFix: state.droppedNoFixCount += 1
    case .staleFix: state.droppedStaleFixCount += 1
    case .inaccurateFix: state.droppedInaccurateFixCount += 1
    case .movedSinceCapture: state.droppedMovedSinceFixCount += 1
    }

    guard let cell = verdict.cell, let coordinate = verdict.coordinate else {
      return FixGate(position: nil, fix: verdict.fix, outcome: verdict.outcome)
    }
    let placement = await Placement(
      cell: cell,
      coordinate: coordinate,
      at: at,
      isStationary: movementHints?.currentMovementHint() == .stationary
    )
    return FixGate(position: placement, fix: verdict.fix, outcome: verdict.outcome)
  }

  /// Populates a raw event's position block from a gate result and hands it to the
  /// session recorder, when one is attached. A rejected fix still contributes what it
  /// knew — the drop reason is analysis data too, and since 2026-09-04 so is the cell,
  /// for every fix real enough to have one.
  private func recordRaw(_ event: MapperRawSampleEvent, gate: FixGate) async {
    guard let rawRecorder else { return }
    var event = event
    if let fix = gate.fix {
      event.setFix(fix, at: event.timestamp)
    }
    event.cellRaw = gate.position?.cell.rawValue
    event.gateOutcome = gate.outcome
    await rawRecorder.record(event)
  }

  /// The speed-scaled age budget, now owned by ``MapperFixGate`` so both engines read one
  /// definition. Kept here as the name the mapper's own call sites and tests already use.
  static func toleratedAgeSeconds(for fix: MapperFix, tuning: MapperTuning) -> TimeInterval {
    MapperFixGate.toleratedAgeSeconds(for: fix, tuning: tuning)
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

  /// The repeaters a packet is evidence about, in path order — CoreScope's capture rule
  /// (docs/SIGNAL_MAPPER_V3.md §1, verified against firmware `Mesh.cpp`).
  ///
  /// Three cases, and the difference between them is the whole correctness of the RX
  /// layer:
  ///
  /// - **Flood, with a path.** Relays *append* their hash as the packet travels, so the
  ///   last entry is the node our radio actually received it from. It gets the SNR and
  ///   RSSI — those numbers describe that one link. Earlier hops are recorded as involved
  ///   with no reading, because the node that measured them was somebody else.
  /// - **Direct-routed, with a path.** Credits **nobody**. A direct packet carries the
  ///   *remaining* route and each forwarder consumes an entry from the front, so what is
  ///   left when it reaches us is the destination side of the route — nodes the packet has
  ///   not visited yet. Reading its last entry as "the repeater we heard" (which this
  ///   engine did until v3) attributes our SNR to a node that never transmitted to us.
  /// - **No path at all.** Nothing relayed it, so we heard the *sender*, and the only
  ///   payload that tells us who the sender is, is an advert — see
  ///   ``advertiserHexID(from:)``. A 0-hop packet of any other type stays anonymous rather
  ///   than being credited to a guess.
  ///
  /// Hash handling goes through ``NodeHexID`` (MIGRATION_PLAN §2.1): no hex strings are
  /// built or compared by hand anywhere in the mapper.
  static func repeaterSightings(from entry: RxLogEntryDTO) -> [SurveySample.RepeaterSighting] {
    let relayed = sightings(
      pathNodes: entry.pathNodes,
      hashSize: entry.pathHashSize,
      snr: entry.snr,
      rssi: entry.rssi,
      isFlood: entry.routeType.isFlood
    )
    if !relayed.isEmpty { return relayed }
    // Empty means either "direct-routed, so nobody is credited" or "no hops at all". Only
    // the second can name the sender.
    guard entry.pathNodes.isEmpty, let sender = advertiserHexID(from: entry) else { return [] }
    return [
      SurveySample.RepeaterSighting(
        id: sender.hex,
        rxSnr: entry.snr,
        txSnr: nil,
        rssi: entry.rssi.map(Double.init)
      )
    ]
  }

  /// The advertiser's hash ID from a 0-hop advert, at the width this packet's path field
  /// was encoded for.
  ///
  /// An advert's payload begins with the advertiser's full 32-byte public key
  /// (`RxLogService` reads the same offset to stamp inbound hop counts). The key is
  /// narrowed to the packet's own hash width so the ID lands in the same key space every
  /// other repeater in the mapper is filed under — a full key here would file the same
  /// node twice, once per representation.
  static func advertiserHexID(from entry: RxLogEntryDTO) -> NodeHexID? {
    guard entry.payloadType == .advert else { return nil }
    guard entry.packetPayload.count >= ProtocolLimits.publicKeySize else { return nil }
    let width = Swift.min(NodeHexID.maxByteWidth, Swift.max(1, entry.pathHashSize))
    return NodeHexID(data: Data(entry.packetPayload.prefix(width)))
  }

  /// A packet's hop hashes in path order, canonical uppercase — what a raw row carries so
  /// the route survives without the packet. Nil when the packet carried no hops.
  static func pathHashes(pathNodes: Data, hashSize: Int) -> [String]? {
    let hops = TrafficHopResolver.hopHashes(pathNodes: pathNodes, hashSize: hashSize)
      .compactMap(NodeHexID.init(data:))
      .map(\.hex)
    return hops.isEmpty ? nil : hops
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
        rssi: detail.rssi,
        isFlood: event.isFlood,
        isEcho: true
      )
    )
  }

  /// - Parameters:
  ///   - isFlood: whether the packet accumulated its path as it travelled. False means the
  ///     path is the remaining route and names nobody we heard (§1) — so no sighting.
  ///   - isEcho: this is one of *our own* packets coming back. An echo is evidence in both
  ///     directions and keeps every hop: the first heard us, the last is the one we heard
  ///     (docs/SIGNAL_MAPPER_V3.md §1, "the three-hops case"). Its route classification is
  ///     about the rebroadcast, not about who is creditable, so the direct rule does not
  ///     apply to it.
  static func sightings(
    pathNodes: Data,
    hashSize: Int,
    snr: Double?,
    rssi: Int?,
    isFlood: Bool,
    isEcho: Bool = false
  ) -> [SurveySample.RepeaterSighting] {
    guard isFlood || isEcho else { return [] }
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
