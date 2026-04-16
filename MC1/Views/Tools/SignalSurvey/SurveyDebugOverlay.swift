import SwiftUI

/// Compact debug overlay showing real-time survey diagnostics.
/// Refreshes once per second via TimelineView for time-derived values.
struct SurveyDebugOverlay: View {
    var viewModel: SignalSurveyViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let info = viewModel.debugInfo

            VStack(alignment: .leading, spacing: 4) {
                // Header
                HStack(spacing: 4) {
                    Image(systemName: "ant.fill")
                        .font(.caption2)
                    Text("DEBUG")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                }
                .foregroundStyle(.orange)

                Divider()

                // GPS
                debugSection("GPS") {
                    debugRow("Accuracy", formatMeters(info.gpsAccuracy))
                    debugRow("Fix age", formatSeconds(info.gpsFixAge))
                    debugRow("Speed", formatSpeed(info.gpsSpeed))
                }

                Divider()

                // Probe
                debugSection("PROBE") {
                    debugRow("Count", "\(info.probeCount)")
                    debugRow("Enabled", info.probeEnabled ? "YES" : "no")
                    debugRow("Flood/cell", "\(info.floodMessagesPerCell)")
                    debugRow("Freq", info.probeFrequency.rawValue)
                    debugRow("Since last", formatSeconds(info.timeSinceLastProbe))
                    if let nextMax = info.nextProbeMaxIn {
                        debugRow("Max in", formatSeconds(nextMax))
                    }
                }

                Divider()

                // Points
                debugSection("POINTS") {
                    debugRow("Total", "\(info.totalPoints)")
                    debugRow("Passive", "\(info.passivePoints)")
                    debugRow("Direct 2-way", "\(info.directPoints)")
                    debugRow("Relayed", "\(info.relayedPoints)")
                }

                Divider()

                // Repeaters
                debugSection("REPEATERS") {
                    debugRow("2-way direct", "\(info.connectedRepeaters)")
                    debugRow("Mesh reach", "\(info.meshReachRepeaters)")
                }

                Divider()

                // Session
                debugSection("SESSION") {
                    debugRow("Cells", "\(info.gridCellCount)")
                    debugRow("Dead zones", "\(info.deadZoneCount)")
                    if info.liveUploadEnabled {
                        debugRow("Uploaded", "\(info.liveUploadCount)")
                    }
                    debugRow("Events", info.eventMonitoringActive ? "ON" : "off")
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .padding(8)
            .frame(width: 160, alignment: .leading)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Helper Views

    private func debugSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .foregroundStyle(.orange.opacity(0.7))
            content()
        }
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value)
        }
    }

    // MARK: - Formatting

    private func formatMeters(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0fm", v)
    }

    private func formatSeconds(_ value: TimeInterval?) -> String {
        guard let v = value else { return "--" }
        if v < 1 { return "<1s" }
        return String(format: "%.0fs", v)
    }

    private func formatSpeed(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f m/s", v)
    }
}
