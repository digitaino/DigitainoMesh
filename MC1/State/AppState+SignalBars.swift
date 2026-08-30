import CoreLocation
import Foundation
import MC1Services

// MARK: - Signal Bars Wiring

extension AppState {
  /// Brings repeater signal tracking up for a connection, or tears it down when there is
  /// none.
  ///
  /// The firmware probe runs on its own task rather than inline: `listSync` against stock
  /// firmware resolves as a device error quickly, but a radio that has gone quiet takes the
  /// full command timeout, and connection setup must not wait on it. The bars simply appear
  /// once the probe resolves.
  func wireSignalBars(services: ServiceContainer) {
    // `signalBarsStartTask` holds whichever transition is in flight — a start, or the stop the
    // disabled path queues. Each one waits the previous out, so a stop cannot land after the
    // start it was meant to precede and leave the engine down under an attached UI.
    let previousTransition = signalBarsStartTask
    previousTransition?.cancel()

    guard let device = connectedDevice, isSignalBarsEnabled else {
      tearDownSignalBars()
      return
    }

    signalBarsStartTask = Task { [weak self] in
      await previousTransition?.value
      // Viewer when the radio advertises the signal-bars slot (it owns the measurement
      // table and the app only mirrors it, so the OLED and the app always agree); engine
      // otherwise. An inconclusive probe leaves the classification unlatched, so the next
      // connection asks again instead of writing the radio off.
      let mode = await services.syncRegistryProbe.signalBarsMode()
      guard !Task.isCancelled, let self else { return }

      logger.info(
        "Signal bars: \(String(describing: mode)) mode, pathHashMode=\(device.pathHashMode)"
      )
      await services.signalBarsEngine.start(mode: mode, pathHashMode: device.pathHashMode)
      // A reconnect mid-ride, or the per-device toggle being switched on mid-ride, would
      // otherwise restart this engine at full cadence underneath a running survey and
      // quietly defeat the airtime rule (analysis 6.4).
      await services.signalBarsEngine.setSurveyActive(signalMapperRideSession != nil)
      await repeaterSignals.attach(to: services.signalBarsEngine)
      startMovementHintsIfAlreadyPermitted()
      // Seed the engine's reference location with whatever is already known, so names
      // resolved in the background rank by proximity from the start. Nothing is requested
      // here — a connect (often an auto-reconnect at launch) is not a reason to run GPS.
      await refreshSignalBarsReferenceLocation()
    }
  }

  /// Whether the connected radio has repeater tracking turned on — the one source of truth for
  /// the wiring and for the Motion & Fitness prompt the feature is the only consumer of.
  var isSignalBarsEnabled: Bool {
    guard let device = connectedDevice else { return false }
    return DevicePreferenceStore().isSignalBarsEnabled(deviceID: device.id)
  }

  /// Releases everything `wireSignalBars(services:)` set up. Safe to call when nothing was
  /// started.
  func tearDownSignalBars() {
    let previousTransition = signalBarsStartTask
    previousTransition?.cancel()
    signalBarsStartTask = nil
    // The motion monitor is shared, so it stops only when *no* consumer wants it. Signal
    // bars used to be the only one and could stop it unilaterally; the signal mapper reads
    // the same hints now, and switching bars off must not silently blind it.
    if !signalMapperNeedsMovementHints {
      movementHintMonitor.stop()
    }
    repeaterSignals.detach()

    // Detaching the façade only stops the *display*: the engine's own loops keep broadcasting
    // discovers and probing on stock firmware, which is the airtime this setting exists to
    // stop. Idempotent — the container's teardown stops it again on disconnect.
    guard let services else { return }
    signalBarsStartTask = Task {
      // A start still waiting on its firmware probe would otherwise start the engine after
      // this stop. It is cancelled, so it resolves without starting anything.
      await previousTransition?.value
      await services.signalBarsEngine.stop()
    }
  }

  /// Starts movement classification only when it costs nothing to ask.
  ///
  /// Connecting a radio is not consent to a Motion & Fitness prompt, and on an auto-reconnect
  /// it would land over the launch screen. So the connect path starts the monitor only when
  /// permission already exists; when it does not, the hint stays stationary — which merely
  /// means probes run at their base cadence — until the user opens the signal table, or
  /// turns the signal mapper's capture on (`requestMapperMovementHintsIfNeeded()`).
  func startMovementHintsIfAlreadyPermitted() {
    guard MovementHintMonitor.authorization == .authorized else { return }
    guard let services, !movementHintMonitor.isRunning else { return }
    startMovementHints(services: services)
  }

  /// Starts movement classification, prompting for Motion & Fitness if that is what it takes.
  ///
  /// Called when the user opens the repeater signal table: that is a deliberate visit to the
  /// feature the permission serves, which makes it the one moment the prompt is proportionate.
  ///
  /// The table is still reachable with the feature switched off, and then the hint has no
  /// consumer — no app-side probe cadence to shorten, no `motionHint` write the radio wants —
  /// so asking for Motion & Fitness would be asking for nothing.
  func requestMovementHintsIfNeeded() {
    guard isSignalBarsEnabled else { return }
    guard MovementHintMonitor.authorization.canDeliverUpdates else { return }
    guard let services, !movementHintMonitor.isRunning else { return }
    startMovementHints(services: services)
  }

  /// Routes each movement reading to both consumers.
  ///
  /// The relay feeds the app's own probe scheduler; the sync write tells the radio, which
  /// runs its own cadence in viewer mode. Both are fed unconditionally because both
  /// de-duplicate: `MotionHintService` is inert unless the radio advertises the slot, and
  /// the relay is free to update. That is simpler — and less fragile across a mode change —
  /// than legacy's either/or routing.
  ///
  /// Not private: the signal mapper starts the same monitor for its own reasons, and both
  /// features route through this one implementation so there is a single place that decides
  /// what a movement reading is worth.
  func startMovementHints(services: ServiceContainer) {
    // Capture the two actors rather than the container, so the monitor's callback does not
    // pin the whole per-connection service graph until it is torn down.
    let relay = services.movementHintRelay
    let motionHints = services.motionHintService
    movementHintMonitor.start { level in
      Task {
        await relay.update(level)
        await motionHints.push(level)
      }
    }
  }

  /// Tells the engine the device's path hash mode changed under it, so probes are addressed
  /// with the right number of key bytes and the table tracks the right hash width.
  func applyPathHashModeToSignalBars(_ mode: UInt8) {
    Task { [weak self] in
      await self?.repeaterSignals.setPathHashMode(mode)
    }
  }

  /// Pushes the freshest known location into the signal-bars engine, so a hash collision
  /// resolves to the nearest matching repeater rather than merely the most recently
  /// advertised one. When the reference moved enough that proximity could rank
  /// differently, already-resolved names are dropped and re-resolved.
  ///
  /// The phone fix is judged by age (``NodeLocationStalenessPolicy``), not presence:
  /// CoreLocation keeps handing back the last fix it took — one from before a suspend,
  /// from before a flight — and ranking against a place the user left would invert the
  /// very bug proximity fixes, with full geographic confidence. An aged fix is never
  /// pushed: the radio's own position stands in, and with neither the engine keeps
  /// ranking by recency until a fresh fix lands.
  ///
  /// Never prompts: a one-shot fix is requested only when the repeater table asks for it
  /// (`requestingFixIfMissing`) and location permission already exists.
  func refreshSignalBarsReferenceLocation(requestingFixIfMissing: Bool = false) async {
    guard let services, isSignalBarsEnabled else { return }
    let freshPhoneFix = locationService.currentLocation.flatMap { fix in
      NodeLocationStalenessPolicy.isFixFresh(fix.timestamp, now: Date()) ? fix : nil
    }
    if requestingFixIfMissing, freshPhoneFix == nil, locationService.isAuthorized {
      // One-shot request (de-duplicated while in flight); the repeater table re-pushes
      // when the fix lands.
      locationService.requestLocation()
    }

    let reference: CLLocationCoordinate2D? = if let freshPhoneFix {
      freshPhoneFix.coordinate
    } else if let device = connectedDevice, device.hasLocation {
      CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
    } else {
      nil
    }
    guard let reference else { return }

    let moved = await services.referenceLocationRelay.update(ReferenceCoordinate(
      latitude: reference.latitude,
      longitude: reference.longitude
    ))
    if moved {
      await services.signalBarsEngine.referenceLocationDidChange()
    }
  }
}
