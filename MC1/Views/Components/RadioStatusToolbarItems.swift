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
///
/// `isHidden` is how a screen takes the pill off its own navigation bar without breaking
/// that rule: the item stays declared and the control stays mounted, so nothing about its
/// identity — or about a popover already anchored to it — changes. It is a value, like every
/// other state this control renders.
@MainActor
@ToolbarContentBuilder
func radioStatusToolbarItems(
  placement: ToolbarItemPlacement = .topBarTrailing,
  isHidden: Bool = false
) -> some ToolbarContent {
  ToolbarItem(placement: placement) {
    RadioStatusControl()
      // Zero width as well as zero opacity: an invisible 44 pt gap between the title and
      // the screen's own buttons reads as a layout bug rather than as nothing.
      .frame(width: isHidden ? 0 : nil)
      .opacity(isHidden ? 0 : 1)
      // A hidden pill must not be tappable. Its label collapsing to a stub is precisely the
      // shape that produced "the pill is dead" (dee5cb65), and an invisible one would be
      // that defect with no way to see it.
      .allowsHitTesting(!isHidden)
      .accessibilityHidden(isHidden)
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
  func radioStatusToolbar(
    placement: ToolbarItemPlacement = .topBarTrailing,
    isHidden: Bool = false
  ) -> some View {
    toolbar { radioStatusToolbarItems(placement: placement, isHidden: isHidden) }
  }
}
