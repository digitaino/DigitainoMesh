import MC1Services
import SwiftUI

extension NodeConfigImportViewModel {
  var importedConfig: MeshCoreNodeConfig? {
    state.input?.config
  }

  var inputID: UUID? {
    state.input?.id
  }

  var inputSource: ImportSource? {
    state.input?.source
  }

  var inputReceiptID: UUID? {
    state.input == nil ? nil : recovery?.receiptID
  }

  var recovery: IdentityImportRecovery? {
    state.recovery
  }

  var isParsing: Bool {
    currentParseID != nil
  }

  var isPreparingConfirmation: Bool {
    if case .preparing = state { return true }
    return false
  }

  var isApplying: Bool {
    if case .applying = state { return true }
    return false
  }

  var importComplete: Bool {
    if case .completed = state { return recovery == nil }
    return false
  }

  var identityRecoveryComplete: Bool {
    if case .completed = state { return recovery != nil }
    return false
  }

  var confirmation: NodeConfigImportState.Confirmation? {
    guard case let .confirming(confirmation) = state else { return nil }
    return confirmation
  }

  var didApplyAnyWrite: Bool {
    state.application?.progress != nil
  }

  var applyProgress: Double {
    guard let progress = state.application?.progress else { return 0 }
    return Double(progress.current) / Double(max(1, progress.total))
  }

  var applyStepDescription: String {
    state.application?.progress.map { Self.description(for: $0.step) } ?? ""
  }

  private var hasOverwriteSections: Bool {
    let selectedSections: ConfigSections = if case let .config(preview) = confirmation {
      preview.sections
    } else {
      sections
    }
    return selectedSections.radioSettings || selectedSections.nodeIdentity || selectedSections.positionSettings
      || selectedSections.otherSettings || (selectedSections.channels && state.input?.channelsWouldOverwrite == true)
  }

  private var hasAdditiveSections: Bool {
    if case let .config(preview) = confirmation {
      return preview.sections.channels || preview.sections.contacts
    }
    return sections.channels || sections.contacts
  }

  var confirmTitle: String {
    if recovery != nil { return L10n.Settings.ConfigImport.confirmTitleIdentityRecovery }
    switch (hasOverwriteSections, hasAdditiveSections) {
    case (false, true): return L10n.Settings.ConfigImport.confirmTitleAdd
    case (true, false): return L10n.Settings.ConfigImport.confirmTitleOverwrite
    default: return L10n.Settings.ConfigImport.confirmTitle
    }
  }

  var confirmButtonRole: ButtonRole? {
    recovery == nil ? nil : .destructive
  }

  /// The recovery sheet stays up while the identity write is in flight, so its result stays visible.
  var recoverySheetDismissalDisabled: Bool {
    recovery != nil && isApplying
  }

  var applyButtonLabel: String {
    if recovery != nil { return L10n.Settings.ConfigImport.retryIdentityImport }
    switch (hasOverwriteSections, hasAdditiveSections) {
    case (false, true): return L10n.Settings.ConfigImport.applyButtonAdd
    case (true, false): return L10n.Settings.ConfigImport.applyButtonOverwrite
    default: return L10n.Settings.ConfigImport.applyButton
    }
  }

  var confirmMessage: String {
    if case let .recovery(summary, _, _) = confirmation {
      return L10n.Settings.ConfigImport.confirmIdentityRecovery("\(summary.sourceName) (\(summary.targetDescription))")
    }
    guard case let .config(preview) = confirmation else { return "" }
    let base = switch (hasOverwriteSections, hasAdditiveSections) {
    case (false, true): L10n.Settings.ConfigImport.confirmMessageAdd(preview.source.name)
    case (true, false): L10n.Settings.ConfigImport.confirmMessageOverwrite(preview.source.name)
    case (true, true): L10n.Settings.ConfigImport.confirmMessageMixed(preview.source.name)
    default: L10n.Settings.ConfigImport.confirmMessage(preview.source.name)
    }
    let notes = preview.notes.map { Self.confirmationNotes(for: $0, sections: preview.sections) } ?? []
    guard !notes.isEmpty else { return base }
    return ([base] + notes).joined(separator: "\n\n")
  }

  /// What the confirmation adds below its summary: contacts left out for room or written with
  /// no location, so the user is not surprised later, and, for channels, the slot alignment.
  static func confirmationNotes(for preview: ImportPreview, sections: ConfigSections) -> [String] {
    var notes: [String] = []
    if !preview.contactCapacityDropped.isEmpty {
      let names = ListFormatter.localizedString(byJoining: preview.contactCapacityDropped)
      notes.append(L10n.Settings.ConfigImport.contactCapacityDropped(preview.contactCapacityDropped.count, names))
    }
    if !preview.contactCoordinateFallbacks.isEmpty {
      let names = ListFormatter.localizedString(byJoining: preview.contactCoordinateFallbacks)
      notes.append(L10n.Settings.ConfigImport.contactCoordinateFallback(preview.contactCoordinateFallbacks.count, names))
    }
    if sections.channels {
      let slotNotes: [([String], (Int, String) -> String)] = [
        (preview.channelsRelocated, { L10n.Settings.ConfigImport.channelsRelocated($0, $1) }),
        (preview.channelsRemoved, { L10n.Settings.ConfigImport.channelsRemoved($0, $1) }),
        (preview.channelsBlocked, { L10n.Settings.ConfigImport.channelsBlocked($0, $1) }),
        (preview.channelsBeyondCapacity, { L10n.Settings.ConfigImport.channelsBeyondCapacity($0, $1) }),
      ]
      for (channelNames, format) in slotNotes where !channelNames.isEmpty {
        notes.append(format(channelNames.count, ListFormatter.localizedString(byJoining: channelNames)))
      }
    }
    return notes
  }

  static func description(for step: ImportStep) -> String {
    switch step {
    case .position: L10n.Settings.ConfigImport.stepPosition
    case .otherParameters: L10n.Settings.ConfigImport.stepOtherParameters
    case .privateKey: L10n.Settings.ConfigImport.stepPrivateKey
    case .nodeName: L10n.Settings.ConfigImport.stepNodeName
    case .radioParameters: L10n.Settings.ConfigImport.stepRadioParameters
    case .txPower: L10n.Settings.ConfigImport.stepTxPower
    case let .channel(name): L10n.Settings.ConfigImport.stepChannel(name)
    case let .clearChannelSlot(index): L10n.Settings.ConfigImport.stepClearChannelSlot(Int(index))
    case let .contact(name): L10n.Settings.ConfigImport.stepContact(name)
    }
  }

  static func cancellationMessage(didApplyAnyWrite: Bool) -> String {
    didApplyAnyWrite ? L10n.Settings.ConfigImport.cancelledPartial : L10n.Settings.ConfigImport.cancelled
  }

  static func failureMessage(for error: Error, didApplyAnyWrite: Bool) -> String {
    didApplyAnyWrite ? L10n.Settings.ConfigImport.failedPartial(error.userFacingMessage) : error.userFacingMessage
  }
}
