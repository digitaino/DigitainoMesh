import MC1Services
import SwiftUI

/// The always-visible evidence that a survey run is alive — a thin capsule strip under
/// the navigation bar, restoring (and widening) the M3 survey pill the first ride-HUD
/// design deleted (UI review S1: with counts hidden behind an invisible tap, a silent
/// ride and a working ride looked identical).
///
/// Contents, left to right: pulsing recording dot (red antenna glyph while the radio
/// link is down), elapsed time, probes·replies·lost, hexagons probed, a fix-health
/// warning chip only when fixes are being rejected, and a 44 pt stop button. Tapping
/// the strip body opens the run-detail sheet; the counts roll with
/// `contentTransition(.numericText())` — the v1 survey pill's idiom.
struct SignalMapperLiveStrip: View {
  let session: SignalMapperRideSession
  let onDetail: () -> Void
  let onStop: () -> Void

  @State private var pulse = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(spacing: 10) {
        Button(action: onDetail) {
          HStack(spacing: 10) {
            leadingGlyph

            Text(elapsedText(now: context.date))
              .font(.subheadline.weight(.semibold))
              .monospacedDigit()

            countsText
              .font(.subheadline)
              .monospacedDigit()

            if totals.skippedNoFixCount > 20 {
              fixHealthChip
            }
          }
          .lineLimit(1)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stripAccessibilityLabel(now: context.date))
        .accessibilityHint(L10n.Tools.Tools.SignalMapper.Strip.detailHint)

        Spacer(minLength: 4)

        Button(action: onStop) {
          Image(systemName: "stop.circle.fill")
            .font(.title2)
            .foregroundStyle(.red)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Tools.Tools.SignalMapper.Survey.stop)
      }
      .padding(.leading, 14)
      .padding(.trailing, 2)
      .padding(.vertical, 2)
      .liquidGlass(in: .capsule)
      .padding(.horizontal, 16)
      .padding(.top, 4)
      .padding(.bottom, 8)
      .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
    .onAppear { pulse = true }
  }

  private var totals: SignalMapperProbeEngine.SessionSnapshot {
    session.displayTotals
  }

  @ViewBuilder
  private var leadingGlyph: some View {
    if session.isRadioConnected {
      Circle()
        .fill(.red)
        .frame(width: 8, height: 8)
        .opacity(pulse ? 0.4 : 1.0)
        .animation(
          .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
          value: pulse
        )
        .accessibilityHidden(true)
    } else {
      // The radio-down state is a strip state, not another banner that shoves
      // everything else around (UI review §5).
      Image(systemName: "antenna.radiowaves.left.and.right.slash")
        .font(.caption.weight(.bold))
        .foregroundStyle(.red)
        .accessibilityHidden(true)
    }
  }

  /// Labelled counts — "2 probes · 6 replies · 0 lost". The first field test proved
  /// that bare dot-separated numbers read as noise, not data: nobody carries the
  /// legend in their head at 25 km/h.
  private var countsText: some View {
    Text(L10n.Tools.Tools.SignalMapper.Strip.counts(
      totals.probesSent,
      totals.traceRepliesHeard + totals.discoverResponsesHeard,
      totals.probesLost
    ))
    .contentTransition(.numericText())
    .animation(.snappy(duration: 0.3), value: totals.probesSent)
  }

  /// The silent-total-failure detector: fixes being rejected means the ride is
  /// recording nothing, which must be loud (ACTIVE_SURVEY_M3_5.md §2.7).
  private var fixHealthChip: some View {
    Label(L10n.Tools.Tools.SignalMapper.Strip.noFix, systemImage: "location.slash.fill")
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(.orange, in: .capsule)
  }

  private func elapsedText(now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(session.startedAt)))
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
    }
    return String(format: "%d:%02d", minutes, seconds % 60)
  }

  private func stripAccessibilityLabel(now: Date) -> String {
    L10n.Tools.Tools.SignalMapper.Strip.accessibility(
      elapsedText(now: now),
      totals.probesSent,
      totals.traceRepliesHeard + totals.discoverResponsesHeard,
      totals.probesLost,
      totals.cellsProbed
    )
  }
}
