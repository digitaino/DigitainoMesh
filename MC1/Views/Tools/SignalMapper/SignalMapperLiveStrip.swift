import MC1Services
import SwiftUI

/// The always-visible evidence that a survey run is alive — a thin capsule strip under
/// the navigation bar, restoring (and widening) the M3 survey pill the first ride-HUD
/// design deleted (UI review S1: with counts hidden behind an invisible tap, a silent
/// ride and a working ride looked identical).
///
/// Contents, left to right: pulsing recording dot (red antenna glyph while the radio
/// link is down), elapsed time, probes·replies·lost, hexagons probed, the adaptive-power
/// step when adaptive power is on, a fix-health warning chip only when fixes are being
/// rejected, and a 44 pt stop button. Tapping the strip body opens the run-detail sheet;
/// the counts roll with `contentTransition(.numericText())` — the v1 survey pill's idiom.
///
/// The labelled counts are the thing this strip exists for and the one thing it will not
/// truncate; when the row runs out of width the elapsed clock is dropped instead. See
/// ``stripRow(now:showsElapsed:)``.
struct SignalMapperLiveStrip: View {
  let session: SignalMapperRideSession
  let onDetail: () -> Void
  let onStop: () -> Void

  @Environment(\.appState) private var appState

  @State private var pulse = false
  @State private var tonePlayer = RepeaterWatchTonePlayer()
  @State private var wasRadioConnected = true
  @State private var lostRadioTrigger = 0

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(spacing: 10) {
        Button(action: onDetail) {
          // The clock is what the row sheds when it cannot hold everything, and it sheds it
          // whole rather than letting the labelled counts truncate. At 393 pt the tap
          // button's slot is 277 pt against a 294 pt row once the power chip is up, and a
          // shortfall of that size eats the last field of "2 probes · 6 replies · 0 lost"
          // outright — label and number both — while `layoutPriority` would instead clip
          // "158mW" to "15…", which reads as a different power level. The elapsed time
          // survives in the run-detail sheet and in `stripAccessibilityLabel`.
          //
          // Measured over the fixed-size children only, for the reason the transmit bar
          // states: the trailing spacer is outside this button, so no candidate can be found
          // to "fit" by compressing it and leave the fallback dead.
          ViewThatFits(in: .horizontal) {
            stripRow(now: context.date, showsElapsed: true)
            stripRow(now: context.date, showsElapsed: false)
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
      .mapperHUDSurface(in: .capsule)
      .padding(.horizontal, 16)
      .padding(.top, 4)
      .padding(.bottom, 8)
      .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
    .onAppear { pulse = true }
    // The radio dropping mid-ride is what makes a whole ride worthless, and the only
    // other cue for it is this strip's glyph — which is exactly what a rider looking at
    // the road is not reading. The alarm belongs to the one view that is on screen for
    // the entire run (UI review P1-6).
    .onChange(of: session.isRadioConnected) { _, connected in
      defer { wasRadioConnected = connected }
      guard wasRadioConnected, !connected else { return }
      tonePlayer.play(.tock)
      lostRadioTrigger += 1
    }
    .sensoryFeedback(.warning, trigger: lostRadioTrigger)
  }

  private var totals: SignalMapperProbeEngine.SessionSnapshot {
    session.displayTotals
  }

  /// The strip's readout, with and without the elapsed clock — one builder rather than two
  /// arrangements to keep in step.
  private func stripRow(now: Date, showsElapsed: Bool) -> some View {
    HStack(spacing: 10) {
      leadingGlyph

      if showsElapsed {
        Text(elapsedText(now: now))
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
      }

      countsText
        .font(.subheadline)
        .monospacedDigit()

      powerChip

      if let warning = fixWarning {
        fixHealthChip(warning)
      }
    }
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

  /// The active adaptive-power step — the one thing the radio pill said that no cell card
  /// can, carried here because the mapper hides that pill for the length of a ride
  /// (Rafael, 2026-09-04). Gated exactly as the pill gates it: shown only while adaptive
  /// power is actually managing the level, or the number implies a control the user has not
  /// turned on. Same colour rule too — red at the ceiling, orange above base, green at base.
  @ViewBuilder
  private var powerChip: some View {
    if let power = appState.services?.adaptivePowerService, power.isEnabled {
      Text(power.currentStep.label)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(power.isAtMax ? .red : (power.isElevated ? .orange : .green))
    }
  }

  /// What the fix-health chip is warning about, or nil when the fixes are fine.
  ///
  /// Two conditions, because they are two different problems with two different answers.
  /// "No fix" is the probe engine failing to *plan* — there is no position at all, so wait
  /// or go outside. "Fixes rejected" is the capture engine refusing to place what the radio
  /// is hearing because the fix is too vague or too old for its own speed, which is the
  /// state that produced a ride reading "3 probes · 12 replies" over an empty cell card
  /// (field report, 2026-09-04). The refusal is the more specific claim, so it wins.
  private enum FixWarning: Equatable {
    case rejected
    case noFix
  }

  private var fixWarning: FixWarning? {
    if session.captureFixHealth.isRejectingFixes, session.captureFixHealth.isQualityRejection {
      return .rejected
    }
    return totals.skippedNoFixCount > 20 ? .noFix : nil
  }

  /// The silent-total-failure detector: fixes being rejected means the ride is
  /// recording nothing placeable, which must be loud (ACTIVE_SURVEY_M3_5.md §2.7).
  private func fixHealthChip(_ warning: FixWarning) -> some View {
    Label(
      warning == .rejected
        ? L10n.Tools.Tools.SignalMapper.Strip.fixRejected
        : L10n.Tools.Tools.SignalMapper.Strip.noFix,
      systemImage: "location.slash.fill"
    )
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

  /// Neither chip's own wording is reachable by VoiceOver — the button around them carries a
  /// single label and hides its children — so both are spoken here or not at all.
  private func stripAccessibilityLabel(now: Date) -> String {
    var spoken = L10n.Tools.Tools.SignalMapper.Strip.accessibility(
      elapsedText(now: now),
      totals.probesSent,
      totals.traceRepliesHeard + totals.discoverResponsesHeard,
      totals.probesLost,
      totals.cellsProbed
    )
    if let power = appState.services?.adaptivePowerService, power.isEnabled {
      spoken += " " + L10n.Tools.Tools.SignalMapper.Strip.power(power.currentStep.label)
    }
    // Both warnings, not just the newer one: the "No fix" chip has been drawn on this strip
    // since M3.5 and has never been spoken, which is the same silence the chip itself was
    // added to break.
    switch fixWarning {
    case .rejected: return spoken + " " + L10n.Tools.Tools.SignalMapper.Strip.fixRejectedHint
    case .noFix: return spoken + " " + L10n.Tools.Tools.SignalMapper.Strip.noFix
    case nil: return spoken
    }
  }
}
