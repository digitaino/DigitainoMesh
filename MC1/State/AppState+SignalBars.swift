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
    signalBarsStartTask?.cancel()

    guard let device = connectedDevice,
          DevicePreferenceStore().isSignalBarsEnabled(deviceID: device.id) else {
      tearDownSignalBars()
      return
    }

    signalBarsStartTask = Task { [weak self] in
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
      await repeaterSignals.attach(to: services.signalBarsEngine)
      startMovementHints(services: services)
    }
  }

  /// Releases everything `wireSignalBars(services:)` set up. Safe to call when nothing was
  /// started.
  func tearDownSignalBars() {
    signalBarsStartTask?.cancel()
    signalBarsStartTask = nil
    movementHintMonitor.stop()
    repeaterSignals.detach()
  }

  /// Starts CoreMotion classification and routes each reading to both consumers.
  ///
  /// The relay feeds the app's own probe scheduler; the sync write tells the radio, which
  /// runs its own cadence in viewer mode. Both are fed unconditionally because both
  /// de-duplicate: `MotionHintService` is inert unless the radio advertises the slot, and
  /// the relay is free to update. That is simpler — and less fragile across a mode change —
  /// than legacy's either/or routing.
  ///
  /// This is also the moment Motion & Fitness is requested. It is deliberately not at
  /// launch: the permission is only meaningful once signal tracking is actually running.
  private func startMovementHints(services: ServiceContainer) {
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
}
