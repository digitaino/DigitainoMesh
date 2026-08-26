import Foundation
import MC1Services

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
  /// Default off. The toggle is reachable in release builds — it ships in the Signal Mapper
  /// tool's own screen, and the DEBUG settings panel is a second door onto the same flag —
  /// so the wiring below is live code on every build, not a debug affordance. Nothing here
  /// transmits on the mesh in any case; automatic mode is purely passive.
  func wireSignalMapper(services: ServiceContainer) {
    // Re-wiring replaces the capture stack a running survey folds into, so the survey
    // ends here whichever branch follows — folding into a replaced engine would silently
    // lose its tail. (The teardown branch repeats this for the paths that skip us.)
    if let probe = signalMapperProbeEngine {
      signalMapperProbeEngine = nil
      Task { await probe.stopSession() }
    }
    surveySessionOwnsCaptureStack = false

    let previousTransition = signalMapperStartTask
    previousTransition?.cancel()

    guard MapperTuningStore().isCaptureEnabled else {
      tearDownSignalMapper()
      return
    }

    let tuning = MapperTuningStore()
    let fixes = MapperFixCache.live(
      locationService: locationService,
      movementHints: services.movementHintRelay,
      tuning: tuning
    )
    let engine = SignalMapperCaptureEngine(
      source: services.rxLogService,
      txHeardSource: services.heardRepeatsService,
      ackSource: services.messageService,
      store: services.dataStore,
      fixProvider: fixes,
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
      await engine.start()
    }

    // Capture only sees the phone move if something is classifying motion. Never prompts
    // from here: connecting a radio is not consent to a Motion & Fitness dialog, and on an
    // auto-reconnect it would land over the launch screen. The prompt belongs to the moment
    // the user turns capture on — see ``requestMapperMovementHintsIfNeeded()``.
    startMovementHintsIfAlreadyPermitted()
  }

  /// Releases everything ``wireSignalMapper(services:)`` set up, flushing whatever the
  /// session had buffered. Safe to call when nothing was started.
  func tearDownSignalMapper() {
    // A survey session cannot outlive the capture stack it folds into — and on a
    // disconnect its radio surface is already dead, so this is a write-off, not a stop
    // the user chose. The completion sheet's numbers are lost; the observations are not.
    if let probe = signalMapperProbeEngine {
      signalMapperProbeEngine = nil
      Task { await probe.stopSession() }
    }
    surveySessionOwnsCaptureStack = false

    let previousTransition = signalMapperStartTask
    previousTransition?.cancel()
    signalMapperStartTask = nil

    guard let engine = signalMapperEngine else {
      signalMapperFixCache = nil
      return
    }
    let fixes = signalMapperFixCache
    signalMapperEngine = nil
    signalMapperFixCache = nil

    signalMapperStartTask = Task {
      await previousTransition?.value
      await engine.stop()
      await fixes?.reset()
    }
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
  }

  // MARK: - Manual survey sessions (M3)

  /// Starts a manual survey session (docs/SIGNAL_MAPPER_V2.md §2.4, §7 "M3").
  ///
  /// A session probes deliberately, so it needs the whole capture stack to fold results
  /// into. With the passive-capture toggle off, the stack is built session-scoped and
  /// torn down again at session end — surveying is not consent to ambient capture, and
  /// ambient capture is not a prerequisite for surveying.
  ///
  /// Returns false when no radio is connected: probes need a session to transmit through.
  @discardableResult
  func startSignalMapperSurvey() async -> Bool {
    guard let services else { return false }
    guard signalMapperProbeEngine == nil else { return true }

    // The prompts belong to this moment: the user just asked to survey, which is exactly
    // when a location or Motion & Fitness dialog is proportionate.
    locationService.requestPermissionIfNeeded()
    requestSurveyMovementHints()

    if signalMapperEngine == nil {
      let tuning = MapperTuningStore()
      let fixes = MapperFixCache.live(
        locationService: locationService,
        movementHints: services.movementHintRelay,
        tuning: tuning
      )
      let engine = SignalMapperCaptureEngine(
        source: services.rxLogService,
        txHeardSource: services.heardRepeatsService,
        ackSource: services.messageService,
        store: services.dataStore,
        fixProvider: fixes,
        movementHints: MovementHintMonitor.authorization == .authorized ? services.movementHintRelay : nil,
        tuningProvider: tuning,
        anchorSeedProvider: tuning
      )
      signalMapperFixCache = fixes
      signalMapperEngine = engine
      surveySessionOwnsCaptureStack = true
      await engine.start()
    }

    guard let engine = signalMapperEngine, let fixes = signalMapperFixCache else { return false }

    let probe = SignalMapperProbeEngine(
      session: services.session,
      sink: engine,
      warmTargets: services.signalBarsEngine,
      store: services.dataStore,
      fixProvider: fixes,
      tuningProvider: MapperTuningStore()
    )
    signalMapperProbeEngine = probe
    await probe.startSession(pathHashMode: connectedDevice?.pathHashMode ?? 0)
    return true
  }

  /// Ends the running survey session, returning its counters for the completion sheet —
  /// or nil when nothing was running.
  func stopSignalMapperSurvey() async -> SignalMapperProbeEngine.SessionSnapshot? {
    guard let probe = signalMapperProbeEngine else { return nil }
    signalMapperProbeEngine = nil
    let summary = await probe.stopSession()

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
    return summary
  }

  /// The session-scoped twin of ``requestMapperMovementHintsIfNeeded()`` — same prompt,
  /// same fallback story, gated on the session rather than the capture toggle.
  private func requestSurveyMovementHints() {
    guard MovementHintMonitor.authorization.canDeliverUpdates else { return }
    guard let services, !movementHintMonitor.isRunning else { return }
    startMovementHints(services: services)
  }
}
