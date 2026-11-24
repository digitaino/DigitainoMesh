import SwiftUI

extension View {
  /// Hides the tab bar while it sits at the bottom, where it competes with a screen's own bottom
  /// toolbar. The iPad's top tab bar stays: it is navigation, and hiding it strands the screen.
  /// Same rule as `SectionSplitPresentation.tabBarVisibility`.
  func hidingBottomTabBar(_ hidden: Bool = true) -> some View {
    modifier(BottomTabBarHiding(hidden: hidden))
  }
}

private struct BottomTabBarHiding: ViewModifier {
  @Environment(\.tabBarPlacement) private var tabBarPlacement
  @Environment(\.horizontalSizeClass) private var sizeClass
  let hidden: Bool

  func body(content: Content) -> some View {
    let atBottom = tabBarPlacement == .bottomBar || sizeClass == .compact
    content.toolbar(hidden && atBottom ? .hidden : .automatic, for: .tabBar)
  }
}
