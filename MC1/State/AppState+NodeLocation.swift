import CoreLocation
import Foundation
import MC1Services

// MARK: - Stale Node Location

extension AppState {
  /// Re-runs the stale-node-location check against the live connection and phone fix.
  ///
  /// Called from two places, because the check needs both halves and either can land first:
  /// `onDeviceSynced` (the radio reached ready and its `SelfInfo` location is mirrored into
  /// the Device row) and `ContentView`'s observation of `locationService.currentLocation`.
  /// When the radio has a location but the phone's fix is missing or too old to write, this
  /// also asks for one, so the second half actually arrives instead of waiting for some other
  /// screen to request it.
  func evaluateNodeLocationStaleness() {
    let needsFreshFix = nodeLocationPrompt.evaluate(
      device: connectedDevice,
      phoneLocation: locationService.currentLocation
    )

    if needsFreshFix {
      locationService.requestLocation()
    }
  }

  /// "Update": writes the captured phone coordinate to the radio through the same verified
  /// path the Settings location editor uses, so the Device row refreshes from the returned
  /// `SelfInfo` via the settings event stream. Failure is non-fatal — an error haptic, and
  /// the offer returns on the next connect because no snooze is recorded.
  ///
  /// The prompt comes in as an argument rather than off `nodeLocationPrompt`: dismissal runs
  /// the alert binding's setter, which clears `pending`, and SwiftUI does that before this task
  /// body starts — so `pending` is always nil by the time the write would read it.
  func applyPendingNodeLocation(_ pending: PendingNodeLocationPrompt) async {
    guard NodeLocationStalenessPolicy.isFixFresh(pending.fixDate, now: Date()) else {
      logger.warning("Node location update skipped — the captured phone fix aged out")
      nodeLocationPrompt.markUpdateFailed()
      return
    }
    guard let settingsService = services?.settingsService else {
      logger.warning("Node location update skipped — no settings service")
      nodeLocationPrompt.markUpdateFailed()
      return
    }

    do {
      _ = try await settingsService.setLocationVerified(
        latitude: pending.latitude,
        longitude: pending.longitude
      )
      logger.info("Node location updated from phone fix after staleness prompt")
      nodeLocationPrompt.markUpdateSucceeded()
    } catch {
      logger.warning("Node location update failed: \(error.localizedDescription)")
      nodeLocationPrompt.markUpdateFailed()
    }
  }
}
