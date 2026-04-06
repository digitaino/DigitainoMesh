import SwiftUI
import MC1Services

struct BenchmarkComparisonView: View {
    let groupA: BenchmarkRunGroup
    let groupB: BenchmarkRunGroup
    @Environment(\.dismiss) private var dismiss

    /// Match targets between groups by path name
    private var comparisonRows: [ComparisonRow] {
        var rows: [ComparisonRow] = []

        // Build lookup from group A paths by target portion of name
        let aByTarget = Dictionary(grouping: groupA.paths) { targetName(from: $0.name) }
        let bByTarget = Dictionary(grouping: groupB.paths) { targetName(from: $0.name) }

        // Union of all target names
        let allTargets = Set(aByTarget.keys).union(bByTarget.keys).sorted()

        for target in allTargets {
            let pathA = aByTarget[target]?.first
            let pathB = bByTarget[target]?.first

            let avgRTTA = pathA?.averageRoundTripMs
            let avgRTTB = pathB?.averageRoundTripMs

            let successRateA = pathA?.successRate
            let successRateB = pathB?.successRate

            // Extract directional SNR: hopsSNR[1] = TX, hopsSNR[2] = RX
            let txSNRA = averageHopSNR(for: pathA, hopIndex: 1)
            let txSNRB = averageHopSNR(for: pathB, hopIndex: 1)
            let rxSNRA = averageHopSNR(for: pathA, hopIndex: 2)
            let rxSNRB = averageHopSNR(for: pathB, hopIndex: 2)

            rows.append(ComparisonRow(
                targetName: target,
                rttA: avgRTTA,
                rttB: avgRTTB,
                successRateA: successRateA,
                successRateB: successRateB,
                txSNRA: txSNRA,
                txSNRB: txSNRB,
                rxSNRA: rxSNRA,
                rxSNRB: rxSNRB
            ))
        }

        return rows
    }

    /// Summary stats
    private var summaryRTTDelta: Int? {
        let deltas = comparisonRows.compactMap { row -> Int? in
            guard let a = row.rttA, let b = row.rttB else { return nil }
            return b - a
        }
        guard !deltas.isEmpty else { return nil }
        return deltas.reduce(0, +) / deltas.count
    }

    private var summaryTXSNRDelta: Double? {
        let deltas = comparisonRows.compactMap { row -> Double? in
            guard let a = row.txSNRA, let b = row.txSNRB else { return nil }
            return b - a
        }
        guard !deltas.isEmpty else { return nil }
        return deltas.reduce(0, +) / Double(deltas.count)
    }

    private var summaryRXSNRDelta: Double? {
        let deltas = comparisonRows.compactMap { row -> Double? in
            guard let a = row.rxSNRA, let b = row.rxSNRB else { return nil }
            return b - a
        }
        guard !deltas.isEmpty else { return nil }
        return deltas.reduce(0, +) / Double(deltas.count)
    }

    var body: some View {
        List {
            // Header
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    headerRow(label: "A (Before)", note: groupA.note, date: groupA.date)
                    headerRow(label: "B (After)", note: groupB.note, date: groupB.date)
                }
            } header: {
                Text("Comparing")
            }

            // Summary
            if summaryRTTDelta != nil || summaryTXSNRDelta != nil || summaryRXSNRDelta != nil {
                Section("Summary") {
                    HStack(spacing: 24) {
                        if let rttDelta = summaryRTTDelta {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("RTT")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(deltaString(rttDelta, unit: "ms", lowerIsBetter: true))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(deltaColor(rttDelta, lowerIsBetter: true))
                            }
                        }
                        if let txDelta = summaryTXSNRDelta {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("TX", systemImage: "arrow.up.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(deltaString(txDelta, unit: "dB", lowerIsBetter: false))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(deltaColor(txDelta, lowerIsBetter: false))
                            }
                        }
                        if let rxDelta = summaryRXSNRDelta {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("RX", systemImage: "arrow.down.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(deltaString(rxDelta, unit: "dB", lowerIsBetter: false))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(deltaColor(rxDelta, lowerIsBetter: false))
                            }
                        }
                    }
                }
            }

            // Per-target comparison
            Section("Per Target") {
                ForEach(comparisonRows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.targetName)
                            .font(.subheadline.weight(.medium))

                        // RTT comparison
                        comparisonStat(label: "RTT",
                                       valueA: row.rttA.map { "\($0)ms" },
                                       valueB: row.rttB.map { "\($0)ms" },
                                       delta: row.rttDelta.map { deltaString($0, unit: "ms", lowerIsBetter: true) },
                                       deltaColor: row.rttDelta.map { deltaColor($0, lowerIsBetter: true) })

                        // TX/RX signal comparison
                        HStack(spacing: 0) {
                            comparisonStat(label: "TX",
                                           icon: "arrow.up.circle.fill",
                                           valueA: row.txSNRA.map { String(format: "%.1f", $0) },
                                           valueB: row.txSNRB.map { String(format: "%.1f", $0) },
                                           delta: row.txDelta.map { deltaString($0, unit: "dB", lowerIsBetter: false) },
                                           deltaColor: row.txDelta.map { deltaColor($0, lowerIsBetter: false) })
                            Spacer()
                            comparisonStat(label: "RX",
                                           icon: "arrow.down.circle.fill",
                                           valueA: row.rxSNRA.map { String(format: "%.1f", $0) },
                                           valueB: row.rxSNRB.map { String(format: "%.1f", $0) },
                                           delta: row.rxDelta.map { deltaString($0, unit: "dB", lowerIsBetter: false) },
                                           deltaColor: row.rxDelta.map { deltaColor($0, lowerIsBetter: false) })
                        }

                        // Success rate
                        if let rateA = row.successRateA, let rateB = row.successRateB {
                            HStack(spacing: 4) {
                                Text("Success:")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text("\(rateA)%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text("\(rateB)%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                let delta = rateB - rateA
                                if delta != 0 {
                                    Text(deltaString(delta, unit: "%", lowerIsBetter: false))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(deltaColor(delta, lowerIsBetter: false))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Comparison")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Helpers

    private func headerRow(label: String, note: String, date: Date) -> some View {
        HStack {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing) {
                Text(note)
                    .font(.subheadline.weight(.medium))
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func targetName(from pathName: String) -> String {
        // Path names are "[Benchmark] TestRepeater → TargetName"
        if let arrowRange = pathName.range(of: " → ") {
            return String(pathName[arrowRange.upperBound...])
        }
        return pathName
    }

    /// Average SNR at a specific hop index across successful runs
    private func averageHopSNR(for path: SavedTracePathDTO?, hopIndex: Int) -> Double? {
        guard let path else { return nil }
        let snrs = path.runs.filter(\.success).compactMap { run -> Double? in
            guard hopIndex < run.hopsSNR.count else { return nil }
            return run.hopsSNR[hopIndex]
        }
        guard !snrs.isEmpty else { return nil }
        return snrs.reduce(0, +) / Double(snrs.count)
    }

    @ViewBuilder
    private func comparisonStat(label: String, icon: String? = nil, valueA: String?, valueB: String?, delta: String?, deltaColor: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let icon {
                Label(label, systemImage: icon)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 4) {
                Text(valueA ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(valueB ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let delta, let color = deltaColor {
                    Text(delta)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                }
            }
        }
    }

    private func deltaString(_ value: Int, unit: String, lowerIsBetter: Bool) -> String {
        if value > 0 { return "+\(value)\(unit)" }
        if value < 0 { return "\(value)\(unit)" }
        return "0\(unit)"
    }

    private func deltaString(_ value: Double, unit: String, lowerIsBetter: Bool) -> String {
        if value > 0 { return String(format: "+%.1f%@", value, unit) }
        if value < 0 { return String(format: "%.1f%@", value, unit) }
        return "0\(unit)"
    }

    private func deltaColor(_ value: Int, lowerIsBetter: Bool) -> Color {
        if value == 0 { return .secondary }
        let improved = lowerIsBetter ? value < 0 : value > 0
        return improved ? .green : .red
    }

    private func deltaColor(_ value: Double, lowerIsBetter: Bool) -> Color {
        if abs(value) < 0.1 { return .secondary }
        let improved = lowerIsBetter ? value < 0 : value > 0
        return improved ? .green : .red
    }
}

// MARK: - Comparison Row Model

private struct ComparisonRow: Identifiable {
    let id = UUID()
    let targetName: String
    let rttA: Int?
    let rttB: Int?
    let successRateA: Int?
    let successRateB: Int?
    let txSNRA: Double?
    let txSNRB: Double?
    let rxSNRA: Double?
    let rxSNRB: Double?

    var rttDelta: Int? {
        guard let a = rttA, let b = rttB else { return nil }
        return b - a
    }
    var txDelta: Double? {
        guard let a = txSNRA, let b = txSNRB else { return nil }
        return b - a
    }
    var rxDelta: Double? {
        guard let a = rxSNRA, let b = rxSNRB else { return nil }
        return b - a
    }
}
