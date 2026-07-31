import CoreLocation
import MC1Services
import SwiftUI

/// The stale-location prompt currently being offered for a radio.
struct PendingNodeLocationPrompt: Identifiable, Equatable {
  /// The radio the prompt is about; also the snooze record's key.
  let deviceID: UUID
  /// How far the radio's configured location is from the phone, in meters.
  let distanceMeters: CLLocationDistance
  /// The phone coordinate the radio would be moved to if the user taps Update. Captured at
  /// prompt time so the write matches the distance the user was shown, even if the phone
  /// has drifted by the time they answer.
  let latitude: Double
  let longitude: Double
  /// When CoreLocation took the captured fix. Re-checked before the write, so an alert that
  /// stood through a suspend cannot commit a coordinate that has since aged out.
  let fixDate: Date

  var id: UUID {
    deviceID
  }
}

/// Owns the one-shot "your radio still says you're 1,400 mi away" prompt: when to offer it,
/// how long a "Not Now" silences it, and the haptic triggers for the update's outcome.
///
/// The decision itself lives in `NodeLocationStalenessPolicy`; this type only supplies the
/// live inputs (connected device, phone fix, persisted snooze) and holds the resulting UI
/// state. Mirrors the `WhatsNewState` idiom: a pure resolver plus a thin stateful shell.
@Observable
@MainActor
final class NodeLocationPromptState {
  private let store: DevicePreferenceStore

  /// The prompt to present, or `nil`. Set by `evaluate`, cleared by every answer path.
  private(set) var pending: PendingNodeLocationPrompt?

  /// `.sensoryFeedback` triggers for the update's outcome.
  private(set) var successTrigger = 0
  private(set) var failureTrigger = 0

  /// Radios already asked during this connect session. A failed update leaves the radio in
  /// here but writes no snooze, so the retry arrives on the next connect rather than as an
  /// immediate re-prompt over the failure.
  private var askedDeviceIDs: Set<UUID> = []

  /// Whether this session has already asked for a fresh phone fix. Unlike "no fix at all",
  /// "the fix is too old" is a condition a new fix can *keep* satisfying — CoreLocation may
  /// answer a request with the same cached fix — and every arrival re-enters `evaluate`
  /// through `ContentView`'s observation. One request per session, so that cannot spin.
  private var didRequestFreshFix = false

  init(store: DevicePreferenceStore = DevicePreferenceStore()) {
    self.store = store
  }

  /// Runs the policy against the current connection and phone fix, presenting the prompt when
  /// it says so. Safe to call repeatedly — it is the connect-ready hook *and* the
  /// location-arrived hook, and whichever lands second is the one that prompts.
  ///
  /// - Returns: whether the caller should ask for a fresh phone fix: the radio has a location
  ///   worth checking, but the fix on hand is missing or too old to decide on. Asked at most
  ///   once per session.
  @discardableResult
  func evaluate(device: DeviceDTO?, phoneLocation: CLLocation?, now: Date = Date()) -> Bool {
    guard pending == nil, let device, !askedDeviceIDs.contains(device.id) else { return false }

    let decision = NodeLocationStalenessPolicy.evaluate(
      deviceLatitude: device.latitude,
      deviceLongitude: device.longitude,
      deviceHasLocation: device.hasLocation,
      phoneLocation: phoneLocation,
      lastSnoozedAt: store.nodeLocationPromptSnoozedAt(deviceID: device.id),
      now: now
    )

    if case .skip(.noPhoneFix) = decision {
      guard !didRequestFreshFix else { return false }
      didRequestFreshFix = true
      return true
    }

    guard let distance = decision.promptDistanceMeters, let phoneLocation else { return false }

    askedDeviceIDs.insert(device.id)
    pending = PendingNodeLocationPrompt(
      deviceID: device.id,
      distanceMeters: distance,
      latitude: phoneLocation.coordinate.latitude,
      longitude: phoneLocation.coordinate.longitude,
      fixDate: phoneLocation.timestamp
    )
    return false
  }

  /// "Not Now": persists the per-device snooze and dismisses.
  func snoozeCurrent(now: Date = Date()) {
    guard let pending else { return }
    store.setNodeLocationPromptSnoozedAt(now, deviceID: pending.deviceID)
    self.pending = nil
  }

  /// Dismissal that records nothing. The session guard still prevents a re-ask until the
  /// next connect.
  func clearPending() {
    pending = nil
  }

  func markUpdateSucceeded() {
    successTrigger += 1
    pending = nil
  }

  /// Non-fatal failure: haptic only, no snooze written, so the next connect re-offers.
  func markUpdateFailed() {
    failureTrigger += 1
    pending = nil
  }

  /// Clears per-connection state on disconnect or device switch.
  func endSession() {
    askedDeviceIDs.removeAll()
    didRequestFreshFix = false
    pending = nil
  }
}
