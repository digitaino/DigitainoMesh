import MC1Services
import SwiftUI

/// Chat settings section for incoming message routing info display
struct MessagesSettingsSection: View {
  @Environment(\.appTheme) private var theme
  @AppStorage(AppStorageKey.showIncomingPath.rawValue) private var showIncomingPath = false
  @AppStorage(AppStorageKey.showIncomingHopCount.rawValue) private var showIncomingHopCount = false
  @AppStorage(AppStorageKey.showIncomingRegion.rawValue) private var showIncomingRegion = false
  @AppStorage(AppStorageKey.messageTranslationEnabled.rawValue)
  private var messageTranslationEnabled = AppStorageKey.defaultMessageTranslationEnabled

  var body: some View {
    Section {
      Toggle(L10n.Settings.Messages.showIncomingPath, isOn: $showIncomingPath)
      Toggle(L10n.Settings.Messages.showIncomingHopCount, isOn: $showIncomingHopCount)
      Toggle(L10n.Settings.Messages.showIncomingRegion, isOn: $showIncomingRegion)
      Toggle(L10n.Settings.Messages.translation, isOn: $messageTranslationEnabled)
    } header: {
      Text(L10n.Settings.Messages.header)
    } footer: {
      Text(L10n.Settings.Messages.footer)
      Text(L10n.Settings.Messages.translationFooter)
    }
    .themedRowBackground(theme)
  }
}

#Preview {
  Form {
    MessagesSettingsSection()
  }
}
