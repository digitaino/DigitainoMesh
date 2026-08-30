import MapperRawLog
import MC1Services
import SwiftUI

/// Everything about the running survey that is worth a stop-and-look but not a permanent
/// slot on the map: full counters, fix health, per-target max range, and the rarely-used
/// ride actions (spot check, edit lock-on, end). Opened by tapping the live strip.
///
/// Spot Check lives here rather than as a permanent map button (UI review S2): it is a
/// stopped-at-a-junction action, and it was costing 40 pt of map on every ride.
struct SignalMapperRunDetailSheet: View {
  /// What this sheet asked for on its way out. Presenting a sibling sheet (the lock-on
  /// picker) or one that a state change triggers (the run summary) from inside a button
  /// that is *also* dismissing this sheet tears down a presentation host mid-dismissal —
  /// the iOS 26 zoom-morph family the toolbar path already defers around. The action is
  /// recorded here and run by the presenter's `onDismiss` instead (UI review P0-4).
  enum PendingAction {
    case editLockOn
    case stop
  }

  let session: SignalMapperRideSession
  let onSpotCheck: () -> Void
  @Binding var pendingAction: PendingAction?

  @Environment(\.dismiss) private var dismiss
  @State private var rawRecorded: Int?

  var body: some View {
    NavigationStack {
      List {
        countersSection
        if !session.focusTargets.isEmpty {
          rangeSection
        }
        actionsSection
      }
      .navigationTitle(L10n.Tools.Tools.SignalMapper.Ride.detailTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
      .task {
        if let recorder = session.recorder {
          rawRecorded = await recorder.snapshot().recordedCount
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private var totals: SignalMapperProbeEngine.SessionSnapshot {
    session.displayTotals
  }

  private var countersSection: some View {
    Section {
      LabeledContent(
        L10n.Tools.Tools.SignalMapper.Survey.Summary.probes,
        value: totals.probesSent.formatted()
      )
      LabeledContent(
        L10n.Tools.Tools.SignalMapper.Survey.Summary.replies,
        value: (totals.traceRepliesHeard + totals.discoverResponsesHeard).formatted()
      )
      LabeledContent(
        L10n.Tools.Tools.SignalMapper.Survey.Summary.noReply,
        value: totals.probesLost.formatted()
      )
      LabeledContent(
        L10n.Tools.Tools.SignalMapper.Ride.cells,
        value: totals.cellsProbed.formatted()
      )
      LabeledContent(
        L10n.Tools.Tools.SignalMapper.Ride.noFixDrops,
        value: totals.skippedNoFixCount.formatted()
      )
      if let rawRecorded {
        LabeledContent(
          L10n.Tools.Tools.SignalMapper.Ride.rawSamples,
          value: rawRecorded.formatted()
        )
      }
    }
  }

  private var rangeSection: some View {
    Section {
      ForEach(session.focusTargets, id: \.id) { target in
        LabeledContent(
          session.focusMeta[target.id]?.name ?? target.id.hex,
          value: session.maxReplyDistanceMeters[target.id].map(distanceText)
            ?? L10n.Tools.Tools.SignalMapper.Ride.noReplyYet
        )
      }
    } header: {
      Text(L10n.Tools.Tools.SignalMapper.Ride.maxRangeHeader)
    }
  }

  private var actionsSection: some View {
    Section {
      Button {
        onSpotCheck()
      } label: {
        Label(L10n.Tools.Tools.SignalMapper.Survey.spotCheck, systemImage: "scope")
      }
      Button {
        pendingAction = .editLockOn
        dismiss()
      } label: {
        Label(L10n.Tools.Tools.SignalMapper.Ride.lockOn, systemImage: "person.crop.circle.badge.plus")
      }
      Button(role: .destructive) {
        pendingAction = .stop
        dismiss()
      } label: {
        Label(L10n.Tools.Tools.SignalMapper.Survey.stop, systemImage: "stop.circle")
      }
    }
  }

  private func distanceText(_ meters: Double) -> String {
    meters >= 1000
      ? String(format: "%.1f km", meters / 1000)
      : String(format: "%.0f m", meters)
  }
}
