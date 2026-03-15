import MC1Services
import SwiftUI

/// Floating pill that appears across the app while a signal survey is recording.
/// Shows signal bars for the user's current cell quality and the total point count.
/// Tapping navigates back to the survey map.
struct SurveyIndicatorView: View {
    let status: SurveyLiveStatus
    let onTap: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Recording dot
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(pulse ? 0.4 : 1.0)

                // Signal quality indicator
                if status.isDeadZone {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if status.currentCellPacketCount > 0 {
                    Image(systemName: "cellularbars", variableValue: status.currentCellQuality.barLevel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(status.currentCellQuality.color)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                // Top repeater hex ID
                if let hexID = status.topRepeaterHexID {
                    Text(hexID)
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                // Point count
                Text("\(status.pointCount)")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .liquidGlass(in: .capsule)
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}
