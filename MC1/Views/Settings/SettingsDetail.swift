import SwiftUI

/// Settings pages reached from the settings list. `SettingsListContent` writes
/// the selection; `SettingsDetailView` renders it in the split detail.
enum SettingsDetail: Hashable {
  case deviceInfo
  case radio
  case location
  case connection
  case advanced
  case notifications
  case chats
  case appearance
  case maps
  case language
  case backup
  case support
  case feedback
  case signalMapperData

  /// The My Device rows only exist while a radio is connected; clearing their selection on
  /// disconnect or a radio switch keeps the detail pane from stranding a now-gone device page.
  var requiresDevice: Bool {
    switch self {
    case .deviceInfo, .radio, .location, .connection, .advanced:
      true
    // The observation table outlives every radio — it is 90 days of what *this phone* heard,
    // and a rider who unpairs a radio must still be able to export and delete it.
    case .notifications, .chats, .appearance, .maps, .language, .backup, .support, .feedback, .signalMapperData:
      false
    }
  }
}
