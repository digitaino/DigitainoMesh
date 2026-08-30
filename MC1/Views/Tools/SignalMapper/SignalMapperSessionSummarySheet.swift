import MapperRawLog
import MC1Services
import SwiftUI

/// What a finished survey session did, shown the moment it ends (§7 "M3").
///
/// The numbers are the session's own counters, not the store's: cells *probed* this walk,
/// probes spent, replies heard, probes that died in the air. "No reply" is presented as a
/// finding rather than a failure — a probe nothing answered is exactly how a dead zone
/// gets proved.
///
/// The upload-consent leg of this sheet arrives with M2; until a server exists, the footer
/// says plainly that nothing leaves the device.
struct SignalMapperSessionSummarySheet: View {
  let summary: SignalMapperProbeEngine.SessionSnapshot
  /// The finished run behind these numbers, when a raw ride log was recorded.
  var runID: UUID?
  var rawLogStore: MapperRawLogStore?

  @State private var exportedURL: URL?
  @State private var isExporting = false

  var body: some View {
    NavigationStack {
      List {
        Section {
          LabeledContent(
            L10n.Tools.Tools.SignalMapper.Survey.Summary.cellsProbed,
            value: summary.cellsProbed.formatted()
          )
          LabeledContent(
            L10n.Tools.Tools.SignalMapper.Survey.Summary.probes,
            value: summary.probesSent.formatted()
          )
          LabeledContent(
            L10n.Tools.Tools.SignalMapper.Survey.Summary.replies,
            value: (summary.traceRepliesHeard + summary.discoverResponsesHeard).formatted()
          )
          LabeledContent(
            L10n.Tools.Tools.SignalMapper.Survey.Summary.noReply,
            value: summary.probesLost.formatted()
          )
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
