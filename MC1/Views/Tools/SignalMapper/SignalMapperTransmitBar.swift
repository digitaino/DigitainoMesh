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
    VStack(alignment: .leading, spacing: 4) {
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

      if let status {
        Text(status.text)
          .font(.caption2)
          .foregroundStyle(status.isFailure ? Color.orange : Color.secondary)
          .lineLimit(2)
          .transition(.opacity)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .sensoryFeedback(feedbackIsSuccess ? .success : .warning, trigger: feedbackTrigger)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
        .labelStyle(.titleAndIcon)
        // Three of these share one phone-width row, and the words are nouns in most
        // locales — "Обнаружение", "Découverte", "Wykrywanie". They shrink rather than
        // truncate or push each other off the row.
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .contentShape(.rect)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
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
