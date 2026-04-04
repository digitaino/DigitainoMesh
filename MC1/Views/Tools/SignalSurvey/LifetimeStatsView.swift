import MC1Services
import SwiftUI

/// Dashboard view showing all-time aggregated survey statistics.
struct LifetimeStatsView: View {
    let sessions: [SurveySessionDTO]
    let sessionStats: [UUID: SignalSurveyViewModel.SessionStats]

    @Environment(\.dismiss) private var dismiss

    private var aggregated: AggregatedStats {
        AggregatedStats(sessions: sessions, sessionStats: sessionStats)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    dateRangeHeader

                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 12) {
                        statCard("Total Time", value: aggregated.totalTimeFormatted, icon: "clock.fill", color: .blue)
                        statCard("Sessions", value: "\(aggregated.totalSessions)", icon: "list.bullet.rectangle.fill", color: .indigo)
                        statCard("Packets", value: formatNumber(aggregated.totalPackets), icon: "wave.3.right", color: .orange)
                        statCard("Unique Cells", value: formatNumber(aggregated.totalCells), icon: "hexagon.fill", color: .green)
                        statCard("Repeaters", value: "\(aggregated.totalUniqueRepeaters)", icon: "antenna.radiowaves.left.and.right", color: .purple)
                        statCard("Avg Session", value: aggregated.avgSessionFormatted, icon: "chart.bar.fill", color: .mint)
                        statCard("Longest", value: aggregated.longestSessionFormatted, icon: "trophy.fill", color: .yellow)
                        statCard("Connected Cells", value: formatNumber(aggregated.totalConnectedCells), icon: "checkmark.circle.fill", color: .green)
                    }
                    .padding(.horizontal)

                    // Coverage breakdown
                    if aggregated.hasCompletionData {
                        coverageSection
                    }

                    // Repeater leaderboard
                    if !aggregated.repeaterLeaderboard.isEmpty {
                        repeaterLeaderboard
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("All-Time Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Date Range

    private var dateRangeHeader: some View {
        Group {
            if let first = sessions.last?.startedAt,
               let last = sessions.first?.startedAt {
                Text("\(first.formatted(date: .abbreviated, time: .omitted)) — \(last.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Coverage Section

    private var coverageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coverage Breakdown")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal)

            HStack(spacing: 0) {
                coverageBar(label: "2-Way", count: aggregated.totalConnectedCells, color: .green)
                coverageBar(label: "Mesh", count: aggregated.totalMeshReachCells, color: .cyan)
                coverageBar(label: "Heard", count: aggregated.totalHeardOnlyCells, color: .orange)
                if aggregated.totalDeadZoneCells > 0 {
                    coverageBar(label: "Dead", count: aggregated.totalDeadZoneCells, color: .gray)
                }
            }
            .frame(height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal)
        }
    }

    private func coverageBar(label: String, count: Int, color: Color) -> some View {
        let total = max(aggregated.totalCells, 1)
        let fraction = CGFloat(count) / CGFloat(total)
        return GeometryReader { geo in
            if fraction > 0 {
                ZStack {
                    Rectangle().fill(color.opacity(0.8))
                    if geo.size.width * fraction > 30 {
                        Text("\(count)")
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: geo.size.width * fraction)
            }
        }
    }

    // MARK: - Repeater Leaderboard

    private var repeaterLeaderboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Repeaters")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal)

            ForEach(Array(aggregated.repeaterLeaderboard.prefix(5).enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 8) {
                    Text("#\(index + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    Text(entry.hexID)
                        .font(.system(.caption, design: .monospaced, weight: .medium))

                    Spacer()

                    Text("\(entry.totalPackets) pkts")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("\(entry.sessionCount) sessions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Stat Card

    private func statCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)

            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Formatting

    private func formatNumber(_ n: Int) -> String {
        if n >= 10000 {
            return String(format: "%.1fk", Double(n) / 1000)
        }
        return "\(n)"
    }
}

// MARK: - Aggregated Stats

private struct AggregatedStats {
    let totalSessions: Int
    let totalPackets: Int
    let totalCells: Int
    let totalConnectedCells: Int
    let totalMeshReachCells: Int
    let totalHeardOnlyCells: Int
    let totalDeadZoneCells: Int
    let totalUniqueRepeaters: Int
    let totalTimeSeconds: TimeInterval
    let longestSessionSeconds: TimeInterval
    let hasCompletionData: Bool
    let repeaterLeaderboard: [RepeaterEntry]

    struct RepeaterEntry {
        let hexID: String
        let totalPackets: Int
        let sessionCount: Int
    }

    init(sessions: [SurveySessionDTO], sessionStats: [UUID: SignalSurveyViewModel.SessionStats]) {
        totalSessions = sessions.count

        // Aggregate from sessionStats (fast cached values)
        totalPackets = sessionStats.values.reduce(0) { $0 + $1.pointCount }
        totalCells = sessionStats.values.reduce(0) { $0 + $1.cellCount }

        // Aggregate from completionStats where available
        var connected = 0, meshReach = 0, heardOnly = 0, deadZone = 0, uniqueRepeaters = 0
        var hasCompletion = false
        var repeaterCounts: [String: (packets: Int, sessions: Int)] = [:]

        for session in sessions {
            guard let cs = session.completionStats else { continue }
            hasCompletion = true
            connected += cs.connectedCells
            meshReach += cs.meshReachCells
            heardOnly += cs.heardOnlyCells
            deadZone += cs.deadZoneCells
            uniqueRepeaters += cs.totalUniqueRepeaters

            // Track best coverage repeater appearances
            if let hexID = cs.bestCoverageRepeaterHexID, let count = cs.bestCoverageRepeaterPacketCount {
                let existing = repeaterCounts[hexID, default: (packets: 0, sessions: 0)]
                repeaterCounts[hexID] = (packets: existing.packets + count, sessions: existing.sessions + 1)
            }
        }

        totalConnectedCells = connected
        totalMeshReachCells = meshReach
        totalHeardOnlyCells = heardOnly
        totalDeadZoneCells = deadZone
        totalUniqueRepeaters = uniqueRepeaters
        self.hasCompletionData = hasCompletion

        // Time calculations
        let durations = sessions.compactMap { s -> TimeInterval? in
            guard let ended = s.endedAt else { return nil }
            return ended.timeIntervalSince(s.startedAt)
        }
        totalTimeSeconds = durations.reduce(0, +)
        longestSessionSeconds = durations.max() ?? 0

        // Sort repeater leaderboard by total packets
        repeaterLeaderboard = repeaterCounts
            .map { RepeaterEntry(hexID: $0.key, totalPackets: $0.value.packets, sessionCount: $0.value.sessions) }
            .sorted { $0.totalPackets > $1.totalPackets }
    }

    var totalTimeFormatted: String {
        let hours = totalTimeSeconds / 3600
        if hours >= 1 {
            return String(format: "%.1f hrs", hours)
        }
        return "\(Int(totalTimeSeconds / 60)) min"
    }

    var avgSessionFormatted: String {
        guard totalSessions > 0 else { return "—" }
        let avg = totalTimeSeconds / Double(totalSessions)
        let minutes = Int(avg / 60)
        if minutes >= 60 {
            return String(format: "%.1f hrs", avg / 3600)
        }
        return "\(minutes) min"
    }

    var longestSessionFormatted: String {
        let minutes = Int(longestSessionSeconds / 60)
        if minutes >= 60 {
            let hours = longestSessionSeconds / 3600
            return String(format: "%.1f hrs", hours)
        }
        return "\(minutes) min"
    }
}
