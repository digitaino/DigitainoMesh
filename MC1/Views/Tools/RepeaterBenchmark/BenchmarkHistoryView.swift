import MC1Services
import SwiftUI

/// Saved benchmark runs, grouped by the note each was saved under.
///
/// The note is the unit because it is what the user changed: "stock whip", "yagi at 6 m".
/// Picking two of them and comparing is the point of keeping history at all — a single run's
/// absolute numbers say much less than the difference between two.
struct BenchmarkHistoryView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss

  let model: RepeaterBenchmarkModel

  @State private var showComparison = false

  var body: some View {
    Group {
      if model.history.isEmpty {
        ContentUnavailableView {
          Label(L10n.Tools.Tools.Benchmark.History.empty, systemImage: "clock.arrow.circlepath")
        } description: {
          Text(L10n.Tools.Tools.Benchmark.History.emptyDescription)
        }
      } else {
        historyList
      }
    }
    .navigationTitle(L10n.Tools.Tools.Benchmark.History.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button(L10n.Tools.Tools.Benchmark.Picker.done) { dismiss() }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showComparison = true
        } label: {
          Label(L10n.Tools.Tools.Benchmark.compare, systemImage: "arrow.left.arrow.right")
        }
        .disabled(model.comparisonPair == nil)
      }
    }
    .sheet(isPresented: $showComparison) {
      if let pair = model.comparisonPair {
        NavigationStack {
          BenchmarkComparisonView(groupA: pair.0, groupB: pair.1)
        }
      }
    }
    .task { await model.reloadHistory() }
  }

  private var historyList: some View {
    List {
      Section {
        ForEach(model.history) { group in
          runRow(group)
        }
      } header: {
        Text(L10n.Tools.Tools.Benchmark.History.selectPrompt)
      } footer: {
        Text(L10n.Tools.Tools.Benchmark.History.selectedCount(model.selectedForComparison.count))
      }
      .themedRowBackground(theme)
    }
    .themedCanvas(theme)
  }

  private func runRow(_ group: BenchmarkRunGroup) -> some View {
    let isSelected = model.isSelectedForComparison(group)
    return Button {
      model.toggleComparison(group)
    } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(group.note.isEmpty ? L10n.Tools.Tools.Benchmark.History.untitled : group.note)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)

          HStack(spacing: 10) {
            Text(group.date.formatted(date: .abbreviated, time: .shortened))
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(L10n.Tools.Tools.Benchmark.History.targetCount(group.paths.count))
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(L10n.Tools.Tools.Benchmark.averageMilliseconds(group.averageRTT))
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
            Text(L10n.Tools.Tools.Benchmark.percent(group.averageSuccessRate))
              .font(.caption.monospaced())
              .foregroundStyle(group.averageSuccessRate >= 80 ? .green : .yellow)
          }
        }

        Spacer(minLength: 0)

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? theme.accentColor : .secondary)
      }
      .contentShape(.rect)
    }
    .tint(.primary)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) {
        Task { await model.delete(group: group) }
      } label: {
        Label(L10n.Tools.Tools.Benchmark.History.delete, systemImage: "trash")
      }

      Button {
        Task {
          await model.loadPlan(from: group)
          dismiss()
        }
      } label: {
        Label(L10n.Tools.Tools.Benchmark.History.repeatRun, systemImage: "arrow.counterclockwise")
      }
      .tint(theme.accentColor)
    }
  }
}
