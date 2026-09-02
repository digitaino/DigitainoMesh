import MC1Services
import SwiftUI

/// Settings section for the Packet Scope opt-in: per-message observer coverage
/// looked up from a CoreScope instance.
///
/// Master toggle defaults **off** and the footer says exactly what enabling it
/// sends — the same privacy-gated-outbound-network pattern as link previews. The
/// server field appears only once the feature is on: coverage is per-instance
/// and regional, so users on another mesh point at their own CoreScope.
struct PacketScopeSettingsSection: View {
  @Environment(\.appTheme) private var theme
  @AppStorage(AppStorageKey.packetScopeEnabled.rawValue)
  private var isEnabled = AppStorageKey.defaultPacketScopeEnabled
  @AppStorage(AppStorageKey.packetScopeBaseURL.rawValue)
  private var baseURL = AppStorageKey.defaultPacketScopeBaseURL

  var body: some View {
    Section {
      Toggle(isOn: $isEnabled) {
        TintedLabel(L10n.Settings.PacketScope.toggle, systemImage: "dot.radiowaves.up.forward")
      }

      if isEnabled {
        HStack {
          Text(L10n.Settings.PacketScope.server)
          TextField(
            AppStorageKey.defaultPacketScopeBaseURL,
            text: $baseURL
          )
          .keyboardType(.URL)
          .textContentType(.URL)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .multilineTextAlignment(.trailing)
          .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text(L10n.Settings.PacketScope.header)
    } footer: {
      Text(L10n.Settings.PacketScope.footer)
    }
    .themedRowBackground(theme)
  }
}

#Preview {
  Form {
    PacketScopeSettingsSection()
  }
}
