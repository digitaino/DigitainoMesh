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

                // Signal quality indicator — prefer live SignalBarsService RX/TX
                if let rxQ = status.bestRepeaterRxQuality {
                    // RX bars with down arrow
                    Image(systemName: "cellularbars", variableValue: rxQ.barLevel)
                        .foregroundStyle(rxQ.color)
                        .font(.system(size: 13))
                        .overlay(alignment: .topLeading) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 5, weight: .black))
                                .foregroundStyle(rxQ.color)
                                .offset(x: -1, y: -1)
                        }
                    // TX bars with up arrow (if measured)
                    if let txQ = status.bestRepeaterTxQuality {
                        Image(systemName: "cellularbars", variableValue: txQ.barLevel)
                            .foregroundStyle(txQ.color)
                            .font(.system(size: 13))
                            .overlay(alignment: .topLeading) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 5, weight: .black))
                                    .foregroundStyle(txQ.color)
                                    .offset(x: -1, y: -1)
                            }
                    }
                } else if status.isDeadZone {
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

                // Best repeater name/ID from SignalBarsService or cell top repeater
                if let name = status.bestRepeaterName {
                    Text(name)
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let hexID = status.topRepeaterHexID {
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
