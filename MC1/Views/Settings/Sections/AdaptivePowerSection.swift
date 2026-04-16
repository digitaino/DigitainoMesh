import SwiftUI
import MC1Services

/// Settings section for configuring adaptive TX power control and PA gain offset.
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
                // Amplifier picker
                Picker("Amplifier", selection: $paGainDb) {
                    Text("None (built-in radio only)").tag(0.0)
                    Text("WisMesh Pocket 1W (+8 dB)").tag(8.0)
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

                // Base Power Step
                Picker("Base Power", selection: $baseStepIndex) {
                    ForEach(powerService.availableSteps) { step in
                        Text(stepDescription(step)).tag(step.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .onChange(of: baseStepIndex) { _, newValue in
                    save()
                    powerService.setBaseStep(newValue)
                }

                // Live status
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text("Target TX: \(powerService.currentRadioDbm) dBm")
                            .font(.system(.subheadline, design: .monospaced))
                        if paGainDb > 0 {
                            Text("+ \(Int(paGainDb)) dB amp = \(Int(powerService.currentStep.eirpDbm)) dBm EIRP")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Device-confirmed power feedback
                    HStack(spacing: 6) {
                        if powerService.lastApplyFailed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                            Text("Radio did not confirm power change")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if let confirmed = powerService.confirmedRadioDbm {
                            Image(systemName: confirmed == powerService.currentRadioDbm
                                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(confirmed == powerService.currentRadioDbm ? .green : .orange)
                            Text("Radio confirms: \(confirmed) dBm")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(confirmed == powerService.currentRadioDbm ? Color.secondary : Color.orange)
                        } else {
                            Image(systemName: "questionmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Not yet confirmed by radio")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 6) {
                        Text("Level: \(powerService.currentStep.label)")
                            .font(.subheadline)
                            .foregroundStyle(statusColor)
                        if powerService.isElevated {
                            Text("(base: \(powerService.baseStep.label))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                            .font(.subheadline)
                        }
                    }
                }
            }
        } header: {
            Text("Adaptive Power")
        } footer: {
            if isEnabled {
                if paGainDb > 0 {
                    Text("Your amplifier adds \(Int(paGainDb)) dB. The radio chip is set to \(powerService.currentRadioDbm) dBm so the total output is \(powerService.currentStep.label). Power escalates when messages aren't repeated, and ramps back down on success. Tap the signal bars to override.")
                } else {
                    Text("Sends at \(powerService.baseStep.label) base power. If no repeats are heard, tap Send Again to escalate. Power ramps back down after successful sends. Tap the signal bars to override.")
                }
            } else {
                Text("Automatically manages TX power — starts low to save battery, escalates when messages aren't repeated, and ramps back down on success.")
            }
        }
        .onAppear { loadSettings() }
    }

    private var statusColor: Color {
        powerService.isAtMax ? .red : powerService.isElevated ? .orange : .green
    }

    private func stepDescription(_ step: AdaptivePowerService.PowerStep) -> String {
        let radioDbm = powerService.radioDbm(for: step)
        if paGainDb > 0 {
            return "\(step.label) (\(radioDbm) dBm radio → \(Int(step.eirpDbm)) dBm out)"
        } else {
            return "\(step.label) (\(Int(step.eirpDbm)) dBm)"
        }
    }

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
