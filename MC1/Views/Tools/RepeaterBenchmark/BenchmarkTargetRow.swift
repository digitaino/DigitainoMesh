import MC1Services
import SwiftUI

/// Number formatting shared by the benchmark's rows, history and comparison.
///
/// Decibels go through a `FormatStyle` and into a `%@` placeholder rather than a `%f` in the
/// strings file: the decimal separator has to follow the reader's locale, and a printf
/// format in a translated string cannot do that.
enum BenchmarkFormat {
  static func decibels(_ value: Double) -> String {
    L10n.Tools.Tools.Benchmark.decibels(
      value.formatted(.number.precision(.fractionLength(1)))
    )
  }
}

/// One target's batch: reliability, round trips, both legs of the link, and the probes
/// behind them.
///
/// The per-probe log is collapsed by default but kept, because the spread matters as much as
/// the mean — five probes averaging 900 ms read very differently when four were 400 ms and
/// one was 3 s.
struct BenchmarkTargetRow: View {
  let testRepeaterName: String?
  let result: BenchmarkTargetResult

  @State private var showTraces = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header

      if result.totalCount > 0 {
        roundTripStats
        signalStats
      }

      if !result.outcomes.isEmpty {
        DisclosureGroup(isExpanded: $showTraces) {
          ForEach(result.outcomes) { outcome in
            BenchmarkTraceDetailRow(outcome: outcome)
          }
        } label: {
          Text(L10n.Tools.Tools.Benchmark.traceLog(result.outcomes.count))
            .font(.caption)
        }
      }
    }
    .padding(.vertical, 4)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      Text(pathLabel)
        .font(.subheadline.weight(.medium))
        .lineLimit(1)

      Spacer(minLength: 0)

      if result.totalCount > 0 {
        Text(L10n.Tools.Tools.Benchmark.successCount(result.successCount, result.totalCount))
          .font(.caption.monospaced())
          .foregroundStyle(reliabilityColor)
      }

      if !result.isComplete {
        ProgressView().controlSize(.small)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var pathLabel: String {
    guard let testRepeaterName else { return result.target.name }
    return "\(testRepeaterName) → \(result.target.name)"
  }

  /// Green at 80% and up, amber down to half, red below. The bands match the signal table's
  /// quality colours so one scan of the screen reads consistently.
  private var reliabilityColor: Color {
    if result.successRate >= 80 { return .green }
    if result.successRate >= 50 { return .yellow }
    return .red
  }

  // MARK: - Stats

  private var roundTripStats: some View {
    HStack(spacing: 16) {
      if let average = result.averageRTT {
        BenchmarkStatLabel(
          title: L10n.Tools.Tools.Benchmark.Stat.average,
          value: L10n.Tools.Tools.Benchmark.milliseconds(average)
        )
      }
      if let minimum = result.minRTT {
        BenchmarkStatLabel(
          title: L10n.Tools.Tools.Benchmark.Stat.minimum,
          value: L10n.Tools.Tools.Benchmark.milliseconds(minimum)
        )
      }
      if let maximum = result.maxRTT {
        BenchmarkStatLabel(
          title: L10n.Tools.Tools.Benchmark.Stat.maximum,
          value: L10n.Tools.Tools.Benchmark.milliseconds(maximum)
        )
      }
    }
  }

  private var signalStats: some View {
    HStack(spacing: 16) {
      if let tx = result.txSNR {
        legStat(leg: .tx, title: L10n.Localizable.SignalBars.Column.tx, snr: tx)
      }
      if let rx = result.rxSNR {
        legStat(leg: .rx, title: L10n.Localizable.SignalBars.Column.rx, snr: rx)
      }
    }
  }

  private func legStat(leg: RepeaterSignalLeg, title: String, snr: Double) -> some View {
    let quality = SNRQuality(snr: snr)
    return HStack(spacing: 5) {
      RepeaterSignalGlyph(leg: leg, quality: quality, size: 12)
      BenchmarkStatLabel(
        title: title,
        value: BenchmarkFormat.decibels(snr),
        color: quality.color
      )
    }
  }
}

// MARK: - Stat label

/// A caption-sized label over its value, the shape every figure in this tool uses.
struct BenchmarkStatLabel: View {
  let title: String
  let value: String
  var color: Color = .secondary

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.caption.monospaced())
        .foregroundStyle(color)
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Per-probe detail

/// One probe: whether it came back, how long it took, and what each hop heard.
struct BenchmarkTraceDetailRow: View {
  let outcome: BenchmarkTraceOutcome

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text("#\(outcome.sequence)")
          .font(.caption.monospaced().weight(.medium))
          .foregroundStyle(.secondary)

        if outcome.success {
          Image(systemName: "checkmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(.green)
          Text(L10n.Tools.Tools.Benchmark.milliseconds(outcome.durationMs))
            .font(.caption.monospaced())
        } else {
          Image(systemName: "xmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(.red)
          Text(failureLabel)
            .font(.caption)
            .foregroundStyle(.red)
        }

        Spacer(minLength: 0)
      }

      if outcome.success {
        hopChain
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  private var failureLabel: String {
    switch outcome.failure {
    case .sendFailed: L10n.Tools.Tools.Benchmark.sendFailed
    default: L10n.Tools.Tools.Benchmark.timedOut
    }
  }

  /// The path the probe took, each hop labelled with the SNR *it* measured.
  private var hopChain: some View {
    HStack(spacing: 0) {
      ForEach(Array(outcome.hops.enumerated()), id: \.offset) { index, hop in
        if index > 0 {
          Image(systemName: "chevron.right")
            .font(.system(size: 7))
            .foregroundStyle(.quaternary)
            .padding(.horizontal, 2)
        }
        hopPill(hop)
      }
    }
  }

  private func hopPill(_ hop: BenchmarkHop) -> some View {
    VStack(spacing: 1) {
      Text(hop.label ?? "—")
        .font(.system(size: 9, design: .monospaced))
        .lineLimit(1)
      if hop.position == .intermediate {
        Text(hop.snr, format: .number.precision(.fractionLength(1)))
          .font(.system(size: 8, design: .monospaced))
          .foregroundStyle(SNRQuality(snr: hop.snr).color)
      }
    }
  }
}
