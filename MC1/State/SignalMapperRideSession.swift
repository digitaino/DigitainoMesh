import Foundation
import MapperRawLog
import MC1Services
import SurveyKit

/// One survey *run*, owned by AppState — the identity that survives BLE rewires.
///
/// Engine instances are cattle: `wireSignalMapper` rebuilds the capture stack on every
/// reconnect and the probe engine dies with it, taking its in-memory counters along.
/// The run is the thing the user started and will stop — it accumulates counters across
/// engine generations, keeps the focus selection, owns the raw-log recorder, and is
/// what the HUD, the screen-awake flag and continuous location key off
/// (docs/ACTIVE_SURVEY_M3_5.md §2.6; review C4/3a: an HUD keyed to an engine instance
/// dies permanently at the first BLE blip, and the screen sleeps mid-ride).
@MainActor
@Observable
final class SignalMapperRideSession {
  let runID: UUID
  let startedAt: Date
  /// The lock-on selection, reapplied to every engine generation.
  var focusTargets: [MapperProbeTarget]

  /// Counter totals from engine generations that have already been torn down.
  private(set) var carried = SignalMapperProbeEngine.SessionSnapshot()
  /// The live engine's snapshot, updated by the HUD's stream subscription.
  var liveSnapshot: SignalMapperProbeEngine.SessionSnapshot?
  /// Bumped whenever a new probe engine is built, so the HUD's `.task(id:)` re-subscribes
  /// to the new engine's stream instead of parking on a finished one forever.
  private(set) var engineGeneration = 0
  /// False while the radio is away — the HUD shows "radio disconnected" instead of
  /// silently vanishing (the moment the user is most likely to glance at it).
  var isRadioConnected = true

  /// What the capture engine is doing with this ride's fixes *lately*.
  ///
  /// The engine's own counters are cumulative since it started, and it restarts on every BLE
  /// rewire, so neither number answers "is the GPS bad right now". This holds the delta over
  /// the last sampling window instead, plus how long the current unbroken run of refusals
  /// has lasted — which is the question the strip's chip asks and the only form of it that
  /// clears itself once the fix comes good.
  ///
  /// It exists because the failure it describes was invisible: a ride can count probes and
  /// replies on the strip while every row they produce is refused a position, and the rider's
  /// only clue was an empty cell card (field report with screenshot, 2026-09-04).
  struct CaptureFixHealth: Equatable, Sendable {
    /// Refusals in the window, by reason. Deliberately not merged with the probe engine's
    /// `skippedNoFixCount`: that one counts probe *cycles* not planned, these count
    /// observations not placed, and the strip's long-standing >20 threshold is tuned for it.
    var droppedNoFixCount = 0
    var droppedStaleFixCount = 0
    var droppedInaccurateFixCount = 0
    /// Observations the gate accepted in the same window — the denominator that makes the
    /// refusals mean something.
    var acceptedCount = 0

    /// The first and the most recent refusal in the current unbroken run, or nil while the
    /// fixes are fine. The span between them is the verdict below.
    ///
    /// A span rather than a count of windows because a window is however long it was
    /// between two probe-engine snapshots, and that engine yields on every reply and every
    /// send as well as on its 2 s tick — "five windows" is anywhere between one second and
    /// ten. Measured refusal-to-refusal rather than against the wall clock so that silence
    /// cannot age a single bad fix into an alarm: with the radio hearing nothing, one
    /// refusal twenty seconds ago is still one refusal.
    var rejectingSince: Date?
    var lastRefusalAt: Date?
    /// Whether anything in the current run was a fix the engine actually had and refused,
    /// as opposed to no fix at all. Carried across the run rather than read off the last
    /// window, so the strip does not change its mind about which problem it is describing
    /// while one run is still going.
    var runRefusedAFixItHad = false

    /// How long a run of refusals has to last before it is a fact about the ride rather
    /// than the gap between two packets.
    static let sustainedRejectionSeconds: TimeInterval = 10

    var droppedCount: Int {
      droppedNoFixCount + droppedStaleFixCount + droppedInaccurateFixCount
    }

    /// A fix exists and is simply not good enough — the state that used to lose rows
    /// silently, and the one worth naming differently from "no fix at all".
    var isQualityRejection: Bool {
      runRefusedAFixItHad
    }

    /// Everything the radio heard went unplaced, and has done for long enough to be worth
    /// saying out loud.
    ///
    /// One-sided on purpose: a window that placed anything at all is a working ride with
    /// some noise in it. Sustained on purpose too — a single window holding one refusal and
    /// no accepts is an ordinary two seconds of a bursty mesh, and deciding on that window
    /// alone made the strip's chip and the card's empty-state reason blink on and off
    /// through a perfectly healthy ride, which is the opposite of the alarm they were added
    /// to be.
    var isRejectingFixes: Bool {
      guard let rejectingSince, let lastRefusalAt else { return false }
      return lastRefusalAt.timeIntervalSince(rejectingSince) >= Self.sustainedRejectionSeconds
    }

    /// This window's own verdict, folded onto the run so far.
    ///
    /// A window that placed something ends the run outright; one that refused everything it
    /// was given extends it; one where nothing arrived at all leaves it exactly as it was,
    /// because a quiet radio is not evidence about the fix in either direction.
    func folding(_ window: CaptureFixHealth, at now: Date) -> CaptureFixHealth {
      var next = window
      if window.acceptedCount > 0 {
        next.rejectingSince = nil
        next.lastRefusalAt = nil
        next.runRefusedAFixItHad = false
      } else if window.droppedCount > 0 {
        next.rejectingSince = rejectingSince ?? now
        next.lastRefusalAt = now
        next.runRefusedAFixItHad =
          runRefusedAFixItHad || window.droppedStaleFixCount + window.droppedInaccurateFixCount > 0
      } else {
        next.rejectingSince = rejectingSince
        next.lastRefusalAt = lastRefusalAt
        next.runRefusedAFixItHad = runRefusedAFixItHad
      }
      return next
    }
  }

  private(set) var captureFixHealth = CaptureFixHealth()
  private var lastCaptureSnapshot: SignalMapperCaptureEngine.Snapshot?

  /// Folds a fresh capture snapshot in as a delta against the previous one.
  ///
  /// A counter that went *down* means the engine was rebuilt (a BLE rewire hands the ride a
  /// new one), so the baseline is re-seeded and that window contributes nothing rather than
  /// a negative.
  func noteCaptureSnapshot(_ snapshot: SignalMapperCaptureEngine.Snapshot, at now: Date = Date()) {
    defer { lastCaptureSnapshot = snapshot }
    guard let previous = lastCaptureSnapshot,
          snapshot.droppedNoFixCount >= previous.droppedNoFixCount,
          snapshot.droppedStaleFixCount >= previous.droppedStaleFixCount,
          snapshot.droppedInaccurateFixCount >= previous.droppedInaccurateFixCount,
          snapshot.sampleCount >= previous.sampleCount else {
      captureFixHealth = CaptureFixHealth()
      return
    }
    let window = CaptureFixHealth(
      droppedNoFixCount: snapshot.droppedNoFixCount - previous.droppedNoFixCount,
      droppedStaleFixCount: snapshot.droppedStaleFixCount - previous.droppedStaleFixCount,
      droppedInaccurateFixCount: snapshot.droppedInaccurateFixCount - previous.droppedInaccurateFixCount,
      acceptedCount: snapshot.sampleCount - previous.sampleCount
    )
    captureFixHealth = captureFixHealth.folding(window, at: now)
  }

  /// The raw ride log for this run. Optional: raw-log storage failing must never block
  /// a survey — the aggregates still capture.
  let recorder: MapperRawSampleRecorder?

  /// Highest reply distance per focus target, meters — the ride's actual answer,
  /// computed app-side where contact positions live.
  var maxReplyDistanceMeters: [NodeHexID: Double] = [:]

  /// Display metadata for focus targets, captured at pick time from the contact table:
  /// the engine deliberately knows nothing about names or advertised positions.
  struct FocusMeta: Equatable {
    var name: String?
    var latitude: Double?
    var longitude: Double?
  }

  var focusMeta: [NodeHexID: FocusMeta] = [:]

  /// Name/position lookup for EVERY known repeater at the session's hash width, keyed
  /// by `NodeHexID.hex`. Loaded once per session from the contact/discovered pools so
  /// the automatic "hearing now" blocks can name responders the user never picked.
  var repeaterDirectory: [String: FocusMeta] = [:]

  func meta(for id: NodeHexID) -> FocusMeta? {
    focusMeta[id] ?? repeaterDirectory[id.hex]
  }

  /// The focus cadence captured once at session start, so the HUD never touches
  /// `UserDefaults` from its render path (UI review S3: the old per-render
  /// `MapperTuningStore()` materialised 22 defaults keys at 1 Hz for hours).
  var focusProbeInterval: TimeInterval = 20

  /// Reads the radio's confirmed TX power right now, dBm. Injected by AppState so
  /// breadcrumbs can stamp it — adaptive power re-steps mid-ride and uplink SNRs
  /// without a power context are not comparable (UI review S3 data-integrity).
  var currentTxPowerDbm: @MainActor () -> Int8? = { nil }

  private var breadcrumbTask: Task<Void, Never>?
  /// When the app last went inactive/background; drives the auto-end rule.
  private var backgroundedAt: Date?
  private var accumulatedBackground: TimeInterval = 0

  init(
    runID: UUID,
    startedAt: Date,
    focusTargets: [MapperProbeTarget],
    recorder: MapperRawSampleRecorder?
  ) {
    self.runID = runID
    self.startedAt = startedAt
    self.focusTargets = focusTargets
    self.recorder = recorder
  }

  /// Totals across all generations: what the HUD and the completion sheet show.
  var displayTotals: SignalMapperProbeEngine.SessionSnapshot {
    guard let live = liveSnapshot else { return carried }
    var total = live
    total.probesSent += carried.probesSent
    total.tracesSent += carried.tracesSent
    total.discoversSent += carried.discoversSent
    total.traceRepliesHeard += carried.traceRepliesHeard
    total.discoverResponsesHeard += carried.discoverResponsesHeard
    total.probesLost += carried.probesLost
    total.probesAbandoned += carried.probesAbandoned
    total.cellsProbed += carried.cellsProbed
    total.skippedNoFixCount += carried.skippedNoFixCount
    total.startedAt = startedAt
    total.isRunning = true
    return total
  }

  /// Folds a dying engine generation's counters into the carried totals.
  func accumulate(_ snapshot: SignalMapperProbeEngine.SessionSnapshot) {
    carried.probesSent += snapshot.probesSent
    carried.tracesSent += snapshot.tracesSent
    carried.discoversSent += snapshot.discoversSent
    carried.traceRepliesHeard += snapshot.traceRepliesHeard
    carried.discoverResponsesHeard += snapshot.discoverResponsesHeard
    carried.probesLost += snapshot.probesLost
    carried.probesAbandoned += snapshot.probesAbandoned
    carried.cellsProbed += snapshot.cellsProbed
    carried.skippedNoFixCount += snapshot.skippedNoFixCount
    liveSnapshot = nil
  }

  func noteNewEngineGeneration() {
    engineGeneration += 1
  }

  // MARK: - Breadcrumbs

  /// Emits a position marker every 2 s independent of radio traffic, so a BLE gap is
  /// distinguishable from a dead zone in the raw log — and so the ride draws a polyline
  /// even where the mesh was silent (review 3c).
  func startBreadcrumbs(fixProvider: MapperFixRouter) {
    guard breadcrumbTask == nil, let recorder else { return }
    breadcrumbTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard let self, !Task.isCancelled else { return }
        guard let fix = await fixProvider.latestFix() else { continue }
        let at = Date()
        var event = MapperRawSampleEvent(timestamp: at, kind: .breadcrumb, gateOutcome: .accepted)
        event.setFix(fix, at: at)
        event.txPowerDbm = self.currentTxPowerDbm()
        event.cellRaw = SurveyGrid.cell(
          containing: GeoCoordinate(latitude: fix.latitude, longitude: fix.longitude)
        )?.rawValue
        await recorder.record(event)
      }
    }
  }

  func stopBreadcrumbs() {
    breadcrumbTask?.cancel()
    breadcrumbTask = nil
  }

  func recordRadioLink(up: Bool) {
    guard let recorder else { return }
    let event = MapperRawSampleEvent(timestamp: Date(), kind: up ? .radioLinkUp : .radioLinkDown)
    Task { await recorder.record(event) }
  }

  // MARK: - Auto-end bookkeeping

  /// A forgotten stop must not turn the ride log into an ambient home log (review F6):
  /// the run auto-ends after 10 cumulative background minutes or a 6 h hard cap.
  static let backgroundBudget: TimeInterval = 10 * 60
  static let hardCap: TimeInterval = 6 * 60 * 60

  /// Tracks scene transitions; returns true when the run should end now.
  func noteScenePhase(isActive: Bool, at: Date = Date()) -> Bool {
    if isActive {
      if let backgroundedAt {
        accumulatedBackground += at.timeIntervalSince(backgroundedAt)
        self.backgroundedAt = nil
      }
    } else if backgroundedAt == nil {
      backgroundedAt = at
    }
    return shouldAutoEnd(at: at)
  }

  func shouldAutoEnd(at: Date = Date()) -> Bool {
    var background = accumulatedBackground
    if let backgroundedAt {
      background += at.timeIntervalSince(backgroundedAt)
    }
    return background >= Self.backgroundBudget || at.timeIntervalSince(startedAt) >= Self.hardCap
  }
}
