import Foundation
import MC1Services

/// The "Copy to This Radio" offer currently being made for a radio.
struct PendingRadioSwapOffer: Identifiable, Equatable {
  /// The radio that took on the identity; also the key of the "already offered" record.
  let deviceID: UUID
  /// The identity's name as the records hold it, for the intro.
  let identityName: String
  /// The capture date of the profile being offered, recorded once the offer is answered.
  let profileCapturedAt: Date

  var id: UUID {
    deviceID
  }
}

/// Owns the one-time offer, after a radio takes on an identity's history, to copy this phone's
/// records of it onto the radio (docs/RADIO_SWAP.md, owner decision 2: ask the first time each
/// radio is used). The offer is the copy screen itself, so nothing is written until the user
/// confirms there; "Not Now" leaves it in Settings.
@Observable
@MainActor
final class RadioSwapPromptState {
  private let store: DevicePreferenceStore

  /// The offer to present, or `nil`.
  var pending: PendingRadioSwapOffer?

  init(store: DevicePreferenceStore = DevicePreferenceStore()) {
    self.store = store
  }

  /// Offers the copy when the radio's swap guard is armed with a stored profile this radio has
  /// not answered an offer for yet.
  func evaluate(deviceID: UUID, swapGuard: SwapGuard, profile: IdentityProfile?) {
    guard pending == nil, !swapGuard.isEmpty, let profile else { return }
    guard store.radioSwapOfferedProfileDate(deviceID: deviceID) != profile.capturedAt else { return }
    pending = PendingRadioSwapOffer(
      deviceID: deviceID,
      identityName: profile.nodeName,
      profileCapturedAt: profile.capturedAt
    )
  }

  /// The sheet closed, by Not Now, Done or a swipe: this arming has been offered. An offer
  /// the connection ended before showing is not recorded, so it comes back next connect.
  func dismiss() {
    if let pending {
      store.setRadioSwapOfferedProfileDate(pending.profileCapturedAt, deviceID: pending.deviceID)
    }
    pending = nil
  }

  /// The connection ended; an offer for that radio no longer applies.
  func endSession() {
    pending = nil
  }
}
