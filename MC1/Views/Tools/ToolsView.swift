import SwiftUI

/// The compact (iPhone / compact-width) Tools tab: a stack that pushes each tool. The iPad
/// regular-width layout routes Tools through `MainSidebarView`'s split (`ToolsContentColumn` +
/// `ToolsDetailColumn`) instead, so this view is only reached in compact width.
struct ToolsView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  /// This stack's own path. It is seeded once from the hoisted `selectedTool` and written back to
  /// it on every change, but nothing drives it from that selection afterwards — the flow is one
  /// way, out of this stack.
  ///
  /// Seeding is the rotation fix: an iPhone whose landscape width class is regular swaps the whole
  /// shell when it turns (`ContentView` builds `MainSidebarView` instead of `MainTabView`), which
  /// tears this view down. The old implicit path meant the rebuilt stack came back at the tool
  /// list, so an open Signal Mapper exited on the way out and was still gone on the way back; a
  /// stack that seeds itself from the tool the other shell was showing comes back on the tool, in
  /// both directions.
  ///
  /// The one-way rule is deliberate. Binding the stack directly to `selectedTool` would also let
  /// every *clear* of that selection pop this stack — and `clearPerDeviceSelection` runs on the
  /// disconnect tick, exactly when `RadioStatusControl` dismisses its popover on
  /// `connectedDevice == nil`. Tearing a popover's host down inside its own dismissal is the
  /// iOS 26 zoom-morph trap behind TestFlight crash B8A782EC, and compact width is its worst case
  /// because every popover here forces `presentationCompactAdaptation(.popover)`. Ignoring
  /// external clears keeps this stack exactly where the pre-fix build left it. The cost is one
  /// edge case: disconnect the radio and *then* rotate, and the rebuilt stack seeds from a
  /// selection that was cleared meanwhile, so it lands on the tool list.
  @State private var path: [ToolSelection] = []

  /// Whether the seed has already run. `onAppear` fires again every time the Tools tab is
  /// re-selected, and re-seeding there would apply an external clear the stack is meant to ignore
  /// — and would re-push a tool the user had popped.
  @State private var hasSeeded = false

  var body: some View {
    NavigationStack(path: $path) {
      List {
        ForEach(ToolSelection.allCases, id: \.self) { tool in
          NavigationLink(value: tool) {
            Label(tool.title, systemImage: tool.systemImage)
          }
        }
        .themedRowBackground(theme)
      }
      .navigationDestination(for: ToolSelection.self) { tool in
        ToolDestinationView(tool: tool) { LineOfSightView() }
      }
      .themedCanvas(theme)
      .navigationTitle(L10n.Tools.Tools.title)
      .toolbar {
        radioStatusToolbarItems(placement: .topBarLeading)
      }
    }
    .onAppear { seedPathOnce() }
    .onChange(of: path) { _, newPath in
      // The regular shell renders its Tools columns from `selectedTool`, so every push and pop
      // here has to reach it: this write is what the split view — and the next rebuild of this
      // stack — reads after a rotation.
      appState.navigation.selectedTool = Self.selection(for: newPath)
    }
  }

  /// Restores the tool the other shell was showing, once per view lifetime.
  private func seedPathOnce() {
    guard !hasSeeded else { return }
    hasSeeded = true
    let seeded = Self.initialPath(for: appState.navigation.selectedTool)
    guard !seeded.isEmpty else { return }
    // Unanimated: this stack is being rebuilt to stand in for the one rotation just destroyed, so
    // an animated push would read as the app opening a screen by itself a beat after the turn.
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { path = seeded }
  }

  /// The stack a freshly built compact Tools tab starts with, for a given hoisted selection. One
  /// level deep: tools never push another tool.
  static func initialPath(for tool: ToolSelection?) -> [ToolSelection] {
    tool.map { [$0] } ?? []
  }

  /// The selection a given stack writes back — the tool actually on screen, which is the top of
  /// the path rather than its first entry.
  static func selection(for path: [ToolSelection]) -> ToolSelection? {
    path.last
  }
}

#Preview {
  ToolsView()
    .environment(\.appState, AppState())
}
