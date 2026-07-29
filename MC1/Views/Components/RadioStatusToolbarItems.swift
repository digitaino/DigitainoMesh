import SwiftUI

/// The radio status control as a toolbar item — the single mount point every screen shares.
///
/// One item, one glass capsule: `RadioStatusControl` folds the former antenna + signal pair
/// into a single compact control (see its docs for the tap/press split). Tab roots mount it at
/// `.topBarLeading`; the default here is `.topBarTrailing` because on a pushed screen the
/// leading slot belongs to the back button, and crowding it there would collide with the
/// title. A screen whose trailing slot is spoken for passes its own placement.
///
/// ## Stable identity is load-bearing
/// Never wrap the item in an `if`/`else`, and never include or exclude it at runtime. The
/// control varies only its *content* by state; removing the `ToolbarItem` itself would hand
/// SwiftUI a new identity and trip the iOS 26 hosted-toolbar graph re-entrancy crash
/// `RadioStatusControl` documents. Mount it statically and let it adapt.
@MainActor
@ToolbarContentBuilder
func radioStatusToolbarItems(placement: ToolbarItemPlacement = .topBarTrailing) -> some ToolbarContent {
  ToolbarItem(placement: placement) {
    RadioStatusControl()
  }
}

extension View {
  /// Mounts `radioStatusToolbarItems(placement:)` on this screen.
  ///
  /// Applied at section navigation chokepoints — the `navigationDestination` builders and the
  /// shared destination views (`SettingsDetailView`, `ToolDestinationView`) — so every pushed
  /// screen in a section inherits the control without each leaf view opting in. Roots are
  /// never pushed, so a chokepoint can never double-mount over a root's own item.
  @MainActor
  func radioStatusToolbar(placement: ToolbarItemPlacement = .topBarTrailing) -> some View {
    toolbar { radioStatusToolbarItems(placement: placement) }
  }
}
