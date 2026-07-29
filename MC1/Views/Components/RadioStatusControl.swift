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
  @State private var showingAdvancedSettings = false
  @State private var showingSignalDetail = false
  @State private var isSendingAdvert = false
  @State private var successFeedbackTrigger = false
  @State private var errorFeedbackTrigger = false
  @State private var isRxFlashing = false
  @State private var isTxFlashing = false
  @State private var lastRxTick: UInt = 0
  @State private var lastTxTick: UInt = 0

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
    .popoverTip(deviceMenuTip)
    .dynamicTypeSize(...DynamicTypeSize.xLarge)
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
      RepeaterSignalPopover()
        .presentationCompactAdaptation(.popover)
    }
    .sheet(isPresented: $showingDeviceSelection) {
      DeviceSelectionSheet()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    .navigationDestination(isPresented: $showingAdvancedSettings) {
      AdvancedSettingsView()
    }
  }

  /// Tap: the one obvious destination for the current state. The signal table needs a
  /// connection to mean anything; without one, the tap goes straight to connecting.
  private func handlePrimaryAction() {
    if appState.connectionState.isConnected {
      showingSignalDetail = true
    } else {
      showingDeviceSelection = true
    }
  }

  // MARK: - Label

  /// The control's face. Branches only *inside* the always-mounted label, varying content by
  /// value; the toolbar item itself never comes or goes.
  @ViewBuilder
  private var labelContent: some View {
    if showsSignalCluster, let best = signals.best {
      HStack(spacing: 3) {
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
    } else if showsSignalCluster {
      HStack(spacing: 3) {
        scanningGlyph
        powerLabel
        watchBadge
      }
    } else {
      StatusIcon(iconName: iconName, iconColor: iconColor, isAnimating: isAnimating)
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
          showingAdvancedSettings = true
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
