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
  /// Set when a tap finds the popover binding already true with nothing on screen. See
  /// ``handlePrimaryAction()``.
  @State private var pendingSignalDetailReopen = false
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

  /// How long to wait before re-presenting the signal table after clearing a binding that
  /// was left stranded `true`. Long enough for any dismissal morph still in flight to
  /// finish, short enough that the second tap still feels like it did something.
  private static let popoverReopenSettleDelay: Duration = .milliseconds(350)

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

  /// A survey used to *stop* the signal-bars engine, which emptied this control's table
  /// and shrank its label to a glyph for the whole ride — and a toolbar item's tap target
  /// is its label's rect, so the pill became almost untappable exactly when a rider needed
  /// it. Bars backs off its cadence now instead of stopping, so there is no paused state
  /// left to render (Rafael, 2026-08-30).

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
      if isGone, !showingWatchScreen {
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
      // Clearing on cancellation matters as much as on success: a `.task(id:)` that
      // returns with its flag still true can never be restarted by setting that flag
      // true again, and the menu item is dead for the rest of the session.
      do { try await Task.sleep(for: Self.menuDismissSettleDelay) } catch {
        pendingAdvancedSettings = false
        return
      }
      pendingAdvancedSettings = false
      appState.navigation.navigateToSetting(.advanced)
    }
    .task(id: pendingSignalDetailReopen) {
      guard pendingSignalDetailReopen else { return }
      do { try await Task.sleep(for: Self.popoverReopenSettleDelay) } catch {
        pendingSignalDetailReopen = false
        return
      }
      pendingSignalDetailReopen = false
      guard appState.connectionState.isConnected else { return }
      pendingMovementHintsPrompt = true
      showingSignalDetail = true
    }
    .task(id: showingSignalDetail) {
      guard !showingSignalDetail, pendingMovementHintsPrompt else {
        if !showingSignalDetail { pendingMovementHintsPrompt = false }
        return
      }
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
  ///
  /// The `guard` is the fix for "I tapped again and now it won't open at all" (field
  /// report, 2026-08-30). A tap that lands while the popover is still running its
  /// dismissal morph — or while the toolbar item is being rebuilt around a survey
  /// starting or ending — is swallowed: SwiftUI drops the presentation but leaves the
  /// binding reading `true`. From then on every tap sets `true` over `true`, which is not
  /// a change, so nothing ever opens again. Finding the binding already true when no
  /// popover is on screen is therefore a *repair*, not a toggle: clear it and re-present
  /// once the morph has settled.
  private func handlePrimaryAction() {
    guard appState.connectionState.isConnected else {
      showingDeviceSelection = true
      return
    }
    guard !showingSignalDetail else {
      showingSignalDetail = false
      // A stranded watch flag disables the *other* reset path — the link-loss handler
      // below skips its cleanup while it reads true — so a tap that is repairing one
      // latch clears the one that would otherwise outlive it. Safe here by construction:
      // the user is tapping the toolbar, so no full-screen watch sheet is up.
      showingWatchScreen = false
      // Clearing this too: leaving it armed points a 600 ms Motion & Fitness alert at the
      // 350 ms re-present below, and a TCC alert landing during a popover presentation is
      // this file's entire crash history.
      pendingMovementHintsPrompt = false
      pendingSignalDetailReopen = true
      return
    }
    pendingMovementHintsPrompt = true
    showingSignalDetail = true
  }

  // MARK: - Label

  /// The control's face. Branches only *inside* the always-mounted label, varying content by
  /// value; the toolbar item itself never comes or goes.
  ///
  /// `fixedSize` is load-bearing: a long navigation title makes the bar compress its items,
  /// and without it the compression lands on the smallest texts first — the dB readouts
  /// truncate to "11…" while the bars stay whole. The cluster renders at its natural width
  /// and the title does the yielding; it is the larger, more redundant element.
  private var labelContent: some View {
    // Structure restored to the shape that renders correctly, after two attempts to give
    // this a 44 pt tap floor broke it in the same way (field reports 2026-08-30 and -31):
    // the content drew at its ideal width while the item's glass capsule stayed small, so
    // the cluster spilled out of both ends of a stub of a pill.
    //
    // Whatever the sizing negotiation is between `fixedSize`, a hosted toolbar item and
    // the `Menu` drawn over it, a `frame` here does not survive it, and the hit area is
    // not worth a broken control. The "won't open at all" report has a second, sufficient
    // cause that is fixed in `handlePrimaryAction` with no layout involved: a presentation
    // binding stranded `true`. Leave the geometry alone.
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
