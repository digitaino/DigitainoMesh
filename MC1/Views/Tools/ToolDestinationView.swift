import SwiftUI

/// Maps a `ToolSelection` to its tool view. Single source of truth for the radio tools, shared
/// by the compact `ToolsView` (stack) and the iPad `ToolsDetailColumn` (split). Line of Sight differs
/// between the two — the compact stack shows the combined map-with-sheet layout from a fresh view
/// model, while the split shows only the map driven by the shared one — so its view is injected.
struct ToolDestinationView<LineOfSight: View>: View {
  let tool: ToolSelection
  @ViewBuilder let lineOfSight: () -> LineOfSight

  /// Like `SettingsDetailView`, the radio status pair is mounted on the shared destination view
  /// rather than on `ToolsView`'s `navigationDestination`, so the compact push and the iPad
  /// detail column both pick it up from one place.
  var body: some View {
    destination
      .radioStatusToolbar()
  }

  @ViewBuilder
  private var destination: some View {
    switch tool {
    case .tracePath: TracePathView()
    case .repeaterBenchmark: RepeaterBenchmarkView()
    case .lineOfSight: lineOfSight()
    case .rxLog: RxLogView()
    case .trafficHeatmap: TrafficHeatmapView()
    case .noiseFloor: NoiseFloorView()
    case .nodeDiscovery: NodeDiscoveryView()
    case .cli: CLIToolView()
    }
  }
}
