import SwiftUI
import MC1Services
import MeshCore

/// Diagnostic view showing the notification rules currently stored on the
/// Digitaino custom firmware (fetched via ``MeshCoreSession/getSync(_:)``),
/// alongside a manual force-resync action.
///
/// Helps verify that iOS-side mute / level changes are actually landing on the
/// device. Not navigated to by default users — surfaced in Settings under
/// "Notifications" for support and debugging.
struct WioNotificationsDiagnosticView: View {
    @Environment(\.appState) private var appState

    @State private var deviceBlob: NotifPrefsBlob?
    @State private var fetchError: String?
    @State private var lastFetched: Date?
    @State private var isFetching = false
    @State private var isResyncing = false
    @State private var resyncStatus: ResyncStatus = .idle
    @State private var channels: [ChannelDTO] = []
    @State private var contacts: [ContactDTO] = []

    enum ResyncStatus: Equatable {
        case idle
        case success(at: Date)
        case failure(String)
    }

    var body: some View {
        List {
            connectionSection
            if let blob = deviceBlob {
                deviceStateSection(blob)
                channelRulesSection(blob)
                contactRulesSection(blob)
            } else if let err = fetchError {
                errorSection(err)
            } else if !isFetching {
                ProgressView().frame(maxWidth: .infinity)
            }
            actionsSection
        }
        .navigationTitle("Wio L1 Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDevice()
            await loadLocal()
        }
        .refreshable {
            await loadDevice()
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            if appState.connectionState == .ready {
                Label("Connected", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Not connected", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text("Rules below are read directly from your Wio L1 Pro. Connect to view or update them.")
        }
    }

    private func deviceStateSection(_ blob: NotifPrefsBlob) -> some View {
        Section {
            HStack {
                Text("Schema version")
                Spacer()
                Text("\(blob.version)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Default mode")
                Spacer()
                Text(modeDescription(blob.globalMode)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Channel overrides")
                Spacer()
                Text("\(blob.channelRules.count)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Contact overrides")
                Spacer()
                Text("\(blob.contactRules.count)").foregroundStyle(.secondary)
            }
            if let when = lastFetched {
                HStack {
                    Text("Fetched")
                    Spacer()
                    Text(when, style: .relative).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Device state")
        } footer: {
            Text("Anything not listed below uses the default mode.")
        }
    }

    private func channelRulesSection(_ blob: NotifPrefsBlob) -> some View {
        Section {
            if blob.channelRules.isEmpty {
                Text("No per-channel overrides").foregroundStyle(.secondary)
            } else {
                ForEach(Array(blob.channelRules.enumerated()), id: \.offset) { _, rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(channelName(for: rule.channelIdx))
                            Text("Index \(rule.channelIdx)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        modeBadge(rule.mode)
                    }
                }
            }
        } header: {
            Text("Per-channel rules")
        }
    }

    private func contactRulesSection(_ blob: NotifPrefsBlob) -> some View {
        Section {
            if blob.contactRules.isEmpty {
                Text("No per-contact overrides").foregroundStyle(.secondary)
            } else {
                ForEach(Array(blob.contactRules.enumerated()), id: \.offset) { _, rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(contactName(for: rule.pubKeyPrefix))
                            Text(rule.pubKeyPrefix.hexString())
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        modeBadge(rule.mode)
                    }
                }
            }
        } header: {
            Text("Per-contact rules (DMs)")
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
        } header: {
            Text("Couldn't read device state")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await loadDevice() }
            } label: {
                if isFetching {
                    HStack { ProgressView(); Text("Refreshing…") }
                } else {
                    Label("Refresh from device", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isFetching || appState.connectionState != .ready)

            Button {
                Task { await forceResync() }
            } label: {
                if isResyncing {
                    HStack { ProgressView(); Text("Resyncing…") }
                } else {
                    Label("Force resync to device", systemImage: "arrow.up.circle")
                }
            }
            .disabled(isResyncing || appState.connectionState != .ready)

            switch resyncStatus {
            case .idle:
                EmptyView()
            case .success(let at):
                Label {
                    HStack {
                        Text("Resynced")
                        Spacer()
                        Text(at, style: .relative).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case .failure(let err):
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Refresh re-reads the rules stored on the device. Force resync pushes the current iOS-side mute and notification-level state up to the device.")
        }
    }

    // MARK: - Helpers

    private func modeDescription(_ mode: FirmwareNotifMode) -> String {
        switch mode {
        case .silent:   return "Silent"
        case .all:      return "All messages"
        case .mentions: return "Mentions only"
        case .urgent:   return "Urgent only"
        }
    }

    @ViewBuilder
    private func modeBadge(_ mode: FirmwareNotifMode) -> some View {
        let label: String = modeDescription(mode)
        let color: Color = {
            switch mode {
            case .silent:   return .gray
            case .mentions: return .orange
            case .all:      return .green
            case .urgent:   return .red
            }
        }()
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func channelName(for index: UInt8) -> String {
        if let match = channels.first(where: { $0.index == index }) {
            return match.displayName
        }
        return "Channel \(index)"
    }

    private func contactName(for prefix: Data) -> String {
        guard let match = contacts.first(where: { $0.publicKey.prefix(prefix.count) == prefix }) else {
            return "Unknown contact"
        }
        return match.name
    }

    // MARK: - Actions

    @MainActor
    private func loadDevice() async {
        guard let services = appState.services else {
            fetchError = "App services unavailable."
            return
        }
        guard appState.connectionState == .ready else {
            fetchError = "Device is not connected."
            return
        }
        isFetching = true
        defer { isFetching = false }
        do {
            let raw = try await services.session.getSync(.notifPrefs)
            if raw.isEmpty {
                deviceBlob = NotifPrefsBlob(globalMode: .all)
            } else {
                deviceBlob = NotifPrefsBlob(decoding: raw) ?? NotifPrefsBlob(globalMode: .all)
            }
            lastFetched = Date()
            fetchError = nil
        } catch {
            fetchError = error.localizedDescription
            deviceBlob = nil
        }
    }

    @MainActor
    private func loadLocal() async {
        guard let services = appState.services, let deviceID = appState.currentDeviceID else { return }
        async let chs: [ChannelDTO] = (try? await services.dataStore.fetchChannels(deviceID: deviceID)) ?? []
        async let cts: [ContactDTO] = (try? await services.dataStore.fetchContacts(deviceID: deviceID)) ?? []
        channels = await chs
        contacts = await cts
    }

    @MainActor
    private func forceResync() async {
        guard let services = appState.services, let deviceID = appState.currentDeviceID else {
            resyncStatus = .failure("App services unavailable.")
            return
        }
        isResyncing = true
        defer { isResyncing = false }
        do {
            try await services.notifSyncService.syncNow(deviceID: deviceID)
            resyncStatus = .success(at: Date())
            // Re-fetch so the screen reflects the just-pushed state
            await loadDevice()
        } catch {
            resyncStatus = .failure(error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        WioNotificationsDiagnosticView()
    }
    .environment(\.appState, AppState())
}
