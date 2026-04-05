import MC1Services
import SwiftUI

/// Compact popover listing all reachable repeaters with firmware-style signal display.
/// Each row: hex ID | ▼ RX bars | ▲ TX bars/status | RTT | age
struct RepeaterSignalPopover: View {
    @Environment(\.appState) private var appState
    @State private var isApplyingHashMode = false

    var body: some View {
        let service = appState.signalBarsService
        VStack(alignment: .leading, spacing: 0) {
            // Header with controls
            HStack {
                Text("Repeaters")
                    .font(.system(.subheadline, weight: .semibold))
                Spacer()

                Button {
                    Task { await service.refreshAll() }
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
                .accessibilityLabel("Refresh all")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if service.repeaters.isEmpty {
                Text("Scanning for repeaters...")
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
                            RepeaterCompactRow(repeater: repeater)
                            if repeater.id != service.repeaters.last?.id {
                                Divider()
                                    .padding(.horizontal, 8)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            // Path hash size quick-picker
            if appState.connectedDevice != nil {
                Divider()
                    .padding(.horizontal, 8)
                pathHashPicker
            }
        }
        .frame(width: 250)
        .padding(.bottom, 8)
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

// MARK: - Compact Row

private struct RepeaterCompactRow: View {
    let repeater: SignalBarsService.RepeaterSignal

    var body: some View {
        HStack(spacing: 0) {
            // Hex ID (or name if available)
            VStack(alignment: .leading, spacing: 0) {
                if let name = repeater.name {
                    Text(name)
                        .font(.system(.caption, weight: .medium))
                        .lineLimit(1)
                    Text(repeater.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(repeater.id)
                        .font(.system(.caption, design: .monospaced, weight: .medium))
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
