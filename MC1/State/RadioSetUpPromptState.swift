import Foundation
import MC1Services

/// The "set this radio up as one of your nodes" question for a radio that just connected.
struct PendingRadioSetUp: Identifiable, Equatable {
  let deviceID: UUID
  /// The node the radio is now, usually the name its firmware gave it, like "480A1F8A".
  let radioName: String
  let radioPublicKey: Data
  /// The saved nodes it can become, most useful first.
  let candidates: [SavedIdentity]

  var id: UUID {
    deviceID
  }
}

enum RadioSetUpPhase: Equatable {
  case asking
  case settingUp(nodeName: String)
  case failed(message: String)
}

/// Who gets asked (docs/RADIO_SWAP.md, flow B). Only a blank radio: one whose node has no
/// history in this app and that no other saved radio carries. Asking an established node would
/// invite overwriting it with a mis-tap.
enum RadioSetUpPolicy {
  static func candidates(
    radioPublicKey: Data,
    radioHasHistory: Bool,
    keyCarriedByAnotherRadio: Bool,
    declinedKey: Data?,
    saved: [SavedIdentity],
    hasRadioRow: (Data) -> Bool
  ) -> [SavedIdentity] {
    guard declinedKey != radioPublicKey, !radioHasHistory, !keyCarriedByAnotherRadio else { return [] }
    // A saved key with no radio row behind it has no history to bring.
    return saved.filter { $0.publicKey != radioPublicKey && hasRadioRow($0.publicKey) }
  }
}

/// Owns the question asked of a blank radio: set it up as one of the user's saved nodes (its key
/// comes from this iPhone), or keep it as the new node it is.
@Observable
@MainActor
final class RadioSetUpPromptState {
  private let store: DevicePreferenceStore

  var pending: PendingRadioSetUp?
  var phase: RadioSetUpPhase = .asking

  init(store: DevicePreferenceStore = DevicePreferenceStore()) {
    self.store = store
  }

  func declinedKey(deviceID: UUID) -> Data? {
    store.radioSetUpDeclinedKey(deviceID: deviceID)
  }

  func offer(_ setUp: PendingRadioSetUp) {
    guard pending == nil, !setUp.candidates.isEmpty else { return }
    phase = .asking
    pending = setUp
  }

  /// "Use as a New Node": not asked again while the radio keeps this key.
  func decline() {
    if let pending {
      store.setRadioSetUpDeclined(publicKey: pending.radioPublicKey, deviceID: pending.deviceID)
    }
    pending = nil
  }

  /// Closed without an answer (a swipe, or after a failure): asked again next connect.
  func close() {
    pending = nil
    phase = .asking
  }

  /// The connection ended; the question no longer applies.
  func endSession() {
    close()
  }
}
