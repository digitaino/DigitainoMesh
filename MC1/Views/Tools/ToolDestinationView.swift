import SwiftUI

/// Maps a `ToolSelection` to its tool view: the single source of truth for the tools.
struct ToolDestinationView: View {
  let tool: ToolSelection

  @Environment(\.appState) private var appState

  /// Like `SettingsDetailView`, the radio status pair is mounted on the shared destination view
  /// rather than on `ToolsView`'s `navigationDestination`, so every tool picks it up from one place.
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
    case .lineOfSight: LineOfSightView()
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
