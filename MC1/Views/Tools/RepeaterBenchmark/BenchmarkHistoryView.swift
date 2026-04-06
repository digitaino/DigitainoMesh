import SwiftUI
import MC1Services

struct BenchmarkHistoryView: View {
    var viewModel: BenchmarkViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showComparison = false

    /// Groups benchmark paths by note (benchmark run)
    private var runGroups: [BenchmarkRunGroup] {
        let benchmarkPaths = viewModel.savedBenchmarkPaths
        var groupsByNote: [String: [SavedTracePathDTO]] = [:]

        for path in benchmarkPaths {
            // Group by note from the most recent run
            let note = path.runs.compactMap(\.note).first ?? "No note"
            groupsByNote[note, default: []].append(path)
        }

        return groupsByNote.map { note, paths in
            let latestDate = paths.flatMap { $0.runs.map(\.date) }.max() ?? .distantPast
            let avgRTT = paths.compactMap(\.averageRoundTripMs).reduce(0, +) / max(paths.compactMap(\.averageRoundTripMs).count, 1)
            let avgSuccessRate = paths.map(\.successRate).reduce(0, +) / max(paths.count, 1)
            return BenchmarkRunGroup(
                note: note,
                paths: paths,
                date: latestDate,
                averageRTT: avgRTT,
                averageSuccessRate: avgSuccessRate
            )
        }
        .sorted { $0.date > $1.date }
    }

    var body: some View {
        Group {
            if runGroups.isEmpty {
                ContentUnavailableView(
                    "No Benchmark History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Run a benchmark and save results to see history here.")
                )
            } else {
                historyList
            }
        }
        .navigationTitle("Benchmark History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showComparison = true
                } label: {
                    Label("Compare", systemImage: "arrow.left.arrow.right")
                }
                .disabled(viewModel.selectedForComparison.count != 2)
            }
        }
        .sheet(isPresented: $showComparison) {
            if let groups = selectedRunGroups {
                NavigationStack {
                    BenchmarkComparisonView(
                        groupA: groups.0,
                        groupB: groups.1
                    )
                }
            }
        }
    }

    private var historyList: some View {
        List {
            Section {
                ForEach(runGroups) { group in
                    runGroupRow(group)
                }
            } header: {
                Text("Tap to select runs for comparison")
            } footer: {
                Text("\(viewModel.selectedForComparison.count) of 2 selected")
            }

            if viewModel.selectedForComparison.count == 2 {
                Section {
                    Button {
                        showComparison = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("Compare Selected", systemImage: "arrow.left.arrow.right")
                                .font(.headline)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func runGroupRow(_ group: BenchmarkRunGroup) -> some View {
        let selected = isSelected(group)
        let dateString = group.date.formatted(date: .abbreviated, time: .shortened)
        let successColor: Color = group.averageSuccessRate >= 80 ? .green : .yellow

        return Button {
            toggleSelection(group)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.note)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 12) {
                        Text(dateString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(group.paths.count) targets")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("avg \(group.averageRTT)ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(group.averageSuccessRate)%")
                            .font(.caption)
                            .foregroundStyle(successColor)
                    }
                }

                Spacer()

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
        }
        .tint(.primary)
        .swipeActions(edge: .trailing) {
            Button {
                viewModel.loadFromRunGroup(group)
                dismiss()
            } label: {
                Label("Repeat", systemImage: "arrow.counterclockwise")
            }
            .tint(Color.accentColor)
        }
    }

    private func toggleSelection(_ group: BenchmarkRunGroup) {
        if viewModel.selectedForComparison.contains(group.id) {
            viewModel.selectedForComparison.remove(group.id)
        } else if viewModel.selectedForComparison.count < 2 {
            viewModel.selectedForComparison.insert(group.id)
        } else {
            // Replace oldest selection
            viewModel.selectedForComparison.removeFirst()
            viewModel.selectedForComparison.insert(group.id)
        }
    }

    private func isSelected(_ group: BenchmarkRunGroup) -> Bool {
        viewModel.selectedForComparison.contains(group.id)
    }

    private var selectedRunGroups: (BenchmarkRunGroup, BenchmarkRunGroup)? {
        let selected = runGroups.filter { viewModel.selectedForComparison.contains($0.id) }
        guard selected.count == 2 else { return nil }
        // Older first (A), newer second (B)
        let sorted = selected.sorted { $0.date < $1.date }
        return (sorted[0], sorted[1])
    }
}

// MARK: - Run Group Model

struct BenchmarkRunGroup: Identifiable {
    /// Stable identity based on note — groups are keyed by note so this is unique
    var id: String { note }
    let note: String
    let paths: [SavedTracePathDTO]
    let date: Date
    let averageRTT: Int
    let averageSuccessRate: Int
}
