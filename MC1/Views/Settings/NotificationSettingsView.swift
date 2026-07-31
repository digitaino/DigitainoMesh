import MC1Services
import SwiftUI

struct NotificationSettingsView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  /// Whether the connected radio implements the notification-prefs sync slot. Starts
  /// hidden and appears only once the service has actually talked to the device, so the
  /// row never advertises a capability stock firmware does not have.
  @State private var showsDeviceRules = false

  var body: some View {
    List {
      NotificationSettingsSection()

      if showsDeviceRules {
        Section {
          NavigationLink(value: SettingsSubpage.deviceNotificationRules) {
            TintedLabel(
              L10n.Settings.DeviceNotificationRules.title,
              systemImage: "antenna.radiowaves.left.and.right"
            )
          }
        } footer: {
          Text(L10n.Settings.DeviceNotificationRules.rowFooter)
        }
        .themedRowBackground(theme)
      }
    }
    .themedCanvas(theme)
    .settingsSubpageDestinations()
    .navigationTitle(L10n.Settings.Notifications.header)
    .navigationBarTitleDisplayMode(.inline)
    .task(id: appState.servicesVersion) {
      await refreshDeviceRulesAvailability()
    }
    // The classification is held by an actor, not observed, so a probe that lands while this
    // screen is open never reaches the row. Re-checking on every appearance at least catches
    // a flip that happened behind a pushed subpage.
    .onAppear {
      Task { await refreshDeviceRulesAvailability() }
    }
  }

  private func refreshDeviceRulesAvailability() async {
    guard let services = appState.services, appState.connectionState == .ready else {
      showsDeviceRules = false
      return
    }
    showsDeviceRules = await services.notifSyncService.support == .supported
  }
}
