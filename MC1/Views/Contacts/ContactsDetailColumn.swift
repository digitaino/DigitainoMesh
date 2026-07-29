import MC1Services
import SwiftUI

/// The iPad sidebar's Nodes detail column. It reproduces the regular-width (split) detail
/// branch of `ContactsListView`: Discovery wins when active, otherwise the selected contact,
/// otherwise an empty placeholder. Selection and discovery state are read from
/// `appState.navigation` so this column stays in sync with `ContactsContentColumn`.
struct ContactsDetailColumn: View {
  @Environment(\.appState) private var appState

  /// The detail column is its own navigation stack, so it carries the radio status pair itself —
  /// the content column's toolbar never reaches across the split.
  var body: some View {
    detail
      .radioStatusToolbar()
  }

  @ViewBuilder
  private var detail: some View {
    if appState.navigation.nodesShowingDiscovery {
      DiscoveryView()
    } else if let selectedContact = appState.navigation.selectedContact {
      ContactDetailView(contact: selectedContact)
        .id(selectedContact.id)
    } else {
      ContentUnavailableView(L10n.Contacts.Contacts.List.selectNode, systemImage: "flipphone")
    }
  }
}

#Preview {
  NavigationStack {
    ContactsDetailColumn()
  }
  .environment(\.appState, AppState())
}
