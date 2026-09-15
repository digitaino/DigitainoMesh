import SwiftUI

/// The set of diagnostic tools. Shared by the compact `ToolsView` (which pushes each as a
/// `NavigationLink`) and the iPad split columns (`ToolsContentColumn` list selection +
/// `ToolsDetailColumn` detail), and persisted as the active selection on `NavigationCoordinator`.
enum ToolSelection: Hashable, CaseIterable {
  case tracePath
  case repeaterBenchmark
  case lineOfSight
  case rxLog
  case trafficHeatmap
  case signalMapper
  case weather
  case noiseFloor
  case nodeDiscovery
  case cli

  var title: String {
    switch self {
    case .tracePath: L10n.Tools.Tools.tracePath
    case .repeaterBenchmark: L10n.Tools.Tools.benchmark
    case .lineOfSight: L10n.Tools.Tools.lineOfSight
    case .rxLog: L10n.Tools.Tools.rxLog
    case .trafficHeatmap: L10n.Tools.Tools.trafficMap
    case .signalMapper: L10n.Tools.Tools.signalMapper
    case .weather: L10n.Weather.Weather.title
    case .noiseFloor: L10n.Tools.Tools.noiseFloor
    case .nodeDiscovery: L10n.Tools.Tools.nodeDiscovery
    case .cli: L10n.Tools.Tools.cli
    }
  }

  var systemImage: String {
    switch self {
    case .tracePath: "point.3.connected.trianglepath.dotted"
    case .repeaterBenchmark: "chart.bar.xaxis"
    case .lineOfSight: "eye"
    case .rxLog: "waveform.badge.magnifyingglass"
    case .trafficHeatmap: "point.3.filled.connected.trianglepath.dotted"
    case .signalMapper: "hexagon.righthalf.filled"
    case .weather: "cloud.sun.bolt"
    case .noiseFloor: "waveform"
    case .nodeDiscovery: "dot.radiowaves.left.and.right"
    case .cli: "terminal"
    }
  }

  /// Line of Sight runs its analysis offline; the Signal Mapper reads coverage that was
  /// captured on earlier walks — cells belong to places, not to whichever radio was paired at
  /// the time; and Weather shows the last picture the bot sent, which is kept on disk and is
  /// exactly what a phone out of range of its radio still wants to see. Only *asking* the bot
  /// needs a radio, and that tool disables its own request buttons. Every other tool needs a
  /// connected radio.
  var requiresRadio: Bool {
    self != .lineOfSight && self != .signalMapper && self != .weather
  }

  /// Tools that collapse the iPad section's sidebar when open, reclaiming its width. Line of Sight
  /// swaps the content column for its analysis panel beside the detail map; Trace Path keeps the tool
  /// list in the content column and gives its own list/map view the freed width in the detail column.
  /// Other tools keep the sidebar's normal width-driven behavior.
  var prefersCollapsedSidebar: Bool {
    self == .lineOfSight || self == .tracePath
  }
}
