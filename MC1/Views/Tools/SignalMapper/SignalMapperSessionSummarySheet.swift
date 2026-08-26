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
        } footer: {
          Label {
            Text(L10n.Tools.Tools.SignalMapper.Survey.Summary.localNote)
          } icon: {
            Image(systemName: "lock.shield")
          }
        }
      }
      .navigationTitle(L10n.Tools.Tools.SignalMapper.Survey.Summary.title)
      .navigationBarTitleDisplayMode(.inline)
    }
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
  }
}
