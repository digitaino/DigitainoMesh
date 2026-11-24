import SwiftUI

/// Tools tab: a stack that mirrors `NavigationCoordinator.selectedTool`, so the open tool
/// survives tab switches and view rebuilds. Back writes an empty path.
struct ToolsView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  /// This stack's own path. It follows `selectedTool` whenever something names a tool (a weather
  /// alert tap, the seed of a rebuilt stack) and writes every push and pop back to it, but it
  /// ignores a *clear* from outside.
  ///
  /// That one exception is deliberate. `clearPerDeviceSelection` runs on the disconnect tick,
  /// exactly when `RadioStatusControl` dismisses its popover on `connectedDevice == nil`. A stack
  /// bound straight to the selection would pop the open radio tool, whose toolbar hosts that
  /// popover, inside its own dismissal: the iOS 26 zoom-morph trap behind TestFlight crash
  /// B8A782EC, worst at compact width, where every popover here forces
  /// `presentationCompactAdaptation(.popover)`. So a disconnect leaves the open tool on screen,
  /// as builds before the fix did, and the user leaves it with Back.
  @State private var path: [ToolSelection] = []

  /// Whether the seed has already run. `onAppear` fires again every time the Tools tab is
  /// re-selected, and re-seeding there would re-push a tool the user had popped.
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
        ToolDestinationView(tool: tool)
      }
      .themedCanvas(theme)
      .navigationTitle(L10n.Tools.Tools.title)
      .toolbar {
        radioStatusToolbarItems(placement: .topBarLeading)
      }
    }
    .onAppear { seedPathOnce() }
    .onChange(of: path) { _, newPath in
      // Every push and pop reaches the selection: it is what the next rebuild of this stack
      // seeds from, and what keeps the open tool across tab switches.
      appState.navigation.selectedTool = Self.selection(for: newPath)
    }
    .onChange(of: appState.navigation.selectedTool) { _, tool in
      // Follow a tool named from outside; ignore a clear (see `path`).
      guard let tool, Self.selection(for: path) != tool else { return }
      path = Self.initialPath(for: tool)
    }
  }

  /// Restores the tool this stack showed before it was rebuilt, once per view lifetime.
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
