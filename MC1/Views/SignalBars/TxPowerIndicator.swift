import SwiftUI
import MC1Services

/// Compact toolbar indicator showing current adaptive TX power level.
/// Displays the power step label (e.g., "200mW") color-coded by escalation state.
/// Tapping opens the adaptive power settings detail.
struct TxPowerIndicator: View {
    @Environment(\.appState) private var appState

    var body: some View {
        let service = appState.adaptivePowerService
        if service.isEnabled, appState.connectionState == .ready {
            Button {
                appState.showAdaptivePowerSheet = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: powerIcon(for: service))
                        .font(.system(size: 10, weight: .semibold))
                    Text(service.currentStep.label)
                        .font(.system(.caption2, design: .monospaced))
                    if service.lastApplyFailed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                }
                .foregroundStyle(powerColor(for: service))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(powerColor(for: service).opacity(0.15))
                )
            }
            .accessibilityLabel("TX Power: \(service.currentStep.label)\(service.lastApplyFailed ? ", verification failed" : "")")
            .accessibilityHint(service.isElevated ? "Elevated from base \(service.baseStep.label)" : "At base power")
        }
    }

    private func powerIcon(for service: AdaptivePowerService) -> String {
        if service.isAtMax {
            return "bolt.fill"
        } else if service.isElevated {
            return "bolt"
        } else {
            return "bolt.slash"
        }
    }

    private func powerColor(for service: AdaptivePowerService) -> Color {
        if service.isAtMax {
            return .red
        } else if service.isElevated {
            return .orange
        } else {
            return .green
        }
    }
}
