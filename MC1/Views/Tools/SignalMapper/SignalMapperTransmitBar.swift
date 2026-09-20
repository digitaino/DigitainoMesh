import MC1Services
import SwiftUI

/// The three manual transmissions, one tap each, on the ride HUD.
///
/// They lived only behind the options menu → Transmit sheet, which is two taps and a
/// screen away from a rider who is stopped at a viewpoint wondering whether anyone can
/// hear him — "way too hidden" (Rafael, 2026-08-31). The sheet stays, because choosing a
/// flood channel and a specific trace target belongs there; this is the fast path for the
/// thing you actually do repeatedly.
///
/// Every button here puts a packet on the air, so every one of them answers: the caption
/// under the row says what happened and why not, rather than leaving a rider tapping a
/// button that looks dead because the fix went stale.
struct SignalMapperTransmitBar: View {
  let session: SignalMapperRideSession
  let model: SignalMapperCoverageModel
  /// Opens the full sheet — for picking a trace target, or setting up a flood channel.
  let onOpenSheet: () -> Void

  @Environment(\.appState) private var appState

  @AppStorage(AppStorageKey.mapperFloodChannelIndex.rawValue)
  private var floodChannelIndex = AppStorageKey.defaultMapperFloodChannelIndex

  @State private var isWorking = false
  @State private var status: Status?
  @State private var feedbackTrigger = 0
  @State private var feedbackIsSuccess = false

  private struct Status: Equatable {
    let text: String
    let isFailure: Bool
  }

  /// The one-tap trace destination: whatever the ride is locked onto. Without a lock-on
  /// there is no obvious "this one", so the button hands over to the picker instead of
  /// guessing.
  private var quickTraceTarget: MapperProbeTarget? {
    session.focusTargets.first
  }

  var body: some View {
    HStack(spacing: 8) {
      // Words where they fit, glyphs where they don't. Shrinking the labels was the old
      // answer and it produced "Dis…" on a 393 pt phone: three truncated nouns cost the
      // same row as three whole ones and say less than the icons alone (Rafael,
      // 2026-09-04). Measured around the three buttons only — the trailing spacer is
      // infinitely compressible, so a `ViewThatFits` wrapped around the whole row would
      // find the labelled candidate "fits" at every width and never fall back.
      ViewThatFits(in: .horizontal) {
        actions.labelStyle(.titleAndIcon)
        actions.labelStyle(.iconOnly)
      }

      Spacer(minLength: 0)

      Button(action: onOpenSheet) {
        Image(systemName: "slider.horizontal.3")
          .font(.caption)
          .frame(width: 44, height: 36)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.tint)
      .accessibilityLabel(L10n.Tools.Tools.SignalMapper.Transmit.title)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    // The verdict floats over the row rather than sitting under it: a caption that comes
    // and goes changes the panel's height, and the panel's height is what the ride camera
    // keeps the rider clear of, so a manual send used to nudge the map. An overlay
    // contributes no layout at all.
    //
    // Hung on the whole bar, not on the spacer between the buttons: the two verdicts are
    // a word and a sentence — "Sent" against "Not sent — no usable fix, no transmit budget
    // left, or no radio" — and a caption sized to the spacer's slack had to be
    // `fixedSize` to be readable at all, which for the refusal meant one unbreakable line
    // running off the leading edge of the phone across the buttons. Proposed the bar's own
    // width it wraps instead, and the refusal is the message that most needs reading.
    //
    // Anchored to the bottom, not the centre: the refusal needs up to four lines in German,
    // Russian and Ukrainian at the accessibility sizes this bar permits, and a centred
    // overlay grows both ways — downward through the panel's own `clipShape`, which cuts the
    // last line off. Growing upward puts the extra lines over the card, inside the same clip.
    .overlay(alignment: .bottomTrailing) { statusCaption }
    .sensoryFeedback(feedbackIsSuccess ? .success : .warning, trigger: feedbackTrigger)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }

  /// The three one-tap transmissions. Each candidate above supplies the label style, so the
  /// words and the glyphs are the same three buttons and not two arrangements to keep in
  /// step.
  private var actions: some View {
    HStack(spacing: 8) {
      button(
        title: L10n.Tools.Tools.SignalMapper.Transmit.discoverShort,
        systemImage: "dot.radiowaves.left.and.right"
      ) {
        await model.manualDiscover(appState: appState)
      }

      button(
        title: L10n.Tools.Tools.SignalMapper.Transmit.traceShort,
        systemImage: "point.topleft.down.to.point.bottomright.curvepath"
      ) {
        guard let target = quickTraceTarget else {
          onOpenSheet()
          // Handing over to the picker is neither a send nor a refusal; claiming
          // "Sent" here would be the dead-button problem inverted.
          return nil
        }
        return await model.manualTrace(appState: appState, target: target)
      }

      button(
        title: L10n.Tools.Tools.SignalMapper.Transmit.floodShort,
        systemImage: "antenna.radiowaves.left.and.right"
      ) {
        guard floodChannelIndex != 0 else {
          // No channel chosen yet: the sheet is where that decision belongs, and it is
          // a decision — a flood on the wrong channel is somebody else's notification.
          onOpenSheet()
          return nil
        }
        return await model.sendFloodProbe(
          appState: appState,
          channelIndex: UInt8(clamping: floodChannelIndex),
          text: L10n.Tools.Tools.SignalMapper.Transmit.floodText
        )
      }
    }
  }

  /// What the last tap did, over the row rather than under it. Cleared on its own after a
  /// few seconds; never hit-testable, so it cannot swallow a tap on the button beneath it.
  ///
  /// Wraps rather than holding one line at any width: the refusal names three possible
  /// causes, and it is a sentence in every locale.
  ///
  /// Four lines for the refusal, two for the success. Two was measured against *one* when
  /// this became an overlay and never against three: at 323 pt the German refusal needs
  /// three lines at xxxL and four at AX2 (Russian and Ukrainian likewise), so a two-line cap
  /// tail-truncated it to "Nicht gesendet — keine / brauchbare Ortung, kein…" — losing both
  /// the budget cause and "kein Funkgerät", the two causes a rider can actually act on. The
  /// success caption is one word and stays where it was.
  @ViewBuilder
  private var statusCaption: some View {
    if let status {
      Text(status.text)
        .font(.caption2)
        .foregroundStyle(status.isFailure ? Color.orange : Color.secondary)
        .lineLimit(status.isFailure ? 4 : 2)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        // A radius that *is* the capsule at one line and a rounded rect at two, rather
        // than a stadium whose side curves would eat into a wrapped sentence.
        .background(.regularMaterial, in: .rect(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }

  private func button(
    title: String,
    systemImage: String,
    action: @escaping () async -> Bool?
  ) -> some View {
    Button {
      run(action)
    } label: {
      Label(title, systemImage: systemImage)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .contentShape(.rect)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    // The word is the label whether or not it is drawn: an icon-only pill that announces
    // itself as "antenna.radiowaves" is a button nobody can identify.
    .accessibilityLabel(title)
    .disabled(isWorking || !session.isRadioConnected)
  }

  /// `nil` from the action means "handed off to the sheet" — no packet, no verdict.
  private func run(_ action: @escaping () async -> Bool?) {
    guard !isWorking else { return }
    isWorking = true
    Task {
      let result = await action()
      isWorking = false
      guard let sent = result else { return }
      feedbackIsSuccess = sent
      feedbackTrigger += 1
      withAnimation(.snappy(duration: 0.2)) {
        status = Status(
          text: sent
            ? L10n.Tools.Tools.SignalMapper.Transmit.sent
            : L10n.Tools.Tools.SignalMapper.Transmit.refused,
          isFailure: !sent
        )
      }
      try? await Task.sleep(for: .seconds(4))
      withAnimation(.snappy(duration: 0.2)) { status = nil }
    }
  }
}
