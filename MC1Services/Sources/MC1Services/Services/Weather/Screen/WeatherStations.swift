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
  /// The station has been in one of a bot's scheduled batches in the last day: it is in that
  /// bot's area, whoever's request delivered the reading held now.
  public var isInFootprint: Bool
  /// The station is in the newest scheduled batch its bot has sent, so a bare `>o` would come
  /// back carrying it. One the bot has since dropped from its batch stays in the footprint for a
  /// day but can only be refreshed by `>o <ICAO>` (docs/MESHWX_UI.md §8, §11).
  public var isInLatestBatch: Bool

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
    // The newest scheduled batch each bot has sent: what a bare `>o` to that bot would answer with.
    var latestBatch: [UInt16: UInt32] = [:]
    for (botID, state) in states {
      for (index, stored) in state.observations {
        if let minutes = stored.lastBatchMinutes {
          latestBatch[botID] = max(latestBatch[botID] ?? 0, minutes)
        }
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
        isInFootprint: footprint.contains(index),
        isInLatestBatch: entry.stored.lastBatchMinutes != nil
          && entry.stored.lastBatchMinutes == latestBatch[entry.botID]
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

  /// The newest reading near a coordinate that is not the place on screen: the temperature and
  /// age each row of the Places sheet carries (docs/MESHWX_UI.md §12).
  ///
  /// The readings' own `distanceKilometres` are measured from the place on screen, so they say
  /// nothing about a saved place; this measures from the row's own coordinate. Only a reading
  /// carrying a temperature counts — a row with nothing to show says so rather than printing a
  /// bare degree sign.
  public static func nearestReading(
    in readings: [WeatherStationReading],
    to coordinate: MeshWXCoordinate,
    within kilometres: Double = WeatherPrimaryStation.maxDistanceKilometres
  ) -> (reading: WeatherStationReading, kilometres: Double)? {
    var best: (reading: WeatherStationReading, kilometres: Double)?
    for reading in readings where reading.stored.observation.tempF != nil {
      let distance = WeatherGeo.kilometres(
        coordinate, MeshWXCoordinate(latitude: reading.station.lat, longitude: reading.station.lon))
      guard distance <= kilometres else { continue }
      if let current = best,
         distance > current.kilometres
           || (distance == current.kilometres && reading.station.icao >= current.reading.station.icao) {
        continue
      }
      best = (reading, distance)
    }
    return best
  }

  /// The station the Now card is showing first, then the order above — distance from the place.
  /// The nearest reading is not always the one the card leads with: a nearer stale one sorts ahead
  /// of the fresh station `WeatherPrimaryStation.pick` chooses, and the list that opens from the
  /// card must not start with a different station from the one the card names.
  public static func ordered(
    _ readings: [WeatherStationReading],
    leading index: UInt16?
  ) -> [WeatherStationReading] {
    guard let index, let primary = readings.first(where: { $0.index == index }) else { return readings }
    return [primary] + readings.filter { $0.index != index }
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

  /// The station whose reading the card is showing, when it is showing one.
  public var index: UInt16? {
    switch self {
    case let .reading(reading): reading.index
    case .noneNearby, .noObservations, .noPlace: nil
    }
  }

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
