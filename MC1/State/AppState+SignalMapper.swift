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
  /// not silently take the mapper's hints away with it.
  var signalMapperNeedsMovementHints: Bool {
    MapperTuningStore().isCaptureEnabled
  }
}
