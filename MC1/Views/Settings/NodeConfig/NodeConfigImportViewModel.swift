import MC1Services
import OSLog
import SwiftUI

@Observable
@MainActor
final class NodeConfigImportViewModel {
  /// Where the config comes from: a JSON file, or this phone's own records of the identity
  /// ("Copy to This Radio", docs/RADIO_SWAP.md R3), which puts each channel back in its slot.
  enum Source {
    case file
    case records
  }

  let source: Source

  init(source: Source = .file) {
    self.source = source
  }

  // Records state
  /// Planner preview of the records config with every section on, for the per-section counts
  /// and the slot notes. Re-run when "Make Room" changes.
  var recordsPreview: ImportPreview?
  var isLoadingRecords = false
  /// Leave to move this radio's own channels out of the identity's slots. Off until the user
  /// turns it on: a slot holding a different channel is never replaced without asking.
  var makeRoomForChannels = false

  // Parse state
  var importedConfig: MeshCoreNodeConfig?
  var errorMessage: String?
  var showFilePicker = false
  var isParsing = false

  /// Section selection
  var sections = ConfigSections()

  // Current device state for diff
  var currentName: String?
  var currentRadio: MeshCoreNodeConfig.RadioSettings?
  var currentPosition: MeshCoreNodeConfig.PositionSettings?

  // Apply state
  var isApplying = false
  var applyProgress: Double = 0
  var applyStepDescription = ""
  var importComplete = false
  var showConfirmation = false
  var isPreparingConfirmation = false

  /// Set from a non-destructive ``NodeConfigService/previewImport(_:sections:)`` pass before the
  /// confirmation alert. True when at least one selected channel would replace an already-configured
  /// slot, so the channels section is not purely additive and the confirmation copy must say so.
  private var channelsWouldOverwrite = false
  /// Contacts the preview found with unusable coordinates; named in the confirmation so the
  /// user knows they will land without a location rather than discovering it on the map.
  private var contactCoordinateFallbacks: [String] = []
  /// Contacts the preview found no free slot for; named so the user knows what stays behind.
  private var contactCapacityDropped: [String] = []
  /// Slot alignment notes from the preview (records source only).
  private var channelsRelocated: [String] = []
  private var channelsRemoved: [String] = []
  private var channelsBlocked: [String] = []
  private var channelsBeyondCapacity: [String] = []

  /// True once the import has reported progress, i.e. at least one destructive write reached the
  /// device. Distinguishes "cancelled before anything changed" from "cancelled mid-write."
  private var didApplyAnyWrite = false

  private var importTask: Task<Void, Never>?

  /// Handle for the in-flight file parse, plus the ID guard that lets a newer parse
  /// (or a dismissal) invalidate a stale result that raced past cancellation.
  private var parseTask: Task<Void, Never>?
  private var currentParseID: UUID?

  /// Handle for the in-flight preview, which does a real BLE round-trip via `previewImport`.
  /// Stored so it can be cancelled if the user leaves the screen or supersedes it.
  private var previewTask: Task<Void, Never>?

  private let logger = Logger(subsystem: "com.mc1", category: "NodeConfigImportVM")

  // MARK: - Dynamic confirmation text

  private var hasOverwriteSections: Bool {
    sections.radioSettings || sections.nodeIdentity || sections.positionSettings
      || sections.otherSettings || (sections.channels && channelsWouldOverwrite)
  }

  private var hasAdditiveSections: Bool {
    sections.channels || sections.contacts
  }

  var confirmTitle: String {
    switch (hasOverwriteSections, hasAdditiveSections) {
    case (false, true): L10n.Settings.ConfigImport.confirmTitleAdd
    case (true, false): L10n.Settings.ConfigImport.confirmTitleOverwrite
    default: L10n.Settings.ConfigImport.confirmTitle
    }
  }

  var applyButtonLabel: String {
    switch (hasOverwriteSections, hasAdditiveSections) {
    case (false, true): L10n.Settings.ConfigImport.applyButtonAdd
    case (true, false): L10n.Settings.ConfigImport.applyButtonOverwrite
    default: L10n.Settings.ConfigImport.applyButton
    }
  }

  func confirmMessage(deviceName: String) -> String {
    let base = switch (hasOverwriteSections, hasAdditiveSections) {
    case (false, true): L10n.Settings.ConfigImport.confirmMessageAdd(deviceName)
    case (true, false): L10n.Settings.ConfigImport.confirmMessageOverwrite(deviceName)
    case (true, true): L10n.Settings.ConfigImport.confirmMessageMixed(deviceName)
    default: L10n.Settings.ConfigImport.confirmMessage(deviceName)
    }
    var notes: [String] = []
    if !contactCapacityDropped.isEmpty {
      let names = ListFormatter.localizedString(byJoining: contactCapacityDropped)
      notes.append(L10n.Settings.ConfigImport.contactCapacityDropped(contactCapacityDropped.count, names))
    }
    if !contactCoordinateFallbacks.isEmpty {
      let names = ListFormatter.localizedString(byJoining: contactCoordinateFallbacks)
      notes.append(L10n.Settings.ConfigImport.contactCoordinateFallback(contactCoordinateFallbacks.count, names))
    }
    if sections.channels {
      let slotNotes: [([String], (Int, String) -> String)] = [
        (channelsRelocated, { L10n.Settings.ConfigImport.channelsRelocated($0, $1) }),
        (channelsRemoved, { L10n.Settings.ConfigImport.channelsRemoved($0, $1) }),
        (channelsBlocked, { L10n.Settings.ConfigImport.channelsBlocked($0, $1) }),
        (channelsBeyondCapacity, { L10n.Settings.ConfigImport.channelsBeyondCapacity($0, $1) }),
      ]
      for (channelNames, format) in slotNotes where !channelNames.isEmpty {
        notes.append(format(channelNames.count, ListFormatter.localizedString(byJoining: channelNames)))
      }
    }
    guard !notes.isEmpty else { return base }
    return ([base] + notes).joined(separator: "\n\n")
  }

  /// Parse a JSON file from a security-scoped URL. The read and decode run detached
  /// because the URL can point at an undownloaded iCloud Drive file, where a
  /// synchronous read on the main actor blocks the UI for the whole download.
  func parseFile(at url: URL) {
    parseTask?.cancel()
    isParsing = true
    errorMessage = nil
    let taskID = UUID()
    currentParseID = taskID
    let didAccessSecurityScope = url.startAccessingSecurityScopedResource()

    parseTask = Task.detached(priority: .userInitiated) { [weak self, url, didAccessSecurityScope] in
      defer {
        if didAccessSecurityScope {
          url.stopAccessingSecurityScopedResource()
        }
      }
      do {
        // .mappedIfSafe lets the OS page-cache the read rather than
        // copying the whole file into the heap.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try Task.checkCancellation()
        let config = try JSONDecoder().decode(MeshCoreNodeConfig.self, from: data)
        try Task.checkCancellation()
        await self?.applyParseSuccess(config, for: taskID)
      } catch is CancellationError {
        // The new invocation or the dismissal owns the parse state; don't clobber it.
        return
      } catch {
        await self?.applyParseFailure(error, for: taskID)
      }
    }
  }

  // MARK: - From This Phone's Records

  /// Builds the config from this phone's records and previews it against the connected radio,
  /// so every section shows what would actually be written. Nil parameters mirror a
  /// disconnected state.
  func loadFromRecords(nodeConfigService: NodeConfigService?, settingsService: SettingsService?, radioID: UUID?) {
    guard source == .records, !isLoadingRecords, !isApplying else { return }
    guard let service = nodeConfigService, let radioID else { return }

    isLoadingRecords = true
    errorMessage = nil
    previewTask?.cancel()
    previewTask = Task {
      defer { isLoadingRecords = false }
      do {
        var everything = ConfigSections()
        everything.selectAll()
        let config = try await service.recordsConfig(radioID: radioID, sections: everything)
        await loadCurrentDeviceState(settingsService: settingsService)
        let preview = try await service.previewImport(
          config, sections: everything, radioID: radioID, makeRoomForChannels: makeRoomForChannels
        )
        guard !Task.isCancelled else { return }
        importedConfig = config
        recordsPreview = preview
        selectChangedSections(of: config)
      } catch is CancellationError {
        // The screen went away; its dismissal owns the state.
      } catch {
        errorMessage = error.userFacingMessage
        logger.error("Records load failed: \(error.localizedDescription)")
      }
    }
  }

  /// Re-runs the records preview after "Make Room" changes, so the channel row and its notes
  /// describe what would now happen.
  func refreshRecordsPreview(nodeConfigService: NodeConfigService?, radioID: UUID?) {
    guard source == .records, let config = importedConfig,
          let service = nodeConfigService, let radioID else { return }
    var everything = ConfigSections()
    everything.selectAll()
    previewTask?.cancel()
    isLoadingRecords = true
    previewTask = Task {
      defer { isLoadingRecords = false }
      do {
        let preview = try await service.previewImport(
          config, sections: everything, radioID: radioID, makeRoomForChannels: makeRoomForChannels
        )
        guard !Task.isCancelled else { return }
        recordsPreview = preview
      } catch is CancellationError {
        // Superseded or dismissed.
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }

  /// Turns on the name when it differs, and channels and contacts. Radio, position and other
  /// settings start off with their difference shown, one tap to align (owner decision 3): a
  /// profile captured from a restored backup's row carries factory defaults for exactly those
  /// fields, and a radio must never be retuned to them unasked.
  private func selectChangedSections(of config: MeshCoreNodeConfig) {
    sections.nodeIdentity = config.name != nil && config.name != currentName
    sections.radioSettings = false
    sections.positionSettings = false
    sections.otherSettings = false
    sections.channels = config.channels?.isEmpty == false
    sections.contacts = config.contacts?.isEmpty == false
  }

  private func applyParseSuccess(_ config: MeshCoreNodeConfig, for taskID: UUID) {
    guard currentParseID == taskID else { return }
    isParsing = false
    importedConfig = config
    errorMessage = nil

    // Auto-select only sections present in the file
    sections.nodeIdentity = config.name != nil || config.publicKey != nil || config.privateKey != nil
    sections.radioSettings = config.radioSettings != nil
    sections.positionSettings = config.positionSettings != nil && !(config.positionSettings?.isZero ?? true)
    sections.otherSettings = config.otherSettings != nil
    sections.channels = config.channels != nil
    sections.contacts = config.contacts != nil
  }

  private func applyParseFailure(_ error: Error, for taskID: UUID) {
    guard currentParseID == taskID else { return }
    isParsing = false
    errorMessage = error.userFacingMessage
    logger.error("Failed to parse config: \(error.localizedDescription)")
  }

  /// Load current device values for diff display. A nil service mirrors a disconnected state.
  func loadCurrentDeviceState(settingsService: SettingsService?) async {
    guard let settingsService else { return }
    do {
      let selfInfo = try await settingsService.getSelfInfo()
      currentName = selfInfo.name
      currentRadio = NodeConfigService.buildRadioSettings(from: selfInfo)
      currentPosition = MeshCoreNodeConfig.PositionSettings(
        latitude: String(selfInfo.latitude),
        longitude: String(selfInfo.longitude)
      )
    } catch {
      logger.error("Failed to load device state: \(error.localizedDescription)")
    }
  }

  /// Runs the non-destructive planner to classify the import (overwrite vs additive) and reject a
  /// malformed config up front, then presents the confirmation alert. Surfacing a planner error here
  /// means a poison file is caught before the user even confirms, and before any write.
  func prepareConfirmation(nodeConfigService: NodeConfigService?, radioID: UUID? = nil) {
    guard !isPreparingConfirmation, !isApplying else { return }
    guard let config = importedConfig,
          let service = nodeConfigService else { return }

    errorMessage = nil
    isPreparingConfirmation = true
    previewTask = Task {
      defer { isPreparingConfirmation = false }
      do {
        let preview = try await service.previewImport(
          config, sections: sections, radioID: radioID, makeRoomForChannels: makeRoomForChannels
        )
        // If the user left the screen while the round-trip was in flight, the dismissal has
        // already reset the UI; presenting the confirmation now would pop an alert over a
        // stale, off-screen state, so honour the cancellation even when the BLE call won the
        // race and returned before observing it.
        guard !Task.isCancelled else { return }
        channelsWouldOverwrite = preview.channelsOverwriteExisting
        contactCoordinateFallbacks = preview.contactCoordinateFallbacks
        contactCapacityDropped = preview.contactCapacityDropped
        channelsRelocated = preview.channelsRelocated
        channelsRemoved = preview.channelsRemoved
        channelsBlocked = preview.channelsBlocked
        channelsBeyondCapacity = preview.channelsBeyondCapacity
        errorMessage = nil
        showConfirmation = true
      } catch is CancellationError {
        // The user left the screen mid-preview — leave the UI untouched.
      } catch {
        errorMessage = error.userFacingMessage
        logger.error("Import preview failed: \(error.localizedDescription)")
      }
    }
  }

  /// Apply the imported config to the device. Nil parameters mirror a disconnected state.
  /// `deviceID` is the connected radio, recorded as set up once a copy from records lands so
  /// a later switch back to it is topped up quietly.
  func applyConfig(
    nodeConfigService: NodeConfigService?,
    settingsService: SettingsService?,
    radioID: UUID?,
    deviceID: UUID? = nil,
    preferences: DevicePreferenceStore = DevicePreferenceStore()
  ) {
    guard !isApplying else { return }
    guard let config = importedConfig,
          let service = nodeConfigService,
          let radioID else { return }

    isApplying = true
    applyProgress = 0
    errorMessage = nil
    importComplete = false
    didApplyAnyWrite = false

    importTask = Task {
      // Deliver progress through one stream consumed in order on the main actor, so updates
      // can't race or arrive out of sequence the way a per-update `Task { @MainActor }` would.
      let (progressStream, progressContinuation) = AsyncStream.makeStream(of: ImportProgress.self)
      let consumer = Task { @MainActor in
        for await progress in progressStream {
          didApplyAnyWrite = true
          applyProgress = Double(progress.current) / Double(max(1, progress.total))
          applyStepDescription = Self.description(for: progress.step)
        }
      }

      do {
        try await service.importConfig(
          config,
          sections: sections,
          radioID: radioID,
          makeRoomForChannels: makeRoomForChannels
        ) { progress in
          progressContinuation.yield(progress)
        }
        progressContinuation.finish()
        await consumer.value
        // Refresh cached device state so Settings UI reflects imported values
        if let settingsService {
          try? await settingsService.refreshDeviceInfo()
        }
        isApplying = false
        importComplete = true
        // A records copy stays on its result: there is no file to pick again.
        guard source == .file else {
          if let deviceID {
            preferences.setCopiedRecordsToRadio(deviceID: deviceID)
          }
          return
        }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        resetToFileSelection()
      } catch is CancellationError {
        progressContinuation.finish()
        await consumer.value
        isApplying = false
        // "No progress reported" means no destructive write landed, so the device is untouched.
        errorMessage = Self.cancellationMessage(didApplyAnyWrite: didApplyAnyWrite)
      } catch {
        progressContinuation.finish()
        await consumer.value
        isApplying = false
        errorMessage = Self.failureMessage(for: error, didApplyAnyWrite: didApplyAnyWrite)
        logger.error("Import failed: \(error.localizedDescription)")
      }
    }
  }

  func cancelImport() {
    importTask?.cancel()
  }

  /// Called when the screen goes away. Cancels any pending preview round-trip and, unless a
  /// destructive import is in flight, resets back to the file picker so re-entering the screen
  /// starts fresh instead of re-showing a stale preview or error. An in-flight import is left
  /// running with its progress state intact: it is a destructive, safety-critical operation with
  /// its own explicit cancel control, so a transient view disappearance must neither abort it
  /// mid-write nor hide its result from a user who returns.
  func handleDismissal() {
    parseTask?.cancel()
    currentParseID = nil
    previewTask?.cancel()
    guard !isApplying else { return }
    resetToFileSelection()
  }

  /// Maps a service-layer ``ImportStep`` to a localized progress description, keeping `L10n`
  /// in the app layer so the service stays localization-free.
  private static func description(for step: ImportStep) -> String {
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

  /// Localized message for a cancelled import; distinguishes a clean cancel from one where a
  /// destructive write already landed on the device.
  static func cancellationMessage(didApplyAnyWrite: Bool) -> String {
    didApplyAnyWrite
      ? L10n.Settings.ConfigImport.cancelledPartial
      : L10n.Settings.ConfigImport.cancelled
  }

  /// Localized message for a failed import; distinguishes a clean failure from one where a
  /// destructive write already landed.
  static func failureMessage(for error: Error, didApplyAnyWrite: Bool) -> String {
    didApplyAnyWrite
      ? L10n.Settings.ConfigImport.failedPartial(error.userFacingMessage)
      : error.userFacingMessage
  }

  /// Reset to the initial file-selection state so the user can import another file.
  private func resetToFileSelection() {
    importedConfig = nil
    errorMessage = nil
    isParsing = false
    sections = ConfigSections()
    currentName = nil
    currentRadio = nil
    currentPosition = nil
    applyProgress = 0
    applyStepDescription = ""
    importComplete = false
    isApplying = false
    isPreparingConfirmation = false
    showConfirmation = false
    channelsWouldOverwrite = false
    didApplyAnyWrite = false
    recordsPreview = nil
    isLoadingRecords = false
    makeRoomForChannels = false
    channelsRelocated = []
    channelsRemoved = []
    channelsBlocked = []
    channelsBeyondCapacity = []
  }
}
