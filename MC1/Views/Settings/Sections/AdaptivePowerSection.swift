import SwiftUI
import MC1Services

struct AdaptivePowerSection: View {
    @Environment(\.appState) private var appState

    @State private var isEnabled: Bool = false
    @State private var paGainDb: Double = 0
    @State private var baseStepIndex: Int = 1

    private var powerService: AdaptivePowerService {
        appState.adaptivePowerService
    }

    private var deviceID: UUID? {
        appState.connectedDevice?.id
    }

    var body: some View {
        Section {
            Toggle("Adaptive Power", isOn: $isEnabled)
                .onChange(of: isEnabled) { _, newValue in
                    save()
                    powerService.setEnabled(newValue)
                }

            if isEnabled {
                Picker("Amplifier", selection: $paGainDb) {
                    Text("None (built-in radio only)").tag(0.0)
                    Text("WisMesh Pocket 1W (measured)").tag(8.0)
                    Text("Heltec V4 (measured)").tag(11.0)
                    Text("Custom +6 dB").tag(6.0)
                    Text("Custom +10 dB").tag(10.0)
                    Text("Custom +12 dB").tag(12.0)
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .onChange(of: paGainDb) { _, newValue in
                    save()
                    powerService.setPAGain(newValue)
                }

                Picker("Base Output", selection: $baseStepIndex) {
                    ForEach(powerService.availableSteps) { step in
                        Text(pickerLabel(for: step)).tag(step.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .onChange(of: baseStepIndex) { _, newValue in
                    save()
                    powerService.setBaseStep(newValue)
                }

                statusPanel
            }
        } header: {
            Text("Adaptive Power")
        } footer: {
            if isEnabled {
                Text("Starts at your base output level. Escalates when messages aren't repeated. Tap the signal bars to manually override.")
            } else {
                Text("Manages TX power automatically — starts low and escalates when messages aren't repeated.")
            }
        }
        .onAppear { loadSettings() }
    }

    // MARK: - Status Panel

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(outputString(for: powerService.currentStep))
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
            }

            if paGainDb > 0 {
                let actualDbm = powerService.actualEirpDbm(for: powerService.currentStep)
                Text("Radio \(powerService.currentRadioDbm) dBm → PA → \(String(format: "%.1f", actualDbm)) dBm out")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            confirmationRow

            escalationRow
        }
    }

    private var confirmationRow: some View {
        HStack(spacing: 4) {
            if powerService.lastApplyFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Radio did not confirm")
                    .foregroundStyle(.red)
            } else if let confirmed = powerService.confirmedRadioDbm {
                let matches = confirmed == powerService.currentRadioDbm
                Image(systemName: matches ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(matches ? .green : .orange)
                Text(matches ? "Confirmed" : "Mismatch: radio at \(confirmed) dBm")
                    .foregroundStyle(matches ? Color.secondary : Color.orange)
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Text("Waiting for radio")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var escalationRow: some View {
        HStack(spacing: 6) {
            if powerService.isElevated {
                Text("Elevated from \(powerService.baseStep.label) base")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("At base level")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if powerService.isUserOverride {
                Text("manual")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2))
                    .clipShape(Capsule())
            }
            Spacer()
            if powerService.isElevated || powerService.isUserOverride {
                Button("Reset") {
                    Task { await powerService.resetToBase() }
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Formatting

    private var statusColor: Color {
        powerService.isAtMax ? .red : powerService.isElevated ? .orange : .green
    }

    private func pickerLabel(for step: AdaptivePowerService.PowerStep) -> String {
        if paGainDb > 0 {
            let actualDbm = powerService.actualEirpDbm(for: step)
            let actualMw = powerService.actualMilliwatts(for: step)
            return "\(formatPower(actualMw)) (\(String(format: "%.0f", actualDbm)) dBm)"
        }
        return "\(step.label) (\(Int(step.eirpDbm)) dBm)"
    }

    private func outputString(for step: AdaptivePowerService.PowerStep) -> String {
        if paGainDb > 0 {
            let actualDbm = powerService.actualEirpDbm(for: step)
            let actualMw = powerService.actualMilliwatts(for: step)
            return "\(formatPower(actualMw)) — \(String(format: "%.1f", actualDbm)) dBm"
        }
        return "\(step.label) — \(Int(step.eirpDbm)) dBm"
    }

    private func formatPower(_ mw: Int) -> String {
        if mw >= 1000 {
            let watts = Double(mw) / 1000.0
            if watts == Double(Int(watts)) {
                return "\(Int(watts))W"
            }
            return String(format: "%.1fW", watts)
        }
        return "\(mw)mW"
    }

    // MARK: - Persistence

    private func loadSettings() {
        guard let deviceID else { return }
        let prefs = DevicePreferenceStore()
        isEnabled = prefs.isAdaptivePowerEnabled(deviceID: deviceID)
        paGainDb = prefs.paGainDb(deviceID: deviceID)
        baseStepIndex = prefs.adaptivePowerBaseStep(deviceID: deviceID)
    }

    private func save() {
        guard let deviceID else { return }
        let prefs = DevicePreferenceStore()
        prefs.setAdaptivePowerEnabled(isEnabled, deviceID: deviceID)
        prefs.setPAGainDb(paGainDb, deviceID: deviceID)
        prefs.setAdaptivePowerBaseStep(baseStepIndex, deviceID: deviceID)
    }
}
