import MC1Services
import Observation
import SwiftUI

/// What a tapped alert notification does to the app (docs/MESHWX_UI.md §16).
///
/// Installed once at launch: the notification delegate is per connection and the Weather tool's
/// model lives for one visit, so neither of them can be what a tap lands on.
/// `WeatherAlertNotificationTap` holds what was tapped; this turns it into navigation, and the
/// tool takes the alert itself when it next appears.
///
/// **What it can do.** Selecting the Tools tab and naming Weather as the open tool is enough on
/// iPad, whose Tools columns render from `NavigationCoordinator.selectedTool`. On iPhone the
/// compact `ToolsView` seeds its stack from that selection once and is deliberately one-way
/// afterwards, so a tap lands on the Tools list and the alert opens as soon as Weather is
/// opened. A route that pushed it would need a `pendingTool` on `NavigationCoordinator`, the way
/// `pendingChatContact` works, and `ToolsView` observing it to append to its path — one property
/// and one `onChange`, in two files this change does not own.
@MainActor
enum WeatherAlertNotificationRouting {
  private static var isInstalled = false

  /// Installs the localized notification copy and starts watching for taps. Safe to call again:
  /// the launch task runs on every appearance of the scene's content.
  static func install(appState: AppState) {
    WeatherAlertNotificationCopyRegistry.install(WeatherAlertNotificationCopyImpl())
    guard !isInstalled else { return }
    isInstalled = true
    observe(appState)
  }

  /// Re-arms itself after every change: `withObservationTracking` fires once.
  private static func observe(_ appState: AppState) {
    withObservationTracking {
      _ = WeatherAlertNotificationTap.shared.pending
    } onChange: {
      // The change has not landed yet when this runs, so the value is read on the next turn.
      Task { @MainActor [weak appState] in
        guard let appState else { return }
        if WeatherAlertNotificationTap.shared.pending != nil { open(appState) }
        observe(appState)
      }
    }
  }

  /// Opens the Weather tool, leaving the tapped alert where the tool will find it.
  private static func open(_ appState: AppState) {
    appState.navigation.selectedTool = .weather
    appState.navigation.selectedTab = AppTab.tools.rawValue
  }
}
