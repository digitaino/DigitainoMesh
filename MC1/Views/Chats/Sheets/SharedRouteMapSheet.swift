import Foundation
import MC1Services
import SwiftUI

/// Presentation identity for the shared-route path map, carried from the
/// tapped card to `.sheet(item:)`. Bundles the radio ID because hop
/// resolution needs the tapped message's radio, not whichever device is
/// currently selected.
struct SharedRouteMapContext: Identifiable {
  let route: SharedRoute
  let radioID: UUID

  var id: String { route.id }
}

/// Hosts `MessagePathMapView` for a route embedded in a message's text, and
/// owns the path view model the map resolves hops against. The actions-sheet
/// path map gets its view model preloaded by `MessageActionsSheet`; the card
/// tap arrives with nothing loaded, so this wrapper does the load itself.
struct SharedRouteMapSheet: View {
  let context: SharedRouteMapContext

  @Environment(\.appState) private var appState
  @State private var pathViewModel = MessagePathViewModel()

  var body: some View {
    MessagePathMapView(source: .sharedRoute(context.route), pathViewModel: pathViewModel)
      .task {
        await pathViewModel.loadContacts(
          dataStore: appState.offlineDataStore,
          radioID: context.radioID
        )
      }
  }
}
