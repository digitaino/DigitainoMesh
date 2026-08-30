import MC1Services
import OSLog
import SwiftUI
import TipKit

private let logger = Logger(subsystem: "com.mc1", category: "BLEStatus")

/// The one radio control in every toolbar: connection state, the best repeater link, and the
/// device menu in a single compact item.
///
/// It replaces the former two-item pair (an antenna glyph carrying the device menu next to a
/// separate signal indicator). Two toolbar items meant two glass capsules plus an extra icon,
/// which crowded pushed screens enough to truncate conversation titles; one control shows the
/// richest thing it knows — the signal cluster while connected, the color-coded antenna
/// otherwise — and layers the interactions instead:
/// - **Tap** opens the repeater signal table (`RepeaterSignalPopover`), or the device picker
///   while disconnected — each state's one obvious destination.
/// - **Sustained press** opens the device menu (adverts, change device, disconnect, advanced).
///
/// ## Stable identity is load-bearing
/// One always-present `ToolbarActionMenu`, never an `if`/`else` between different control
/// kinds: SwiftUI gives a branch's arms distinct identities, so toggling on connection state
/// rebuilds the hosted toolbar item mid-update and trips a graph re-entrancy crash on iOS 26.
/// Only the label and menu content vary by value, which updates the control in place.
struct RadioStatusControl: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  @State private var showingDeviceSelection = false
  @State private var showingSignalDetail = false
  @State private var showingWatchScreen = false
  @State private var pendingMovementHintsPrompt = false
  @State private var pendingAdvancedSettings = false
  @State private var isSendingAdvert = false
  @State private var successFeedbackTrigger = false
  @State private var errorFeedbackTrigger = false
  @State private var isRxFlashing = false
  @State private var isTxFlashing = false
  @State private var lastRxTick: UInt = 0
  @State private var lastTxTick: UInt = 0
  @State private var menuHapticTrigger = 0

  /// How long the device-menu press must be held before the haptic confirms it.
  /// Matches the system menu-open hold on `Menu(primaryAction:)` closely enough
  /// that the thump lands as the menu unfolds.
  private static let menuHapticHoldDuration: Double = 0.5

  /// How long after the signal popover closes before the Motion & Fitness prompt may fire —
  /// comfortably past the popover's dismissal morph, so the system alert never lands while
  /// a popover transition is in flight.
  private static let movementPromptSettleDelay: Duration = .milliseconds(600)

  /// How long after the Advanced Settings tap before the tab actually switches. Switching
  /// tabs deallocates this control and every popover it owns; doing that synchronously from
  /// a menu action runs the teardown straight into the menu's own dismissal morph — on iPad
  /// the menu *is* a popover — which is the transition-conflict family behind crash
  /// B8A782EC. One dismissal morph, same budget as the movement prompt.
  private static let menuDismissSettleDelay: Duration = .milliseconds(600)

  private let deviceMenuTip = DeviceMenuTip()

  private var signals: RepeaterSignalModel {
    appState.repeaterSignals
  }

  /// Whether the label shows the signal cluster rather than the antenna glyph: a live engine
  /// on a connected radio. False while disconnected, and while the per-device signal-tracking
  /// setting is off.
  private var showsSignalCluster: Bool {
    signals.isAttached && appState.connectionState.isConnected
  }

  var body: some View {
    ToolbarActionMenu(primaryAction: handlePrimaryAction) {
      menuContent
    } label: {
      labelContent
    }
    // Confirms the sustained press that opens the device menu, which the system
    // plays no haptic for. A *simultaneous* gesture so it only observes the
    // press the menu recognizer owns; if the recognizers ever stop sharing the
    // touch the failure mode is a missing thump, never a spurious one.
    .simultaneousGesture(
      LongPressGesture(minimumDuration: Self.menuHapticHoldDuration)
        .onEnded { _ in menuHapticTrigger += 1 }
    )
    .deviceMenuTipPopover(deviceMenuTip)
    .dynamicTypeSize(...DynamicTypeSize.xLarge)
    .sensoryFeedback(.impact(flexibility: .solid), trigger: menuHapticTrigger)
    .sensoryFeedback(.success, trigger: successFeedbackTrigger)
    .sensoryFeedback(.error, trigger: errorFeedbackTrigger)
    .accessibilityLabel(L10n.Settings.BleStatus.accessibilityLabel)
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(accessibilityHint)
    .onChange(of: appState.connectedDevice != nil, initial: true) { _, isConnected in
      DeviceMenuTip.isConnected = isConnected
    }
    .onChange(of: signals.snapshot.rxFlashTick) { _, tick in
      flash(tick, last: &lastRxTick, binding: $isRxFlashing)
    }
    .onChange(of: signals.snapshot.txFlashTick) { _, tick in
      flash(tick, last: &lastTxTick, binding: $isTxFlashing)
    }
    .popover(isPresented: $showingSignalDetail) {
      RepeaterSignalPopover(showWatchScreen: $showingWatchScreen)
        .presentationCompactAdaptation(.popover)
    }
    // Terminal link loss closes the table rather than leaving it up hollow: session
    // teardown strips the popover's rows and controls, and dismissing a popover over that
    // torn-down state is the working theory for the iOS 26 zoom-morph trap in TestFlight
    // crash B8A782EC (`_UIZoomTransitionController.startInteractiveTransition`, not
    // reproduced locally). Keyed on `connectedDevice` — which survives the auto-reconnect
    // window — so a sub-second BLE blip cannot yank the table while a user is watching a
    // marginal link. Skipped while the watch sheet is up: yanking its presenter would
    // start a second teardown mid-presentation, the same transition-conflict family.
    .onChange(of: appState.connectedDevice == nil) { _, isGone in
      if isGone && !showingWatchScreen {
        showingSignalDetail = false
      }
    }
    // The Motion & Fitness prompt belongs to the repeater table — the one deliberate visit
    // to this feature, never the connect path, which can fire during an auto-reconnect at
    // launch. But the system alert must not land while a popover transition is in flight
    // (suspected aggravator in crash B8A782EC), so it fires only after a visit *ends*,
    // once the dismissal morph has settled and no popover exists to collide with. The
    // binding flips at dismissal start, so reopening inside the settle window cancels this
    // task and the still-pending flag re-arms it for the next close. A no-op once
    // authorization is determined.
    // Deferred for the reason on `menuDismissSettleDelay`: the tab switch tears this
    // control down, so it must not land while the menu is still dismissing. Cancellation
    // (the control going away first) simply drops the navigation, which is correct — there
    // is nothing to navigate away from.
    .task(id: pendingAdvancedSettings) {
      guard pendingAdvancedSettings else { return }
      do { try await Task.sleep(for: Self.menuDismissSettleDelay) } catch { return }
      pendingAdvancedSettings = false
      appState.navigation.navigateToSetting(.advanced)
    }
    .task(id: showingSignalDetail) {
      guard !showingSignalDetail, pendingMovementHintsPrompt else { return }
      do { try await Task.sleep(for: Self.movementPromptSettleDelay) } catch { return }
      pendingMovementHintsPrompt = false
      appState.requestMovementHintsIfNeeded()
    }
    .sheet(isPresented: $showingDeviceSelection) {
      DeviceSelectionSheet()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
  }

  /// Tap: the one obvious destination for the current state. The signal table needs a
  /// connection to mean anything; without one, the tap goes straight to connecting.
  private func handlePrimaryAction() {
    if appState.connectionState.isConnected {
      pendingMovementHintsPrompt = true
      showingSignalDetail = true
    } else {
      showingDeviceSelection = true
    }
  }

  // MARK: - Label

  /// The control's face. Branches only *inside* the always-mounted label, varying content by
  /// value; the toolbar item itself never comes or goes.
  ///
  /// `fixedSize` is load-bearing: a long navigation title makes the bar compress its items,
  /// and without it the compression lands on the smallest texts first — the dB readouts
  /// truncate to "11…" while the bars stay whole. The cluster renders at its natural width
  /// and the title does the yielding; it is the larger, more redundant element.
  @ViewBuilder
  private var labelContent: some View {
    Group {
      if showsSignalCluster, let best = signals.best {
        HStack(spacing: 6) {
          legColumn(
            glyph: RepeaterSignalGlyph(leg: .rx, quality: best.rxQuality, isFlashing: isRxFlashing),
            readout: RepeaterSNRText(snr: best.rxSnr, quality: best.rxQuality)
          )
          legColumn(
            glyph: RepeaterTXGlyph(state: best.txState, isFlashing: isTxFlashing),
            readout: RepeaterSNRText(snr: best.txSnr, quality: best.txQuality)
          )
          identityColumn(for: best)
          watchBadge
        }
        .padding(.horizontal, 2)
      } else if showsSignalCluster {
        HStack(spacing: 6) {
          scanningGlyph
          powerLabel
          watchBadge
        }
      } else {
        StatusIcon(iconName: iconName, iconColor: iconColor, isAnimating: isAnimating)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
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
    if signals.watched != nil {
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

  // MARK: - Menu Content

  @ViewBuilder
  private var menuContent: some View {
    if let device = appState.connectedDevice {
      Section {
        if device.clientRepeat {
          Label(L10n.Settings.BleStatus.repeatModeActive, systemImage: "repeat")
            .foregroundStyle(AppColors.Radio.repeatMode)
        }
        VStack(alignment: .leading) {
          Label(device.nodeName, systemImage: "antenna.radiowaves.left.and.right")
          if let battery = appState.batteryMonitor.deviceBattery {
            let ocvArray = appState.batteryMonitor.activeBatteryOCVArray(for: appState.connectedDevice)
            Label(
              "\(battery.percentage(using: ocvArray))% (\(battery.voltage, format: .number.precision(.fractionLength(2)))v)",
              systemImage: battery.iconName(using: ocvArray)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }

        Button {
          showingDeviceSelection = true
        } label: {
          Label(L10n.Settings.BleStatus.changeDevice, systemImage: "flipphone")
        }

        Button(role: .destructive) {
          logger.info("Disconnect tapped in BLE status menu")
          Task {
            await appState.disconnect(reason: .statusMenuDisconnectTap)
          }
        } label: {
          Label(L10n.Settings.BleStatus.disconnect, systemImage: "eject")
        }
      }

      Section {
        Button {
          sendAdvert(flood: false)
        } label: {
          Label(L10n.Settings.BleStatus.sendZeroHopAdvert, systemImage: "dot.radiowaves.right")
        }
        .radioDisabled(for: appState.connectionState, or: isSendingAdvert)
        .accessibilityHint(L10n.Settings.BleStatus.SendZeroHopAdvert.hint)

        Button {
          sendAdvert(flood: true)
        } label: {
          Label(L10n.Settings.BleStatus.sendFloodAdvert, systemImage: "dot.radiowaves.left.and.right")
        }
        .radioDisabled(for: appState.connectionState, or: isSendingAdvert)
        .accessibilityHint(L10n.Settings.BleStatus.SendFloodAdvert.hint)
      }

      Section {
        Button {
          pendingAdvancedSettings = true
        } label: {
          Label(L10n.Settings.AdvancedSettings.title, systemImage: "gearshape")
        }
      }
    } else {
      Button {
        showingDeviceSelection = true
      } label: {
        Label(L10n.Settings.Device.connect, systemImage: "antenna.radiowaves.left.and.right")
      }
    }
  }

  // MARK: - Accessibility

  private var accessibilityValue: String {
    guard showsSignalCluster, let best = signals.best else { return statusTitle }
    return "\(statusTitle), \(best.accessibilityDescription)"
  }

  private var accessibilityHint: String {
    appState.connectedDevice != nil
      ? L10n.Settings.BleStatus.AccessibilityHint.connected
      : L10n.Settings.BleStatus.AccessibilityHint.disconnected
  }

  // MARK: - Status

  private var iconName: String {
    switch appState.connectionState {
    case .disconnected:
      "antenna.radiowaves.left.and.right.slash"
    case .connecting, .connected, .syncing, .ready:
      "antenna.radiowaves.left.and.right"
    }
  }

  private var iconColor: Color {
    if appState.connectedDevice?.clientRepeat == true {
      return AppColors.Radio.repeatMode
    }
    switch appState.connectionState {
    case .disconnected:
      return .secondary
    case .connecting, .connected, .syncing:
      return AppColors.Radio.connecting
    case .ready:
      return AppColors.Radio.ready
    }
  }

  private var isAnimating: Bool {
    appState.connectionState == .connecting
  }

  private var statusTitle: String {
    switch appState.connectionState {
    case .disconnected:
      L10n.Settings.BleStatus.Status.disconnected
    case .connecting:
      L10n.Settings.BleStatus.Status.connecting
    case .connected:
      L10n.Settings.BleStatus.Status.connected
    case .syncing:
      L10n.Settings.BleStatus.Status.syncing
    case .ready:
      L10n.Settings.BleStatus.Status.ready
    }
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

  // MARK: - Actions

  private func sendAdvert(flood: Bool) {
    guard !isSendingAdvert else { return }
    isSendingAdvert = true

    Task {
      do {
        try await appState.sendSelfAdvert(flood: flood)
        successFeedbackTrigger.toggle()
      } catch {
        logger.error("Failed to send advert (flood=\(flood)): \(error.localizedDescription)")
        errorFeedbackTrigger.toggle()
      }
      isSendingAdvert = false
    }
  }
}

// MARK: - Tip gating

private extension View {
  /// Anchors the device-menu tip on iOS 18 only. On iOS 26 popovers dismiss through the
  /// Liquid Glass zoom morph, which trapped on a nil transition source in TestFlight
  /// crash B8A782EC — and a tip is the one popover here that presents with no
  /// interaction, so it can be mid-transition during the connection-state updates that
  /// reshape this control (suspected, not reproduced: the crash recurred ~4s into fresh
  /// launches, which fits an auto-presenting tip whose display count was never persisted
  /// because the process died first). The availability branch is constant for the life of
  /// the process, so the toolbar item's structural identity never changes at runtime —
  /// the invariant this control's docs require.
  ///
  /// TODO: temporary suppression — re-home the tip off the popover-presenting toolbar
  /// item (e.g. an inline `TipView`) once the crash is confirmed fixed on TestFlight.
  @ViewBuilder
  func deviceMenuTipPopover(_ tip: DeviceMenuTip) -> some View {
    if #unavailable(iOS 26.0) {
      popoverTip(tip)
    } else {
      self
    }
  }
}

// MARK: - Status Icon

private struct StatusIcon: View {
  let iconName: String
  let iconColor: Color
  let isAnimating: Bool

  var body: some View {
    Image(systemName: iconName)
      .foregroundStyle(iconColor)
      .symbolEffect(.pulse, isActive: isAnimating)
  }
}

#Preview("Disconnected") {
  NavigationStack {
    Text("Content")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          RadioStatusControl()
        }
      }
  }
  .environment(\.appState, AppState())
}
