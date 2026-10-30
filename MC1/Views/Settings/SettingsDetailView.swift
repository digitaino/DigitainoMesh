import SwiftUI

/// Renders the destination for a `SettingsDetail`. Used as the split detail
/// root by `SettingsView`.
struct SettingsDetailView: View {
  let detail: SettingsDetail
  let descendantPath: [SettingsSubpage]
  let requestNameEdit: SettingsEditorPresentation.NameRequest
  let requestRegionAdd: SettingsEditorPresentation.RegionRequest
  let backupPresentation: SettingsBackupPresentation?

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
      DeviceInfoView(requestNameEdit: requestNameEdit)
    case .radio:
      RadioSettingsView()
    case .location:
      LocationSettingsView()
    case .connection:
      ConnectionSettingsView(descendantPath: descendantPath)
    case .advanced:
      AdvancedSettingsView(descendantPath: descendantPath, requestRegionAdd: requestRegionAdd)
    case .notifications:
      NotificationSettingsView()
    case .chats:
      ChatSettingsView()
    case .appearance:
      AppearanceView()
    case .maps:
      MapsSettingsView()
    case .language:
      LanguageSettingsView()
    case .backup:
      if let backupPresentation {
        BackupRestoreView(presentation: backupPresentation)
      }
    case .support:
      SupportDevelopmentView()
    case .feedback:
      FeedbackView()
    case .signalMapperData:
      SignalMapperDataView()
    }
  }
}
