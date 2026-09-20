@testable import MC1
import SwiftUI
import Testing

@Suite("SidebarNavigationLayout")
struct SidebarNavigationLayoutTests {
  /// Point width of an 11-inch iPad in portrait. The narrowest device we promise
  /// three-column tiling for (iPad mini at 744pt intentionally collapses, matching Mail).
  static let iPad11InchPortraitWidth: CGFloat = 834

  /// Point width of an iPad mini in portrait. Intentionally below the tiling breakpoint
  /// so it collapses to the section's hidden shape rather than tiling three columns.
  static let iPadMiniPortraitWidth: CGFloat = 744

  /// Upper bound for an icon-only sidebar width; a full text sidebar would exceed this.
  static let iconSidebarUpperBound: CGFloat = 115

  @Test
  func `Section sidebar is narrow enough that 11-inch portrait tiles all three columns`() {
    #expect(MainSidebarView.sidebarTileableMinWidth <= Self.iPad11InchPortraitWidth)
  }

  @Test
  func `iPad mini portrait intentionally collapses rather than tiling`() {
    #expect(MainSidebarView.sidebarTileableMinWidth > Self.iPadMiniPortraitWidth)
  }

  @Test
  func `Sidebar width is in icon-only range, not a full sidebar`() {
    // Guards the configured constant. That iPadOS actually renders the sidebar this narrow and
    // tiles three columns is validated by manual layout testing on device, not asserted here.
    #expect(MainSidebarView.sidebarColumnWidth <= Self.iconSidebarUpperBound)
  }

  @Test
  func `A sidebar-collapsing tool collapses the sidebar even when the container is wide`() {
    let visibility = MainSidebarView.sidebarVisibility(
      isWide: true,
      toolCollapsesSidebar: true,
      sectionCollapsed: .doubleColumn
    )
    #expect(visibility == .doubleColumn)
  }

  @Test
  func `A wide container tiles the sidebar when no sidebar-collapsing tool is open`() {
    let visibility = MainSidebarView.sidebarVisibility(
      isWide: true,
      toolCollapsesSidebar: false,
      sectionCollapsed: .doubleColumn
    )
    #expect(visibility == .all)
  }

  @Test
  func `A narrow container collapses to the section's hidden shape`() {
    #expect(
      MainSidebarView.sidebarVisibility(
        isWide: false, toolCollapsesSidebar: false, sectionCollapsed: .doubleColumn
      ) == .doubleColumn
    )
    #expect(
      MainSidebarView.sidebarVisibility(
        isWide: false, toolCollapsesSidebar: false, sectionCollapsed: .detailOnly
      ) == .detailOnly
    )
  }

  // MARK: - Tool selection on a tab change

  @Test
  func `Leaving Tools clears the open tool`() {
    #expect(
      MainSidebarView.clearsToolSelection(
        arrivingAt: .chats, selectedTool: .cli, signalMapperRideActive: false
      )
    )
  }

  @Test
  func `Arriving at Tools clears nothing`() {
    #expect(
      !MainSidebarView.clearsToolSelection(
        arrivingAt: .tools, selectedTool: .cli, signalMapperRideActive: false
      )
    )
  }

  /// A ride keeps recording while the rider looks at another tab, so the map has to still be there
  /// when they come back — on a phone in landscape this selection is also what the compact stack
  /// seeds from after the next rotation.
  @Test
  func `Leaving Tools keeps the Signal Mapper while a ride records`() {
    #expect(
      !MainSidebarView.clearsToolSelection(
        arrivingAt: .chats, selectedTool: .signalMapper, signalMapperRideActive: true
      )
    )
  }

  @Test
  func `Leaving Tools clears the Signal Mapper when no ride is open`() {
    #expect(
      MainSidebarView.clearsToolSelection(
        arrivingAt: .chats, selectedTool: .signalMapper, signalMapperRideActive: false
      )
    )
  }

  /// The ride pins the mapper, not the Tools section.
  @Test
  func `Leaving Tools clears another tool even while a ride records`() {
    #expect(
      MainSidebarView.clearsToolSelection(
        arrivingAt: .chats, selectedTool: .tracePath, signalMapperRideActive: true
      )
    )
  }

  @Test
  func `Line of Sight and Trace Path collapse the sidebar; other tools keep it`() {
    #expect(ToolSelection.lineOfSight.prefersCollapsedSidebar)
    #expect(ToolSelection.tracePath.prefersCollapsedSidebar)
    for tool in ToolSelection.allCases where tool != .lineOfSight && tool != .tracePath {
      #expect(!tool.prefersCollapsedSidebar)
    }
  }
}
