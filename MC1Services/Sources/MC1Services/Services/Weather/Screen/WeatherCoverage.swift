import Foundation
import MeshWX

/// The area a bot demonstrably reports on: the stations in its scheduled observation batches
/// (docs/MESHWX_UI.md §6).
///
/// A batch of one station is the answer to somebody's single-station request — a `>o KJFK`
/// would otherwise put Manhattan "in coverage" — so only multi-station batches count, and only
/// from the last 24 hours on the bot's clock.
public struct WeatherCoverage: Sendable, Hashable {
  public struct Station: Sendable, Hashable {
    public var index: UInt16
    public var station: MeshWXStation
    public var botID: UInt16

    public var coordinate: MeshWXCoordinate {
      MeshWXCoordinate(latitude: station.lat, longitude: station.lon)
    }
  }

  public var stations: [Station]

  public static let footprintWindow: TimeInterval = 24 * 60 * 60
  /// A place with a footprint station this close is inside coverage.
  public static let radiusKilometres = 80.0

  public init(stations: [Station]) {
    self.stations = stations
  }

  public static func make(states: [UInt16: WeatherBotState], tables: MeshWXTables, now: Date) -> WeatherCoverage {
    var byIndex: [UInt16: Station] = [:]
    for (botID, state) in states {
      for (index, stored) in state.observations
      where stored.batchSize > 1 && now.timeIntervalSince(stored.observedAt) <= footprintWindow {
        guard let station = tables.station(at: index) else { continue }
        byIndex[index] = Station(index: index, station: station, botID: botID)
      }
    }
    return WeatherCoverage(stations: byIndex.values.sorted { $0.index < $1.index })
  }

  public var isEmpty: Bool { stations.isEmpty }

  public func nearest(to point: MeshWXCoordinate) -> (station: Station, kilometres: Double)? {
    stations
      .map { ($0, WeatherGeo.kilometres(point, $0.coordinate)) }
      .min { $0.1 < $1.1 }
  }

  public func contains(_ point: MeshWXCoordinate) -> Bool {
    guard let nearest = nearest(to: point) else { return false }
    return nearest.kilometres <= Self.radiusKilometres
  }

  /// The bots with a footprint station near a point.
  public func botIDs(covering point: MeshWXCoordinate) -> Set<UInt16> {
    Set(stations.filter { WeatherGeo.kilometres(point, $0.coordinate) <= Self.radiusKilometres }.map(\.botID))
  }
}
