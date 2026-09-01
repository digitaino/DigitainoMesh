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
  /// The label held steady for as long as the repeater table is anchored here, or `nil` to
  /// follow the live data. See ``PinnedLabel`` and ``labelArm``.
  @State private var pinnedLabel: PinnedLabel?
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

  /// How long after the table closes before the label may change arms again. The unpin is
  /// itself an arm swap, so releasing it the instant the binding flips would put the swap
  /// inside the dismissal morph — the very collision the pin exists to prevent. One
  /// dismissal morph, same budget as the movement prompt.
  private static let labelUnpinSettleDelay: Duration = .milliseconds(600)

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

  // A survey used to *stop* the signal-bars engine, which emptied this control's table
  // and shrank its label to a glyph for the whole ride — and a toolbar item's tap target
  // is its label's rect, so the pill became almost untappable exactly when a rider needed
  // it. Bars backs off its cadence now instead of stopping, so there is no paused state
  // left to render (Rafael, 2026-08-30).

  /// Which arm of ``labelContent`` is drawn. Named because the three arms are three
  /// *identities*, not three appearances: swapping arms destroys one subtree of views and
  /// builds another, which is a structural change to whatever the presented popover is
  /// anchored to. See ``labelArm``.
  private enum LabelArm: Equatable {
    /// The full cluster: both legs, the identity column, the watch badge.
    case cluster
    /// Attached but nothing heard yet — the scanning glyph.
    case scanning
    /// Not attached, or not connected — the antenna glyph.
    case status
  }

  /// What ``labelContent`` draws while the repeater table is anchored to this control.
  private struct PinnedLabel: Equatable {
    let arm: LabelArm
    /// Stands in if the live `best` vanishes under a pinned `.cluster` — clearing stale
    /// rows from inside the table can empty it — so the arm outlives its own data rather
    /// than collapsing to a different one at the worst moment.
    let best: RepeaterSignal?
  }

  /// The arm the live data asks for.
  private var liveLabelArm: LabelArm {
    guard showsSignalCluster else { return .status }
    return signals.best != nil ? .cluster : .scanning
  }

  /// The arm actually drawn: the live one, unless the repeater table is up and pinned it.
  ///
  /// TestFlight crash 066A8D88 (0.11.0 build 5, iOS 26.6.1) is B8A782EC recurring on the
  /// build that was meant to fix it. The reporter re-enabled signal bars and tapped this
  /// control inside the seconds `wireSignalBars` spends probing the firmware, so the table
  /// opened over the `.status` arm and then `isAttached` flipped underneath it — walking
  /// this label `.status` → `.scanning` → `.cluster` with the popover already presented.
  /// SwiftUI answers a structural anchor change by dismissing and re-presenting
  /// (`UIKitPopoverBridge.dismissAndReset`), which it did from inside `layoutSubviews`,
  /// where iOS 26's zoom morph then trapped on the anchor it could no longer find.
  ///
  /// Pinning holds the arm — never the readings inside it, which stay live — for as long
  /// as the table is anchored. It is the second of two defences and deliberately
  /// redundant with the stable anchor in `body`: which view SwiftUI resolves the anchor
  /// against, the modified view or the hosted toolbar item, is not something this side of
  /// the framework can verify, and the crash has already survived one fix.
  private var labelArm: LabelArm {
    pinnedLabel?.arm ?? liveLabelArm
  }

  /// The link the cluster arm draws. Falls back to the pinned copy so a table that empties
  /// under an open popover cannot pull the arm out from under it.
  private var displayedBest: RepeaterSignal? {
    signals.best ?? pinnedLabel?.best
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
    // The table anchors to a spacer, not to the label. `labelContent` swaps between three
    // identities and sizes itself from live engine data, so as an anchor it is a view that
    // can be destroyed and re-created under a presented popover — the mechanism behind
    // TestFlight crash 066A8D88 (see ``labelArm``). This 1 pt spacer never changes
    // identity or size, so the iOS 26 zoom morph always has something to dismiss into.
    //
    // A `Color.clear` in a `background` draws nothing and contributes no layout, so the
    // sizing negotiation between `fixedSize`, the hosted toolbar item and the `Menu` drawn
    // over it — which has broken this control twice under a `frame`, see `labelContent` —
    // is untouched. Centred, so the arrow points where it pointed before. Hit testing off:
    // the tap belongs to the `Menu` overlay above it, and a stray 1 pt target here would
    // be a second thing to reason about.
    .background(alignment: .center) {
      Color.clear
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .popover(isPresented: $showingSignalDetail) {
          RepeaterSignalPopover(showWatchScreen: $showingWatchScreen)
            .presentationCompactAdaptation(.popover)
        }
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
      pinnedLabel = PinnedLabel(arm: liveLabelArm, best: signals.best)
      showingSignalDetail = true
    }
    // Releases the label pin once the dismissal morph has settled. Deliberately does *not*
    // clear on cancellation: the only cancellation that matters is the table re-opening,
    // and `handlePrimaryAction` has already written a fresh pin by then — clearing here
    // would wipe it. The other cancellation is this control going away, which takes the
    // state with it.
    .task(id: showingSignalDetail) {
      guard !showingSignalDetail, pinnedLabel != nil else { return }
      do { try await Task.sleep(for: Self.labelUnpinSettleDelay) } catch { return }
      pinnedLabel = nil
    }
    // The breadcrumb this crash has cost two builds for. 066A8D88 and B8A782EC are both
    // unreproducible off-device, and both were fixed against a reasoned mechanism rather
    // than an observed one; a line in the log immediately before the next crash report —
    // or its absence — is what turns the mechanism above into a fact.
    .onChange(of: liveLabelArm) { from, to in
      guard showingSignalDetail else { return }
      logger.info(
        "Label arm \(String(describing: from)) -> \(String(describing: to)) with the repeater table presented (pinned=\(pinnedLabel != nil))"
      )
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
    // Pinned *before* the binding flips, so the arm the table anchors to is already frozen
    // by the time the presentation starts. Doing it from an `onChange` of the binding
    // would leave one update where the popover is presenting against a still-live label.
    pinnedLabel = PinnedLabel(arm: liveLabelArm, best: signals.best)
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
    //
    // The arm comes from `labelArm`, not from the live data directly: while the repeater
    // table is anchored here the arm is pinned, because swapping arms under a presented
    // popover is what crashed TestFlight build 5 (see `labelArm`). The contents of an arm
    // stay live either way.
    Group {
      switch labelArm {
      case .cluster:
        // `displayedBest` rather than `signals.best`: a pinned `.cluster` must be able to
        // draw even if the table empties under it, or the fallback here would be the arm
        // change the pin exists to prevent.
        if let best = displayedBest {
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
        }
      case .scanning:
        HStack(spacing: 6) {
          scanningGlyph
          powerLabel
          watchBadge
        }
      case .status:
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
