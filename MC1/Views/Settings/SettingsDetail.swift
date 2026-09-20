import SwiftUI

/// The set of Settings detail pages reached from the settings list. Shared by the compact
/// `SettingsView` (which pushes each via `NavigationLink(value:)`) and the iPad split columns
/// (`SettingsListContent` list selection + `SettingsDetailView` detail), and persisted as the
/// active selection on `NavigationCoordinator`.
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
    case .notifications, .chats, .appearance, .maps, .backup, .support, .feedback, .signalMapperData:
      false
    }
  }
}
