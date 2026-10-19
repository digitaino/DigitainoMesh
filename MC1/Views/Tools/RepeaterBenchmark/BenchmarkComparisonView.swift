import MC1Services
import SwiftUI

/// Two saved runs side by side, per target and in summary.
///
/// A is the older run and B the newer, so every figure reads left to right as "before →
/// after" and every delta is B − A. Colour follows the metric rather than the sign: less
/// round-trip time is better, more SNR is better, and
/// `BenchmarkComparison.isImprovement(delta:lowerIsBetter:)` is the one place that rule is
/// stated.
struct BenchmarkComparisonView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss

  let groupA: BenchmarkRunGroup
  let groupB: BenchmarkRunGroup

  private var rows: [BenchmarkComparisonRow] {
    BenchmarkComparison.rows(groupA: groupA, groupB: groupB)
  }

  private var summary: BenchmarkComparisonSummary {
    BenchmarkComparison.summary(rows: rows)
  }

  var body: some View {
    List {
      Section(L10n.Tools.Tools.Benchmark.Comparison.comparing) {
        runHeader(label: L10n.Tools.Tools.Benchmark.Comparison.before, group: groupA)
        runHeader(label: L10n.Tools.Tools.Benchmark.Comparison.after, group: groupB)
      }
      .themedRowBackground(theme)

      if !summary.isEmpty {
        Section(L10n.Tools.Tools.Benchmark.Comparison.summary) {
          summaryRow
        }
        .themedRowBackground(theme)
      }

      Section(L10n.Tools.Tools.Benchmark.Comparison.perTarget) {
        ForEach(rows) { row in
          targetRow(row)
        }
      }
      .themedRowBackground(theme)
    }
    .themedCanvas(theme)
    .navigationTitle(L10n.Tools.Tools.Benchmark.Comparison.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button(L10n.Tools.Tools.Benchmark.Picker.done) { dismiss() }
      }
    }
  }

  // MARK: - Header

  private func runHeader(label: String, group: BenchmarkRunGroup) -> some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: 2) {
        Text(group.note.isEmpty ? L10n.Tools.Tools.Benchmark.History.untitled : group.note)
          .font(.subheadline.weight(.medium))
        Text(group.date.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    } label: {
      Text(label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Summary

  private var summaryRow: some View {
    HStack(spacing: 24) {
      if let delta = summary.rttDelta {
        deltaStat(
          title: L10n.Tools.Tools.Benchmark.Comparison.roundTrip,
          text: deltaText(delta, unit: L10n.Tools.Tools.Benchmark.Unit.milliseconds),
          delta: Double(delta),
          lowerIsBetter: true
        )
      }
      if let delta = summary.txSNRDelta {
        deltaStat(
          title: L10n.Localizable.SignalBars.Column.tx,
          text: deltaText(delta, unit: L10n.Tools.Tools.Benchmark.Unit.decibels),
          delta: delta,
          lowerIsBetter: false
        )
      }
      if let delta = summary.rxSNRDelta {
        deltaStat(
          title: L10n.Localizable.SignalBars.Column.rx,
          text: deltaText(delta, unit: L10n.Tools.Tools.Benchmark.Unit.decibels),
          delta: delta,
          lowerIsBetter: false
        )
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
  }

  private func deltaStat(
    title: String,
    text: String,
    delta: Double,
    lowerIsBetter: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Text(text)
        .font(.subheadline.weight(.medium).monospacedDigit())
        .foregroundStyle(deltaColor(delta, lowerIsBetter: lowerIsBetter))
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: - Per target

  private func targetRow(_ row: BenchmarkComparisonRow) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(row.targetName)
        .font(.subheadline.weight(.medium))

      pairStat(
        title: L10n.Tools.Tools.Benchmark.Comparison.roundTrip,
        valueA: row.rttA.map { L10n.Tools.Tools.Benchmark.milliseconds($0) },
        valueB: row.rttB.map { L10n.Tools.Tools.Benchmark.milliseconds($0) },
        delta: row.rttDelta.map { (deltaText($0, unit: L10n.Tools.Tools.Benchmark.Unit.milliseconds), Double($0)) },
        lowerIsBetter: true
      )

      HStack(alignment: .top, spacing: 20) {
        pairStat(
          title: L10n.Localizable.SignalBars.Column.tx,
          valueA: row.txSNRA.map { BenchmarkFormat.decibels($0) },
          valueB: row.txSNRB.map { BenchmarkFormat.decibels($0) },
          delta: row.txDelta.map { (deltaText($0, unit: L10n.Tools.Tools.Benchmark.Unit.decibels), $0) },
          lowerIsBetter: false
        )
        pairStat(
          title: L10n.Localizable.SignalBars.Column.rx,
          valueA: row.rxSNRA.map { BenchmarkFormat.decibels($0) },
          valueB: row.rxSNRB.map { BenchmarkFormat.decibels($0) },
          delta: row.rxDelta.map { (deltaText($0, unit: L10n.Tools.Tools.Benchmark.Unit.decibels), $0) },
          lowerIsBetter: false
        )
        Spacer(minLength: 0)
      }

      pairStat(
        title: L10n.Tools.Tools.Benchmark.Comparison.reliability,
        valueA: row.successRateA.map { L10n.Tools.Tools.Benchmark.percent($0) },
        valueB: row.successRateB.map { L10n.Tools.Tools.Benchmark.percent($0) },
        delta: row.successRateDelta.map { (deltaText($0, unit: L10n.Tools.Tools.Benchmark.Unit.percent), Double($0)) },
        lowerIsBetter: false
      )
    }
    .padding(.vertical, 4)
  }

  private func pairStat(
    title: String,
    valueA: String?,
    valueB: String?,
    delta: (text: String, value: Double)?,
    lowerIsBetter: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.tertiary)
      HStack(spacing: 4) {
        Text(valueA ?? "—")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        Image(systemName: "arrow.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Text(valueB ?? "—")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        if let delta {
          Text(delta.text)
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(deltaColor(delta.value, lowerIsBetter: lowerIsBetter))
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: - Delta formatting

  private func deltaText(_ value: Int, unit: String) -> String {
    value > 0 ? "+\(value)\(unit)" : "\(value)\(unit)"
  }

  private func deltaText(_ value: Double, unit: String) -> String {
    let rounded = value.formatted(.number.precision(.fractionLength(1)))
    return value > 0 ? "+\(rounded)\(unit)" : "\(rounded)\(unit)"
  }

  /// Neutral inside the noise floor of a measurement — a tenth of a decibel of change across
  /// a handful of probes is not a result, and colouring it green would say otherwise.
  private func deltaColor(_ value: Double, lowerIsBetter: Bool) -> Color {
    guard abs(value) >= 0.1 else { return .secondary }
    return BenchmarkComparison.isImprovement(delta: value, lowerIsBetter: lowerIsBetter)
      ? .green
      : .red
  }
}
