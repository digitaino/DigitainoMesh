import MC1Services
import SwiftUI

/// The repeater signal indicator as a reusable toolbar item, mounted immediately after
/// `bleStatusToolbarItem()` on every section that surfaces radio state.
///
/// It shares the leading edge with that control on purpose: "am I connected" and "how well is
/// the mesh hearing me" are one question, and the trailing slots already belong to each
/// section's own actions. A section whose leading slot is spoken for passes a placement, the
/// same escape hatch the radio status item offers.
@MainActor
@ToolbarContentBuilder
func repeaterSignalToolbarItem(placement: ToolbarItemPlacement = .topBarLeading) -> some ToolbarContent {
  ToolbarItem(placement: placement) {
    RepeaterSignalIndicatorView()
  }
}

/// Best-link signal at a glance: how well this radio and its best repeater hear each other,
/// which repeater that is, and what power we are transmitting at.
///
/// Both legs are shown because they are measured separately and routinely differ — a repeater
/// booming in while it can barely hear us is exactly the situation this control exists to
/// make visible. Tapping opens the full table.
struct RepeaterSignalIndicatorView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  @State private var isShowingDetail = false
  @State private var isRxFlashing = false
  @State private var isTxFlashing = false
  @State private var lastRxTick: UInt = 0
  @State private var lastTxTick: UInt = 0

  private var model: RepeaterSignalModel {
    appState.repeaterSignals
  }

  var body: some View {
    Button {
      isShowingDetail = true
    } label: {
      label
    }
    .disabled(!isVisible)
    .accessibilityHidden(!isVisible)
    .dynamicTypeSize(...DynamicTypeSize.xLarge)
    .accessibilityLabel(L10n.Localizable.SignalBars.title)
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(L10n.Localizable.SignalBars.Accessibility.toolbarHint)
    .popover(isPresented: $isShowingDetail) {
      RepeaterSignalPopover()
        .presentationCompactAdaptation(.popover)
    }
    .onChange(of: model.snapshot.rxFlashTick) { _, tick in
      flash(tick, last: &lastRxTick, binding: $isRxFlashing)
    }
    .onChange(of: model.snapshot.txFlashTick) { _, tick in
      flash(tick, last: &lastTxTick, binding: $isTxFlashing)
    }
  }

  /// Whether there is anything to show: a live engine on a connected radio. False while
  /// disconnected, and while the per-device signal-tracking setting is off.
  private var isVisible: Bool {
    model.isAttached && appState.connectionState.isConnected
  }

  // MARK: - Label

  /// The `ToolbarItem` stays mounted and only its *content* varies, collapsing to nothing when
  /// there is no signal to report. Removing the item itself would give SwiftUI a new identity
  /// on every connection change, which is the hosted-toolbar rebuild that trips the iOS 26
  /// graph re-entrancy crash `BLEStatusIndicatorView` documents.
  @ViewBuilder
  private var label: some View {
    if !isVisible {
      EmptyView()
    } else {
      HStack(spacing: 4) {
        if let best = model.best {
          legColumn(
            glyph: RepeaterSignalGlyph(leg: .rx, quality: best.rxQuality, isFlashing: isRxFlashing),
            readout: RepeaterSNRText(snr: best.rxSnr, quality: best.rxQuality)
          )
          legColumn(
            glyph: RepeaterTXGlyph(state: best.txState, isFlashing: isTxFlashing),
            readout: RepeaterSNRText(snr: best.txSnr, quality: best.txQuality)
          )
          identityColumn(for: best)
        } else {
          scanningGlyph
          powerLabel
        }
        watchBadge
      }
    }
  }

  private func legColumn(glyph: some View, readout: some View) -> some View {
    VStack(spacing: 0) {
      glyph
      readout
    }
  }

  /// Who the best link is, and what we are shouting at it with.
  private func identityColumn(for best: RepeaterSignal) -> some View {
    VStack(spacing: 1) {
      Text(best.hexID)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
      powerLabel
    }
  }

  private var scanningGlyph: some View {
    Image(systemName: "cellularbars", variableValue: 0)
      .font(.system(size: 14))
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  }

  /// The active adaptive-power step, only while adaptive power is actually managing it —
  /// otherwise the number would imply a control the user has not turned on.
  @ViewBuilder
  private var powerLabel: some View {
    if let power = appState.services?.adaptivePowerService, power.isEnabled {
      Text(power.currentStep.label)
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(powerColor(for: power))
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var watchBadge: some View {
    if model.watched != nil {
      Image(systemName: "binoculars.fill")
        .font(.system(size: 10))
        .foregroundStyle(theme.accentColor)
        .accessibilityHidden(true)
    }
  }

  private func powerColor(for power: AdaptivePowerService) -> Color {
    if power.isAtMax { return .red }
    return power.isElevated ? .orange : .green
  }

  // MARK: - Accessibility

  private var accessibilityValue: String {
    guard let best = model.best else {
      return L10n.Localizable.SignalBars.noRepeaters
    }
    return best.accessibilityDescription
  }

  // MARK: - Flash

  /// Ticks are counters, not events: comparing against the last one seen means a snapshot
  /// republished for an unrelated reason cannot re-trigger the animation.
  private func flash(_ tick: UInt, last: inout UInt, binding: Binding<Bool>) {
    guard tick != last else { return }
    last = tick
    binding.wrappedValue = true
    Task {
      try? await Task.sleep(for: .milliseconds(150))
      binding.wrappedValue = false
    }
  }
}
