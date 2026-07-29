import SwiftUI

/// Renders the destination for a `SettingsDetail`. Single source of truth for the settings detail
/// pages, used by the compact `SettingsView` (`navigationDestination`) and the iPad split's detail
/// column (`MainSidebarView`).
struct SettingsDetailView: View {
  @Environment(\.appState) private var appState
  let detail: SettingsDetail

  /// The radio status pair is mounted here rather than on `SettingsView`'s
  /// `navigationDestination` so it reaches both hosts from one place: the compact push and the
  /// iPad detail column both land on this view.
  var body: some View {
    page
      .radioStatusToolbar()
  }

  @ViewBuilder
  private var page: some View {
    switch detail {
    case .deviceInfo:
      DeviceInfoView()
    case .radio:
      RadioSettingsView()
    case .location:
      LocationSettingsView()
    case .connection:
      ConnectionSettingsView()
    case .advanced:
      AdvancedSettingsView()
    case .notifications:
      NotificationSettingsView()
    case .chats:
      ChatSettingsView()
    case .appearance:
      AppearanceView()
    case .maps:
      MapsSettingsView()
    case .backup:
      BackupRestoreView(
        connectionManager: appState.connectionManager,
        onImportRestoredData: { [appState] in appState.notifyDataRestored() },
        onChannelDraftSlotsAffected: { [appState] slotsByRadio in
          appState.draftStore.clearChannelDrafts(slotsByRadio: slotsByRadio)
        }
      )
    case .support:
      SupportDevelopmentView()
    case .feedback:
      FeedbackView()
    }
  }
}
