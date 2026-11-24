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

  struct ImportSource: Equatable, Sendable {
    let generation: UUID
    let requestID: UUID
    let deviceID: UUID
    let radioID: UUID
    let name: String

    @MainActor
    init(_ snapshot: ConnectionSnapshot) {
      generation = snapshot.generation
      requestID = snapshot.requestID
      deviceID = snapshot.device.id
      radioID = snapshot.device.radioID
      name = snapshot.device.nodeName
    }
  }

  let source: Source

  init(source: Source = .file, preferences: DevicePreferenceStore = DevicePreferenceStore()) {
    self.source = source
    self.preferences = preferences
  }

  var state: NodeConfigImportState = .selectingFile
  var errorMessage: String?
  var showFilePicker = false
  // Alert dismissal can precede its action; apply and cancel consume the confirmation payload.
  var showConfirmation = false
  var sections = ConfigSections()
  var currentName: String?
  var currentRadio: MeshCoreNodeConfig.RadioSettings?
  var currentPosition: MeshCoreNodeConfig.PositionSettings?
  var importTask: Task<Void, Never>?
  var parseTask: Task<Void, Never>?
  var currentParseID: UUID?
  var previewTask: Task<Void, Never>?
  var connectionManager: ConnectionManager?
  let logger = Logger(subsystem: "com.mc1", category: "NodeConfigImportVM")
  /// Records that a copy from records landed on a radio, so a later switch back to it is
  /// topped up quietly.
  let preferences: DevicePreferenceStore

  // Records state
  /// Planner preview of the records config with every section on, for the per-section counts
  /// and the slot notes. Re-run when "Make Room" changes.
  var recordsPreview: ImportPreview?
  var isLoadingRecords = false
  /// Leave to move this radio's own channels out of the identity's slots. Off until the user
  /// turns it on: a slot holding a different channel is never replaced without asking.
  var makeRoomForChannels = false

  private var nodeConfigServiceProvider: @MainActor () -> NodeConfigService? = { nil }
  private var settingsServiceProvider: @MainActor () -> SettingsService? = { nil }
  private var connectedDeviceProvider: @MainActor () -> DeviceDTO? = { nil }
  var nodeConfigService: NodeConfigService? {
    nodeConfigServiceProvider()
  }

  var settingsService: SettingsService? {
    settingsServiceProvider()
  }

  var connectedDevice: DeviceDTO? {
    connectedDeviceProvider()
  }

  func configure(
    nodeConfigService: @escaping @MainActor () -> NodeConfigService?,
    settingsService: @escaping @MainActor () -> SettingsService?,
    connectedDevice: @escaping @MainActor () -> DeviceDTO?,
    connectionManager: ConnectionManager
  ) {
    nodeConfigServiceProvider = nodeConfigService
    settingsServiceProvider = settingsService
    connectedDeviceProvider = connectedDevice
    self.connectionManager = connectionManager
  }

  // MARK: - From This Phone's Records

  /// The current connection as an import source, when the connected device is the one it names.
  private var currentImportSource: ImportSource? {
    guard let snapshot = connectionManager?.currentConnection,
          connectedDevice?.id == snapshot.device.id else { return nil }
    return ImportSource(snapshot)
  }

  /// Builds the config from this phone's records and previews it against the connected radio,
  /// so every section shows what would actually be written. Does nothing while disconnected.
  func loadFromRecords() {
    guard source == .records, !isLoadingRecords, !isApplying else { return }
    guard let service = nodeConfigService, let importSource = currentImportSource else { return }

    retireInputWork()
    isLoadingRecords = true
    errorMessage = nil
    let makeRoom = makeRoomForChannels
    previewTask = Task {
      defer { isLoadingRecords = false }
      do {
        var everything = ConfigSections()
        everything.selectAll()
        let config = try await service.recordsConfig(radioID: importSource.radioID, sections: everything)
        await loadCurrentDeviceState()
        let preview = try await service.previewImport(
          config, sections: everything, radioID: importSource.radioID, makeRoomForChannels: makeRoom
        )
        guard !Task.isCancelled,
              connectionManager?.isCurrent(generation: importSource.generation, requestID: importSource.requestID) == true
        else { return }
        state = .preview(NodeConfigImportState.Input(id: UUID(), config: config, source: importSource))
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
  func refreshRecordsPreview() {
    guard source == .records, !isApplying, let input = state.input, let importSource = input.source,
          let service = nodeConfigService else { return }
    var everything = ConfigSections()
    everything.selectAll()
    let makeRoom = makeRoomForChannels
    previewTask?.cancel()
    isLoadingRecords = true
    previewTask = Task {
      defer { isLoadingRecords = false }
      do {
        let preview = try await service.previewImport(
          input.config, sections: everything, radioID: importSource.radioID, makeRoomForChannels: makeRoom
        )
        guard !Task.isCancelled, inputID == input.id else { return }
        recordsPreview = preview
      } catch is CancellationError {
        // Superseded or dismissed.
      } catch {
        guard inputID == input.id else { return }
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

  /// Clears the records preview and "Make Room" with the rest of the input.
  func resetRecordsState() {
    recordsPreview = nil
    isLoadingRecords = false
    makeRoomForChannels = false
  }
}
