import Foundation
import MapperRawLog
import MC1Services
import SurveyKit
import UIKit

// MARK: - Signal Mapper Wiring

extension AppState {
  /// Brings passive coverage capture up for a connection, or tears it down when the M0
  /// debug flag is off (docs/SIGNAL_MAPPER_V2.md §2.3, §7 "M0").
  ///
  /// The engine is per-connection because its RX source is: `RxLogService` is rebuilt with
  /// every `ServiceContainer`, and a stream from a torn-down container never yields again.
  /// The *store* is not per-connection — cells belong to places, not to radios — so
  /// reconnecting continues folding into the same rows.
  ///
  /// A running survey **run** is not ended here (M3.5 §2.6): the probe engine of the old
  /// stack is stopped and its counters folded into the run, and once the new stack is up
  /// the probe session restarts against it silently — no prompts, same runID, same focus.
  func wireSignalMapper(services: ServiceContainer) {
    // Re-wiring replaces the capture stack a running survey folds into, so the current
    // probe engine ends here whichever branch follows — folding into a replaced engine
    // would silently lose its tail. The run itself survives.
    suspendProbeEngineForRewire()

    let previousTransition = signalMapperStartTask
    previousTransition?.cancel()

    guard MapperTuningStore().isCaptureEnabled || signalMapperRideSession != nil else {
      tearDownSignalMapper()
      return
    }

    let tuning = MapperTuningStore()
    let fixes = MapperFixCache.live(
      locationService: locationService,
      movementHints: services.movementHintRelay,
      tuning: tuning
    )
    let router = mapperFixRouter()
    let engine = SignalMapperCaptureEngine(
      source: services.rxLogService,
      txHeardSource: services.heardRepeatsService,
      ackSource: services.messageService,
      store: services.dataStore,
      fixProvider: router,
      // Passed only when something is genuinely classifying motion. An unauthorized relay
      // reports `.stationary` forever, and handing that to the engine would mark every
      // observation as dwell and eventually declare the user's whole commute an anchor —
      // so "we don't know" is passed as nil and the anchor policy falls back to volume.
      movementHints: MovementHintMonitor.authorization == .authorized ? services.movementHintRelay : nil,
      tuningProvider: tuning,
      anchorSeedProvider: tuning
    )
    signalMapperFixCache = fixes
    signalMapperEngine = engine

    signalMapperStartTask = Task {
      // Wait out whichever transition was already in flight, so a stop queued a moment ago
      // cannot land after the start it was meant to precede.
      await previousTransition?.value
      guard !Task.isCancelled else { return }
      await router.setFallback(fixes)
      await engine.start()
      if let session = self.signalMapperRideSession {
        await engine.setRawRecorder(session.recorder)
      }
    }

    // Capture only sees the phone move if something is classifying motion. Never prompts
    // from here: connecting a radio is not consent to a Motion & Fitness dialog, and on an
    // auto-reconnect it would land over the launch screen. The prompt belongs to the moment
    // the user turns capture on — see ``requestMapperMovementHintsIfNeeded()``.
    startMovementHintsIfAlreadyPermitted()

    // A run that lost its radio resumes probing against the new stack — silently, with no
    // permission prompts (review C4b: a TCC dialog at 25 km/h, over an in-flight popover
    // transition, is both unusable and the iOS 26 crash family).
    if signalMapperRideSession != nil {
      resumeProbeSessionAfterRewire(services: services)
    }
  }

  /// Releases everything ``wireSignalMapper(services:)`` set up, flushing whatever the
  /// session had buffered. Safe to call when nothing was started.
  ///
  /// A running run stays open (§2.6): its probe engine is written off into the run's
  /// carried counters and the HUD switches to "radio disconnected". The run ends only at
  /// explicit stop or auto-end — riding out of BLE range must not end the ride.
  func tearDownSignalMapper() {
    suspendProbeEngineForRewire()

    let previousTransition = signalMapperStartTask
    previousTransition?.cancel()
    signalMapperStartTask = nil

    guard let engine = signalMapperEngine else {
      signalMapperFixCache = nil
      Task { await signalMapperFixRouter?.setFallback(nil) }
      return
    }
    let fixes = signalMapperFixCache
    let router = signalMapperFixRouter
    signalMapperEngine = nil
    signalMapperFixCache = nil

    signalMapperStartTask = Task {
      await previousTransition?.value
      await engine.stop()
      await fixes?.reset()
      await router?.setFallback(nil)
    }
  }

  /// Stops the current probe engine, folding its counters into the run (when one is
  /// active) so nothing is lost across a rewire. The shared front half of
  /// `wireSignalMapper` and `tearDownSignalMapper`.
  private func suspendProbeEngineForRewire() {
    if let probe = signalMapperProbeEngine {
      signalMapperProbeEngine = nil
      let session = signalMapperRideSession
      Task {
        let final = await probe.stopSession()
        await MainActor.run {
          session?.accumulate(final)
        }
      }
    }
    if let session = signalMapperRideSession, session.isRadioConnected {
      session.isRadioConnected = false
      session.recordRadioLink(up: false)
    }
    surveySessionOwnsCaptureStack = false
  }

  /// Re-runs the wiring so a change to the capture toggle takes effect now rather than at
  /// the next connect.
  func applySignalMapperCaptureSetting() {
    // Before the wiring, so the engine is built with a movement provider if the user grants
    // permission here rather than having to wait for the next connect to see one.
    requestMapperMovementHintsIfNeeded()

    guard let services else {
      tearDownSignalMapper()
      return
    }
    wireSignalMapper(services: services)
  }

  /// Starts movement classification for the mapper, prompting for Motion & Fitness if that
  /// is what it takes.
  ///
  /// The mapper owns this dependency rather than inheriting it. Its movement hints used to
  /// arrive only if the signal-bars feature happened to have asked for the permission
  /// first, which meant a user who enabled coverage capture and never touched signal bars
  /// got a relay stuck on `.stationary` for good: §2.2's "on movement, request a fresh fix"
  /// never fired, and the dwell signal anchor detection reads was uniformly wrong.
  ///
  /// Called when capture is switched on, which is the one moment the prompt is
  /// proportionate — the same rule signal bars applies when the user opens its table.
  /// Declining is survivable: the fix gate's speed-scaled displacement budget needs no
  /// permission, and anchor detection falls back to observation volume.
  func requestMapperMovementHintsIfNeeded() {
    guard MapperTuningStore().isCaptureEnabled else { return }
    guard MovementHintMonitor.authorization.canDeliverUpdates else { return }
    guard let services, !movementHintMonitor.isRunning else { return }
    startMovementHints(services: services)
  }

  /// Whether the mapper still wants movement classification running.
  ///
  /// Read by signal bars' teardown, which shares the one monitor: switching bars off must
  /// not silently take the mapper's hints away with it. A running survey session counts
  /// the same as the capture toggle — its fix gate reads the same hints.
  var signalMapperNeedsMovementHints: Bool {
    MapperTuningStore().isCaptureEnabled || signalMapperProbeEngine != nil
      || signalMapperRideSession != nil
  }

  /// The app-lifetime fix router, created on first use (needs `locationService`, which
  /// outlives every connection).
  func mapperFixRouter() -> MapperFixRouter {
    if let router = signalMapperFixRouter { return router }
    let router = MapperFixRouter(locationService: locationService)
    signalMapperFixRouter = router
    return router
  }

  // MARK: - Survey runs (M3 sessions, M3.5 rides)

  /// Starts a survey run. The only entry point that may show permission prompts — the
  /// user just asked to survey, which is exactly when a location or Motion & Fitness
  /// dialog is proportionate. Everything else (rewire resume) goes through
  /// ``resumeProbeSessionAfterRewire(services:)`` and prompts for nothing.
  ///
  /// Returns false when no radio is connected: probes need a session to transmit through.
  @discardableResult
  func startSignalMapperSurvey(focusTargets: [MapperProbeTarget] = []) async -> Bool {
    guard let services else { return false }
    guard signalMapperRideSession == nil else {
      // Already running: a non-empty selection is a focus update; an argless re-entry
      // (the old UI path) changes nothing.
      if !focusTargets.isEmpty {
        await setSurveyFocusTargets(focusTargets)
      }
      return true
    }

    locationService.requestPermissionIfNeeded()
    requestSurveyMovementHints()

    // The raw ride log. Failing to open it degrades the run to aggregates-only rather
    // than blocking it — but that degradation is loud in the summary sheet.
    let recorder = await makeRawRecorder(focusTargets: focusTargets)
    let session = SignalMapperRideSession(
      runID: recorder?.runID ?? UUID(),
      startedAt: Date(),
      focusTargets: focusTargets,
      recorder: recorder?.recorder
    )
    signalMapperRideSession = session

    // Live location for the whole run — keyed to the run, not the connection (review 3b:
    // the rider is still riding during a BLE drop, and GPS re-acquisition after a
    // restart costs 2–10 s of samples).
    locationService.startContinuousUpdates()
    await mapperFixRouter().setLiveMode(true)
    session.startBreadcrumbs(fixProvider: mapperFixRouter())
    updateMapperIdleTimer()

    // The mapper must not stack its traces on top of signal bars' independent prober
    // (review C3: two uncoordinated schedulers, one duty-cycle budget). The bars table
    // freezes for the ride; `wireSignalBars` restores it at run end.
    signalBarsStartTask = Task { [signalBarsStartTask] in
      await signalBarsStartTask?.value
      await services.signalBarsEngine.stop()
    }

    await startProbeSession(services: services)
    return true
  }

  /// Builds the probe engine against the current stack and starts it. Shared by the
  /// user-initiated start and the silent rewire resume.
  private func startProbeSession(services: ServiceContainer) async {
    guard let session = signalMapperRideSession else { return }

    if signalMapperEngine == nil {
      let tuning = MapperTuningStore()
      let fixes = MapperFixCache.live(
        locationService: locationService,
        movementHints: services.movementHintRelay,
        tuning: tuning
      )
      let router = mapperFixRouter()
      let engine = SignalMapperCaptureEngine(
        source: services.rxLogService,
        txHeardSource: services.heardRepeatsService,
        ackSource: services.messageService,
        store: services.dataStore,
        fixProvider: router,
        movementHints: MovementHintMonitor.authorization == .authorized ? services.movementHintRelay : nil,
        tuningProvider: tuning,
        anchorSeedProvider: tuning
      )
      signalMapperFixCache = fixes
      signalMapperEngine = engine
      surveySessionOwnsCaptureStack = true
      // Chain on the in-flight transition exactly like the ambient path (review C4d: a
      // session-scoped start racing a stopping engine builds two engines flushing into
      // one store).
      let previousTransition = signalMapperStartTask
      signalMapperStartTask = Task {
        await previousTransition?.value
        await router.setFallback(fixes)
        await engine.start()
      }
      await signalMapperStartTask?.value
    }

    guard let engine = signalMapperEngine else { return }
    await engine.setRawRecorder(session.recorder)

    let probe = SignalMapperProbeEngine(
      session: services.session,
      sink: engine,
      warmTargets: services.signalBarsEngine,
      store: services.dataStore,
      fixProvider: mapperFixRouter(),
      tuningProvider: MapperTuningStore(),
      rawRecorder: session.recorder
    )
    signalMapperProbeEngine = probe
    await probe.setFocusTargets(session.focusTargets)
    // A range ride pins the fine tier: at 15–30 km/h the automatic tier flaps across its
    // hysteresis band and sampling density becomes a function of traffic lights.
    await probe.setTierOverride(.fine)
    await probe.startSession(pathHashMode: connectedDevice?.pathHashMode ?? 0)
    session.isRadioConnected = true
    session.noteNewEngineGeneration()
  }

  /// Restarts the probe session after a BLE rewire — silently: no prompts, same run.
  private func resumeProbeSessionAfterRewire(services: ServiceContainer) {
    guard let session = signalMapperRideSession else { return }
    Task {
      await self.signalMapperStartTask?.value
      guard self.signalMapperRideSession === session, self.signalMapperProbeEngine == nil else { return }
      // Signal bars restarted with the connection; put it back to sleep for the ride.
      await services.signalBarsEngine.stop()
      session.recordRadioLink(up: true)
      await self.startProbeSession(services: services)
    }
  }

  /// Ends the running survey run, returning its cumulative counters for the completion
  /// sheet — or nil when nothing was running.
  func stopSignalMapperSurvey() async -> SignalMapperProbeEngine.SessionSnapshot? {
    guard let session = signalMapperRideSession else { return nil }

    if let probe = signalMapperProbeEngine {
      signalMapperProbeEngine = nil
      let final = await probe.stopSession()
      session.accumulate(final)
    }
    signalMapperRideSession = nil

    session.stopBreadcrumbs()
    await mapperFixRouter().setLiveMode(false)
    locationService.stopContinuousUpdates()
    updateMapperIdleTimer()

    await signalMapperEngine?.setRawRecorder(nil)

    var totals = session.carried
    totals.isRunning = false
    totals.startedAt = session.startedAt

    // Close out the raw log: final flush, then stamp the run row.
    if let recorder = session.recorder {
      _ = await recorder.finish()
    }
    if let store = mapperRawLogStore {
      let runID = session.runID
      let carried = session.carried
      try? await store.accumulateCounters(
        runID: runID,
        probesSent: carried.probesSent,
        tracesSent: carried.tracesSent,
        discoversSent: carried.discoversSent,
        repliesHeard: carried.traceRepliesHeard + carried.discoverResponsesHeard,
        probesLost: carried.probesLost,
        cellsProbed: carried.cellsProbed
      )
      try? await store.endRun(runID, at: Date())
    }

    if surveySessionOwnsCaptureStack {
      surveySessionOwnsCaptureStack = false
      // The toggle is still off; the stack existed only for this session. `tearDown`
      // flushes the buffered tail before stopping, so the session's last cells land.
      tearDownSignalMapper()
    } else {
      // Ambient capture keeps running, but the completion sheet reloads the map *now* —
      // without this, the session's last half-minute sits in the buffer until the next
      // scheduled flush and the sheet appears over a map missing its own ending.
      await signalMapperEngine?.flushNow()
    }

    // Wake signal bars back up per its own setting.
    if let services {
      wireSignalBars(services: services)
    }
    return totals
  }

  /// Updates the lock-on selection mid-run.
  func setSurveyFocusTargets(_ targets: [MapperProbeTarget]) async {
    guard let session = signalMapperRideSession else { return }
    session.focusTargets = Array(targets.prefix(SignalMapperProbeEngine.maxFocusTargets))
    await signalMapperProbeEngine?.setFocusTargets(session.focusTargets)
    if let store = mapperRawLogStore {
      try? await store.updateFocusTargets(
        runID: session.runID,
        hexIDs: session.focusTargets.map(\.id.hex)
      )
    }
  }

  /// Screen-awake, owned here and keyed on *run active ∧ scene active* — never on view
  /// visibility: the session outlives the coverage view, and navigating to Chats
  /// mid-ride must not let the screen sleep (review M16). `.inactive` (Control Centre, a
  /// notification banner) keeps it on; only a real background clears it, and the
  /// foreground-only capture story means the run is effectively paused then anyway.
  func updateMapperIdleTimer(scenePhaseIsBackground: Bool = false) {
    let wantAwake = signalMapperRideSession != nil && !scenePhaseIsBackground
      && MapperTuningStore().tuning.rideKeepsScreenAwake
    UIApplication.shared.isIdleTimerDisabled = wantAwake
  }

  /// Scene-phase hook for the run's auto-end rule (review F6): 10 cumulative background
  /// minutes, or the 6 h hard cap, ends the run as if the user had tapped stop.
  func handleRideScenePhaseChange(isActive: Bool) {
    guard let session = signalMapperRideSession else { return }
    updateMapperIdleTimer(scenePhaseIsBackground: !isActive)
    if session.noteScenePhase(isActive: isActive) {
      Task { _ = await stopSignalMapperSurvey() }
    }
  }

  // MARK: - Raw log plumbing

  /// Opens (or reuses) the raw-log store and creates the run row + recorder. Runs the
  /// launch maintenance on first open: orphaned runs get their `endedAt` stamped and
  /// expired runs purge per the retention tuning.
  private func makeRawRecorder(
    focusTargets: [MapperProbeTarget]
  ) async -> (runID: UUID, recorder: MapperRawSampleRecorder)? {
    let store: MapperRawLogStore
    if let existing = mapperRawLogStore {
      store = existing
    } else {
      guard let fresh = try? MapperRawLogStore.live() else { return nil }
      mapperRawLogStore = fresh
      store = fresh
      let tuning = MapperTuningStore().tuning
      _ = try? await fresh.reconcileOrphanRuns(now: Date())
      _ = try? await fresh.purgeExpired(retentionDays: tuning.rawRetentionDays, now: Date())
    }

    let device = connectedDevice
    guard let runID = try? await store.createRun(
      radioID: device?.id,
      frequency: device?.frequency,
      bandwidth: device?.bandwidth,
      spreadingFactor: device?.spreadingFactor,
      codingRate: device?.codingRate,
      txPower: device?.txPower,
      focusTargetHexIDs: focusTargets.map(\.id.hex),
      startedAt: Date()
    ) else { return nil }

    let recorder = MapperRawSampleRecorder(
      store: store,
      runID: runID,
      startingSeq: 0,
      cap: MapperTuningStore().tuning.rawSampleCapPerSession
    )
    return (runID, recorder)
  }

  /// The session-scoped twin of ``requestMapperMovementHintsIfNeeded()`` — same prompt,
  /// same fallback story, gated on the session rather than the capture toggle.
  private func requestSurveyMovementHints() {
    guard MovementHintMonitor.authorization.canDeliverUpdates else { return }
    guard let services, !movementHintMonitor.isRunning else { return }
    startMovementHints(services: services)
  }
}
