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
