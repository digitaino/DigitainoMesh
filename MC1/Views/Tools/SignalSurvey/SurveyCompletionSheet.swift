import SwiftUI

/// Summary sheet shown after stopping a survey session, displaying
/// session stats, coverage breakdown, repeater info, and community map impact.
struct SurveyCompletionSheet: View {
    let stats: SignalSurveyViewModel.SurveyCompletionStats
    let resolveRepeater: (String) -> String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sessionOverviewSection
                    coverageBreakdownSection
                    if stats.totalUniqueRepeaters > 0 {
                        repeaterStatsSection
                    }
                    if let impact = stats.communityImpact {
                        communityImpactSection(impact)
                    }
                }
                .padding()
            }
            .navigationTitle("Survey Complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Session Overview

    private var sessionOverviewSection: some View {
        infoSection(icon: "clock", iconColor: .blue, title: "Session Overview") {
            statRow(label: "Duration", value: formatDuration(stats.duration))
            statRow(label: "Total Packets", value: "\(stats.totalPackets)")
            statRow(label: "Cells Logged", value: "\(stats.totalCells)")
        }
    }

    // MARK: - Coverage Breakdown

    private var coverageBreakdownSection: some View {
        infoSection(icon: "map", iconColor: .green, title: "Coverage Breakdown") {
            coverageRow(label: "Connected (2-way)", count: stats.connectedCells, color: .green, icon: "checkmark.circle.fill")
            coverageRow(label: "Mesh Reach", count: stats.meshReachCells, color: .cyan, icon: "arrow.triangle.branch")
            coverageRow(label: "Heard Only", count: stats.heardOnlyCells, color: .orange, icon: "ear.fill")
            if stats.deadZoneCells > 0 {
                coverageRow(label: "Dead Zones", count: stats.deadZoneCells, color: .gray, icon: "xmark.circle.fill")
            }
        }
    }

    // MARK: - Repeater Stats

    private var repeaterStatsSection: some View {
        infoSection(icon: "antenna.radiowaves.left.and.right", iconColor: .purple, title: "Repeater Stats") {
            statRow(label: "Unique Repeaters", value: "\(stats.totalUniqueRepeaters)")
            if let best = stats.bestCoverageRepeater {
                statRow(
                    label: "Most Packets",
                    value: "\(resolveRepeater(best.hexID)) — \(best.packetCount)"
                )
            }
            if let best = stats.bestConnectedRepeater {
                statRow(
                    label: "Most 2-Way Cells",
                    value: "\(resolveRepeater(best.hexID)) — \(best.connectedCellCount)"
                )
            }
        }
    }

    // MARK: - Community Map Impact

    private func communityImpactSection(_ impact: SignalSurveyViewModel.SurveyCompletionStats.CommunityImpact) -> some View {
        infoSection(icon: "globe.americas", iconColor: .cyan, title: "Community Map Impact") {
            if impact.newCells > 0 {
                statRow(label: "New Cells", value: "\(impact.newCells)", highlight: true)
            }
            if impact.updatedCells > 0 {
                statRow(label: "Updated Cells", value: "\(impact.updatedCells)")
            }
            if impact.newCells == 0, let age = impact.oldestUpdatedAge {
                statRow(label: "Oldest Cell Updated", value: formatAge(age))
            }
        }
    }

    // MARK: - Helpers

    private func infoSection<Content: View>(
        icon: String,
        iconColor: Color,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.headline)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
            }

            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statRow(label: String, value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(highlight ? .bold : .medium))
                .foregroundStyle(highlight ? .green : .primary)
        }
    }

    private func coverageRow(label: String, count: Int, color: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.medium).monospacedDigit())
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }

    private func formatAge(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86400
        if days > 0 { return "\(days) day\(days == 1 ? "" : "s") ago" }
        let hours = Int(seconds) / 3600
        if hours > 0 { return "\(hours) hour\(hours == 1 ? "" : "s") ago" }
        return "recently"
    }
}
