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

/// What happens after the first sync on a radio whose swap guard is armed: it took on the
/// identity for the first time, or the identity just switched back to it from another radio
/// (docs/RADIO_SWAP.md, owner decision 2).
enum RadioSwapStep: Equatable {
  /// Nothing to do: no guard, no profile, or this arming was already offered and answered.
  case none
  /// Offer the copy screen.
  case offer
  /// A radio already set up from these records: top it up quietly, and offer the copy screen
  /// only if the top-up leaves one of the identity's channels out.
  case topUp
}

/// Owns the offer, after a radio takes on an identity's history, to copy this phone's records
/// of it onto the radio. The offer is the copy screen itself, so nothing is written until the
/// user confirms there; "Not Now" leaves it in Settings.
@Observable
@MainActor
final class RadioSwapPromptState {
  private let store: DevicePreferenceStore

  /// The offer to present, or `nil`.
  var pending: PendingRadioSwapOffer?

  init(store: DevicePreferenceStore = DevicePreferenceStore()) {
    self.store = store
  }

  /// Decides what this arming calls for. A radio never copied to is offered the copy once per
  /// arming; one copied to before is topped up quietly.
  func step(deviceID: UUID, swapGuard: SwapGuard, profile: IdentityProfile?) -> RadioSwapStep {
    guard pending == nil, !swapGuard.isEmpty, let profile else { return .none }
    if store.hasCopiedRecordsToRadio(deviceID: deviceID) {
      return .topUp
    }
    return store.radioSwapOfferedProfileDate(deviceID: deviceID) == profile.capturedAt ? .none : .offer
  }

  /// Presents the copy screen for this arming, unless it was already answered.
  func offer(deviceID: UUID, profile: IdentityProfile) {
    guard pending == nil, store.radioSwapOfferedProfileDate(deviceID: deviceID) != profile.capturedAt else { return }
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
