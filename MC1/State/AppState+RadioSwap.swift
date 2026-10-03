import Foundation
import MC1Services

// MARK: - Radio Swap Offer

extension AppState {
  /// Reads the connected radio's swap guard and stored profile and lets `radioSwapPrompt`
  /// decide whether to offer "Copy to This Radio". Called from `onDeviceSynced`.
  func evaluateRadioSwapOffer() async {
    guard let device = connectedDevice, let dataStore = services?.dataStore else { return }
    let swapGuard = (try? await dataStore.fetchSwapGuard(radioID: device.radioID)) ?? []
    let profile = try? await dataStore.fetchSwapProfile(radioID: device.radioID)
    // The connection may have moved on during the reads.
    guard connectedDevice?.id == device.id else { return }
    radioSwapPrompt.evaluate(deviceID: device.id, swapGuard: swapGuard, profile: profile)
  }
}
