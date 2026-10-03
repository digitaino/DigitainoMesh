import Foundation
import MC1Services

// MARK: - Radio Swap Offer

extension AppState {
  /// After the first sync on a radio whose swap guard is armed: offers "Copy to This Radio" to
  /// a radio never set up from these records, and quietly tops up one that was, asking only
  /// when the top-up has to leave one of the identity's channels out. Called from
  /// `onDeviceSynced`; a radio that already matched has released its guard by then.
  func evaluateRadioSwapOffer() async {
    guard let device = connectedDevice, let services else { return }
    let swapGuard = (try? await services.dataStore.fetchSwapGuard(radioID: device.radioID)) ?? []
    let profile = try? await services.dataStore.fetchSwapProfile(radioID: device.radioID)
    // The connection may have moved on during the reads.
    guard connectedDevice?.id == device.id, let profile else { return }

    switch radioSwapPrompt.step(deviceID: device.id, swapGuard: swapGuard, profile: profile) {
    case .none:
      return
    case .offer:
      radioSwapPrompt.offer(deviceID: device.id, profile: profile)
    case .topUp:
      do {
        let result = try await services.nodeConfigService.topUpFromRecords(radioID: device.radioID)
        guard connectedDevice?.id == device.id else { return }
        if !result.channelsBlocked.isEmpty {
          radioSwapPrompt.offer(deviceID: device.id, profile: profile)
        }
      } catch {
        logger.warning("Radio top-up from records failed: \(error.localizedDescription)")
      }
    }
  }
}
