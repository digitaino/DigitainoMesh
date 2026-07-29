import SwiftUI

/// The radio status control and the repeater signal indicator as one toolbar unit.
///
/// The pair answers a single question — "am I connected, and how well is the mesh hearing me" —
/// so they are always mounted together. Tab roots have surfaced them since the beginning
/// (`ChatsListModifiers`, `ContactsSidebarContent`, `MapView`, `ToolsView`/`ToolsContentColumn`,
/// `SettingsListContent`); this builder exists so *pushed* screens can surface them too. Pushing
/// into a conversation, a node, a tool or a settings subpage used to hide the radio state
/// entirely, which is exactly when a user is most likely to want it.
///
/// The default placement is `.topBarTrailing`, not the roots' `.topBarLeading`: on a pushed
/// screen the leading slot belongs to the back button, and crowding it there would collide with
/// the title. A screen whose trailing slot is spoken for passes its own placement.
///
/// ## Stable identity is load-bearing
/// Never wrap these items in an `if`/`else`, and never include or exclude them at runtime.
/// Both hosted views vary only their *content* when there is nothing to report (see
/// `BLEStatusIndicatorView` and `RepeaterSignalIndicatorView`); removing the `ToolbarItem`
/// itself would hand SwiftUI a new identity and trip the iOS 26 hosted-toolbar graph
/// re-entrancy crash those two files document. Mount them statically and let them collapse.
@MainActor
@ToolbarContentBuilder
func radioStatusToolbarItems(placement: ToolbarItemPlacement = .topBarTrailing) -> some ToolbarContent {
  bleStatusToolbarItem(placement: placement)
  repeaterSignalToolbarItem(placement: placement)
}

extension View {
  /// Mounts `radioStatusToolbarItems(placement:)` on this screen.
  ///
  /// Applied at section navigation chokepoints — the `navigationDestination` builders and the
  /// shared destination views (`SettingsDetailView`, `ToolDestinationView`) — so every pushed
  /// screen in a section inherits the pair without each leaf view opting in. Roots are never
  /// pushed, so a chokepoint can never double-mount over a root's own pair.
  @MainActor
  func radioStatusToolbar(placement: ToolbarItemPlacement = .topBarTrailing) -> some View {
    toolbar { radioStatusToolbarItems(placement: placement) }
  }
}
