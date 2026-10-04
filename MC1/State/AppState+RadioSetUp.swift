import Foundation
import MC1Services

/// Why setting a radio up as a saved node stopped.
enum RadioSetUpError: Error {
  /// The key was not on this iPhone after all (forgotten in Settings meanwhile).
  case keyNotSaved
  /// The radio answered, but still reports its own key: firmware without key import.
  case radioKeptItsKey
}

// MARK: - Set Up a Blank Radio

extension AppState {
  /// After the first sync on a radio: asks a blank one (a node with no history here that no
  /// other saved radio carries) whether to set it up as one of the user's saved nodes
  /// (docs/RADIO_SWAP.md, flow B). Called from `onDeviceSynced`.
  func evaluateRadioSetUp() async {
    guard IdentityKeyVault.isEnabled(), let device = connectedDevice, let services else { return }
    let store = services.dataStore
    guard let saved = try? await IdentityKeyVault.shared.savedIdentities(),
          let radioHasHistory = try? await store.hasMessages(radioID: device.radioID),
          let radioRows = try? await store.deviceCount(publicKey: device.publicKey) else { return }

    var rowsByKey: [Data: Int] = [:]
    for identity in saved {
      rowsByKey[identity.publicKey] = (try? await store.deviceCount(publicKey: identity.publicKey)) ?? 0
    }
    let candidates = RadioSetUpPolicy.candidates(
      radioPublicKey: device.publicKey,
      radioHasHistory: radioHasHistory,
      keyCarriedByAnotherRadio: radioRows > 1,
      declinedKey: radioSetUpPrompt.declinedKey(deviceID: device.id),
      saved: saved,
      hasRadioRow: { (rowsByKey[$0] ?? 0) > 0 }
    )
    // The connection may have moved on during the reads.
    guard connectedDevice?.id == device.id, !candidates.isEmpty else { return }
    radioSetUpPrompt.offer(PendingRadioSetUp(
      deviceID: device.id,
      radioName: device.nodeName,
      radioPublicKey: device.publicKey,
      candidates: candidates
    ))
  }

  /// Writes the saved node's key to the connected radio, then reconnects it. On reconnect the
  /// radio joins that node's history with its deletions held, and its first sync brings the
  /// usual "Copy to This Radio" offer, which lists everything else that will be written.
  func setUpConnectedRadio(as identity: SavedIdentity) async {
    guard let pending = radioSetUpPrompt.pending,
          let services,
          connectedDevice?.id == pending.deviceID else { return }
    radioSetUpPrompt.phase = .settingUp(nodeName: identity.nodeName)
    do {
      guard let key = try await IdentityKeyVault.shared.privateKey(for: identity.publicKey) else {
        throw RadioSetUpError.keyNotSaved
      }
      try await services.settingsService.importPrivateKey(key)
      guard try await services.settingsService.getSelfInfo().publicKey == identity.publicKey else {
        throw RadioSetUpError.radioKeptItsKey
      }
    } catch {
      logger.warning("Setting up radio as \(identity.nodeName) failed: \(error.localizedDescription)")
      radioSetUpPrompt.phase = .failed(message: Self.radioSetUpFailureMessage(error))
      return
    }
    // The node the radio was is gone; its key would only clutter the list.
    try? await IdentityKeyVault.shared.forget(publicKey: pending.radioPublicKey)
    // The sheet's work is done; the reconnect shows in the radio pill, and the copy offer
    // follows its first sync.
    radioSetUpPrompt.close()
    await reconnectAfterIdentityChange()
  }

  private static func radioSetUpFailureMessage(_ error: Error) -> String {
    switch error {
    case RadioSetUpError.keyNotSaved:
      return L10n.Settings.RadioSetUp.Error.keyNotSaved
    case RadioSetUpError.radioKeptItsKey:
      return L10n.Settings.RadioSetUp.Error.radioKeptItsKey
    case let SettingsServiceError.sessionError(meshError):
      if case .featureDisabled = meshError {
        return L10n.Settings.RegenerateIdentity.Error.featureDisabled
      }
      if case .deviceError = meshError {
        return L10n.Settings.RegenerateIdentity.Error.deviceRejected
      }
      return error.userFacingMessage
    default:
      return error.userFacingMessage
    }
  }

  /// After Import Key or Regenerate Key: reconnects the radio at once, so it joins the history of
  /// the node it now carries (or holds its own deletions after a new key) without waiting for
  /// the next connect (docs/RADIO_SWAP.md, H8).
  func reconnectAfterIdentityChange() async {
    guard let deviceID = connectedDevice?.id else { return }
    await connectionManager.disconnect(reason: .identityChanged)
    do {
      try await connectionManager.connect(to: deviceID, forceFullSync: true, forceReconnect: true)
    } catch {
      connectionUI.presentSavedDeviceConnectFailure(deviceID: deviceID, error: error)
    }
  }
}
