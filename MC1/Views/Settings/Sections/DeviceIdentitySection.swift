import MC1Services
import SwiftUI

/// Section for managing the device's cryptographic identity
struct DeviceIdentitySection: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Binding var showingImportKeySheet: Bool
  @Binding var showingRegenerateSheet: Bool

  /// Whether this iPhone keeps node keys, so a new radio can be set up as the node
  /// (`IdentityKeyVault`, docs/RADIO_SWAP.md R5). Off forgets every saved key and stops
  /// saving them; a per-node forget would not stick, since each connect saves the key again.
  @AppStorage(AppStorageKey.keepNodeKeysOnPhone.rawValue)
  private var keepNodeKeys = AppStorageKey.defaultKeepNodeKeysOnPhone

  var body: some View {
    Section {
      Button {
        showingImportKeySheet = true
      } label: {
        Label(L10n.Settings.ImportKey.title, systemImage: "square.and.arrow.down")
      }
      .radioDisabled(for: appState.connectionState)

      Button {
        showingRegenerateSheet = true
      } label: {
        Label(L10n.Settings.RegenerateIdentity.title, systemImage: "arrow.triangle.2.circlepath")
      }
      .radioDisabled(for: appState.connectionState)

      Toggle(L10n.Settings.NodeKeys.keep, isOn: $keepNodeKeys)
        .onChange(of: keepNodeKeys) { _, keep in
          guard !keep else { return }
          Task { try? await IdentityKeyVault.shared.forgetAll() }
        }
    } header: {
      Text(L10n.Settings.RegenerateIdentity.header)
    } footer: {
      Text(L10n.Settings.NodeKeys.footer)
    }
    .themedRowBackground(theme)
  }
}
