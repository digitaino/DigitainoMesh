import Foundation
import MeshWX

/// One station's newest reading across every bot, placed against the place.
public struct WeatherStationReading: Sendable, Hashable, Identifiable {
  public var index: UInt16
  public var station: MeshWXStation
  public var stored: WeatherStoredObservation
  public var botID: UInt16
  public var distanceKilometres: Double?
  /// From the place towards the station.
  public var direction: MeshWXCompass?
  public var isStale: Bool
  /// Part of a bot's scheduled batch, rather than an answer to somebody's one-station request.
  public var isInFootprint: Bool

  public var id: UInt16 { index }
}

public enum WeatherStations {
  /// Newest reading per station, nearest to the place first (footprint before one-off answers
  /// when there is no place).
  public static func readings(
    states: [UInt16: WeatherBotState],
    coverage: WeatherCoverage,
    place: WeatherPlace?,
    tables: MeshWXTables,
    now: Date
  ) -> [WeatherStationReading] {
    var newest: [UInt16: (stored: WeatherStoredObservation, botID: UInt16)] = [:]
    for (botID, state) in states {
      for (index, stored) in state.observations {
        if let held = newest[index], held.stored.timestampMinutes >= stored.timestampMinutes { continue }
        newest[index] = (stored, botID)
      }
    }
    let footprint = Set(coverage.stations.map(\.index))
    let readings: [WeatherStationReading] = newest.compactMap { index, entry in
      guard let station = tables.station(at: index) else { return nil }
      let coordinate = MeshWXCoordinate(latitude: station.lat, longitude: station.lon)
      return WeatherStationReading(
        index: index,
        station: station,
        stored: entry.stored,
        botID: entry.botID,
        distanceKilometres: place.map { WeatherGeo.kilometres($0.coordinate, coordinate) },
        direction: place.map { WeatherGeo.direction(from: $0.coordinate, to: coordinate) },
        isStale: entry.stored.isStale(at: now),
        isInFootprint: footprint.contains(index)
      )
    }
    return readings.sorted { lhs, rhs in
      switch (lhs.distanceKilometres, rhs.distanceKilometres) {
      case let (l?, r?) where l != r: return l < r
      default:
        if lhs.isInFootprint != rhs.isInFootprint { return lhs.isInFootprint }
        return lhs.station.icao < rhs.station.icao
      }
    }
  }
}

/// The reading the Now card leads with (docs/MESHWX_UI.md §8).
public enum WeatherPrimaryStation: Sendable, Hashable {
  case reading(WeatherStationReading)
  /// Nothing within reach; the nearest is named with its distance instead.
  case noneNearby(nearest: WeatherStationReading)
  case noObservations
  case noPlace

  public static let maxDistanceKilometres = 80.0

  /// Fresh with a temperature, then fresh, then stale with a temperature, then stale — each
  /// the nearest within 80 km. All fields come from the one station chosen.
  public static func pick(readings: [WeatherStationReading], place: WeatherPlace?) -> WeatherPrimaryStation {
    guard !readings.isEmpty else { return .noObservations }
    guard place != nil else { return .noPlace }
    let inReach = readings.filter { ($0.distanceKilometres ?? .infinity) <= maxDistanceKilometres }
    let choice = inReach.first { !$0.isStale && $0.stored.observation.tempF != nil }
      ?? inReach.first { !$0.isStale }
      ?? inReach.first { $0.stored.observation.tempF != nil }
      ?? inReach.first
    if let choice { return .reading(choice) }
    return .noneNearby(nearest: readings[0])
  }
}
