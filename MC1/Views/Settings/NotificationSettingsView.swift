import SwiftUI

struct NotificationSettingsView: View {
    var body: some View {
        List {
            NotificationSettingsSection()

            // Surface the Wio L1 firmware-side notification rules for inspection
            // and manual resync. Only visible when a device is paired.
            Section {
                NavigationLink {
                    WioNotificationsDiagnosticView()
                } label: {
                    TintedLabel("Wio L1 Pro device rules", systemImage: "antenna.radiowaves.left.and.right")
                }
            } footer: {
                Text("View the per-channel and per-contact notification rules currently stored on your Wio L1 Pro, and force a resync if needed.")
            }
        }
        .navigationTitle(L10n.Settings.Notifications.header)
        .navigationBarTitleDisplayMode(.inline)
    }
}
