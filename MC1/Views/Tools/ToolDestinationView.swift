import SwiftUI

/// Maps a `ToolSelection` to its tool view. Single source of truth for the radio tools, shared
/// by the compact `ToolsView` (stack) and the iPad `ToolsDetailColumn` (split). Line of Sight differs
/// between the two — the compact stack shows the combined map-with-sheet layout from a fresh view
/// model, while the split shows only the map driven by the shared one — so its view is injected.
struct ToolDestinationView<LineOfSight: View>: View {
  let tool: ToolSelection
  @ViewBuilder let lineOfSight: () -> LineOfSight

  @Environment(\.appState) private var appState

  /// Like `SettingsDetailView`, the radio status pair is mounted on the shared destination view
  /// rather than on `ToolsView`'s `navigationDestination`, so the compact push and the iPad
  /// detail column both pick it up from one place.
  var body: some View {
    destination
      .radioStatusToolbar(isHidden: hidesRadioStatus)
  }

  /// The signal mapper answers the pill's question better than the pill does while a ride is
  /// running: the best link's two SNRs are per-cell facts on the map's own card, and the pill
  /// beside them is the same numbers for somewhere the rider may no longer be (Rafael,
  /// 2026-09-04). Scoped to this screen and to the run — every other screen, and this one the
  /// moment the ride ends, keeps the pill and the connection route it carries.
  private var hidesRadioStatus: Bool {
    tool == .signalMapper && appState.signalMapperRideSession != nil
  }

  @ViewBuilder
  private var destination: some View {
    switch tool {
    case .tracePath: TracePathView()
    case .repeaterBenchmark: RepeaterBenchmarkView()
    case .lineOfSight: lineOfSight()
    case .rxLog: RxLogView()
    case .trafficHeatmap: TrafficHeatmapView()
    case .signalMapper: SignalMapperCoverageView()
    case .weather: WeatherToolView()
    case .noiseFloor: NoiseFloorView()
    case .nodeDiscovery: NodeDiscoveryView()
    case .cli: CLIToolView()
    }
  }
}
