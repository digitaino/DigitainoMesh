@testable import MC1
import Testing

/// The compact Tools stack's two halves: the seed that restores an open tool after the shell swap
/// an iPhone rotation performs, and the write-back that tells the regular shell which tool is open.
/// The flow is one way by design — nothing here reads the hoisted selection back into a live stack,
/// so an external clear (a disconnect) cannot pop the compact stack while a popover is dismissing
/// on the same tick. See `ToolsView.path` for the crash class that rules out.
@Suite("ToolsView Compact Path")
@MainActor
struct ToolsViewPathTests {
  // MARK: - Seed

  @Test
  func `no open tool seeds an empty stack`() {
    #expect(ToolsView.initialPath(for: nil).isEmpty)
  }

  @Test
  func `an open tool seeds a stack already showing it`() {
    #expect(ToolsView.initialPath(for: .signalMapper) == [.signalMapper])
  }

  @Test
  func `every tool seeds one level deep`() {
    for tool in ToolSelection.allCases {
      #expect(ToolsView.initialPath(for: tool) == [tool])
    }
  }

  // MARK: - Write-back

  @Test
  func `an empty stack writes back no selection`() {
    #expect(ToolsView.selection(for: []) == nil)
  }

  @Test
  func `a pushed tool writes itself back`() {
    #expect(ToolsView.selection(for: [.signalMapper]) == .signalMapper)
  }

  /// Tools never push another tool, so a deeper stack is not a state this view can reach — but if a
  /// destination ever did push one, the tool on screen is the top of the stack, not its root.
  @Test
  func `a deeper stack writes back the tool on top`() {
    #expect(ToolsView.selection(for: [.cli, .rxLog]) == .rxLog)
  }

  // MARK: - Rotation

  /// The defect, end to end: a stack showing a tool writes that tool out, and the stack rotation
  /// rebuilds seeds from it comes back showing the same tool. Both halves have to agree for the
  /// Signal Mapper to survive a turn of the phone in either direction.
  @Test
  func `what a stack writes back is what the rebuilt stack seeds from`() {
    for tool in ToolSelection.allCases {
      let written = ToolsView.selection(for: [tool])
      #expect(ToolsView.initialPath(for: written) == [tool])
    }
  }

  @Test
  func `a popped stack writes back nothing and rebuilds at the tool list`() {
    let written = ToolsView.selection(for: [])
    #expect(ToolsView.initialPath(for: written).isEmpty)
  }
}
