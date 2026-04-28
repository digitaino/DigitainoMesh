import MC1Services
import SwiftUI

/// Compact toolbar button showing the best repeater's RX+TX signal and hex ID.
/// Arrows are tucked into the top-leading corner above the shortest bar (firmware style).
/// Arrows flash briefly when packets are received (▼) or sent (▲).
struct SignalBarsToolbarItem: View {
    @Environment(\.appState) private var appState
    @State private var showingDetail = false
    @State private var rxFlash = false
    @State private var txFlash = false
    @State private var watchFlash = false
    @State private var lastRxTick: UInt = 0
    @State private var lastTxTick: UInt = 0
    @State private var lastWatchTick: UInt = 0

    /// When true, always shows even if a survey is active (used in survey view's own toolbar).
    var showDuringSurvey = false

    var body: some View {
        let service = appState.signalBarsService
        if appState.connectionState == .ready || appState.connectionState == .connected,
           isEnabled,
           showDuringSurvey || !appState.isSurveyActive {
            Button { showingDetail = true } label: {
                if let best = service.bestRepeater {
                    // Repeater found — show full signal bars
                    HStack(spacing: 3) {
                        // RX: ▼ tucked above shortest bar, SNR label below
                        VStack(spacing: 0) {
                            signalGroup(
                                arrowName: "arrow.down",
                                arrowColor: best.rxQuality.color,
                                arrowFlash: rxFlash,
                                barsValue: best.rxQuality.barLevel,
                                barsColor: best.rxQuality.color
                            )
                            if let snr = best.rxSnr {
                                Text("\(Int(snr))dB")
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(best.rxQuality.color)
                            }
                        }

                        // TX: ▲ tucked above shortest bar, TX SNR below
                        VStack(spacing: 0) {
                            txGroup(for: best)
                            if case .measured(let quality) = best.txState, let txSnr = best.txSnr {
                                Text("\(Int(txSnr))dB")
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(quality.color)
                            }
                        }

                        // Hex ID + adaptive power label
                        VStack(spacing: 1) {
                            Text(best.id)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if appState.adaptivePowerService.isEnabled {
                                let power = appState.adaptivePowerService
                                Text(power.currentStep.label)
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(power.isAtMax ? .red : power.isElevated ? .orange : .green)
                            }
                        }

                        watchBadge
                    }
                } else {
                    // No repeaters yet — show scanning state with TX power if enabled
                    HStack(spacing: 3) {
                        Image(systemName: "cellularbars", variableValue: 0)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 14))

                        if appState.adaptivePowerService.isEnabled {
                            let power = appState.adaptivePowerService
                            Text(power.currentStep.label)
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(power.isAtMax ? .red : power.isElevated ? .orange : .green)
                        }

                        watchBadge
                    }
                }
            }
            .accessibilityLabel(service.bestRepeater.map { "Signal: \($0.rxQuality.qualityLabel) from \($0.name ?? $0.id)" } ?? "No repeaters found")
            .popover(isPresented: $showingDetail) {
                RepeaterSignalPopover()
                    .presentationCompactAdaptation(.popover)
            }
            .onChange(of: service.rxFlashTick) { _, newValue in
                guard newValue != lastRxTick else { return }
                lastRxTick = newValue
                triggerFlash($rxFlash)
            }
            .onChange(of: service.txFlashTick) { _, newValue in
                guard newValue != lastTxTick else { return }
                lastTxTick = newValue
                triggerFlash($txFlash)
            }
            .onChange(of: appState.watchedRepeaterFlashTick) { _, newValue in
                guard newValue != lastWatchTick else { return }
                lastWatchTick = newValue
                watchFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    watchFlash = false
                }
            }
        }
    }

    // MARK: - Watch Badge

    @ViewBuilder
    private var watchBadge: some View {
        if appState.watchedRepeaterHexID != nil {
            Image(systemName: "binoculars.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
                .scaleEffect(watchFlash ? 1.4 : 1.0)
                .animation(.easeOut(duration: 0.3), value: watchFlash)
        }
    }

    // MARK: - Signal Group (arrow tucked above shortest bar)

    /// Overlays a small arrow in the top-leading corner of the cellularbars icon,
    /// sitting in the empty vertical space above the shortest (leftmost) bar.
    private func signalGroup(
        arrowName: String,
        arrowColor: Color,
        arrowFlash: Bool,
        barsValue: Double,
        barsColor: Color
    ) -> some View {
        Image(systemName: "cellularbars", variableValue: barsValue)
            .foregroundStyle(barsColor)
            .font(.system(size: 14))
            .overlay(alignment: .topLeading) {
                Image(systemName: arrowName)
                    .font(.system(size: 5, weight: .black))
                    .foregroundStyle(arrowColor)
                    .opacity(arrowFlash ? 1.0 : 0.6)
                    .scaleEffect(arrowFlash ? 1.3 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: arrowFlash)
                    .offset(x: -1, y: -1)
            }
    }

    // MARK: - TX Group

    @ViewBuilder
    private func txGroup(for repeater: SignalBarsService.RepeaterSignal) -> some View {
        switch repeater.txState {
        case .unknown:
            HStack(spacing: 1) {
                txArrow(color: .secondary)
                Image(systemName: "questionmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .measuring:
            HStack(spacing: 1) {
                txArrow(color: .secondary)
                ProgressView()
                    .controlSize(.mini)
            }
        case .measured(let quality):
            signalGroup(
                arrowName: "arrow.up",
                arrowColor: quality.color,
                arrowFlash: txFlash,
                barsValue: quality.barLevel,
                barsColor: quality.color
            )
        case .failed:
            HStack(spacing: 1) {
                txArrow(color: .red)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
    }

    private func txArrow(color: Color) -> some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 5, weight: .black))
            .foregroundStyle(color)
            .opacity(txFlash ? 1.0 : 0.6)
            .scaleEffect(txFlash ? 1.3 : 1.0)
            .animation(.easeOut(duration: 0.15), value: txFlash)
    }

    // MARK: - Flash

    private func triggerFlash(_ binding: Binding<Bool>) {
        binding.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            binding.wrappedValue = false
        }
    }

    private var isEnabled: Bool {
        guard let deviceID = appState.currentDeviceID else { return true }
        return DevicePreferenceStore().isSignalBarsEnabled(deviceID: deviceID)
    }
}
