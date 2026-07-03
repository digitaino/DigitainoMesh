import AVFoundation
import MC1Services
import SwiftUI

/// Compact popover listing all reachable repeaters with firmware-style signal display.
/// Each row: hex ID | ▼ RX bars | ▲ TX bars/status | RTT | age
struct RepeaterSignalPopover: View {
    @Environment(\.appState) private var appState
    @State private var isApplyingHashMode = false
    @State private var showingWatchPicker = false

    var body: some View {
        let service = appState.signalBarsService
        VStack(alignment: .leading, spacing: 0) {
            // Header with controls
            HStack {
                Text("Repeaters")
                    .font(.system(.subheadline, weight: .semibold))
                Spacer()

                Button {
                    Task { await service.startProbe() }
                } label: {
                    if service.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                    }
                }
                .buttonStyle(.plain)
                .disabled(service.isRefreshing)
                .accessibilityLabel("Scan for repeaters")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Sync status: are these bars mirrored from the radio (viewer) or measured by the app (engine)?
            HStack(spacing: 4) {
                Image(systemName: service.mode == .viewer
                      ? "antenna.radiowaves.left.and.right"
                      : "iphone.radiowaves.left.and.right")
                    .font(.system(size: 9))
                Text(service.mode == .viewer ? "Synced with radio" : "Measuring locally")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            // Adaptive power quick-picker
            if appState.adaptivePowerService.isEnabled {
                adaptivePowerRow
                Divider()
                    .padding(.horizontal, 8)
            }

            if service.repeaters.isEmpty {
                Text("Scanning for repeaters…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                // Column headers
                HStack(spacing: 0) {
                    Text("ID")
                        .frame(width: 52, alignment: .leading)
                    Text("RX")
                        .frame(width: 32, alignment: .center)
                    Text("TX")
                        .frame(width: 32, alignment: .center)
                    Text("RTT")
                        .frame(width: 44, alignment: .trailing)
                    Text("Age")
                        .frame(width: 48, alignment: .trailing)
                }
                .font(.system(.caption2, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

                Divider()
                    .padding(.horizontal, 8)

                // Repeater rows
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(service.repeaters) { repeater in
                            let isWatched = appState.watchedRepeaterHexID == repeater.id
                                || (appState.watchedRepeaterHexID.map { repeater.id.hasPrefix($0) || $0.hasPrefix(repeater.id) } ?? false)
                            RepeaterCompactRow(repeater: repeater, isWatched: isWatched)
                                .contextMenu {
                                    Button {
                                        Task { await service.requestRefresh(targetHexID: repeater.id) }
                                    } label: {
                                        Label("Ping Now", systemImage: "dot.radiowaves.left.and.right")
                                    }
                                    if isWatched {
                                        Button(role: .destructive) {
                                            appState.clearWatchedRepeater()
                                        } label: {
                                            Label("Stop Watching", systemImage: "binoculars.fill")
                                        }
                                    } else {
                                        Button {
                                            appState.watchRepeater(hexID: repeater.id, name: repeater.name)
                                        } label: {
                                            Label("Watch Repeater", systemImage: "binoculars")
                                        }
                                    }
                                }
                            if repeater.id != service.repeaters.last?.id {
                                Divider()
                                    .padding(.horizontal, 8)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            // Watched repeater section (grouped below signal table)
            Divider()
                .padding(.horizontal, 8)
            watchedRepeaterSection

            // Path hash size quick-picker
            if appState.connectedDevice != nil {
                Divider()
                    .padding(.horizontal, 8)
                pathHashPicker
            }
        }
        .frame(width: 250)
        .padding(.bottom, 8)
        .sheet(isPresented: $showingWatchPicker) {
            WatchRepeaterPicker()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Watched Repeater Section

    @State private var watchFlash = false
    @State private var previousFlashTick: UInt = 0

    private var watchedRepeaterSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let hexID = appState.watchedRepeaterHexID {
                // Active watch — name, signal, packet count, stop button
                HStack(spacing: 6) {
                    Image(systemName: "binoculars.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)

                    Text(appState.watchedRepeaterName ?? hexID)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .lineLimit(1)

                    if let rxQ = appState.watchedRepeaterRxQuality {
                        Image(systemName: "cellularbars", variableValue: rxQ.barLevel)
                            .foregroundStyle(rxQ.color)
                            .font(.system(size: 12))
                    }

                    Spacer()

                    if appState.watchedRepeaterPacketCount > 0 {
                        Text("\(appState.watchedRepeaterPacketCount)")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }

                    Button(role: .destructive) {
                        appState.clearWatchedRepeater()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(watchFlash ? 0.15 : 0))
                        .animation(.easeOut(duration: 0.6), value: watchFlash)
                )
                .onChange(of: appState.watchedRepeaterFlashTick) { _, newTick in
                    guard newTick != previousFlashTick else { return }
                    previousFlashTick = newTick
                    watchFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        watchFlash = false
                    }
                }

                // Sound + change controls
                HStack(spacing: 6) {
                    Button {
                        appState.watchedRepeaterSoundEnabled.toggle()
                    } label: {
                        Image(systemName: appState.watchedRepeaterSoundEnabled
                              ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(appState.watchedRepeaterSoundEnabled ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)

                    if appState.watchedRepeaterSoundEnabled {
                        WatchSoundPicker()
                    }

                    Spacer()

                    Button {
                        showingWatchPicker = true
                    } label: {
                        Text("Change…")
                            .font(.system(.caption2, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            } else {
                // No active watch — just a button
                Button {
                    showingWatchPicker = true
                } label: {
                    Label("Watch Repeater…", systemImage: "binoculars")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Adaptive Power Row

    private var adaptivePowerRow: some View {
        let power = appState.adaptivePowerService

        return HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10))
                .foregroundStyle(powerColor)

            Text("TX")
                .font(.system(.caption2, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            Menu {
                ForEach(power.availableSteps) { step in
                    Button {
                        Task { await power.setUserOverride(stepIndex: step.id) }
                    } label: {
                        HStack {
                            Text(step.label)
                            if step.id == power.currentStepIndex {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if power.isElevated || power.isUserOverride {
                    Divider()
                    Button {
                        Task { await power.resetToBase() }
                    } label: {
                        Label("Reset to Base", systemImage: "arrow.counterclockwise")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(power.currentStep.label)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var powerColor: Color {
        let power = appState.adaptivePowerService
        return power.isAtMax ? .red : power.isElevated ? .orange : .green
    }

    // MARK: - Path Hash Size Picker

    private var pathHashPicker: some View {
        let currentMode = appState.connectedDevice?.pathHashMode ?? 0
        return HStack(spacing: 6) {
            Image(systemName: "number")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Path Hash")
                .font(.system(.caption2, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            if isApplyingHashMode {
                ProgressView()
                    .controlSize(.mini)
            }

            Picker("", selection: Binding(
                get: { currentMode },
                set: { newMode in
                    applyHashMode(newMode)
                }
            )) {
                Text("1B").tag(UInt8(0))
                Text("2B").tag(UInt8(1))
                Text("3B").tag(UInt8(2))
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .disabled(isApplyingHashMode)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func applyHashMode(_ mode: UInt8) {
        guard mode != appState.connectedDevice?.pathHashMode else { return }
        isApplyingHashMode = true
        Task {
            defer { isApplyingHashMode = false }
            do {
                guard let settingsService = appState.services?.settingsService else { return }
                _ = try await settingsService.setPathHashModeVerified(mode)
            } catch {
                // Silently revert — the picker will sync from device state
            }
        }
    }
}

// MARK: - Watch Sound Picker

/// Inline picker for the watched repeater alert sound.
private struct WatchSoundPicker: View {
    @Environment(\.appState) private var appState

    var body: some View {
        Menu {
            ForEach(WatchTone.allCases) { tone in
                Button {
                    appState.watchedRepeaterToneID = tone.rawValue
                    tone.playPreview()
                } label: {
                    HStack {
                        Text(tone.displayName)
                        if appState.watchedRepeaterToneID == tone.rawValue {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(WatchTone.current(from: appState.watchedRepeaterToneID).displayName)
                    .font(.system(.caption2, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.fill.tertiary, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Watch Repeater Picker

/// Sheet for selecting a repeater to watch — unified search filters by name and hex ID.
private struct WatchRepeaterPicker: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var repeaterContacts: [ContactDTO] = []

    private var filteredContacts: [ContactDTO] {
        guard !searchText.isEmpty else { return repeaterContacts }
        let query = searchText.lowercased()
        return repeaterContacts.filter {
            $0.displayName.lowercased().contains(query)
            || $0.publicKeyHex.lowercased().contains(query)
            || $0.name.lowercased().contains(query)
        }
    }

    private var isValidHexID: Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0.isHexDigit }
    }

    var body: some View {
        NavigationStack {
            List {
                // Direct hex entry — shown when the search text is valid hex
                if isValidHexID {
                    Section {
                        Button {
                            let hexID = searchText.trimmingCharacters(in: .whitespaces).uppercased()
                            appState.watchRepeater(hexID: hexID, name: nil)
                            dismiss()
                        } label: {
                            Label {
                                Text("Watch \"\(searchText.trimmingCharacters(in: .whitespaces).uppercased())\"")
                                    .font(.system(.body, design: .monospaced))
                            } icon: {
                                Image(systemName: "binoculars")
                            }
                        }
                    } header: {
                        Text("By Hex ID")
                    }
                }

                // Known repeater contacts
                if !filteredContacts.isEmpty {
                    Section {
                        ForEach(filteredContacts, id: \.id) { contact in
                            Button {
                                let hexID = contact.publicKey.prefix(2).map {
                                    String(format: "%02X", $0)
                                }.joined()
                                appState.watchRepeater(hexID: hexID, name: contact.displayName)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(contact.displayName)
                                            .font(.system(.body, weight: .medium))
                                        Text(contact.publicKeyHex.prefix(8) + "…")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "binoculars")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Known Repeaters")
                    }
                } else if !searchText.isEmpty && !isValidHexID {
                    Section {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Name or hex ID")
            .navigationTitle("Watch Repeater")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if appState.watchedRepeaterHexID != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Stop", role: .destructive) {
                            appState.clearWatchedRepeater()
                            dismiss()
                        }
                    }
                }
            }
            .task {
                guard let deviceID = appState.currentDeviceID,
                      let dataStore = appState.offlineDataStore else { return }
                let contacts = (try? await dataStore.fetchContacts(deviceID: deviceID)) ?? []
                repeaterContacts = contacts.filter { $0.type == .repeater }
                    .sorted { $0.name < $1.name }
            }
        }
    }
}

// MARK: - Compact Row

private struct RepeaterCompactRow: View {
    let repeater: SignalBarsService.RepeaterSignal
    var isWatched: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Hex ID (or name if available)
            VStack(alignment: .leading, spacing: 0) {
                if let name = repeater.name {
                    Text(name)
                        .font(.system(.caption, weight: .medium))
                        .lineLimit(1)
                } else {
                    Text(repeater.id)
                        .font(.system(.caption, design: .monospaced, weight: .medium))
                }
                if repeater.name != nil {
                    Text(repeater.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, alignment: .leading)

            // RX: ▼ tucked above shortest bar
            Image(systemName: "cellularbars", variableValue: repeater.rxQuality.barLevel)
                .foregroundStyle(repeater.rxQuality.color)
                .font(.system(size: 13))
                .overlay(alignment: .topLeading) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 5, weight: .black))
                        .foregroundStyle(repeater.rxQuality.color)
                        .offset(x: -1, y: -1)
                }
                .frame(width: 32, alignment: .center)

            // TX: ▲ tucked above shortest bar
            txIndicator
                .frame(width: 32, alignment: .center)

            // RTT
            Group {
                if let rtt = repeater.rttMs {
                    Text("\(rtt)ms")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(width: 44, alignment: .trailing)

            // Age
            Text(repeater.lastHeard, style: .relative)
                .font(.system(.caption2))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var txIndicator: some View {
        switch repeater.txState {
        case .unknown:
            HStack(spacing: 1) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 5, weight: .black))
                    .foregroundStyle(.secondary)
                Image(systemName: "questionmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .measuring:
            HStack(spacing: 1) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 5, weight: .black))
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.mini)
            }
        case .measured(let quality):
            Image(systemName: "cellularbars", variableValue: quality.barLevel)
                .foregroundStyle(quality.color)
                .font(.system(size: 13))
                .overlay(alignment: .topLeading) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 5, weight: .black))
                        .foregroundStyle(quality.color)
                        .offset(x: -1, y: -1)
                }
        case .failed:
            HStack(spacing: 1) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 5, weight: .black))
                    .foregroundStyle(.red)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Watch Tone

/// Available alert tones for the watched repeater ping notification.
enum WatchTone: String, CaseIterable, Identifiable {
    case note = "sms-received3"
    case chime = "sms-received1"
    case bell = "sms-received5"
    case tweet = "tweet_sent"
    case tink = "Tink"
    case tock = "Tock"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .note: "Note"
        case .chime: "Chime"
        case .bell: "Bell"
        case .tweet: "Tweet"
        case .tink: "Tink"
        case .tock: "Tock"
        }
    }

    var filePath: String {
        "/System/Library/Audio/UISounds/\(rawValue).caf"
    }

    static func current(from id: String) -> WatchTone {
        WatchTone(rawValue: id) ?? .note
    }

    @MainActor
    func playPreview() {
        let url = URL(fileURLWithPath: filePath)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            _previewPlayer = try AVAudioPlayer(contentsOf: url)
            _previewPlayer?.volume = 0.8
            _previewPlayer?.play()
        } catch {
            // Sound file not available on this device
        }
    }
}

@MainActor private var _previewPlayer: AVAudioPlayer?
