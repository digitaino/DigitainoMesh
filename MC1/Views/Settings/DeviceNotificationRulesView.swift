import MC1Services
import MeshCore
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.mc1", category: "DeviceNotificationRulesView")

/// Inspects the notification rules Digitaino custom firmware currently has stored
/// (`SyncID.notifPrefs`) and offers a manual resync.
///
/// The app pushes these rules automatically on every notification-preference change and
/// reconciles them on connect; this screen exists to confirm that a mute actually landed
/// on the radio, which is otherwise invisible from the phone.
struct DeviceNotificationRulesView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  @State private var deviceBlob: NotifPrefsBlob?
  @State private var support: NotifSyncService.FirmwareSupport = .unknown
  @State private var fetchError: String?
  @State private var lastFetched: Date?
  @State private var isFetching = false
  @State private var isResyncing = false
  @State private var resyncStatus: ResyncStatus = .idle
  @State private var channels: [ChannelDTO] = []
  @State private var contacts: [ContactDTO] = []

  private enum ResyncStatus: Equatable {
    case idle
    case succeeded(at: Date)
    case failed(String)
  }

  private var isConnected: Bool {
    appState.connectionState == .ready
  }

  var body: some View {
    List {
      statusSection

      if let deviceBlob {
        deviceStateSection(deviceBlob)
        channelRulesSection(deviceBlob)
        contactRulesSection(deviceBlob)
      } else if let fetchError {
        errorSection(fetchError)
      } else if isFetching {
        Section {
          ProgressView().frame(maxWidth: .infinity)
        }
        .themedRowBackground(theme)
      }

      actionsSection
    }
    .themedCanvas(theme)
    .navigationTitle(L10n.Settings.DeviceNotificationRules.title)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await loadLocal()
      await loadDevice()
    }
    .refreshable {
      await loadDevice()
    }
  }

  // MARK: - Sections

  private var statusSection: some View {
    Section {
      if !isConnected {
        Label(L10n.Settings.DeviceNotificationRules.notConnected, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      } else if support == .unsupported {
        Label(L10n.Settings.DeviceNotificationRules.unsupported, systemImage: "xmark.seal")
          .foregroundStyle(.secondary)
      } else {
        Label(L10n.Settings.DeviceNotificationRules.connected, systemImage: "checkmark.seal.fill")
          .foregroundStyle(.green)
      }
    } footer: {
      Text(L10n.Settings.DeviceNotificationRules.footer)
    }
    .themedRowBackground(theme)
  }

  private func deviceStateSection(_ blob: NotifPrefsBlob) -> some View {
    Section {
      LabeledContent(L10n.Settings.DeviceNotificationRules.schemaVersion, value: "\(blob.version)")
      LabeledContent(L10n.Settings.DeviceNotificationRules.defaultMode, value: description(of: blob.globalMode))
      LabeledContent(L10n.Settings.DeviceNotificationRules.channelOverrides, value: "\(blob.channelRules.count)")
      LabeledContent(L10n.Settings.DeviceNotificationRules.contactOverrides, value: "\(blob.contactRules.count)")
      if let lastFetched {
        LabeledContent(L10n.Settings.DeviceNotificationRules.fetched) {
          Text(lastFetched, style: .relative)
        }
      }
    } header: {
      Text(L10n.Settings.DeviceNotificationRules.deviceState)
    } footer: {
      Text(L10n.Settings.DeviceNotificationRules.deviceStateFooter)
    }
    .themedRowBackground(theme)
  }

  private func channelRulesSection(_ blob: NotifPrefsBlob) -> some View {
    Section {
      if blob.channelRules.isEmpty {
        Text(L10n.Settings.DeviceNotificationRules.noChannelRules)
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(blob.channelRules.enumerated()), id: \.offset) { _, rule in
          ruleRow(
            title: channelName(forIndex: rule.channelIdx),
            subtitle: L10n.Settings.DeviceNotificationRules.channelIndex(Int(rule.channelIdx)),
            mode: rule.mode
          )
        }
      }
    } header: {
      Text(L10n.Settings.DeviceNotificationRules.channelRules)
    } footer: {
      overflowNote(local: localChannelRuleCount, cap: NotifPrefsBlob.maxChannelRules)
    }
    .themedRowBackground(theme)
  }

  private func contactRulesSection(_ blob: NotifPrefsBlob) -> some View {
    Section {
      if blob.contactRules.isEmpty {
        Text(L10n.Settings.DeviceNotificationRules.noContactRules)
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(blob.contactRules.enumerated()), id: \.offset) { _, rule in
          ruleRow(
            title: contactName(forPrefix: rule.pubKeyPrefix),
            subtitle: rule.pubKeyPrefix.hexString,
            mode: rule.mode
          )
        }
      }
    } header: {
      Text(L10n.Settings.DeviceNotificationRules.contactRules)
    } footer: {
      overflowNote(local: localContactRuleCount, cap: NotifPrefsBlob.maxContactRules)
    }
    .themedRowBackground(theme)
  }

  /// Names the rules the firmware's per-list cap left behind, which are otherwise invisible:
  /// the app enforces the same cap when it builds the blob, so the device state looks complete.
  @ViewBuilder
  private func overflowNote(local: Int, cap: Int) -> some View {
    if local > cap {
      Text(L10n.Settings.DeviceNotificationRules.ruleOverflow(cap, local))
        .foregroundStyle(.orange)
    }
  }

  private func errorSection(_ message: String) -> some View {
    Section {
      Label(message, systemImage: "xmark.octagon")
        .foregroundStyle(.red)
    } header: {
      Text(L10n.Settings.DeviceNotificationRules.readFailed)
    }
    .themedRowBackground(theme)
  }

  private var actionsSection: some View {
    Section {
      Button {
        Task { await loadDevice() }
      } label: {
        AsyncActionLabel(isLoading: isFetching, showSuccess: false) {
          TintedLabel(L10n.Settings.DeviceNotificationRules.refresh, systemImage: "arrow.clockwise")
        }
      }
      .disabled(!canAct || isFetching)

      Button {
        Task { await forceResync() }
      } label: {
        AsyncActionLabel(isLoading: isResyncing, showSuccess: false) {
          TintedLabel(L10n.Settings.DeviceNotificationRules.resync, systemImage: "arrow.up.circle")
        }
      }
      .disabled(!canAct || isResyncing)

      switch resyncStatus {
      case .idle:
        EmptyView()
      case let .succeeded(at):
        LabeledContent {
          Text(at, style: .relative)
        } label: {
          Label(L10n.Settings.DeviceNotificationRules.resynced, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      case let .failed(message):
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
    } footer: {
      Text(L10n.Settings.DeviceNotificationRules.actionsFooter)
    }
    .themedRowBackground(theme)
  }

  private func ruleRow(title: String, subtitle: String, mode: FirmwareNotifMode) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(subtitle)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      Spacer()
      modeBadge(mode)
    }
    .accessibilityElement(children: .combine)
  }

  private func modeBadge(_ mode: FirmwareNotifMode) -> some View {
    let color = color(for: mode)
    return Text(description(of: mode))
      .font(.caption.bold())
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.18))
      .foregroundStyle(color)
      .clipShape(.capsule)
  }

  // MARK: - Formatting

  private var canAct: Bool {
    isConnected && support != .unsupported
  }

  /// What the phone's preferences ask for, before the firmware cap.
  private var localChannelRuleCount: Int {
    NotifSyncService.channelRules(from: channels).count
  }

  private var localContactRuleCount: Int {
    NotifSyncService.contactRules(from: contacts).count
  }

  private func description(of mode: FirmwareNotifMode) -> String {
    switch mode {
    case .silent: L10n.Settings.DeviceNotificationRules.Mode.silent
    case .all: L10n.Settings.DeviceNotificationRules.Mode.all
    case .mentions: L10n.Settings.DeviceNotificationRules.Mode.mentions
    case .urgent: L10n.Settings.DeviceNotificationRules.Mode.urgent
    }
  }

  private func color(for mode: FirmwareNotifMode) -> Color {
    switch mode {
    case .silent: .gray
    case .mentions: .orange
    case .all: .green
    case .urgent: .red
    }
  }

  private func channelName(forIndex index: UInt8) -> String {
    channels.first { $0.index == index }?.name
      ?? L10n.Settings.DeviceNotificationRules.unknownChannel
  }

  private func contactName(forPrefix prefix: Data) -> String {
    contacts.first { $0.publicKey.prefix(prefix.count) == prefix }?.name
      ?? L10n.Settings.DeviceNotificationRules.unknownContact
  }

  // MARK: - Actions

  private func loadLocal() async {
    guard let services = appState.services, let radioID = appState.currentRadioID else { return }
    channels = await (try? services.dataStore.fetchChannels(radioID: radioID)) ?? []
    contacts = await (try? services.dataStore.fetchContacts(radioID: radioID)) ?? []
  }

  private func loadDevice() async {
    guard let services = appState.services, isConnected else {
      fetchError = L10n.Settings.DeviceNotificationRules.notConnected
      deviceBlob = nil
      return
    }

    isFetching = true
    defer { isFetching = false }

    do {
      // An empty slot is a valid state, not an error: the firmware simply has nothing
      // stored yet and is falling back to its default mode.
      deviceBlob = try await services.notifSyncService.deviceBlob() ?? NotifPrefsBlob()
      lastFetched = Date()
      fetchError = nil
    } catch {
      logger.warning("Could not read device notification rules: \(error)")
      fetchError = error.localizedDescription
      deviceBlob = nil
    }
    support = await services.notifSyncService.support
    if support == .unsupported {
      deviceBlob = nil
      fetchError = nil
    }
  }

  private func forceResync() async {
    guard let services = appState.services, let radioID = appState.currentRadioID else {
      resyncStatus = .failed(L10n.Settings.DeviceNotificationRules.notConnected)
      return
    }

    isResyncing = true
    defer { isResyncing = false }

    do {
      // A rejected write is swallowed by the service, so the outcome — not the absence of a
      // thrown error — is what says whether anything reached the radio.
      let outcome = try await services.notifSyncService.syncNow(radioID: radioID, force: true)
      resyncStatus = outcome == .unsupported
        ? .failed(L10n.Settings.DeviceNotificationRules.unsupported)
        : .succeeded(at: Date())
      await loadDevice()
    } catch {
      resyncStatus = .failed(error.localizedDescription)
    }
  }
}
