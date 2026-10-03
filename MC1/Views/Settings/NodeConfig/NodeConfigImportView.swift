import MC1Services
import SwiftUI

struct NodeConfigImportView: View {
  @Environment(\.appState) private var appState
  @State private var viewModel: NodeConfigImportViewModel
  /// Set when the screen opens as the offer after a radio takes on an identity: the name the
  /// intro uses for that identity.
  private let swapIdentityName: String?
  /// Closes the screen when it is presented as that offer's sheet.
  private let onClose: (() -> Void)?

  init(
    source: NodeConfigImportViewModel.Source = .file,
    swapIdentityName: String? = nil,
    onClose: (() -> Void)? = nil
  ) {
    _viewModel = State(initialValue: NodeConfigImportViewModel(source: source))
    self.swapIdentityName = swapIdentityName
    self.onClose = onClose
  }

  var body: some View {
    Group {
      if let config = viewModel.importedConfig {
        ImportPreviewList(viewModel: viewModel, config: config, swapIdentityName: swapIdentityName)
      } else if viewModel.source == .records {
        RecordsLoadingList(viewModel: viewModel)
      } else {
        SelectFileList(viewModel: viewModel)
      }
    }
    .navigationTitle(
      viewModel.source == .records ? L10n.Settings.ConfigImport.CopyFromRecords.title : L10n.Settings.ConfigImport.title
    )
    .task {
      viewModel.loadFromRecords(
        nodeConfigService: appState.services?.nodeConfigService,
        settingsService: appState.services?.settingsService,
        radioID: appState.connectedDevice?.radioID
      )
    }
    .onDisappear { viewModel.handleDismissal() }
    .toolbar {
      if let onClose {
        ToolbarItem(placement: .cancellationAction) {
          Button(viewModel.importComplete
            ? L10n.Localizable.Common.done
            : L10n.Settings.ConfigImport.CopyFromRecords.notNow) {
            onClose()
          }
          .disabled(viewModel.isApplying)
        }
      }
    }
    // A sheet must not be swiped away halfway through writing to the radio.
    .interactiveDismissDisabled(viewModel.isApplying)
    .fileImporter(
      isPresented: $viewModel.showFilePicker,
      allowedContentTypes: [.json]
    ) { result in
      switch result {
      case let .success(url):
        viewModel.parseFile(at: url)
        Task { await viewModel.loadCurrentDeviceState(settingsService: appState.services?.settingsService) }
      case let .failure(error):
        viewModel.errorMessage = error.userFacingMessage
      }
    }
    .alert(
      viewModel.confirmTitle,
      isPresented: $viewModel.showConfirmation
    ) {
      Button(viewModel.applyButtonLabel) {
        viewModel.applyConfig(
          nodeConfigService: appState.services?.nodeConfigService,
          settingsService: appState.services?.settingsService,
          radioID: appState.connectedDevice?.radioID
        )
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: {
      Text(viewModel.confirmMessage(deviceName: appState.connectedDevice?.nodeName ?? L10n.Settings.ConfigImport.thisDevice))
    }
  }
}

// MARK: - Select File

private struct SelectFileList: View {
  @Environment(\.appTheme) private var theme
  @Bindable var viewModel: NodeConfigImportViewModel

  var body: some View {
    List {
      Section {
        Button {
          viewModel.showFilePicker = true
        } label: {
          HStack {
            Text(L10n.Settings.ConfigImport.selectFile)
            if viewModel.isParsing {
              Spacer()
              ProgressView()
            }
          }
        }
        .disabled(viewModel.isParsing)
      }
      .themedRowBackground(theme)

      if let error = viewModel.errorMessage {
        Section {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
        .themedRowBackground(theme)
      }
    }
    .themedCanvas(theme)
  }
}

// MARK: - Records Loading

private struct RecordsLoadingList: View {
  @Environment(\.appTheme) private var theme
  @Bindable var viewModel: NodeConfigImportViewModel

  var body: some View {
    List {
      Section {
        if let error = viewModel.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        } else {
          HStack {
            Text(L10n.Settings.ConfigImport.CopyFromRecords.loading)
            Spacer()
            ProgressView()
          }
        }
      }
      .themedRowBackground(theme)
    }
    .themedCanvas(theme)
  }
}

// MARK: - Import Preview

private struct ImportPreviewList: View {
  @Environment(\.appTheme) private var theme
  @Bindable var viewModel: NodeConfigImportViewModel
  let config: MeshCoreNodeConfig
  let swapIdentityName: String?

  var body: some View {
    List {
      if viewModel.source == .records {
        Section {
          Text(swapIdentityName.map { L10n.Settings.ConfigImport.CopyFromRecords.swapIntro($0) }
            ?? L10n.Settings.ConfigImport.CopyFromRecords.intro)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .themedRowBackground(theme)
      }

      if config.name != nil || config.privateKey != nil {
        NodeIdentitySection(viewModel: viewModel, config: config)
      }

      if let radio = config.radioSettings {
        RadioSettingsSection(viewModel: viewModel, radio: radio, currentRadio: viewModel.currentRadio)
      }

      if let position = config.positionSettings {
        PositionSection(viewModel: viewModel, position: position, currentPosition: viewModel.currentPosition)
      }

      if config.otherSettings != nil {
        Section {
          Toggle(L10n.Settings.ConfigExport.otherSettings, isOn: $viewModel.sections.otherSettings)
        }
        .themedRowBackground(theme)
      }

      if let channels = config.channels {
        ChannelsSection(viewModel: viewModel, channels: channels)
      }

      if let contacts = config.contacts {
        ContactsSection(viewModel: viewModel, contacts: contacts)
      }

      Section {
        Label(L10n.Settings.ConfigImport.proximityWarning, systemImage: "antenna.radiowaves.left.and.right")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .themedRowBackground(theme)

      ApplySection(viewModel: viewModel)

      if let error = viewModel.errorMessage {
        Section {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
        .themedRowBackground(theme)
      }

      if viewModel.importComplete, !viewModel.isApplying {
        Section {
          Label(L10n.Settings.ConfigImport.importSuccess, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
        .themedRowBackground(theme)
      }
    }
    .themedCanvas(theme)
    // Lock the section toggles while the preview round-trip is in flight, so the selection
    // the confirmation copy was computed from matches the selection the apply uses.
    .disabled(viewModel.isPreparingConfirmation)
  }
}

// MARK: - Section Views

private struct NodeIdentitySection: View {
  @Environment(\.appTheme) private var theme
  @Bindable var viewModel: NodeConfigImportViewModel
  let config: MeshCoreNodeConfig

  var body: some View {
    Section {
      Toggle(isOn: $viewModel.sections.nodeIdentity) {
        VStack(alignment: .leading) {
          Text(L10n.Settings.ConfigExport.nodeIdentity)
          if let newName = config.name {
            DiffRow(
              current: viewModel.currentName ?? "\u{2014}",
              new: newName
            )
          }
          if config.privateKey != nil {
            Label(L10n.Settings.ConfigImport.privateKeyWarning, systemImage: "exclamationmark.shield")
              .font(.footnote)
              .foregroundStyle(.orange)
          }
        }
      }
    }
    .themedRowBackground(theme)
  }
}

private struct RadioSettingsSection: View {
  @Environment(\.appTheme) private var theme
  @Bindable var viewModel: NodeConfigImportViewModel
  let radio: MeshCoreNodeConfig.RadioSettings
  let currentRadio: MeshCoreNodeConfig.RadioSettings?

  var body: some View {
    Section {
      Toggle(isOn: $viewModel.sections.radioSettings) {
        VStack(alignment: .leading) {
          Text(L10n.Settings.ConfigExport.radioSettings)
          DiffRow(
            current: currentRadio.map { RadioFormatter.format($0) } ?? "\u{2014}",
            new: RadioFormatter.format(radio)
          )
          if let current = currentRadio, current != radio {
            Label(L10n.Settings.ConfigImport.radioWarning, systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(.orange)
          }
        }
      }
    }
    .themedRowBackground(theme)
  }
}

private struct PositionSection: View {
  @Environment(\.appTheme) private var theme
  @Bindable var viewModel: NodeConfigImportViewModel
  let position: MeshCoreNodeConfig.PositionSettings
  let currentPosition: MeshCoreNodeConfig.PositionSettings?

  var body: some View {
    Section {
      Toggle(isOn: $viewModel.sections.positionSettings) {
        VStack(alignment: .leading) {
          Text(L10n.Settings.ConfigExport.positionSettings)
          DiffRow(
            current: currentPosition.map { "\($0.latitude), \($0.longitude)" } ?? "\u{2014}",
            new: "\(position.latitude), \(position.longitude)"
          )
        }
      }
    }
    .themedRowBackground(theme)
  }
}

private struct ChannelsSection: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.appState) private var appState
  @Bindable var viewModel: NodeConfigImportViewModel
  let channels: [MeshCoreNodeConfig.ChannelConfig]

  /// The radio's own channels sitting in the identity's slots: blocked while "Make Room" is
  /// off, moved or removed once it is on.
  private var conflicts: [String] {
    guard let preview = viewModel.recordsPreview else { return [] }
    return viewModel.makeRoomForChannels
      ? preview.channelsRelocated + preview.channelsRemoved
      : preview.channelsBlocked
  }

  var body: some View {
    Section {
      Toggle(isOn: $viewModel.sections.channels) {
        VStack(alignment: .leading) {
          Text(L10n.Settings.ConfigExport.channels)
          Text(L10n.Settings.ConfigImport.channelCount(viewModel.recordsPreview?.channelWriteCount ?? channels.count))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      if !conflicts.isEmpty || viewModel.makeRoomForChannels {
        Toggle(L10n.Settings.ConfigImport.makeRoom, isOn: $viewModel.makeRoomForChannels)
          .disabled(!viewModel.sections.channels || viewModel.isLoadingRecords)
          .onChange(of: viewModel.makeRoomForChannels) {
            viewModel.refreshRecordsPreview(
              nodeConfigService: appState.services?.nodeConfigService,
              radioID: appState.connectedDevice?.radioID
            )
          }
      }
    } footer: {
      if let blocked = viewModel.recordsPreview?.channelsBlocked, !blocked.isEmpty, !viewModel.makeRoomForChannels {
        Text(L10n.Settings.ConfigImport.MakeRoom.footer(ListFormatter.localizedString(byJoining: blocked)))
      }
    }
    .themedRowBackground(theme)
  }
}

private struct ContactsSection: View {
  @Environment(\.appTheme) private var theme
  @Bindable var viewModel: NodeConfigImportViewModel
  let contacts: [MeshCoreNodeConfig.ContactConfig]

  var body: some View {
    Section {
      Toggle(isOn: $viewModel.sections.contacts) {
        VStack(alignment: .leading) {
          Text(L10n.Settings.ConfigExport.contacts)
          Text(L10n.Settings.ConfigImport.contactCount(viewModel.recordsPreview?.contactWriteCount ?? contacts.count))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .themedRowBackground(theme)
  }
}

private struct ApplySection: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.appState) private var appState
  @Bindable var viewModel: NodeConfigImportViewModel

  var body: some View {
    Section {
      if viewModel.isApplying {
        VStack {
          ProgressView(value: viewModel.applyProgress)
          Text(viewModel.applyStepDescription)
            .font(.footnote)
            .foregroundStyle(.secondary)
          Button(L10n.Localizable.Common.cancel, role: .cancel) {
            viewModel.cancelImport()
          }
        }
      } else if !viewModel.importComplete {
        Button(viewModel.applyButtonLabel) {
          viewModel.prepareConfirmation(
            nodeConfigService: appState.services?.nodeConfigService,
            radioID: appState.connectedDevice?.radioID
          )
        }
        .disabled(viewModel.isPreparingConfirmation || viewModel.isLoadingRecords)
      }
    }
    .themedRowBackground(theme)
  }
}

// MARK: - Diff Row

private struct DiffRow: View {
  let current: String
  let new: String

  private var hasChanged: Bool {
    current != new
  }

  var body: some View {
    VStack(alignment: .leading) {
      Text(L10n.Settings.ConfigImport.current(current))
        .font(.footnote)
        .foregroundStyle(.secondary)
      Text(L10n.Settings.ConfigImport.new(new))
        .font(.footnote)
        .foregroundStyle(hasChanged ? .primary : .secondary)
    }
  }
}

// MARK: - Radio Formatter

private enum RadioFormatter {
  static func format(_ radio: MeshCoreNodeConfig.RadioSettings) -> String {
    let freqMHz = (Double(radio.frequency) / 1000).formatted(.number.precision(.fractionLength(0...3)).locale(.posix))
    let bwKHz = (Double(radio.bandwidth) / 1000).formatted(.number.precision(.fractionLength(0...1)).locale(.posix))
    return "\(freqMHz) MHz, BW \(bwKHz) kHz, SF \(radio.spreadingFactor), CR \(radio.codingRate)"
  }
}
