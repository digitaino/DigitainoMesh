import MC1Services
import SwiftUI

/// Whether this radio tracks the repeaters around it.
///
/// The setting is per-device because what it costs depends on the firmware: on Digitaino
/// custom firmware the radio is already measuring its neighbours and the app only mirrors the
/// table, so tracking is free; on stock firmware the app *is* the engine and every refresh is
/// a discover broadcast and a trace probe it transmits. Turning it off is how someone on a
/// congested band, or one with a strict duty cycle, opts out of that airtime.
///
/// Defaults to on: the probe cadence matches what the firmware would run anyway, and the
/// feature is only useful if it is measuring by the time you look at it.
struct SignalBarsSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  @State private var isEnabled = true

  private var deviceID: UUID? {
    appState.connectedDevice?.id
  }

  var body: some View {
    Section {
      Toggle(isOn: $isEnabled) {
        TintedLabel(L10n.Settings.SignalBars.enable, systemImage: "cellularbars")
      }
      .onChange(of: isEnabled) { _, newValue in
        guard let deviceID else { return }
        DevicePreferenceStore().setSignalBarsEnabled(newValue, deviceID: deviceID)
        // Take effect now rather than at the next connect: re-running the wiring starts or
        // tears down the engine, the motion monitor and the toolbar together.
        if let services = appState.services {
          appState.wireSignalBars(services: services)
        }
      }
    } header: {
      Text(L10n.Settings.SignalBars.header)
    } footer: {
      Text(L10n.Settings.SignalBars.footer)
    }
    .themedRowBackground(theme)
    .disabled(deviceID == nil)
    .onAppear { load() }
    .onChange(of: deviceID) { _, _ in load() }
  }

  private func load() {
    guard let deviceID else { return }
    isEnabled = DevicePreferenceStore().isSignalBarsEnabled(deviceID: deviceID)
  }
}
