import MapperRawLog
import MC1Services
import SwiftUI

/// What a finished ride did, shown the moment it ends (docs/SIGNAL_MAPPER_V3.md §8:
/// "the ride completion sheet stays, simplified").
///
/// **Every number is a fold of the ride's own rows** (``MapperRawLogStore/rideTotals(runID:)``),
/// not the probe engine's in-memory tallies. That is the whole simplification: an engine
/// rebuilt by a BLE rewire could disagree with the log it had been writing to, and the
/// counters that had no row behind them at all — cells *probed*, probes that died in the
/// air — are gone rather than reconciled. What is left is what the ride recorded.
///
/// The upload-consent leg of this sheet arrives later; until a server exists, the footer
/// says plainly that nothing leaves the device.
struct SignalMapperSessionSummarySheet: View {
  let summary: SignalMapperProbeEngine.SessionSnapshot
  /// The finished run behind these numbers, when a raw ride log was recorded.
  var runID: UUID?
  var rawLogStore: MapperRawLogStore?

  @State private var totals: MapperRideTotals?
  @State private var exportedURL: URL?
  @State private var isExporting = false

  var body: some View {
    NavigationStack {
      List {
        Section {
          if let totals {
            LabeledContent(
              L10n.Tools.Tools.SignalMapper.Survey.Summary.hexagons,
              value: totals.hexagonCount.formatted()
            )
            LabeledContent(
              L10n.Tools.Tools.SignalMapper.Survey.Summary.repeatersHeard,
              value: totals.repeatersHeard.formatted()
            )
            LabeledContent(
              L10n.Tools.Tools.SignalMapper.Survey.Summary.probes,
              value: totals.probesSent.formatted()
            )
            LabeledContent(
              L10n.Tools.Tools.SignalMapper.Survey.Summary.replies,
              value: totals.probeReplies.formatted()
            )
          } else {
            ProgressView()
          }
          if let startedAt = summary.startedAt {
            LabeledContent(
              L10n.Tools.Tools.SignalMapper.Survey.Summary.duration,
              value: Duration.seconds(Date().timeIntervalSince(startedAt))
                .formatted(.time(pattern: .hourMinute))
            )
          }
        } footer: {
          Label {
            Text(L10n.Tools.Tools.SignalMapper.Survey.Summary.localNote)
          } icon: {
            Image(systemName: "lock.shield")
          }
        }
      }
      .navigationTitle(L10n.Tools.Tools.SignalMapper.Survey.Summary.title)
      .safeAreaInset(edge: .bottom) {
        exportBar
      }
      .navigationBarTitleDisplayMode(.inline)
      .task {
        guard let runID, let rawLogStore else { return }
        totals = try? await rawLogStore.rideTotals(runID: runID)
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  /// The share leg exports the **scrubbed** tier only (docs/ACTIVE_SURVEY_M3_5.md §2.8):
  /// coordinates coarsened, the first and last 500 m of the ride trimmed, repeater keys
  /// truncated. The full-fidelity file exists solely behind the debug panel, under a
  /// filename that says what it is.
  @ViewBuilder
  private var exportBar: some View {
    if let runID, let rawLogStore {
      VStack(spacing: 6) {
        if let exportedURL {
          ShareLink(item: exportedURL) {
            Label(
              L10n.Tools.Tools.SignalMapper.Survey.Summary.share,
              systemImage: "square.and.arrow.up"
            )
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
        } else {
          Button {
            isExporting = true
            Task {
              defer { isExporting = false }
              guard let run = try? await rawLogStore.fetchRun(runID) else { return }
              exportedURL = try? await MapperRideExport.scrubbedExport(run: run, store: rawLogStore)
            }
          } label: {
            Label(
              L10n.Tools.Tools.SignalMapper.Survey.Summary.export,
              systemImage: "square.and.arrow.up"
            )
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .disabled(isExporting)
        }
        Text(L10n.Tools.Tools.SignalMapper.Survey.Summary.exportNote)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal)
      .padding(.bottom, 8)
      .background(.bar)
      .onDisappear { MapperRideExport.deleteExports() }
    }
  }
}
